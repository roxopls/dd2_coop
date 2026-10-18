// DD2 Co-op: sincronização do jogador 2 pela rede.
//
// O que trafega, um pacote por frame:
//   * o estado do controle do jogador (campos de app.UserInput: flags de botão,
//     analógicos, gatilhos) — o mesmo dado do espelho em Lua, que move o jogador 2 certo;
//   * a direção (yaw) da câmera de quem envia: o movimento pelo analógico é relativo à
//     câmera, então quem recebe gira o analógico pela diferença entre as duas câmeras;
//   * a pose do jogador (posição universal + yaw), lida do Transform por pacote;
//     a pose enviada pelo Lua e usada como reserva se o Transform faltar.
//
// Fluxo:
//   * hook em app.UserInput.update(bool, bool):
//       - no input do player: depois do update, os campos são lidos e enviados;
//       - no input do jogador 2: o update é pulado e os campos recebem o próximo pacote
//         do buffer de reprodução (não lê o controle), com o analógico esquerdo girado.
//   * modos:
//       - eco: ISteamNetworkingSockets::CreateSocketPair com loopback de rede real;
//       - p2p: ISteamNetworkingMessages com o SteamID64 do amigo (relay da Steam, sem
//         abrir portas). Os dois lados enviam um para o outro, o que aceita a sessão.
//   * buffer de reprodução (jitter): começa a tocar quando junta `jitter` pacotes e
//     consome um por frame; vazio, mantem botoes sem repetir eventos de borda.
//     Depois de 500 ms sem dados, neutraliza o input e descarta a fila antiga.
//
// Ponte com o Lua (lenta, por arquivo, em reframework\data):
//   dd2coop_net_cfg.json    (Lua -> plugin) {"mode":"off|eco|p2p","peer":"<SteamID64>",
//                           "orig":<UserInput do player>,"clone":<UserInput do jogador 2>,
//                           "jitter":<frames>,"px","py","pz":<posição universal>,"pyaw":<yaw>}
//   dd2coop_net_status.json (plugin -> Lua) contadores, erro, SteamID local e a última
//                           pose recebida.

#include "net_sync.hpp"
#include "input_safety.hpp"
#include "motion_correction.hpp"
#include "save_io.hpp"

#include <windows.h>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

namespace net_sync {
namespace {

const REFrameworkPluginFunctions* g_ref = nullptr;
const REFrameworkSDKData* g_sdk = nullptr;
std::string g_dir;
char g_instance_id[64]{};
std::atomic<uint64_t> g_lua_epoch{0}, g_native_saves_blocked{0};
std::atomic<bool> g_save_locked{true}, g_lua_ready{false};
uint32_t g_save_hooks = 0;
thread_local bool t_save_skipped = false;

// ---------------------------------------------------------------------------------------
// Steam (API flat do steam_api64.dll do jogo)

using SteamIfaceFn = void* (*)();
using CreateSocketPairFn = bool (*)(void*, uint32_t*, uint32_t*, bool, const void*, const void*);
using SendToConnFn = int (*)(void*, uint32_t, const void*, uint32_t, int, int64_t*);
using RecvOnConnFn = int (*)(void*, uint32_t, void**, int);
using CloseConnFn = bool (*)(void*, uint32_t, int, const char*, bool);
using MsgReleaseFn = void (*)(void*);
using SendToUserFn = int (*)(void*, const void*, const void*, uint32_t, int, int);
using RecvOnChannelFn = int (*)(void*, int, void**, int);
using SetSteamId64Fn = void (*)(void*, uint64_t);
using InitRelayFn = void (*)(void*);
using GetSteamIdFn = uint64_t (*)(void*);

// SteamNetworkingMessage_t: só os dois primeiros campos interessam
struct SteamMsgHead {
    void* data;
    int size;
};

// SteamNetworkingIdentity: 136 bytes, preenchido por SetSteamID64
struct alignas(8) SteamIdentity {
    uint8_t raw[136];
};

constexpr int kSendReliableNoNagle = 8 | 1;
constexpr int kChannel = 7;

struct Steam {
    void* sockets = nullptr;
    void* messages = nullptr;
    void* utils = nullptr;
    CreateSocketPairFn create_pair = nullptr;
    SendToConnFn send = nullptr;
    RecvOnConnFn recv = nullptr;
    CloseConnFn close = nullptr;
    MsgReleaseFn release = nullptr;
    SendToUserFn send_user = nullptr;
    RecvOnChannelFn recv_channel = nullptr;
    SetSteamId64Fn set_id64 = nullptr;
    InitRelayFn init_relay = nullptr;
    uint64_t me = 0;
    uint32_t conn_a = 0;  // eco: ponta que envia
    uint32_t conn_b = 0;  // eco: ponta que recebe
} g_steam;

template <typename T>
T resolve(HMODULE mod, const char* name) {
    return reinterpret_cast<T>(reinterpret_cast<void*>(GetProcAddress(mod, name)));
}

bool steam_load() {
    if (g_steam.sockets) {
        return true;
    }
    HMODULE m = GetModuleHandleA("steam_api64.dll");
    if (!m) {
        return false;
    }
    auto sockets = resolve<SteamIfaceFn>(m, "SteamAPI_SteamNetworkingSockets_SteamAPI_v012");
    auto messages = resolve<SteamIfaceFn>(m, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002");
    auto utils = resolve<SteamIfaceFn>(m, "SteamAPI_SteamNetworkingUtils_SteamAPI_v004");
    auto user = resolve<SteamIfaceFn>(m, "SteamAPI_SteamUser_v021");
    auto get_id = resolve<GetSteamIdFn>(m, "SteamAPI_ISteamUser_GetSteamID");
    g_steam.create_pair = resolve<CreateSocketPairFn>(m, "SteamAPI_ISteamNetworkingSockets_CreateSocketPair");
    g_steam.send = resolve<SendToConnFn>(m, "SteamAPI_ISteamNetworkingSockets_SendMessageToConnection");
    g_steam.recv = resolve<RecvOnConnFn>(m, "SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection");
    g_steam.close = resolve<CloseConnFn>(m, "SteamAPI_ISteamNetworkingSockets_CloseConnection");
    g_steam.release = resolve<MsgReleaseFn>(m, "SteamAPI_SteamNetworkingMessage_t_Release");
    g_steam.send_user = resolve<SendToUserFn>(m, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser");
    g_steam.recv_channel = resolve<RecvOnChannelFn>(m, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel");
    g_steam.set_id64 = resolve<SetSteamId64Fn>(m, "SteamAPI_SteamNetworkingIdentity_SetSteamID64");
    g_steam.init_relay = resolve<InitRelayFn>(m, "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess");
    if (!sockets || !messages || !utils || !user || !get_id || !g_steam.create_pair || !g_steam.send ||
        !g_steam.recv || !g_steam.close || !g_steam.release || !g_steam.send_user || !g_steam.recv_channel ||
        !g_steam.set_id64 || !g_steam.init_relay) {
        return false;
    }
    g_steam.sockets = sockets();
    g_steam.messages = messages();
    g_steam.utils = utils();
    if (void* u = user()) {
        g_steam.me = get_id(u);
    }
    return g_steam.sockets && g_steam.messages && g_steam.utils;
}

// ---------------------------------------------------------------------------------------
// Campos de app.UserInput sincronizados (mesma lista do espelho em Lua)

const char* kFieldNames[] = {
    "ButtonOnFlags", "OldButtonOnFlags", "ButtonReleaseFlags", "ButtonTriggerFlags", "ButtonRepeatFlags",
    "ButtonOnFlagsForUI", "PadButtonDown", "PadButtonUp", "PadButton", "PadButtonRepeat",
    "_AxisL", "<AxisR>k__BackingField", "<AxisMagnitudeL>k__BackingField", "<AxisMagnitudeR>k__BackingField",
    "<AnalogL>k__BackingField", "<AnalogR>k__BackingField",
    "KeyboardMouseAxisL", "KeyboardMouseAxisR", "KeyboardMouseAnalogL", "KeyboardMouseAnalogR",
    "<IsMouseMovedInFrame>k__BackingField", "<IsPadAxisRMovedInFrame>k__BackingField",
};
// campos girados pela diferença de câmera (via.vec2: x lateral, y frente)
const char* kRotatedFields[] = { "_AxisL", "KeyboardMouseAxisL" };

struct Field {
    const char* name;
    uint32_t offset;
    uint32_t size;
    bool rotate;
    input_safety::Kind kind;
};
std::vector<Field> g_fields;
uint32_t g_payload_size = 0;

// Pacote v3: cabeçalho + hora do envio + câmera + pose + bytes dos campos na ordem de g_fields
#pragma pack(push, 1)
struct PacketHeader {
    uint32_t magic;       // 'DD2C'
    uint16_t version;     // 3
    uint16_t field_count;
    uint32_t seq;
    uint32_t payload_size;
    float cam_yaw;        // yaw da câmera de quem envia (rad)
    double px, py, pz;    // posição universal do jogador de quem envia
    float pyaw;           // yaw do jogador de quem envia (rad)
    uint8_t pose_valid;
    uint32_t t_ms;        // relógio de quem envia (ms), para reproduzir no ritmo dele
};
#pragma pack(pop)
constexpr uint32_t kMagic = 0x43324444;  // "DD2C"
constexpr uint16_t kVersion = 3;

bool resolve_fields() {
    g_fields.clear();
    g_payload_size = 0;
    auto tdb = g_sdk->functions->get_tdb();
    for (const char* n : kFieldNames) {
        auto f = g_sdk->tdb->find_field(tdb, "app.UserInput", n);
        if (!f) {
            g_ref->log_error("[dd2coop_net] campo nao achado: app.UserInput.%s", n);
            continue;
        }
        auto ft = g_sdk->field->get_type(f);
        uint32_t size = ft ? g_sdk->type_definition->get_valuetype_size(ft) : 0;
        if (size == 0 || size > 64) {
            g_ref->log_error("[dd2coop_net] tamanho estranho em %s: %u", n, size);
            continue;
        }
        bool rot = false;
        for (const char* r : kRotatedFields) rot = rot || std::strcmp(r, n) == 0;
        g_fields.push_back({ n, g_sdk->field->get_offset_from_base(f), size, rot && size == 8,
            input_safety::classify(n) });
        g_payload_size += size;
    }
    g_ref->log_info("[dd2coop_net] campos de input: %zu (%u bytes de dados por pacote)", g_fields.size(),
        g_payload_size);
    return !g_fields.empty();
}

// ---------------------------------------------------------------------------------------
// Câmera: yaw da câmera principal, por invocação de métodos do jogo
// via.SceneManager.get_MainView -> via.SceneView.get_PrimaryCamera -> get_GameObject ->
// get_Transform -> get_Rotation

struct CamMethods {
    REFrameworkMethodHandle main_view = nullptr, primary_camera = nullptr, game_object = nullptr,
                            transform = nullptr, rotation = nullptr, univ_get = nullptr, univ_set = nullptr,
                            rot_set = nullptr;
    bool ok = false;
} g_cam;

void resolve_camera() {
    auto tdb = g_sdk->functions->get_tdb();
    g_cam.main_view = g_sdk->tdb->find_method(tdb, "via.SceneManager", "get_MainView");
    g_cam.primary_camera = g_sdk->tdb->find_method(tdb, "via.SceneView", "get_PrimaryCamera");
    g_cam.game_object = g_sdk->tdb->find_method(tdb, "via.Component", "get_GameObject");
    g_cam.transform = g_sdk->tdb->find_method(tdb, "via.GameObject", "get_Transform");
    g_cam.rotation = g_sdk->tdb->find_method(tdb, "via.Transform", "get_Rotation");
    g_cam.univ_get = g_sdk->tdb->find_method(tdb, "via.Transform", "get_UniversalPosition");
    g_cam.univ_set = g_sdk->tdb->find_method(tdb, "via.Transform", "set_UniversalPosition");
    g_cam.rot_set = g_sdk->tdb->find_method(tdb, "via.Transform", "set_Rotation");
    if (!g_cam.univ_get || !g_cam.univ_set || !g_cam.rot_set) {
        g_ref->log_error("[dd2coop_net] metodos de pose do Transform nao achados");
    }
    g_cam.ok = g_cam.main_view && g_cam.primary_camera && g_cam.game_object && g_cam.transform && g_cam.rotation;
    if (!g_cam.ok) g_ref->log_error("[dd2coop_net] metodos da camera nao achados");
}

void* invoke_ptr(REFrameworkMethodHandle m, void* self) {
    if (!self) return nullptr;
    alignas(16) uint8_t out[256]{};
    if (g_sdk->method->invoke(m, self, nullptr, 0, out, sizeof(out)) != REFRAMEWORK_ERROR_NONE) return nullptr;
    void* p;
    std::memcpy(&p, out, sizeof(p));
    return p;
}

// yaw (rad) da frente de um quaternion: frente = rot * (0,0,dir_z)
float yaw_of(const float q[4], float dir_z) {
    float x = q[0], y = q[1], z = q[2], w = q[3];
    float fx = 2.0f * (x * z + w * y) * dir_z;
    float fz = (1.0f - 2.0f * (x * x + y * y)) * dir_z;
    return std::atan2(fx, fz);
}

bool camera_yaw(float& yaw) {
    if (!g_cam.ok) return false;
    void* sm = g_sdk->functions->get_native_singleton("via.SceneManager");
    void* view = invoke_ptr(g_cam.main_view, sm);
    void* cam = invoke_ptr(g_cam.primary_camera, view);
    void* go = invoke_ptr(g_cam.game_object, cam);
    void* xf = invoke_ptr(g_cam.transform, go);
    if (!xf) return false;
    alignas(16) uint8_t out[256]{};
    if (g_sdk->method->invoke(g_cam.rotation, xf, nullptr, 0, out, sizeof(out)) != REFRAMEWORK_ERROR_NONE) {
        return false;
    }
    float q[4];
    std::memcpy(q, out, sizeof(q));
    yaw = yaw_of(q, -1.0f);  // câmera olha para -Z local
    return true;
}

// ---------------------------------------------------------------------------------------
// Estado

struct Pose {
    double x = 0, y = 0, z = 0;
    float yaw = 0;
    bool valid = false;
};

struct PeerCfg {
    uint64_t id = 0;         // SteamID64 (0 no eco)
    uintptr_t clone = 0;     // app.UserInput da cópia dele (0 = ainda sem cópia: só envia)
    uintptr_t clone_xf = 0;  // via.Transform da cópia (lido para medir a deriva)
    uintptr_t clone_ch = 0;  // app.Character da cópia (warp quando a deriva passa de snap)
    bool operator==(const PeerCfg& o) const { return id == o.id && clone == o.clone; }
};

struct Config {
    std::string mode = "off";
    uintptr_t orig = 0;   // app.UserInput do player
    uintptr_t orig_xf = 0;   // via.Transform do player (pose enviada em todo pacote)
    PeerCfg peers[3];
    int peer_count = 0;
    double snap = 1.5;       // deriva (m) a partir da qual a cópia é puxada aos poucos
    double snap_far = 6.0;   // deriva (m) a partir da qual a cópia é teleportada de uma vez
    double nudge = 0.25;     // fração da deriva corrigida por passo (puxar aos poucos)
    int nudge_every = 4;     // quadros entre passos
    bool smooth_correction = true;
    bool echo_correction = false; // explicit local test, preserving the clone's initial offset
    int jitter = 6;
    Pose my_pose;         // pose do player escrita pelo Lua (reserva, se orig_xf faltar)
} g_cfg;

struct Stats {
    uint64_t sent = 0, received = 0, applied = 0, held = 0, bad = 0;
    uint64_t timeouts = 0, neutralized = 0;
    std::string error;
} g_stats;

struct Remote {
    std::vector<uint8_t> fields;
    float cam_yaw = 0;
    Pose pose;  // pose de quem enviou no mesmo instante do input
    uint32_t t_ms = 0;  // hora do envio no relógio de quem enviou
};

// pose de um via.Transform: posição universal (3 doubles) + yaw da frente (+Z local)
bool read_pose(uintptr_t xf, Pose& out) {
    if (!g_cam.univ_get || !g_cam.rotation) return false;
    alignas(16) uint8_t buf[256]{};
    auto self = reinterpret_cast<void*>(xf);
    if (g_sdk->method->invoke(g_cam.univ_get, self, nullptr, 0, buf, sizeof(buf)) != REFRAMEWORK_ERROR_NONE) {
        return false;
    }
    double p[3];
    std::memcpy(p, buf, sizeof(p));
    std::memset(buf, 0, sizeof(buf));
    if (g_sdk->method->invoke(g_cam.rotation, self, nullptr, 0, buf, sizeof(buf)) != REFRAMEWORK_ERROR_NONE) {
        return false;
    }
    float q[4];
    std::memcpy(q, buf, sizeof(q));
    out = Pose{ p[0], p[1], p[2], yaw_of(q, 1.0f), true };
    return true;
}

// põe um via.Transform na pose dada (posição universal + yaw)
bool write_pose(uintptr_t xf, const Pose& pose) {
    if (!g_cam.univ_set || !g_cam.rot_set) return false;
    auto self = reinterpret_cast<void*>(xf);
    alignas(16) uint8_t out[256]{};
    double p[3] = { pose.x, pose.y, pose.z };
    void* args_p[1] = { p };  // tipos de valor maiores que 8 bytes vão por ponteiro
    if (g_sdk->method->invoke(g_cam.univ_set, self, args_p, sizeof(args_p), out, sizeof(out)) !=
        REFRAMEWORK_ERROR_NONE) {
        return false;
    }
    float h = pose.yaw * 0.5f;
    alignas(16) float q[4] = { 0.0f, std::sin(h), 0.0f, std::cos(h) };  // x, y, z, w
    void* args_q[1] = { q };
    g_sdk->method->invoke(g_cam.rot_set, self, args_q, sizeof(args_q), out, sizeof(out));
    return true;
}

// Um slot por jogador remoto (até 3: sessão de 4; a 5ª Arisen trava o jogo, 2026-10-17).
// Cada um tem a própria fila, reprodução e cópia; o input chega pelo canal 7 e é separado
// pelo SteamID de quem mandou (no eco, tudo vai para o slot 0).
constexpr int kMaxSlots = 3;

struct Slot {
    uint64_t peer64 = 0;
    SteamIdentity ident{};
    uintptr_t clone = 0, clone_xf = 0, clone_ch = 0;  // UserInput, Transform e Character da cópia
    std::deque<Remote> buffer;
    Remote current;                 // último pacote aplicado (repetido se faltar)
    bool playing = false;
    input_safety::Watchdog watchdog;
    bool fresh_input = false;       // input edges are consumed once per packet
    Pose remote_pose;               // última pose recebida
    bool placed = false;            // cópia já foi posta na pose do jogador
    double drift = -1;              // distância entre a cópia e a pose do pacote aplicado
    uint64_t snaps = 0, nudges = 0, warp_fail = 0;
    int last_warp = -1000;          // quadro do último warp
    double correction_x = 0, correction_z = 0, last_root_ms = 0;
    uint64_t smooth_steps = 0, correction_suspended = 0;
    ULONGLONG jump_grace_until = 0, last_hard_warp_ms = 0;
    Pose echo_offset;
    double play_offset = 0;         // hora local - hora do remetente no ponto de reprodução
    double last_play_ms = 0;
    uint64_t received = 0, applied = 0, held = 0, timeouts = 0, neutralized = 0;

    void reset_playback() {
        buffer.clear(); current = Remote{}; playing = false; watchdog = {};
        fresh_input = false; remote_pose = Pose{}; placed = false;
        correction_x = correction_z = last_root_ms = 0;
        jump_grace_until = last_hard_warp_ms = 0;
        echo_offset = Pose{};
    }
};

std::mutex g_mtx;                 // slots: buffer, reprodução, pose remota
Slot g_slots[kMaxSlots];
int g_slot_count = 0;
uint32_t g_seq = 0;
thread_local uintptr_t t_capture = 0;
int g_frame = 0;
float g_my_cam_yaw = 0;           // yaw da câmera local, atualizado por frame

// relógio de alta resolução em ms desde a carga do plugin (GetTickCount64 anda em passos
// de ~16 ms; contar desde a carga mantém t_ms de 32 bits longe da volta de 49 dias)
double now_ms() {
    static const double inv = [] { LARGE_INTEGER f; QueryPerformanceFrequency(&f); return 1000.0 / f.QuadPart; }();
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    static const LONGLONG start = c.QuadPart;
    return (c.QuadPart - start) * inv;
}

// ---------------------------------------------------------------------------------------
// Ponte por arquivo

std::string read_file(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return {};
    std::string s;
    char buf[1024];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) s.append(buf, n);
    std::fclose(f);
    return s;
}

// extrator mínimo de JSON plano: "chave": "texto" ou "chave": número
std::string json_str(const std::string& s, const char* key) {
    auto k = s.find(std::string("\"") + key + "\"");
    if (k == std::string::npos) return {};
    auto c = s.find(':', k);
    auto q1 = s.find('"', c + 1);
    auto q2 = s.find('"', q1 + 1);
    if (c == std::string::npos || q1 == std::string::npos || q2 == std::string::npos) return {};
    return s.substr(q1 + 1, q2 - q1 - 1);
}

double json_num(const std::string& s, const char* key, double def) {
    auto k = s.find(std::string("\"") + key + "\"");
    if (k == std::string::npos) return def;
    auto c = s.find(':', k);
    if (c == std::string::npos) return def;
    return std::strtod(s.c_str() + c + 1, nullptr);
}

bool json_bool(const std::string& s, const char* key, bool fallback) {
    auto at = s.find(std::string("\"") + key + "\"");
    if (at == std::string::npos) return fallback;
    at = s.find(':', at);
    if (at == std::string::npos) return fallback;
    at = s.find_first_not_of(" \t\r\n", at + 1);
    if (at == std::string::npos) return fallback;
    const auto end = s.find_first_of(",} \t\r\n", at);
    const auto value = s.substr(at, end - at);
    return value == "true" ? true : value == "false" ? false : fallback;
}

bool current_lua_config(const std::string& s) {
    const auto last = s.find_last_not_of(" \t\r\n");
    if (last == std::string::npos || s[last] != '}' || json_str(s, "instance") != g_instance_id) return false;
    auto at = s.find("\"lua_epoch\"");
    if (at == std::string::npos) return false;
    at = s.find(':', at);
    if (at == std::string::npos) return false;
    at = s.find_first_not_of(" \t\r\n", at + 1);
    if (at == std::string::npos || s[at] < '0' || s[at] > '9') return false;
    char* end = nullptr;
    const auto epoch = std::strtoull(s.c_str() + at, &end, 10);
    return end && std::strchr(",} \t\r\n", *end) && epoch == g_lua_epoch.load();
}

void update_save_guard(const std::string& s) {
    // A file from another process/reset, a missing flag, or a partial write
    // cannot unlock saving. Native hooks survive Lua script resets.
    // Com o save co-op ativo o vanilla não é tocado: a cópia viva não bloqueia mais o save
    // (o que for gravado vai para win64_coop).
    // force_lock: cópias extras vivas (3+ Arisen). Um save co-op gravado com 3 cópias quebrou o
    // carregamento (2026-10-17); até validar, nem o save co-op grava com elas.
    g_save_locked = ((!current_lua_config(s) || json_bool(s, "save_lock", true)) && !save_io::coop_active()) ||
        (current_lua_config(s) && json_bool(s, "force_lock", false));
}

int pre_save(int, void**, REFrameworkTypeDefinitionHandle*, unsigned long long) {
    update_save_guard(read_file(g_dir + "dd2coop_net_cfg.json"));
    t_save_skipped = g_save_locked.load();
    if (!t_save_skipped) return REFRAMEWORK_HOOK_CALL_ORIGINAL;
    ++g_native_saves_blocked;
    return REFRAMEWORK_HOOK_SKIP_ORIGINAL;
}

void post_save(void** result, REFrameworkTypeDefinitionHandle, unsigned long long) {
    if (t_save_skipped && result) *result = nullptr;
    t_save_skipped = false;
}

void install_save_guard() {
    auto tdb = g_sdk->functions->get_tdb();
    for (const char* type : { "app.SaveDataManager", "app.MainFlowManager" }) {
        auto td = g_sdk->tdb->find_type(tdb, type);
        if (!td) continue;
        std::vector<REFrameworkMethodHandle> methods(g_sdk->type_definition->get_num_methods(td));
        unsigned int count = 0;
        if (g_sdk->type_definition->get_methods(td, methods.data(),
                static_cast<unsigned int>(methods.size() * sizeof(methods[0])), &count) != REFRAMEWORK_ERROR_NONE) continue;
        for (unsigned int i = 0; i < count && i < methods.size(); ++i) {
            const char* name = g_sdk->method->get_name(methods[i]);
            if (!name) continue;
            const bool main_flow = std::strcmp(type, "app.MainFlowManager") == 0;
            const bool target = main_flow ? std::strcmp(name, "requestSaveGameData") == 0 :
                std::strcmp(name, "requestSave") == 0 || std::strcmp(name, "requestSaveAuto") == 0 ||
                std::strcmp(name, "requestSaveManual") == 0 || std::strcmp(name, "requestSaveSlot") == 0;
            if (target) { g_sdk->functions->add_hook(methods[i], pre_save, post_save, false); ++g_save_hooks; }
        }
    }
    g_ref->log_info("[dd2coop_net] protecao nativa de save: %u hooks", g_save_hooks);
}

void close_links() {
    if (g_steam.conn_a) g_steam.close(g_steam.sockets, g_steam.conn_a, 0, "fim", false);
    if (g_steam.conn_b) g_steam.close(g_steam.sockets, g_steam.conn_b, 0, "fim", false);
    g_steam.conn_a = g_steam.conn_b = 0;
}

bool open_links() {
    if (!steam_load()) {
        g_stats.error = "API de rede da Steam indisponivel";
        return false;
    }
    if (g_cfg.mode == "eco") {
        if (g_steam.conn_a) return true;
        if (!g_steam.create_pair(g_steam.sockets, &g_steam.conn_a, &g_steam.conn_b, true, nullptr, nullptr)) {
            g_stats.error = "CreateSocketPair falhou";
            g_steam.conn_a = g_steam.conn_b = 0;
            return false;
        }
        g_ref->log_info("[dd2coop_net] eco: par de sockets criado (%u, %u)", g_steam.conn_a, g_steam.conn_b);
        return true;
    }
    if (g_cfg.mode == "p2p") {
        if (g_slot_count == 0) {
            g_stats.error = "nenhum jogador remoto";
            return false;
        }
        g_steam.init_relay(g_steam.utils);
        for (int i = 0; i < g_slot_count && i < kMaxSlots; ++i) {
            std::memset(&g_slots[i].ident, 0, sizeof(g_slots[i].ident));
            g_steam.set_id64(&g_slots[i].ident, g_slots[i].peer64);
            g_ref->log_info("[dd2coop_net] p2p: jogador %d = %llu", i, (unsigned long long)g_slots[i].peer64);
        }
        return true;
    }
    return false;
}

// Jogadores remotos: "peer_count" + "peer0".."peer2", "clone0", "clone_xf0", "clone_ch0"...
// Sem "peer_count" vale o formato antigo de um par ("peer", "clone", "clone_xf", "clone_ch").
int parse_peers(const std::string& s, PeerCfg* out) {
    const int n = static_cast<int>(json_num(s, "peer_count", -1));
    const bool legacy = n < 0;
    auto key = [&](const char* base, int i) {
        char k[32];
        if (legacy) std::snprintf(k, sizeof(k), "%s", base);
        else std::snprintf(k, sizeof(k), "%s%d", base, i);
        return std::string(k);
    };
    const int count = legacy ? (json_str(s, "peer").empty() && json_num(s, "clone", 0) == 0 ? 0 : 1) :
        (n > kMaxSlots ? kMaxSlots : n);
    for (int i = 0; i < count; ++i) {
        PeerCfg p;
        p.id = std::strtoull(json_str(s, key("peer", i).c_str()).c_str(), nullptr, 10);
        p.clone = static_cast<uintptr_t>(json_num(s, key("clone", i).c_str(), 0));
        p.clone_xf = static_cast<uintptr_t>(json_num(s, key("clone_xf", i).c_str(), 0));
        p.clone_ch = static_cast<uintptr_t>(json_num(s, key("clone_ch", i).c_str(), 0));
        out[i] = p;
    }
    return count;
}

void load_config() {
    auto s = read_file(g_dir + "dd2coop_net_cfg.json");
    if (s.empty()) return;
    Config c;
    c.mode = json_str(s, "mode");
    if (c.mode.empty()) c.mode = "off";
    c.orig = static_cast<uintptr_t>(json_num(s, "orig", 0));
    c.jitter = static_cast<int>(json_num(s, "jitter", 6));
    if (c.jitter < 1) c.jitter = 1;
    c.orig_xf = static_cast<uintptr_t>(json_num(s, "orig_xf", 0));
    c.peer_count = parse_peers(s, c.peers);
    c.snap = json_num(s, "snap", 1.5);
    c.snap_far = json_num(s, "snap_far", 6.0);
    c.nudge = json_num(s, "nudge", 0.25);
    c.nudge_every = static_cast<int>(json_num(s, "nudge_every", 4));
    c.smooth_correction = json_bool(s, "smooth_correction", true);
    c.echo_correction = json_bool(s, "echo_correction", false);
    if (c.nudge_every < 1) c.nudge_every = 1;
    c.my_pose.x = json_num(s, "px", 0);
    c.my_pose.y = json_num(s, "py", 0);
    c.my_pose.z = json_num(s, "pz", 0);
    c.my_pose.yaw = static_cast<float>(json_num(s, "pyaw", 0));
    c.my_pose.valid = s.find("\"px\"") != std::string::npos;
    const bool current = current_lua_config(s);
    update_save_guard(s);
    g_lua_ready = current;
    if (!current) { c.mode = "off"; c.orig = c.orig_xf = 0; c.peer_count = 0; }

    bool link_changed = c.mode != g_cfg.mode || c.orig != g_cfg.orig || c.peer_count != g_cfg.peer_count;
    for (int i = 0; !link_changed && i < c.peer_count; ++i) link_changed = !(c.peers[i] == g_cfg.peers[i]);
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        const bool mode_changed = c.mode != g_cfg.mode;
        if (link_changed) {
            // slot de cada jogador: mantém a fila de quem continua com a mesma cópia
            Slot old[kMaxSlots];
            const int old_count = g_slot_count;
            for (int i = 0; i < old_count; ++i) old[i] = std::move(g_slots[i]);
            for (int i = 0; i < c.peer_count; ++i) {
                Slot ns;
                for (int j = 0; j < old_count; ++j) {
                    if (!mode_changed && old[j].peer64 == c.peers[i].id && old[j].clone == c.peers[i].clone) {
                        ns = std::move(old[j]);
                    }
                }
                ns.peer64 = c.peers[i].id;
                ns.clone = c.peers[i].clone;
                std::memset(&ns.ident, 0, sizeof(ns.ident));
                if (ns.peer64 && g_steam.set_id64) g_steam.set_id64(&ns.ident, ns.peer64);
                g_slots[i] = std::move(ns);
            }
            for (int i = c.peer_count; i < kMaxSlots; ++i) g_slots[i] = Slot{};
            g_slot_count = c.peer_count;
        }
        for (int i = 0; i < c.peer_count; ++i) {
            if (c.echo_correction != g_cfg.echo_correction) {
                g_slots[i].echo_offset = Pose{};
                g_slots[i].correction_x = g_slots[i].correction_z = 0;
                g_slots[i].last_root_ms = 0;
            }
            g_slots[i].clone_xf = c.peers[i].clone_xf;
            g_slots[i].clone_ch = c.peers[i].clone_ch;
        }
        g_cfg = c;
        if (mode_changed) for (int i = 0; i < g_slot_count; ++i) g_slots[i].reset_playback();
    }
    if (link_changed) {
        g_ref->log_info("[dd2coop_net] modo=%s orig=%p jogadores=%d jitter=%d", g_cfg.mode.c_str(),
            reinterpret_cast<void*>(g_cfg.orig), g_slot_count, g_cfg.jitter);
        close_links();
        g_stats.error.clear();
        if (g_cfg.mode != "off") open_links();
    }
}

void prof_status(FILE* f);

const char* slot_state(const Slot& s, long long& age) {
    age = -1;
    if (!s.watchdog.seen()) return "waiting";
    age = static_cast<long long>(s.watchdog.age(GetTickCount64()));
    return s.watchdog.expired() ? "timeout" : s.playing ? "active" : "buffering";
}

// status: campos de topo = slot 0 (compatível com o Lua de um par) e "slots" com todos
void write_status() {
    if (g_steam.me == 0) steam_load();  // a Steam pode não estar pronta na carga do plugin
    FILE* f = std::fopen((g_dir + "dd2coop_net_status.json").c_str(), "w");
    if (!f) return;
    std::lock_guard<std::mutex> lk(g_mtx);
    static const Slot empty;
    const Slot& s0 = g_slot_count > 0 ? g_slots[0] : empty;
    long long rx_age_ms;
    const char* input_state = slot_state(s0, rx_age_ms);
    const Pose& rp = s0.remote_pose;
    std::fprintf(f,
        "{\"mode\":\"%s\",\"me\":\"%llu\",\"sent\":%llu,\"received\":%llu,\"applied\":%llu,\"held\":%llu,"
        "\"bad\":%llu,\"buffered\":%zu,\"bytes_per_packet\":%u,\"cam_yaw\":%.4f,\"remote_valid\":%s,"
        "\"rx\":%.4f,\"ry\":%.4f,\"rz\":%.4f,\"ryaw\":%.4f,\"drift\":%.3f,\"snaps\":%llu,\"warp_fail\":%llu,\"error\":\"%s\","
        "\"input_state\":\"%s\",\"rx_age_ms\":%lld,\"timeouts\":%llu,\"neutralized\":%llu,"
        "\"instance\":\"%s\",\"lua_epoch\":%llu,\"save_locked\":%s,\"native_saves_blocked\":%llu,\"save_hooks\":%u",
        g_cfg.mode.c_str(), (unsigned long long)g_steam.me, (unsigned long long)g_stats.sent,
        (unsigned long long)s0.received, (unsigned long long)s0.applied,
        (unsigned long long)s0.held, (unsigned long long)g_stats.bad, s0.buffer.size(),
        (unsigned)(sizeof(PacketHeader) + g_payload_size), g_my_cam_yaw, rp.valid ? "true" : "false", rp.x, rp.y,
        rp.z, rp.yaw, s0.drift, (unsigned long long)s0.snaps, (unsigned long long)s0.warp_fail, g_stats.error.c_str(),
        input_state, rx_age_ms, (unsigned long long)s0.timeouts, (unsigned long long)s0.neutralized,
        g_instance_id, (unsigned long long)g_lua_epoch.load(), g_save_locked ? "true" : "false",
        (unsigned long long)g_native_saves_blocked.load(), g_save_hooks);
    std::fprintf(f, ",\"slots\":[");
    for (int i = 0; i < g_slot_count; ++i) {
        const Slot& s = g_slots[i];
        long long age;
        const char* st = slot_state(s, age);
        std::fprintf(f, "%s{\"peer\":\"%llu\",\"input_state\":\"%s\",\"rx_age_ms\":%lld,\"received\":%llu,"
            "\"applied\":%llu,\"held\":%llu,\"buffered\":%zu,\"drift\":%.3f,\"snaps\":%llu,\"nudges\":%llu,\"warp_fail\":%llu,"
            "\"timeouts\":%llu,\"remote_valid\":%s,\"rx\":%.4f,\"ry\":%.4f,\"rz\":%.4f,"
            "\"smooth_steps\":%llu,\"correction_suspended\":%llu}",
            i ? "," : "", (unsigned long long)s.peer64, st, age, (unsigned long long)s.received,
            (unsigned long long)s.applied, (unsigned long long)s.held, s.buffer.size(), s.drift,
            (unsigned long long)s.snaps, (unsigned long long)s.nudges, (unsigned long long)s.warp_fail, (unsigned long long)s.timeouts,
            s.remote_pose.valid ? "true" : "false", s.remote_pose.x, s.remote_pose.y, s.remote_pose.z,
            (unsigned long long)s.smooth_steps, (unsigned long long)s.correction_suspended);
    }
    std::fprintf(f, "]");
    prof_status(f);
    std::fclose(f);
}

// ---------------------------------------------------------------------------------------
// Captura, envio, recepção e aplicação

void capture_and_send(uintptr_t input) {
    std::vector<uint8_t> pkt(sizeof(PacketHeader) + g_payload_size);
    PacketHeader h{};
    h.magic = kMagic;
    h.version = kVersion;
    h.field_count = static_cast<uint16_t>(g_fields.size());
    h.seq = g_seq++;
    h.payload_size = g_payload_size;
    h.cam_yaw = g_my_cam_yaw;
    Pose pose = g_cfg.my_pose;
    Pose now;
    if (g_cfg.orig_xf && read_pose(g_cfg.orig_xf, now)) pose = now;  // mesmo instante do input
    h.px = pose.x;
    h.py = pose.y;
    h.pz = pose.z;
    h.pyaw = pose.yaw;
    h.pose_valid = pose.valid ? 1 : 0;
    h.t_ms = static_cast<uint32_t>(now_ms());
    std::memcpy(pkt.data(), &h, sizeof(h));
    uint8_t* p = pkt.data() + sizeof(h);
    for (const auto& f : g_fields) {
        std::memcpy(p, reinterpret_cast<const void*>(input + f.offset), f.size);
        p += f.size;
    }
    int r = 0;
    bool any = false;
    if (g_cfg.mode == "eco" && g_steam.conn_a) {
        r = g_steam.send(g_steam.sockets, g_steam.conn_a, pkt.data(), static_cast<uint32_t>(pkt.size()),
            kSendReliableNoNagle, nullptr);
        any = true;
    } else if (g_cfg.mode == "p2p") {
        // malha: o input vai para todos os jogadores remotos (cada um tem a cópia deste)
        r = 1;
        for (int i = 0; i < g_slot_count; ++i) {
            if (!g_slots[i].peer64) continue;
            any = true;
            const int ri = g_steam.send_user(g_steam.messages, &g_slots[i].ident, pkt.data(),
                static_cast<uint32_t>(pkt.size()), kSendReliableNoNagle, kChannel);
            if (ri != 1) r = ri;
        }
    }
    if (!any) return;
    if (r == 1) {  // k_EResultOK
        ++g_stats.sent;
    } else {
        g_stats.error = "envio falhou: EResult " + std::to_string(r);
    }
}

void handle_packet(Slot& s, const void* data, int size) {
    bool ok = size >= static_cast<int>(sizeof(PacketHeader));
    PacketHeader h{};
    if (ok) {
        std::memcpy(&h, data, sizeof(h));
        ok = h.magic == kMagic && h.version == kVersion && h.payload_size == g_payload_size &&
             size == static_cast<int>(sizeof(PacketHeader) + g_payload_size);
    }
    if (!ok) {
        ++g_stats.bad;
        return;
    }
    const auto* b = static_cast<const uint8_t*>(data) + sizeof(PacketHeader);
    std::lock_guard<std::mutex> lk(g_mtx);
    s.watchdog.received(GetTickCount64());
    Remote r;
    r.fields.assign(b, b + g_payload_size);
    r.cam_yaw = h.cam_yaw;
    r.t_ms = h.t_ms;
    if (h.pose_valid) r.pose = Pose{ h.px, h.py, h.pz, h.pyaw, true };
    s.buffer.push_back(std::move(r));
    while (s.buffer.size() > 240) s.buffer.pop_front();  // não acumula se travar
    if (h.pose_valid) s.remote_pose = Pose{ h.px, h.py, h.pz, h.pyaw, true };
    ++s.received;
}

// SteamNetworkingMessage_t: m_identityPeer em +16; tipo (16 = SteamID) e SteamID64 em +8 dele
uint64_t msg_sender(const void* m) {
    const auto* raw = static_cast<const uint8_t*>(m);
    int32_t type;
    uint64_t sender;
    std::memcpy(&type, raw + 16, sizeof(type));
    std::memcpy(&sender, raw + 24, sizeof(sender));
    return type == 16 ? sender : 0;
}

Slot* slot_of(uint64_t sender) {
    for (int i = 0; i < g_slot_count; ++i) {
        if (sender && g_slots[i].peer64 == sender) return &g_slots[i];
    }
    return nullptr;
}

void receive_all() {
    void* msgs[64];
    int n = 0;
    const bool eco = g_cfg.mode == "eco";
    if (eco && g_steam.conn_b) {
        n = g_steam.recv(g_steam.sockets, g_steam.conn_b, msgs, 64);
    } else if (g_cfg.mode == "p2p") {
        n = g_steam.recv_channel(g_steam.messages, kChannel, msgs, 64);
    }
    for (int i = 0; i < n; ++i) {
        auto* m = static_cast<SteamMsgHead*>(msgs[i]);
        Slot* s = eco ? (g_slot_count > 0 ? &g_slots[0] : nullptr) : slot_of(msg_sender(msgs[i]));
        if (s) handle_packet(*s, m->data, m->size);
        else ++g_stats.bad;  // de quem não está na sessão
        g_steam.release(msgs[i]);
    }
}

void merge_remote(Remote& acc, const Remote& newer) {
    size_t at = 0;
    for (const auto& f : g_fields) {
        input_safety::merge_field(f.kind, acc.fields.data() + at, newer.fields.data() + at, f.size);
        at += f.size;
    }
    acc.cam_yaw = newer.cam_yaw;
    acc.pose = newer.pose;
    acc.t_ms = newer.t_ms;
}

// Reprodução no relógio de quem enviou: começa quando o buffer junta `jitter` pacotes
// (esse é o atraso inicial) e, a cada frame local, toca todos os pacotes cuja hora de envio
// já passou. Remetente com FPS maior: vários pacotes num frame, com bordas somadas.
// Remetente com FPS menor: frames sem pacote mantêm o último sem repetir bordas.
// Fila longa demais (atraso crescendo) acelera 25% até voltar; fila vazia atrasa 1 ms.
void advance_playback(Slot& s) {
    std::lock_guard<std::mutex> lk(g_mtx);
    if (s.watchdog.expire(GetTickCount64())) {
        s.buffer.clear();
        s.current = Remote{};
        s.playing = false;
        s.fresh_input = false;
        s.remote_pose = Pose{};
        s.placed = false;
        ++s.timeouts;
    }
    const double now = now_ms();
    if (!s.playing && static_cast<int>(s.buffer.size()) >= g_cfg.jitter) {
        s.playing = true;
        s.play_offset = now - s.buffer.front().t_ms;
        s.last_play_ms = now;
    }
    if (!s.playing) return;
    if (static_cast<int>(s.buffer.size()) > 3 * g_cfg.jitter) s.play_offset -= (now - s.last_play_ms) * 0.25;
    s.last_play_ms = now;
    const double due = now - s.play_offset;  // hora do remetente que deve estar tocando agora
    bool took = false;
    while (!s.buffer.empty() && s.buffer.front().t_ms <= due) {
        if (!took && !s.fresh_input) s.current = std::move(s.buffer.front());
        else merge_remote(s.current, s.buffer.front());  // bordas ainda não aplicadas se somam
        s.buffer.pop_front();
        took = true;
    }
    if (took) {
        s.fresh_input = true;
    } else {
        ++s.held;  // sem pacote vencido: mantém o último
        if (s.buffer.empty()) s.play_offset += 1.0;
    }
}

// gira um analógico (x direita, y frente) da câmera de quem enviou para a câmera local.
// Direção no mundo (plano XZ): x * direita + y * frente, com frente = (sin a, cos a) e
// direita = frente x cima = (-cos a, sin a) (Y para cima, câmera olhando para -Z local).
// O sinal da direita precisa ser o do jogo: com (cos a, -sin a), usado no 1º teste, o
// movimento saía espelhado e o jogador 2 ia para o lugar errado.
void rotate_stick(float* v, float from_yaw, float to_yaw) {
    float sf = std::sin(from_yaw), cf = std::cos(from_yaw);
    float wx = -v[0] * cf + v[1] * sf;
    float wz = v[0] * sf + v[1] * cf;
    float st = std::sin(to_yaw), ct = std::cos(to_yaw);
    v[0] = -wx * ct + wz * st;
    v[1] = wx * st + wz * ct;
}

void apply_to(Slot& s, uintptr_t input) {
    std::lock_guard<std::mutex> lk(g_mtx);
    const bool neutral = !g_lua_ready || !s.playing || s.watchdog.expired() ||
        s.current.fields.size() != g_payload_size;
    const auto mode = neutral ? input_safety::Mode::Neutral :
        s.fresh_input ? input_safety::Mode::Fresh : input_safety::Mode::Hold;
    // Read the last actually applied state before writing any field. On timeout,
    // release held buttons once; subsequent neutral updates contain no edges.
    uint64_t previous_buttons = 0, previous_pad = 0;
    for (const auto& f : g_fields) {
        uint64_t* value = std::strcmp(f.name, "ButtonOnFlags") == 0 ? &previous_buttons :
            std::strcmp(f.name, "PadButton") == 0 ? &previous_pad : nullptr;
        if (value) std::memcpy(value, reinterpret_cast<const void*>(input + f.offset),
            f.size < sizeof(*value) ? f.size : sizeof(*value));
    }
    const uint8_t* p = s.current.fields.data();
    for (const auto& f : g_fields) {
        auto* dst = reinterpret_cast<uint8_t*>(input + f.offset);
        input_safety::apply_field(f.kind, dst, neutral ? nullptr : p, f.size, mode,
            previous_buttons, previous_pad);
        if (f.rotate && !neutral) {
            float v[2];
            std::memcpy(v, dst, sizeof(v));
            rotate_stick(v, s.current.cam_yaw, g_my_cam_yaw);
            std::memcpy(dst, v, sizeof(v));
        }
        if (!neutral) p += f.size;
    }
    s.fresh_input = false;
    if (neutral) { ++s.neutralized; return; }
    ++s.applied;
}

// ---------------------------------------------------------------------------------------
// Hooks em app.UserInput.update(bool, bool)

int pre_update(int argc, void** argv, REFrameworkTypeDefinitionHandle*, unsigned long long) {
    if (argc < 2 || g_cfg.mode == "off") return REFRAMEWORK_HOOK_CALL_ORIGINAL;
    auto self = reinterpret_cast<uintptr_t>(argv[1]);
    if (self == 0) return REFRAMEWORK_HOOK_CALL_ORIGINAL;
    for (int i = 0; i < g_slot_count; ++i) {
        if (g_slots[i].clone && self == g_slots[i].clone) {
            apply_to(g_slots[i], self);
            return REFRAMEWORK_HOOK_SKIP_ORIGINAL;
        }
    }
    if (self == g_cfg.orig && g_lua_ready) t_capture = self;
    return REFRAMEWORK_HOOK_CALL_ORIGINAL;
}

void post_update(void**, REFrameworkTypeDefinitionHandle, unsigned long long) {
    if (t_capture != 0) {
        capture_and_send(t_capture);
        t_capture = 0;
    }
}

// app.Character.warp(via.Position, via.Quaternion, app.CharacterWarpOption): o teleporte do
// jogo. Escrever no Transform (write_pose) não move o personagem: o CharacterController
// devolve a posição dele no quadro seguinte (2026-10-16: drift fixo em 106 m e reposição em
// todo quadro deixavam o jogador 2 "preso no chão").
REFrameworkMethodHandle g_warp = nullptr;

void resolve_warp() {
    auto tdb = g_sdk->functions->get_tdb();
    auto td = g_sdk->tdb->find_type(tdb, "app.Character");
    if (!td) return;
    std::vector<REFrameworkMethodHandle> methods(g_sdk->type_definition->get_num_methods(td));
    unsigned int count = 0;
    if (g_sdk->type_definition->get_methods(td, methods.data(),
            static_cast<unsigned int>(methods.size() * sizeof(methods[0])), &count) != REFRAMEWORK_ERROR_NONE) return;
    for (unsigned int i = 0; i < count && i < methods.size(); ++i) {
        const char* name = g_sdk->method->get_name(methods[i]);
        if (!name || std::strcmp(name, "warp") != 0 || g_sdk->method->get_num_params(methods[i]) != 3) continue;
        REFrameworkMethodParameter params[3]{};
        unsigned int n = 0;
        if (g_sdk->method->get_params(methods[i], params, sizeof(params), &n) != REFRAMEWORK_ERROR_NONE || n != 3) continue;
        char t0[128]{}, t1[128]{};
        unsigned int l = 0;
        g_sdk->type_definition->get_full_name(params[0].t, t0, sizeof(t0), &l);
        g_sdk->type_definition->get_full_name(params[1].t, t1, sizeof(t1), &l);
        if (std::strcmp(t0, "via.Position") == 0 && std::strcmp(t1, "via.Quaternion") == 0) { g_warp = methods[i]; return; }
    }
}

bool warp_clone(uintptr_t ch, const Pose& pose) {
    if (!g_warp || !ch) return false;
    alignas(16) uint8_t out[256]{};  // >= InvokeRet (129 bytes); com 64 o invoke recusava e nunca reposicionava
    double p[3] = { pose.x, pose.y, pose.z };
    const float h = pose.yaw * 0.5f;
    alignas(16) float q[4] = { 0.0f, std::sin(h), 0.0f, std::cos(h) };  // x, y, z, w
    void* args[3] = { p, q, nullptr };  // valores > 8 bytes por ponteiro; opção (classe) nula
    return g_sdk->method->invoke(g_warp, reinterpret_cast<void*>(ch), args, sizeof(args), out, sizeof(out)) ==
        REFRAMEWORK_ERROR_NONE;
}

struct MotionMethods {
    REFrameworkMethodHandle ground = nullptr, jumping = nullptr, catcher = nullptr,
        caught = nullptr, catch_active = nullptr, caught_active = nullptr;
    bool ready = false;
} g_motion;

bool invoke_bool(REFrameworkMethodHandle m, void* self, bool& result) {
    if (!m || !self) return false;
    alignas(16) uint8_t out[256]{};
    if (g_sdk->method->invoke(m, self, nullptr, 0, out, sizeof(out)) != REFRAMEWORK_ERROR_NONE) return false;
    result = out[0] != 0;
    return true;
}

bool correction_mode() {
    return g_cfg.mode == "p2p" || (g_cfg.mode == "eco" && g_cfg.echo_correction);
}

bool correction_safe(uintptr_t character) {
    if (!g_motion.ready || !character) return false;
    auto ch = reinterpret_cast<void*>(character);
    bool ground = false, jumping = true, carrying = true, caught = true;
    if (!invoke_bool(g_motion.ground, ch, ground) || !ground ||
            !invoke_bool(g_motion.jumping, ch, jumping) || jumping) return false;
    void* catcher = invoke_ptr(g_motion.catcher, ch);
    void* caught_controller = invoke_ptr(g_motion.caught, ch);
    return invoke_bool(g_motion.catch_active, catcher, carrying) && !carrying &&
        invoke_bool(g_motion.caught_active, caught_controller, caught) && !caught;
}

int pre_root_motion(int argc, void** argv, REFrameworkTypeDefinitionHandle*, unsigned long long) {
    if (argc < 4 || !argv[2] || !g_lua_ready || !correction_mode() || !g_cfg.smooth_correction)
        return REFRAMEWORK_HOOK_CALL_ORIGINAL;
    const auto character = reinterpret_cast<uintptr_t>(argv[1]);
    for (int i = 0; i < g_slot_count; ++i) {
        Slot& s = g_slots[i];
        if (!character || character != s.clone_ch) continue;
        const double now = now_ms();
        double dx, dz, elapsed;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            elapsed = s.last_root_ms > 0 ? (now - s.last_root_ms) / 1000.0 : 0;
            s.last_root_ms = now;
            if (!s.playing || s.watchdog.expired() || GetTickCount64() < s.jump_grace_until) break;
            dx = s.correction_x; dz = s.correction_z;
        }
        const auto step = motion_correction::step(dx, dz, elapsed);
        if ((step.x == 0 && step.z == 0) || !correction_safe(character)) break;
        float root[3];
        std::memcpy(root, argv[2], sizeof(root));
        if (!std::isfinite(root[0]) || !std::isfinite(root[1]) || !std::isfinite(root[2])) break;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            if (!g_lua_ready || !s.playing || s.watchdog.expired() ||
                    (s.correction_x == 0 && s.correction_z == 0)) break;
            root[0] += step.x; root[2] += step.z;
            std::memcpy(argv[2], root, sizeof(root)); // preserve root height and the quaternion argument
            ++s.smooth_steps;
        }
        break;
    }
    return REFRAMEWORK_HOOK_CALL_ORIGINAL;
}

void resolve_motion() {
    auto tdb = g_sdk->functions->get_tdb();
    auto find = [&](const char* type, const char* method) { return g_sdk->tdb->find_method(tdb, type, method); };
    g_motion.ground = find("app.Character", "get_IsGround");
    g_motion.jumping = find("app.Character", "get_IsJumpCtrlActive");
    g_motion.catcher = find("app.Character", "get_CatchController");
    g_motion.caught = find("app.Character", "get_CaughtController");
    g_motion.catch_active = find("app.CatchController", "get_IsActive");
    g_motion.caught_active = find("app.CaughtController", "get_IsActive");
    auto root = find("app.Character", "onRootApply");
    if (!root || g_sdk->method->get_num_params(root) != 2 || !g_motion.ground || !g_motion.jumping ||
            !g_motion.catcher || !g_motion.caught || !g_motion.catch_active || !g_motion.caught_active) {
        g_ref->log_error("[dd2coop_net] motion methods unavailable; position correction suspended");
        return;
    }
    auto hook = g_sdk->functions->add_hook(root, pre_root_motion, nullptr, false);
    g_motion.ready = hook != 0;
    if (!g_motion.ready) g_ref->log_error("[dd2coop_net] root motion hook unavailable; position correction suspended");
}

bool pending_jump(const Slot& s) {
    if (!s.fresh_input || s.current.fields.size() != g_payload_size) return false;
    size_t at = 0;
    for (const auto& f : g_fields) {
        if (std::strcmp(f.name, "ButtonTriggerFlags") == 0) {
            uint64_t flags = 0;
            std::memcpy(&flags, s.current.fields.data() + at, std::min<size_t>(f.size, sizeof(flags)));
            return (flags & (uint64_t{1} << 3)) != 0; // reflected CharacterInput.Action.Jump
        }
        at += f.size;
    }
    return false;
}

// Track the pose of the SAME packet as the input. Normal drift is corrected in
// onRootApply, not by short teleports. Warp is reserved for initial/far placement.
void correct_clone(Slot& s) {
    if (!correction_mode() || !s.clone_xf || !g_lua_ready) return;
    const ULONGLONG now = GetTickCount64();
    Pose target;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        s.correction_x = s.correction_z = 0;
        if (!s.playing || s.watchdog.expired() || !s.current.pose.valid) return;
        if (pending_jump(s)) s.jump_grace_until = now + 200;
        target = s.current.pose;
    }
    Pose cur;
    if (!read_pose(s.clone_xf, cur)) return;
    if (g_cfg.mode == "eco") {
        if (!s.echo_offset.valid) {
            s.echo_offset = Pose{cur.x - target.x, cur.y - target.y, cur.z - target.z, 0, true};
            s.placed = true; // never put the echo body on top of the original
        }
        target.x += s.echo_offset.x; target.y += s.echo_offset.y; target.z += s.echo_offset.z;
    }
    double dx = cur.x - target.x, dy = cur.y - target.y, dz = cur.z - target.z;
    s.drift = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (!std::isfinite(s.drift)) return;
    if (now < s.jump_grace_until || !correction_safe(s.clone_ch)) {
        ++s.correction_suspended;
        return;
    }
    const bool hard = !s.placed || s.drift >= g_cfg.snap_far;
    if (!hard && g_cfg.smooth_correction) {
        std::lock_guard<std::mutex> lk(g_mtx);
        s.correction_x = -dx; s.correction_z = -dz;
        return;
    }
    if (!hard && s.drift < g_cfg.snap) return;
    if (hard && s.placed && now - s.last_hard_warp_ms < 333) return;
    if (!hard && g_frame - s.last_warp < g_cfg.nudge_every) return;
    Pose to = target;
    if (!hard) {
        to.x = cur.x - dx * g_cfg.nudge;
        to.y = cur.y - dy * g_cfg.nudge;
        to.z = cur.z - dz * g_cfg.nudge;
    }
    if (warp_clone(s.clone_ch, to)) {
        s.placed = true;
        s.last_warp = g_frame;
        if (hard) s.last_hard_warp_ms = now;
        if (hard) ++s.snaps; else ++s.nudges;
    } else if (++s.warp_fail == 1) {
        g_ref->log_error("[dd2coop_net] warp da copia recusado (ch=%llx)", (unsigned long long)s.clone_ch);
    }
}


// ---------------------------------------------------------------------------------------
// Troca de perfil (aparência completa + vocação/armas), independente do modo de input:
// o perfil do amigo precisa chegar ANTES de criar o jogador 2.
//   dd2coop_profile_req.json (Lua -> plugin) {"id":<n>,"mode":"eco|p2p","peer":"<SteamID64>"}
//       id novo: lê dd2coop_profile_out.json e envia pelo canal 8 (confiável), reenviando
//       a cada 2 s até a confirmação (máx. 30 tentativas).
//   dd2coop_peer_profile.json (plugin -> Lua) último perfil recebido, já conferido (tamanho,
//       hash, remetente = SteamID configurado). O Lua valida o conteúdo antes de usar.
// Eco usa um par de sockets próprio, para testar o caminho completo num PC só.

constexpr int kProfileChannel = 8;
constexpr uint32_t kProfMagic = 0x50324444;  // "DD2P"
constexpr uint16_t kProfVersion = 1;
constexpr size_t kProfMax = 256 * 1024;
constexpr int kProfTries = 30;
constexpr int kSendReliable = 8;

#pragma pack(push, 1)
struct ProfHeader {
    uint32_t magic;
    uint16_t version;
    uint8_t kind;  // 0 dados, 1 confirmação
    uint8_t pad;
    uint32_t id;
    uint32_t size;
    uint32_t hash;
};
#pragma pack(pop)

struct PeerTx {
    uint64_t id = 0;
    SteamIdentity ident{};
    bool acked = false;
};

// "peers":"id1,id2,id3" (ou o antigo "peer":"id")
std::vector<PeerTx> parse_peer_list(const std::string& s) {
    std::string list = json_str(s, "peers");
    if (list.empty()) list = json_str(s, "peer");
    std::vector<PeerTx> out;
    const char* p = list.c_str();
    while (*p) {
        char* end = nullptr;
        const uint64_t id = std::strtoull(p, &end, 10);
        if (end == p) { ++p; continue; }
        if (id && out.size() < static_cast<size_t>(kMaxSlots)) {
            PeerTx t;
            t.id = id;
            g_steam.set_id64(&t.ident, id);
            out.push_back(t);
        }
        p = end;
    }
    return out;
}

struct ProfState {
    double req_id = -1;
    std::string mode;
    std::vector<PeerTx> peers;
    uint32_t pa = 0, pb = 0;  // eco
    std::string payload;
    uint32_t send_id = 0, hash = 0;
    bool done = true;         // todos confirmaram (ou desistiu)
    int tries = 0;
    ULONGLONG next = 0;
    uint64_t sent = 0, received = 0, rejected = 0;
    uint32_t rx_hash = 0;     // último recebido (de qualquer um)
    std::vector<std::pair<uint64_t, uint32_t>> rx_hashes;  // por remetente
    std::string error;
} g_prof;

struct BusState {
    const char* out;   // Lua -> plugin
    const char* in;    // plugin -> Lua (o mais recente de qualquer um; por remetente: <in>_<id>.json)
    int channel;
    int poll;          // lê o arquivo de saída a cada N quadros
    double seq = -1;
    std::string mode;
    std::vector<PeerTx> peers;
    uint64_t sent = 0, received = 0, rejected = 0;
};
// mundo (2 s, horário/clima/quests/vida) e inimigos (~10 Hz, estado do host)
BusState g_bus{ "dd2coop_bus_out.json", "dd2coop_bus_in", 9, 10 };
BusState g_enemy_bus{ "dd2coop_enemy_out.json", "dd2coop_enemy_in", 10, 3 };

bool all_acked() {
    for (const auto& p : g_prof.peers) if (!p.acked) return false;
    return true;
}

void prof_status(FILE* f) {
    std::fprintf(f, ",\"prof_req\":%.0f,\"prof_sent\":%llu,\"prof_acked\":%s,\"prof_received\":%llu,"
        "\"prof_rx_hash\":%u,\"prof_rejected\":%llu,\"prof_error\":\"%s\",\"bus_sent\":%llu,\"bus_received\":%llu,"
        "\"bus_rejected\":%llu,\"enemy_sent\":%llu,\"enemy_received\":%llu,\"enemy_rejected\":%llu,\"prof_peers\":[",
        g_prof.req_id, (unsigned long long)g_prof.sent,
        g_prof.error.empty() && g_prof.sent && (g_prof.mode == "eco" ? g_prof.done : all_acked()) ? "true" : "false",
        (unsigned long long)g_prof.received, g_prof.rx_hash, (unsigned long long)g_prof.rejected, g_prof.error.c_str(),
        (unsigned long long)g_bus.sent, (unsigned long long)g_bus.received, (unsigned long long)g_bus.rejected,
        (unsigned long long)g_enemy_bus.sent, (unsigned long long)g_enemy_bus.received, (unsigned long long)g_enemy_bus.rejected);
    for (size_t i = 0; i < g_prof.peers.size(); ++i) {
        std::fprintf(f, "%s{\"peer\":\"%llu\",\"acked\":%s}", i ? "," : "", (unsigned long long)g_prof.peers[i].id,
            g_prof.peers[i].acked ? "true" : "false");
    }
    std::fprintf(f, "]}");
}

uint32_t fnv1a(const void* data, size_t n) {
    uint32_t h = 2166136261u;
    const auto* p = static_cast<const uint8_t*>(data);
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 16777619u; }
    return h;
}

bool write_atomic(const std::string& path, const char* data, size_t n) {
    const std::string tmp = path + ".tmp";
    FILE* f = std::fopen(tmp.c_str(), "wb");
    if (!f) return false;
    const bool ok = std::fwrite(data, 1, n, f) == n;
    std::fclose(f);
    return ok && MoveFileExA(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
}

// eco: dados por pa, confirmações por pb. p2p: para o SteamID dado (to == nullptr: ninguém)
bool prof_send_raw(const ProfHeader& h, const std::string* body, const SteamIdentity* to) {
    std::vector<uint8_t> buf(sizeof(h) + (body ? body->size() : 0));
    std::memcpy(buf.data(), &h, sizeof(h));
    if (body) std::memcpy(buf.data() + sizeof(h), body->data(), body->size());
    int r = 0;
    if (g_prof.mode == "eco") {
        uint32_t conn = h.kind == 0 ? g_prof.pa : g_prof.pb;
        if (!conn) return false;
        r = g_steam.send(g_steam.sockets, conn, buf.data(), static_cast<uint32_t>(buf.size()), kSendReliable, nullptr);
    } else if (g_prof.mode == "p2p" && to) {
        r = g_steam.send_user(g_steam.messages, to, buf.data(), static_cast<uint32_t>(buf.size()),
            kSendReliable, kProfileChannel);
    }
    if (r != 1) g_prof.error = "envio do perfil falhou: EResult " + std::to_string(r);
    return r == 1;
}

void prof_request() {
    auto s = read_file(g_dir + "dd2coop_profile_req.json");
    if (s.empty()) return;
    double id = json_num(s, "id", -1);
    if (id < 0 || id == g_prof.req_id) return;
    g_prof.req_id = id;
    g_prof.error.clear();
    if (!steam_load()) { g_prof.error = "API de rede da Steam indisponivel"; return; }
    g_prof.mode = json_str(s, "mode");
    g_prof.peers.clear();
    if (g_prof.mode == "eco") {
        if (!g_prof.pa && !g_steam.create_pair(g_steam.sockets, &g_prof.pa, &g_prof.pb, true, nullptr, nullptr)) {
            g_prof.pa = g_prof.pb = 0;
            g_prof.error = "CreateSocketPair do perfil falhou";
            return;
        }
    } else if (g_prof.mode == "p2p") {
        g_prof.peers = parse_peer_list(s);
        if (g_prof.peers.empty()) { g_prof.error = "SteamID do amigo invalido"; return; }
        g_steam.init_relay(g_steam.utils);
    } else {
        g_prof.error = "modo de envio do perfil invalido";
        return;
    }
    std::string body = read_file(g_dir + "dd2coop_profile_out.json");
    if (body.empty() || body.size() > kProfMax || body[0] != '{') {
        g_prof.error = "dd2coop_profile_out.json ausente ou grande demais";
        return;
    }
    g_prof.payload = std::move(body);
    g_prof.send_id = static_cast<uint32_t>(GetTickCount64());
    g_prof.hash = fnv1a(g_prof.payload.data(), g_prof.payload.size());
    g_prof.done = false;
    g_prof.tries = 0;
    g_prof.next = 0;
    g_ref->log_info("[dd2coop_net] perfil: enviando %zu bytes (%s, %zu jogadores)", g_prof.payload.size(),
        g_prof.mode.c_str(), g_prof.peers.size());
}

void prof_handle(const SteamMsgHead* m, uint64_t sender, bool eco) {
    PeerTx* from = nullptr;
    if (!eco) {
        for (auto& p : g_prof.peers) if (p.id == sender) from = &p;
        // perfil de quem ainda não está na lista de envio (entrou agora) também vale; só a
        // confirmação precisa de um destino conhecido
        if (!sender) { ++g_prof.rejected; return; }
    }
    if (m->size < static_cast<int>(sizeof(ProfHeader))) { ++g_prof.rejected; return; }
    ProfHeader h;
    std::memcpy(&h, m->data, sizeof(h));
    if (h.magic != kProfMagic || h.version != kProfVersion) { ++g_prof.rejected; return; }
    const char* body = static_cast<const char*>(m->data) + sizeof(h);
    const size_t n = static_cast<size_t>(m->size) - sizeof(h);
    if (h.kind == 1) {
        if (h.id == g_prof.send_id && h.hash == g_prof.hash) {
            if (eco) g_prof.done = true;
            else if (from && !from->acked) {
                from->acked = true;
                g_ref->log_info("[dd2coop_net] perfil: %llu confirmou", (unsigned long long)sender);
            }
        }
        return;
    }
    if (h.kind != 0 || n != h.size || n == 0 || n > kProfMax || body[0] != '{' || fnv1a(body, n) != h.hash) {
        ++g_prof.rejected;
        return;
    }
    uint32_t* last = nullptr;
    for (auto& e : g_prof.rx_hashes) if (e.first == sender) last = &e.second;
    if (!last) { g_prof.rx_hashes.push_back({ sender, 0 }); last = &g_prof.rx_hashes.back().second; }
    if (h.hash != *last) {
        char name[64];
        std::snprintf(name, sizeof(name), "dd2coop_peer_profile_%llu.json", (unsigned long long)sender);
        if (!write_atomic(g_dir + name, body, n) ||
                !write_atomic(g_dir + "dd2coop_peer_profile.json", body, n)) {
            g_prof.error = "falha ao gravar perfil recebido";
            return;
        }
        *last = h.hash;
        g_prof.rx_hash = h.hash;
        ++g_prof.received;
        g_ref->log_info("[dd2coop_net] perfil: recebido %zu bytes de %llu", n, (unsigned long long)sender);
    }
    ProfHeader ack = h;
    ack.kind = 1;
    ack.size = 0;
    // confirma também reenvios, direto para quem mandou
    SteamIdentity to{};
    if (!eco) g_steam.set_id64(&to, sender);
    prof_send_raw(ack, nullptr, eco ? nullptr : &to);
}

void prof_pump() {
    if (!g_steam.sockets) return;
    void* msgs[16];
    if (g_prof.mode == "eco") {
        for (uint32_t conn : { g_prof.pb, g_prof.pa }) {
            if (!conn) continue;
            int n = g_steam.recv(g_steam.sockets, conn, msgs, 16);
            for (int i = 0; i < n; ++i) { prof_handle(static_cast<SteamMsgHead*>(msgs[i]), 0, true); g_steam.release(msgs[i]); }
        }
    } else {
        int n = g_steam.recv_channel(g_steam.messages, kProfileChannel, msgs, 16);
        for (int i = 0; i < n; ++i) {
            prof_handle(static_cast<SteamMsgHead*>(msgs[i]), msg_sender(msgs[i]), false);
            g_steam.release(msgs[i]);
        }
    }
    if (g_prof.done || g_prof.payload.empty()) return;
    if (g_prof.mode == "p2p" && all_acked()) { g_prof.done = true; return; }
    const ULONGLONG now = GetTickCount64();
    if (now < g_prof.next) return;
    if (g_prof.tries >= kProfTries) {
        g_prof.done = true;  // desiste; um novo pedido recomeça
        g_prof.error = "jogador nao confirmou o perfil";
        return;
    }
    ProfHeader h{ kProfMagic, kProfVersion, 0, 0, g_prof.send_id,
        static_cast<uint32_t>(g_prof.payload.size()), g_prof.hash };
    bool any = false;
    if (g_prof.mode == "eco") {
        any = prof_send_raw(h, &g_prof.payload, nullptr);
    } else {
        for (auto& p : g_prof.peers) if (!p.acked && prof_send_raw(h, &g_prof.payload, &p.ident)) any = true;
    }
    if (any) ++g_prof.sent;
    ++g_prof.tries;
    g_prof.next = now + 2000;
}

// ---------------------------------------------------------------------------------------
// Barramentos (canal 9: mundo; canal 10: personagens). O conteúdo é JSON escrito e lido pelo Lua.
//   <out> (Lua -> plugin) {"seq":<n>,"mode":"eco|p2p","peers":"<id>,<id>","msgs":[...]}
//       seq novo: envia o arquivo inteiro a cada jogador da lista (confiável). eco: grava
//       direto na entrada.
//   <in>_<SteamID>.json (plugin -> Lua) último arquivo recebido de cada jogador; <in>.json,
//       o último de qualquer um (formato antigo, um par). Eco grava <in>_0.json e <in>.json.
// Só aceita de quem está na lista de jogadores do próprio <out> (ou do perfil/barramento do mundo).
constexpr size_t kBusMax = 64 * 1024;

void bus_write_in(const BusState& b, uint64_t sender, const char* data, size_t n) {
    char name[64];
    std::snprintf(name, sizeof(name), "%s_%llu.json", b.in, (unsigned long long)sender);
    write_atomic(g_dir + name, data, n);
    write_atomic(g_dir + b.in + ".json", data, n);
}

void bus_pump(BusState& b) {
    if (!g_steam.sockets) return;
    if (g_frame % b.poll == 0) {
        std::string s = read_file(g_dir + b.out);
        const double seq = s.empty() ? -1 : json_num(s, "seq", -1);
        if (seq >= 0 && seq != b.seq && s.size() <= kBusMax && s[0] == '{') {
            b.seq = seq;
            b.mode = json_str(s, "mode");
            auto peers = parse_peer_list(s);
            if (!peers.empty()) b.peers = std::move(peers);
            if (b.mode == "eco") {
                bus_write_in(b, 0, s.data(), s.size());
                ++b.sent; ++b.received;
            } else if (b.mode == "p2p") {
                bool any = false;
                for (const auto& p : b.peers) {
                    if (g_steam.send_user(g_steam.messages, &p.ident, s.data(), static_cast<uint32_t>(s.size()),
                            kSendReliable, b.channel) == 1) any = true;
                }
                if (any) ++b.sent;
            }
        }
    }
    void* msgs[16];
    const int n = g_steam.recv_channel(g_steam.messages, b.channel, msgs, 16);
    // vários na fila: só o último de cada remetente importa (estado; eventos se repetem)
    for (int i = 0; i < n; ++i) {
        auto* m = static_cast<SteamMsgHead*>(msgs[i]);
        const uint64_t sender = msg_sender(msgs[i]);
        const auto* body = static_cast<const char*>(m->data);
        // quem só recebe (cliente no barramento de inimigos) não escreve <out> e fica sem lista:
        // vale também quem está na sessão pelo perfil ou pelo barramento do mundo
        bool known = false;
        for (const auto* list : { &b.peers, &g_bus.peers, &g_prof.peers })
            for (const auto& p : *list) known = known || (sender && p.id == sender);
        bool newest = true;
        for (int j = i + 1; j < n; ++j) newest = newest && msg_sender(msgs[j]) != sender;
        if (!known || m->size <= 0 || static_cast<size_t>(m->size) > kBusMax || body[0] != '{') {
            ++b.rejected;
        } else {
            if (newest) bus_write_in(b, sender, body, static_cast<size_t>(m->size));
            ++b.received;
        }
        g_steam.release(msgs[i]);
    }
}

void on_update_behavior() {
    ++g_frame;
    if (g_frame % 30 == 0) prof_request();
    prof_pump();
    bus_pump(g_bus);
    bus_pump(g_enemy_bus);
    if (g_frame % 30 == 0 || !g_lua_ready) load_config();
    if (g_cfg.mode != "off") {
        float y;
        if (camera_yaw(y)) g_my_cam_yaw = y;
        receive_all();
        for (int i = 0; i < g_slot_count; ++i) {
            advance_playback(g_slots[i]);
            correct_clone(g_slots[i]);
        }
    }
    if (g_frame % 30 == 0) write_status();
}

void on_lua_destroyed(lua_State*) {
    g_save_locked = true;
    g_lua_ready = false;
    ++g_lua_epoch;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        for (int i = 0; i < g_slot_count; ++i) g_slots[i].reset_playback();
    }
    write_status();
}

}  // namespace

void init(const REFrameworkPluginInitializeParam* param) {
    g_ref = param->functions;
    g_sdk = param->sdk;
    char exe[MAX_PATH];
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    g_dir = exe;
    g_dir = g_dir.substr(0, g_dir.find_last_of("\\/")) + "\\reframework\\data\\";
    std::snprintf(g_instance_id, sizeof(g_instance_id), "%lu_%llu",
        GetCurrentProcessId(), (unsigned long long)GetTickCount64());

    // endereços de uma sessão anterior seriam memória inválida: começa sempre desligado
    if (FILE* f = std::fopen((g_dir + "dd2coop_net_cfg.json").c_str(), "w")) {
        std::fprintf(f, "{\"mode\":\"off\",\"save_lock\":true,\"instance\":\"%s\",\"lua_epoch\":0}", g_instance_id);
        std::fclose(f);
    }
    install_save_guard();
    // pedido de envio de perfil deixado pela execução anterior não é reenviado na carga
    g_prof.req_id = json_num(read_file(g_dir + "dd2coop_profile_req.json"), "id", -1);
    g_ref->on_lua_state_destroyed(on_lua_destroyed);
    write_status();

    if (!resolve_fields()) {
        g_ref->log_error("[dd2coop_net] sem campos de input; sincronizacao desligada");
        return;
    }
    resolve_camera();
    resolve_warp();
    resolve_motion();
    if (!g_warp) g_ref->log_error("[dd2coop_net] app.Character.warp nao achado; jogador 2 sem reposicao");
    auto tdb = g_sdk->functions->get_tdb();
    auto m = g_sdk->tdb->find_method(tdb, "app.UserInput", "update");
    if (!m) {
        g_ref->log_error("[dd2coop_net] app.UserInput.update nao achado");
        return;
    }
    g_sdk->functions->add_hook(m, pre_update, post_update, false);
    g_ref->on_pre_application_entry("UpdateBehavior", on_update_behavior);
    if (steam_load()) {
        g_ref->log_info("[dd2coop_net] sincronizacao pronta (hook em app.UserInput.update)");
    }
}

}  // namespace net_sync
