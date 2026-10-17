// DD2 Co-op: plugin de rede (REFramework, API C).
// Etapa 0: prova que o toolchain MinGW gera um plugin que o REFramework carrega
// e que a API do Steam já inicializada pelo jogo responde (SteamID, nome, AppID,
// interface SteamNetworkingMessages). Também grava a lista de todos os tipos do TDB.

#include <windows.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "reframework/API.h"
#include "net_sync.hpp"
#include "save_io.hpp"
#include "lobby.hpp"

namespace {

const REFrameworkPluginFunctions* g_ref = nullptr;
const REFrameworkSDKData* g_sdk = nullptr;
int g_frames = 0;
bool g_probed = false;

// API "flat" do Steam: funções C exportadas pelo steam_api64.dll do jogo.
using SteamIfaceFn = void* (*)();
using GetSteamIdFn = uint64_t (*)(void*);
using GetPersonaNameFn = const char* (*)(void*);
using GetAppIdFn = uint32_t (*)(void*);
using IsSteamRunningFn = bool (*)();

template <typename T>
T resolve(HMODULE mod, const char* name) {
    return reinterpret_cast<T>(reinterpret_cast<void*>(GetProcAddress(mod, name)));
}

void probe_steam() {
    HMODULE steam = GetModuleHandleA("steam_api64.dll");
    if (steam == nullptr) {
        g_ref->log_error("[dd2coop_net] steam_api64.dll nao carregado");
        return;
    }
    auto is_running = resolve<IsSteamRunningFn>(steam, "SteamAPI_IsSteamRunning");
    auto user_v021 = resolve<SteamIfaceFn>(steam, "SteamAPI_SteamUser_v021");
    auto friends_v017 = resolve<SteamIfaceFn>(steam, "SteamAPI_SteamFriends_v017");
    auto utils_v010 = resolve<SteamIfaceFn>(steam, "SteamAPI_SteamUtils_v010");
    auto msgs_v002 = resolve<SteamIfaceFn>(steam, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002");
    auto get_id = resolve<GetSteamIdFn>(steam, "SteamAPI_ISteamUser_GetSteamID");
    auto get_name = resolve<GetPersonaNameFn>(steam, "SteamAPI_ISteamFriends_GetPersonaName");
    auto get_app = resolve<GetAppIdFn>(steam, "SteamAPI_ISteamUtils_GetAppID");

    if (!is_running || !user_v021 || !friends_v017 || !utils_v010 || !msgs_v002 || !get_id || !get_name
        || !get_app) {
        g_ref->log_error("[dd2coop_net] faltam exports do Steam");
        return;
    }

    void* user = user_v021();
    void* friends = friends_v017();
    void* utils = utils_v010();
    void* msgs = msgs_v002();
    g_ref->log_info("[dd2coop_net] Steam rodando=%d user=%p friends=%p utils=%p messages=%p",
        is_running() ? 1 : 0, user, friends, utils, msgs);
    if (user && friends && utils) {
        // O SteamID vai para o log local do jogo; não sai do PC.
        g_ref->log_info("[dd2coop_net] SteamID=%llu nome=%s AppID=%u",
            static_cast<unsigned long long>(get_id(user)), get_name(friends), get_app(utils));
    }
}

std::string type_name(REFrameworkTypeDefinitionHandle t) {
    if (t == nullptr) {
        return "?";
    }
    char buf[1024];
    unsigned int len = 0;
    if (g_sdk->type_definition->get_full_name(t, buf, sizeof(buf), &len) != REFRAMEWORK_ERROR_NONE) {
        return "?";
    }
    return std::string(buf, len);
}

// Grava reframework\data\dd2coop_all_types.txt (todos os tipos do TDB, com o pai) e
// dd2coop_singletons.txt (singletons gerenciados e nativos). O Lua do REFramework não
// enumera o TDB; daqui a lista inteira fica disponível para busca fora do jogo.
void dump_types() {
    char exe[MAX_PATH];
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    std::string dir(exe);
    dir = dir.substr(0, dir.find_last_of("\\/")) + "\\reframework\\data\\";
    CreateDirectoryA(dir.c_str(), nullptr);

    const auto* tdb_fns = g_sdk->tdb;
    auto tdb = g_sdk->functions->get_tdb();
    const unsigned int n = tdb_fns->get_num_types(tdb);
    FILE* f = std::fopen((dir + "dd2coop_all_types.txt").c_str(), "w");
    if (f == nullptr) {
        g_ref->log_error("[dd2coop_net] nao abriu dd2coop_all_types.txt");
        return;
    }
    for (unsigned int i = 0; i < n; ++i) {
        auto t = tdb_fns->get_type(tdb, i);
        if (t == nullptr) {
            continue;
        }
        const auto* td = g_sdk->type_definition;
        std::fprintf(f, "%s : %s  [m=%u f=%u]\n", type_name(t).c_str(), type_name(td->get_parent_type(t)).c_str(),
            td->get_num_methods(t), td->get_num_fields(t));
    }
    std::fclose(f);

    FILE* s = std::fopen((dir + "dd2coop_singletons.txt").c_str(), "w");
    if (s != nullptr) {
        std::vector<REFrameworkManagedSingleton> ms(4096);
        unsigned int count = 0;
        if (g_sdk->functions->get_managed_singletons(ms.data(), unsigned(ms.size() * sizeof(ms[0])), &count)
            == REFRAMEWORK_ERROR_NONE) {
            for (unsigned int i = 0; i < count; ++i) {
                std::fprintf(s, "managed %s\n", type_name(ms[i].t).c_str());
            }
        }
        std::vector<REFrameworkNativeSingleton> ns(4096);
        count = 0;
        if (g_sdk->functions->get_native_singletons(ns.data(), unsigned(ns.size() * sizeof(ns[0])), &count)
            == REFRAMEWORK_ERROR_NONE) {
            for (unsigned int i = 0; i < count; ++i) {
                std::fprintf(s, "native %s\n", ns[i].name ? ns[i].name : type_name(ns[i].t).c_str());
            }
        }
        std::fclose(s);
    }
    g_ref->log_info("[dd2coop_net] tipos gravados: %u", n);
}

// Grava reframework\data\dd2coop_method_rva.txt: "RVA tipo::metodo" de cada método com
// código, ordenado por endereço. Serve para traduzir o endereço de um crash que o
// REFramework não capturou (ex.: evento do Windows "DD2.exe+0xa9d605") no método que o
// contém: o maior RVA <= endereço.
void dump_method_rvas() {
    char exe[MAX_PATH];
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    std::string dir(exe);
    dir = dir.substr(0, dir.find_last_of("\\/")) + "\\reframework\\data\\";
    const auto base = reinterpret_cast<uintptr_t>(GetModuleHandleA(nullptr));

    const auto* tdb_fns = g_sdk->tdb;
    const auto* mfn = g_sdk->method;
    auto tdb = g_sdk->functions->get_tdb();
    const unsigned int n = tdb_fns->get_num_methods(tdb);

    struct Entry {
        uintptr_t rva;
        REFrameworkMethodHandle m;
    };
    std::vector<Entry> entries;
    entries.reserve(n);
    for (unsigned int i = 0; i < n; ++i) {
        auto m = tdb_fns->get_method(tdb, i);
        if (m == nullptr) {
            continue;
        }
        const auto fn = reinterpret_cast<uintptr_t>(mfn->get_function(m));
        if (fn <= base || fn - base > 0x40000000) {
            continue;
        }
        entries.push_back({ fn - base, m });
    }
    std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) { return a.rva < b.rva; });

    FILE* f = std::fopen((dir + "dd2coop_method_rva.txt").c_str(), "w");
    if (f == nullptr) {
        return;
    }
    for (const auto& e : entries) {
        const char* name = mfn->get_name(e.m);
        std::fprintf(f, "%08llx %s::%s\n", static_cast<unsigned long long>(e.rva),
            type_name(mfn->get_declaring_type(e.m)).c_str(), name ? name : "?");
    }
    std::fclose(f);
    g_ref->log_info("[dd2coop_net] metodos com endereco gravados: %zu", entries.size());
}

void on_present() {
    save_io::poll();  // engata no ISteamRemoteStorage assim que a Steam estiver de pé
    // Espera o jogo terminar de subir o Steam antes de consultar.
    if (g_probed || ++g_frames < 300) {
        return;
    }
    g_probed = true;
    probe_steam();
    // listas de tipos e de métodos: só se ainda não existirem (pesam na abertura do jogo)
    char exe[MAX_PATH];
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    std::string data(exe);
    data = data.substr(0, data.find_last_of("\\/")) + "\\reframework\\data\\";
    if (GetFileAttributesA((data + "dd2coop_all_types.txt").c_str()) == INVALID_FILE_ATTRIBUTES) {
        dump_types();
    }
    if (GetFileAttributesA((data + "dd2coop_method_rva.txt").c_str()) == INVALID_FILE_ATTRIBUTES) {
        dump_method_rvas();
    }
}

} // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* version) {
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    version->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
    version->game_name = "DD2";
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    g_ref = param->functions;
    g_sdk = param->sdk;
    g_ref->log_info("[dd2coop_net] carregado (REFramework plugin API %d.%d.%d)", param->version->major,
        param->version->minor, param->version->patch);
    g_ref->on_present(on_present);
    net_sync::init(param);
    {
        char exe[MAX_PATH];
        GetModuleFileNameA(nullptr, exe, MAX_PATH);
        std::string dir = exe;
        const std::string data_dir = dir.substr(0, dir.find_last_of("\\/")) + "\\reframework\\data\\";
        save_io::init(param, data_dir);
        lobby::init(param, data_dir);
    }
    return true;
}
