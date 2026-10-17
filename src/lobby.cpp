// DD2 Co-op: sessão por lobby da Steam (host/cliente).
//
// Host: cria um lobby só para amigos, grava a versão do protocolo ("dd2coop_ver") e é o dono
// (o dono do lobby é o host da sessão). Cliente: acha o lobby do amigo pelo jogo que ele está
// jogando (ISteamFriends::GetFriendGamePlayed -> m_steamIDLobby), entra e confere a versão;
// versão diferente sai do lobby. Sem callbacks registrados: as chamadas assíncronas da Steam
// (CreateLobby, JoinLobby) são acompanhadas por IsAPICallCompleted/GetAPICallResult.
//
// Ponte (reframework\data):
//   dd2coop_lobby_req.json    (Lua -> plugin) {"id":<n>,"action":"host|join|leave","friend":"<SteamID64>"}
//   dd2coop_lobby_status.json (plugin -> Lua) papel, lobby, dono, membros, versão e erro.

#include "lobby.hpp"

#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace lobby {
namespace {

constexpr const char* kVersion = "5";  // até 4 jogadores (slots, perfis e barramentos por SteamID); igual em todos
constexpr int kLobbyCreated = 513;     // LobbyCreated_t::k_iCallback
constexpr int kLobbyEnter = 504;       // LobbyEnter_t::k_iCallback
constexpr int kFriendsOnly = 1;        // k_ELobbyTypeFriendsOnly
constexpr int kMaxMembers = 4;

#pragma pack(push, 8)
struct LobbyCreated { int32_t result; uint64_t lobby; };
struct LobbyEnter { uint64_t lobby; uint32_t permissions; bool locked; uint32_t response; };
struct FriendGameInfo { uint64_t game; uint32_t ip; uint16_t port, query_port; uint64_t lobby; };
#pragma pack(pop)

using Iface = void* (*)();
struct Api {
    void* mm = nullptr; void* utils = nullptr; void* friends = nullptr;
    uint64_t (*create)(void*, int, int) = nullptr;
    uint64_t (*join)(void*, uint64_t) = nullptr;
    void (*leave)(void*, uint64_t) = nullptr;
    int (*num_members)(void*, uint64_t) = nullptr;
    uint64_t (*member)(void*, uint64_t, int) = nullptr;
    uint64_t (*owner)(void*, uint64_t) = nullptr;
    bool (*set_data)(void*, uint64_t, const char*, const char*) = nullptr;
    const char* (*get_data)(void*, uint64_t, const char*) = nullptr;
    bool (*completed)(void*, uint64_t, bool*) = nullptr;
    bool (*result)(void*, uint64_t, void*, int, int, bool*) = nullptr;
    bool (*friend_game)(void*, uint64_t, FriendGameInfo*) = nullptr;
    const char* (*friend_name)(void*, uint64_t) = nullptr;
} g;

const REFrameworkPluginFunctions* g_ref = nullptr;
std::string g_dir;
double g_req_id = -1;
std::string g_role = "nenhum";  // nenhum | criando | entrando | host | cliente
uint64_t g_lobby = 0, g_call = 0, g_me = 0;
std::string g_error;
int g_frame = 0;

template <typename T>
bool bind(HMODULE m, T& fn, const char* name) {
    fn = reinterpret_cast<T>(reinterpret_cast<void*>(GetProcAddress(m, name)));
    return fn != nullptr;
}

bool load() {
    if (g.mm) return true;
    HMODULE m = GetModuleHandleA("steam_api64.dll");
    if (!m) return false;
    Iface mm, utils, friends, user;
    uint64_t (*get_id)(void*) = nullptr;
    bool ok = bind(m, mm, "SteamAPI_SteamMatchmaking_v009") && bind(m, utils, "SteamAPI_SteamUtils_v010") &&
        bind(m, friends, "SteamAPI_SteamFriends_v017") && bind(m, user, "SteamAPI_SteamUser_v021") &&
        bind(m, get_id, "SteamAPI_ISteamUser_GetSteamID") &&
        bind(m, g.create, "SteamAPI_ISteamMatchmaking_CreateLobby") && bind(m, g.join, "SteamAPI_ISteamMatchmaking_JoinLobby") &&
        bind(m, g.leave, "SteamAPI_ISteamMatchmaking_LeaveLobby") &&
        bind(m, g.num_members, "SteamAPI_ISteamMatchmaking_GetNumLobbyMembers") &&
        bind(m, g.member, "SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex") &&
        bind(m, g.owner, "SteamAPI_ISteamMatchmaking_GetLobbyOwner") &&
        bind(m, g.set_data, "SteamAPI_ISteamMatchmaking_SetLobbyData") &&
        bind(m, g.get_data, "SteamAPI_ISteamMatchmaking_GetLobbyData") &&
        bind(m, g.completed, "SteamAPI_ISteamUtils_IsAPICallCompleted") &&
        bind(m, g.result, "SteamAPI_ISteamUtils_GetAPICallResult") &&
        bind(m, g.friend_game, "SteamAPI_ISteamFriends_GetFriendGamePlayed") &&
        bind(m, g.friend_name, "SteamAPI_ISteamFriends_GetFriendPersonaName");
    if (!ok) return false;
    void* u = user();
    g.mm = mm(); g.utils = utils(); g.friends = friends();
    if (!g.mm || !g.utils || !g.friends || !u) { g.mm = nullptr; return false; }
    g_me = get_id(u);
    return true;
}

std::string read_file(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return {};
    std::string s;
    char buf[512];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) s.append(buf, n);
    std::fclose(f);
    return s;
}

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
    return c == std::string::npos ? def : std::strtod(s.c_str() + c + 1, nullptr);
}

// nomes de amigos podem ter aspas/barras; o status é JSON
std::string escape(const char* s) {
    std::string out;
    for (; s && *s; ++s) {
        const unsigned char c = static_cast<unsigned char>(*s);
        if (c == '"' || c == '\\') { out += '\\'; out += static_cast<char>(c); }
        else if (c >= 0x20) out += static_cast<char>(c);
    }
    return out;
}

void leave_lobby() {
    if (g_lobby && g.leave) g.leave(g.mm, g_lobby);
    g_lobby = 0;
    g_call = 0;
    g_role = "nenhum";
}

void request() {
    auto s = read_file(g_dir + "dd2coop_lobby_req.json");
    if (s.empty()) return;
    const double id = json_num(s, "id", -1);
    if (id < 0 || id == g_req_id) return;
    g_req_id = id;
    g_error.clear();
    if (!load()) { g_error = "API da Steam indisponivel"; return; }
    const std::string action = json_str(s, "action");
    if (action == "leave") { leave_lobby(); return; }
    if (g_lobby || g_call) { g_error = "ja esta numa sessao; saia antes"; return; }
    if (action == "host") {
        g_call = g.create(g.mm, kFriendsOnly, kMaxMembers);
        g_role = "criando";
    } else if (action == "join") {
        const uint64_t fr = std::strtoull(json_str(s, "friend").c_str(), nullptr, 10);
        FriendGameInfo info{};
        if (!fr || !g.friend_game(g.friends, fr, &info)) { g_error = "amigo nao esta jogando"; return; }
        if (!info.lobby) { g_error = "amigo nao esta hospedando uma sessao"; return; }
        g_call = g.join(g.mm, info.lobby);
        g_role = "entrando";
    } else {
        g_error = "acao desconhecida";
        return;
    }
    if (!g_call) { g_error = "a Steam recusou o pedido"; g_role = "nenhum"; }
}

void poll_call() {
    if (!g_call) return;
    bool failed = false;
    if (!g.completed(g.utils, g_call, &failed)) return;
    if (g_role == "criando") {
        LobbyCreated r{};
        const bool ok = !failed && g.result(g.utils, g_call, &r, sizeof(r), kLobbyCreated, &failed) && !failed;
        g_call = 0;
        if (!ok || r.result != 1 || !r.lobby) { g_error = "falha ao criar a sessao"; g_role = "nenhum"; return; }
        g_lobby = r.lobby;
        g_role = "host";
        g.set_data(g.mm, g_lobby, "dd2coop_ver", kVersion);
        g_ref->log_info("[dd2coop_net] lobby: sessao criada %llu", (unsigned long long)g_lobby);
    } else if (g_role == "entrando") {
        LobbyEnter r{};
        const bool ok = !failed && g.result(g.utils, g_call, &r, sizeof(r), kLobbyEnter, &failed) && !failed;
        g_call = 0;
        if (!ok || r.response != 1 || !r.lobby) { g_error = "falha ao entrar na sessao"; g_role = "nenhum"; return; }
        g_lobby = r.lobby;
        const char* ver = g.get_data(g.mm, g_lobby, "dd2coop_ver");
        if (!ver || std::strcmp(ver, kVersion) != 0) {
            g_error = std::string("versao diferente do host (host ") + (ver && *ver ? ver : "?") + ", sua " + kVersion + ")";
            leave_lobby();
            return;
        }
        g_role = "cliente";
        g_ref->log_info("[dd2coop_net] lobby: entrou na sessao %llu", (unsigned long long)g_lobby);
    }
}

void write_status() {
    FILE* f = std::fopen((g_dir + "dd2coop_lobby_status.json").c_str(), "w");
    if (!f) return;
    std::fprintf(f, "{\"role\":\"%s\",\"lobby\":\"%llu\",\"me\":\"%llu\",\"version\":\"%s\",\"error\":\"%s\",\"req\":%.0f",
        g_role.c_str(), (unsigned long long)g_lobby, (unsigned long long)g_me, kVersion, escape(g_error.c_str()).c_str(), g_req_id);
    if (g_lobby) {
        std::fprintf(f, ",\"owner\":\"%llu\",\"members\":[", (unsigned long long)g.owner(g.mm, g_lobby));
        const int n = g.num_members(g.mm, g_lobby);
        for (int i = 0; i < n; ++i) {
            const uint64_t id = g.member(g.mm, g_lobby, i);
            std::fprintf(f, "%s{\"id\":\"%llu\",\"name\":\"%s\"}", i ? "," : "", (unsigned long long)id,
                escape(g.friend_name(g.friends, id)).c_str());
        }
        std::fprintf(f, "]");
    }
    std::fprintf(f, "}");
    std::fclose(f);
}

void on_update() {
    ++g_frame;
    if (g_frame % 30 == 0) request();
    poll_call();
    if (g_frame % 30 == 0) write_status();
}

}  // namespace

void init(const REFrameworkPluginInitializeParam* param, const std::string& data_dir) {
    g_ref = param->functions;
    g_dir = data_dir;
    // pedido deixado pela execução anterior não é refeito na carga
    g_req_id = json_num(read_file(g_dir + "dd2coop_lobby_req.json"), "id", -1);
    g_ref->on_pre_application_entry("UpdateBehavior", on_update);
}

}  // namespace lobby
