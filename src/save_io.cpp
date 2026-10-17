// DD2 Co-op: reconhecimento do I/O de save (passo 1 do save isolado do co-op).
//
// Só observa: troca, na tabela de importação do DD2.exe, as funções de arquivo do kernel32
// por versões que registram o caminho quando ele passa pela pasta de saves da Steam
// ("win64_save") e chamam a original. Nada é redirecionado nem alterado.
// Registro: reframework\data\dd2coop_save_io.txt (no máximo 2000 linhas por execução).
//
// Próximo passo (ainda não implementado): com o modo co-op ligado, redirecionar esses
// caminhos para uma pasta própria do mod, fora da pasta sincronizada pela Steam Cloud.

#include "save_io.hpp"

#include <windows.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>

namespace save_io {
namespace {

const REFrameworkPluginFunctions* g_ref = nullptr;
std::string g_log_path;
std::mutex g_log_mtx;
std::atomic<int> g_lines{0};
constexpr int kMaxLines = 2000;

bool interesting(const wchar_t* path) {
    return path && std::wcsstr(path, L"win64_save") != nullptr;
}

void note(const char* op, const wchar_t* a, const wchar_t* b, unsigned long detail, unsigned long result) {
    if (!interesting(a) && !interesting(b)) return;
    if (g_lines.fetch_add(1) >= kMaxLines) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    std::lock_guard<std::mutex> lk(g_log_mtx);
    FILE* f = std::fopen(g_log_path.c_str(), "a");
    if (!f) return;
    std::fprintf(f, "%02d:%02d:%02d.%03d tid=%lu %s detail=0x%lX result=0x%lX %ls%s%ls\n",
        t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, GetCurrentThreadId(), op, detail, result,
        a ? a : L"", b ? L" -> " : L"", b ? b : L"");
    std::fclose(f);
}

using CreateFileW_t = HANDLE(WINAPI*)(LPCWSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES, DWORD, DWORD, HANDLE);
using CreateFile2_t = HANDLE(WINAPI*)(LPCWSTR, DWORD, DWORD, DWORD, LPCREATEFILE2_EXTENDED_PARAMETERS);
using MoveFileExW_t = BOOL(WINAPI*)(LPCWSTR, LPCWSTR, DWORD);
using DeleteFileW_t = BOOL(WINAPI*)(LPCWSTR);
using GetFileAttributesExW_t = BOOL(WINAPI*)(LPCWSTR, GET_FILEEX_INFO_LEVELS, LPVOID);
using GetFileAttributesW_t = DWORD(WINAPI*)(LPCWSTR);
using FindFirstFileExW_t = HANDLE(WINAPI*)(LPCWSTR, FINDEX_INFO_LEVELS, LPVOID, FINDEX_SEARCH_OPS, LPVOID, DWORD);
using ReplaceFileW_t = BOOL(WINAPI*)(LPCWSTR, LPCWSTR, LPCWSTR, DWORD, LPVOID, LPVOID);
using CreateDirectoryW_t = BOOL(WINAPI*)(LPCWSTR, LPSECURITY_ATTRIBUTES);

CreateFileW_t o_CreateFileW;
CreateFile2_t o_CreateFile2;
MoveFileExW_t o_MoveFileExW;
DeleteFileW_t o_DeleteFileW;
GetFileAttributesExW_t o_GetFileAttributesExW;
GetFileAttributesW_t o_GetFileAttributesW;
FindFirstFileExW_t o_FindFirstFileExW;
ReplaceFileW_t o_ReplaceFileW;
CreateDirectoryW_t o_CreateDirectoryW;

HANDLE WINAPI h_CreateFileW(LPCWSTR p, DWORD acc, DWORD share, LPSECURITY_ATTRIBUTES sa, DWORD disp, DWORD fl, HANDLE tmpl) {
    HANDLE r = o_CreateFileW(p, acc, share, sa, disp, fl, tmpl);
    note(acc & GENERIC_WRITE ? "CreateFileW(escrita)" : "CreateFileW(leitura)", p, nullptr, disp,
        r == INVALID_HANDLE_VALUE ? GetLastError() : 0);
    return r;
}
HANDLE WINAPI h_CreateFile2(LPCWSTR p, DWORD acc, DWORD share, DWORD disp, LPCREATEFILE2_EXTENDED_PARAMETERS ex) {
    HANDLE r = o_CreateFile2(p, acc, share, disp, ex);
    note(acc & GENERIC_WRITE ? "CreateFile2(escrita)" : "CreateFile2(leitura)", p, nullptr, disp,
        r == INVALID_HANDLE_VALUE ? GetLastError() : 0);
    return r;
}
BOOL WINAPI h_MoveFileExW(LPCWSTR a, LPCWSTR b, DWORD fl) {
    BOOL r = o_MoveFileExW(a, b, fl);
    note("MoveFileExW", a, b, fl, r ? 0 : GetLastError());
    return r;
}
BOOL WINAPI h_DeleteFileW(LPCWSTR p) {
    BOOL r = o_DeleteFileW(p);
    note("DeleteFileW", p, nullptr, 0, r ? 0 : GetLastError());
    return r;
}
BOOL WINAPI h_GetFileAttributesExW(LPCWSTR p, GET_FILEEX_INFO_LEVELS lv, LPVOID info) {
    BOOL r = o_GetFileAttributesExW(p, lv, info);
    note("GetFileAttributesExW", p, nullptr, lv, r ? 0 : GetLastError());
    return r;
}
DWORD WINAPI h_GetFileAttributesW(LPCWSTR p) {
    DWORD r = o_GetFileAttributesW(p);
    note("GetFileAttributesW", p, nullptr, 0, r == INVALID_FILE_ATTRIBUTES ? GetLastError() : 0);
    return r;
}
HANDLE WINAPI h_FindFirstFileExW(LPCWSTR p, FINDEX_INFO_LEVELS lv, LPVOID d, FINDEX_SEARCH_OPS op, LPVOID f, DWORD fl) {
    HANDLE r = o_FindFirstFileExW(p, lv, d, op, f, fl);
    note("FindFirstFileExW", p, nullptr, lv, r == INVALID_HANDLE_VALUE ? GetLastError() : 0);
    return r;
}
BOOL WINAPI h_ReplaceFileW(LPCWSTR a, LPCWSTR b, LPCWSTR bak, DWORD fl, LPVOID x, LPVOID y) {
    BOOL r = o_ReplaceFileW(a, b, bak, fl, x, y);
    note("ReplaceFileW", a, b, fl, r ? 0 : GetLastError());
    return r;
}
BOOL WINAPI h_CreateDirectoryW(LPCWSTR p, LPSECURITY_ATTRIBUTES sa) {
    BOOL r = o_CreateDirectoryW(p, sa);
    note("CreateDirectoryW", p, nullptr, 0, r ? 0 : GetLastError());
    return r;
}

struct Patch {
    const char* name;
    void* hook;
    void** original;
};

// troca entradas da IAT do módulo principal; devolve quantas foram trocadas
int patch_iat(HMODULE mod, const Patch* patches, int count) {
    auto* base = reinterpret_cast<uint8_t*>(mod);
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    const auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return 0;
    int done = 0;
    for (auto* imp = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + dir.VirtualAddress); imp->Name; ++imp) {
        const char* dll = reinterpret_cast<const char*>(base + imp->Name);
        if (_stricmp(dll, "kernel32.dll") != 0 && _strnicmp(dll, "api-ms-win-core-file", 20) != 0) continue;
        if (!imp->OriginalFirstThunk) continue;
        auto* names = reinterpret_cast<IMAGE_THUNK_DATA*>(base + imp->OriginalFirstThunk);
        auto* slots = reinterpret_cast<IMAGE_THUNK_DATA*>(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; ++names, ++slots) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            const char* fn = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + names->u1.AddressOfData)->Name;
            for (int i = 0; i < count; ++i) {
                if (std::strcmp(fn, patches[i].name) != 0) continue;
                DWORD old;
                if (!VirtualProtect(&slots->u1.Function, sizeof(void*), PAGE_READWRITE, &old)) break;
                if (!*patches[i].original) *patches[i].original = reinterpret_cast<void*>(slots->u1.Function);
                slots->u1.Function = reinterpret_cast<ULONG_PTR>(patches[i].hook);
                VirtualProtect(&slots->u1.Function, sizeof(void*), old, &old);
                ++done;
                break;
            }
        }
    }
    return done;
}

// ---------------------------------------------------------------------------------------
// ISteamRemoteStorage: o DD2 grava o save pela Steam (remote\win64_save é a pasta do
// RemoteStorage, escrita pelo cliente Steam). Troca entradas da vtable do objeto da
// interface; o índice de cada método é lido do "jmp [rax+N]" da função flat equivalente.

std::atomic<int> g_write_lines{0};

void note_rs(const char* op, const char* name, long long size, long long result) {
    // gravações têm limite próprio: as leituras de varredura de slots não as escondem
    const bool write = std::strstr(op, "Write") || std::strstr(op, "Delete") || std::strstr(op, "Forget");
    if ((write ? g_write_lines : g_lines).fetch_add(1) >= kMaxLines) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    std::lock_guard<std::mutex> lk(g_log_mtx);
    FILE* f = std::fopen(g_log_path.c_str(), "a");
    if (!f) return;
    std::fprintf(f, "%02d:%02d:%02d.%03d tid=%lu RS.%s \"%s\" tamanho=%lld resultado=%lld\n",
        t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, GetCurrentThreadId(), op, name ? name : "", size, result);
    std::fclose(f);
}

using RsWrite_t = bool (*)(void*, const char*, const void*, int32_t);
using RsRead_t = int32_t (*)(void*, const char*, void*, int32_t);
using RsWriteAsync_t = uint64_t (*)(void*, const char*, const void*, uint32_t);
using RsReadAsync_t = uint64_t (*)(void*, const char*, uint32_t, uint32_t);
using RsName_t = bool (*)(void*, const char*);
using RsSize_t = int32_t (*)(void*, const char*);
using RsTime_t = int64_t (*)(void*, const char*);
using RsStream_t = uint64_t (*)(void*, const char*);
using RsCount_t = int32_t (*)(void*);
using RsNameAndSize_t = const char* (*)(void*, int, int32_t*);

RsWrite_t r_FileWrite; RsRead_t r_FileRead; RsWriteAsync_t r_FileWriteAsync; RsReadAsync_t r_FileReadAsync;
RsName_t r_FileExists, r_FileDelete, r_FileForget, r_FilePersisted; RsSize_t r_GetFileSize;
RsTime_t r_GetFileTimestamp; RsStream_t r_FileWriteStreamOpen; RsCount_t r_GetFileCount;
RsNameAndSize_t r_GetFileNameAndSize;

// Save co-op: com g_coop, todo nome "win64_save/..." vira "win64_coop/..." antes de ir para
// a Steam (que continua cuidando do assíncrono, dos callbacks e da nuvem). O save vanilla
// não é lido nem escrito; na listagem, os nomes se invertem para o jogo só enxergar o co-op.
bool g_coop = false;
thread_local std::string t_map;

const char* map_name(const char* n) {
    if (!g_coop || !n) return n;
    const char* p = std::strncmp(n, "./", 2) == 0 ? n + 2 : n;
    if (std::strncmp(p, "win64_save/", 11) != 0) return n;
    t_map.assign(n, p - n);
    t_map += "win64_coop/";
    t_map += p + 11;
    return t_map.c_str();
}

bool w_FileWrite(void* s, const char* n, const void* d, int32_t c) { n = map_name(n); bool r = r_FileWrite(s, n, d, c); note_rs("FileWrite", n, c, r); return r; }
int32_t w_FileRead(void* s, const char* n, void* d, int32_t c) { n = map_name(n); int32_t r = r_FileRead(s, n, d, c); note_rs("FileRead", n, c, r); return r; }
uint64_t w_FileWriteAsync(void* s, const char* n, const void* d, uint32_t c) { n = map_name(n); uint64_t r = r_FileWriteAsync(s, n, d, c); note_rs("FileWriteAsync", n, c, (long long)r); return r; }
uint64_t w_FileReadAsync(void* s, const char* n, uint32_t o, uint32_t c) { n = map_name(n); uint64_t r = r_FileReadAsync(s, n, o, c); note_rs("FileReadAsync", n, c, (long long)r); return r; }
bool w_FileExists(void* s, const char* n) { n = map_name(n); bool r = r_FileExists(s, n); if (r) note_rs("FileExists", n, -1, r); return r; }
bool w_FileDelete(void* s, const char* n) { n = map_name(n); bool r = r_FileDelete(s, n); note_rs("FileDelete", n, -1, r); return r; }
bool w_FileForget(void* s, const char* n) { n = map_name(n); bool r = r_FileForget(s, n); note_rs("FileForget", n, -1, r); return r; }
bool w_FilePersisted(void* s, const char* n) { n = map_name(n); bool r = r_FilePersisted(s, n); note_rs("FilePersisted", n, -1, r); return r; }
int32_t w_GetFileSize(void* s, const char* n) { n = map_name(n); int32_t r = r_GetFileSize(s, n); note_rs("GetFileSize", n, -1, r); return r; }
int64_t w_GetFileTimestamp(void* s, const char* n) { n = map_name(n); int64_t r = r_GetFileTimestamp(s, n); note_rs("GetFileTimestamp", n, -1, r); return r; }
uint64_t w_FileWriteStreamOpen(void* s, const char* n) { n = map_name(n); uint64_t r = r_FileWriteStreamOpen(s, n); note_rs("FileWriteStreamOpen", n, -1, (long long)r); return r; }
int32_t w_GetFileCount(void* s) { int32_t r = r_GetFileCount(s); note_rs("GetFileCount", "", -1, r); return r; }
thread_local std::string t_list;
const char* w_GetFileNameAndSize(void* s, int i, int32_t* sz) {
    const char* r = r_GetFileNameAndSize(s, i, sz);
    note_rs("GetFileNameAndSize", r, sz ? *sz : -1, i);
    if (!g_coop || !r) return r;
    const char* p = std::strncmp(r, "./", 2) == 0 ? r + 2 : r;
    const bool coop = std::strncmp(p, "win64_coop/", 11) == 0, vanilla = std::strncmp(p, "win64_save/", 11) == 0;
    if (!coop && !vanilla) return r;
    t_list.assign(r, p - r);
    t_list += coop ? "win64_save/" : "win64_vanilla_oculto/";
    t_list += p + 11;
    return t_list.c_str();
}

bool g_rs_done = false;
int g_rs_tries = 0;

// índice da vtable no corpo da função flat: "mov rax,[rcx]" ... "jmp qword ptr [rax+disp]"
int vtable_index(const void* flat) {
    const auto* p = static_cast<const uint8_t*>(flat);
    for (int i = 0; i < 32; ++i) {
        if (p[i] == 0xFF && p[i + 1] == 0x20) return 0;                                  // [rax]
        if (p[i] == 0xFF && p[i + 1] == 0x60) return p[i + 2] / 8;                      // disp8
        if (p[i] == 0xFF && p[i + 1] == 0xA0) {                                          // disp32
            int32_t d;
            std::memcpy(&d, p + i + 2, 4);
            return d / 8;
        }
        if (p[i] == 0xE9 || p[i] == 0xC3) break;  // outro formato: não arrisca
    }
    return -1;
}

std::string g_data_dir;
std::string g_status = "save vanilla (modo co-op desligado)";
int g_seeded = 0;
unsigned long long g_quota_total = 0, g_quota_free = 0;

void write_status() {
    FILE* f = std::fopen((g_data_dir + "dd2coop_save_status.json").c_str(), "w");
    if (!f) return;
    std::fprintf(f, "{\"coop\":%s,\"seeded\":%d,\"quota_total\":%llu,\"quota_free\":%llu,\"status\":\"%s\"}",
        g_coop ? "true" : "false", g_seeded, g_quota_total, g_quota_free, g_status.c_str());
    std::fclose(f);
}

// primeira vez em modo co-op: copia cada arquivo de win64_save que ainda não tem par em
// win64_coop (só leitura do vanilla). Sem espaço na cota da Steam Cloud, não copia nada e
// desliga o modo co-op nesta execução.
bool seed_coop(HMODULE m, void* iface) {
    using Quota_t = bool (*)(void*, unsigned long long*, unsigned long long*);
    auto quota = reinterpret_cast<Quota_t>(reinterpret_cast<void*>(GetProcAddress(m, "SteamAPI_ISteamRemoteStorage_GetQuota")));
    if (quota) quota(iface, &g_quota_total, &g_quota_free);
    struct Pending { std::string from, to; int32_t size; };
    std::vector<Pending> todo;
    unsigned long long need = 0;
    const int32_t count = r_GetFileCount(iface);
    for (int32_t i = 0; i < count; ++i) {
        int32_t size = 0;
        const char* n = r_GetFileNameAndSize(iface, i, &size);
        if (!n) continue;
        const char* p = std::strncmp(n, "./", 2) == 0 ? n + 2 : n;
        if (std::strncmp(p, "win64_save/", 11) != 0) continue;
        std::string to = std::string(n, p - n) + "win64_coop/" + (p + 11);
        if (r_FileExists(iface, to.c_str())) continue;
        todo.push_back({ n, to, size });
        need += static_cast<unsigned long long>(size);
    }
    if (todo.empty()) { g_status = "save co-op ativo (win64_coop)"; return true; }
    if (quota && g_quota_free < need + need / 5) {

        g_status = "save co-op DESLIGADO: sem espaco na Steam Cloud para a copia inicial";
        return false;
    }
    std::vector<uint8_t> buf;
    for (const auto& t : todo) {
        buf.resize(static_cast<size_t>(t.size > 0 ? t.size : 1));
        const int32_t got = r_FileRead(iface, t.from.c_str(), buf.data(), t.size);
        if (got != t.size || !r_FileWrite(iface, t.to.c_str(), buf.data(), got)) {
            // cópia incompleta: não abrir um save co-op pela metade
            g_status = "save co-op DESLIGADO: falha ao copiar " + t.from;
            return false;
        }
        ++g_seeded;
    }
    g_status = "save co-op ativo (win64_coop); copia inicial do vanilla feita";
    return true;
}

}  // namespace

bool coop_active() { return g_coop; }

void poll() {
    if (g_rs_done || ++g_rs_tries > 36000) return;  // tenta por ~10 min de frames
    HMODULE m = GetModuleHandleA("steam_api64.dll");
    if (!m) return;
    using Accessor = void* (*)();
    auto acc = reinterpret_cast<Accessor>(reinterpret_cast<void*>(GetProcAddress(m, "SteamAPI_SteamRemoteStorage_v016")));
    if (!acc) { g_rs_done = true; return; }
    void* iface = acc();
    if (!iface) return;  // Steam ainda não iniciou
    g_rs_done = true;
    void** vt = *static_cast<void***>(iface);
    // os nomes só passam a ser trocados depois da cópia inicial (sem corrida com a tela título)
    bool want_coop = g_coop;
    g_coop = false;
    struct Item { const char* flat; void* hook; void** original; };
    const Item items[] = {
        { "SteamAPI_ISteamRemoteStorage_FileWrite", (void*)w_FileWrite, (void**)&r_FileWrite },
        { "SteamAPI_ISteamRemoteStorage_FileRead", (void*)w_FileRead, (void**)&r_FileRead },
        { "SteamAPI_ISteamRemoteStorage_FileWriteAsync", (void*)w_FileWriteAsync, (void**)&r_FileWriteAsync },
        { "SteamAPI_ISteamRemoteStorage_FileReadAsync", (void*)w_FileReadAsync, (void**)&r_FileReadAsync },
        { "SteamAPI_ISteamRemoteStorage_FileExists", (void*)w_FileExists, (void**)&r_FileExists },
        { "SteamAPI_ISteamRemoteStorage_FileDelete", (void*)w_FileDelete, (void**)&r_FileDelete },
        { "SteamAPI_ISteamRemoteStorage_FileForget", (void*)w_FileForget, (void**)&r_FileForget },
        { "SteamAPI_ISteamRemoteStorage_FilePersisted", (void*)w_FilePersisted, (void**)&r_FilePersisted },
        { "SteamAPI_ISteamRemoteStorage_GetFileSize", (void*)w_GetFileSize, (void**)&r_GetFileSize },
        { "SteamAPI_ISteamRemoteStorage_GetFileTimestamp", (void*)w_GetFileTimestamp, (void**)&r_GetFileTimestamp },
        { "SteamAPI_ISteamRemoteStorage_FileWriteStreamOpen", (void*)w_FileWriteStreamOpen, (void**)&r_FileWriteStreamOpen },
        { "SteamAPI_ISteamRemoteStorage_GetFileCount", (void*)w_GetFileCount, (void**)&r_GetFileCount },
        { "SteamAPI_ISteamRemoteStorage_GetFileNameAndSize", (void*)w_GetFileNameAndSize, (void**)&r_GetFileNameAndSize },
    };
    int done = 0;
    char idx[512] = {};
    constexpr int kItems = static_cast<int>(sizeof(items) / sizeof(items[0]));
    int index[kItems];
    for (int k = 0; k < kItems; ++k) {
        const void* flat = reinterpret_cast<const void*>(GetProcAddress(m, items[k].flat));
        index[k] = flat ? vtable_index(flat) : -1;
        if (index[k] > 80) index[k] = -1;
        std::snprintf(idx + std::strlen(idx), sizeof(idx) - std::strlen(idx), " %s=%d", items[k].flat + 29, index[k]);
        // sem todos os métodos, alguma gravação poderia escapar para o vanilla: sem co-op
        if (index[k] < 0 && want_coop) {
            want_coop = false;
            g_status = "save co-op DESLIGADO: interface da Steam incompleta";
        }
    }
    for (int k = 0; k < kItems; ++k) {
        const auto& it = items[k];
        const int i = index[k];
        if (i < 0) continue;
        DWORD old;
        if (!VirtualProtect(&vt[i], sizeof(void*), PAGE_READWRITE, &old)) continue;
        *it.original = vt[i];
        vt[i] = it.hook;
        VirtualProtect(&vt[i], sizeof(void*), old, &old);
        ++done;
    }
    g_ref->log_info("[dd2coop_net] save_io: ISteamRemoteStorage %p, %d metodos observados:%s", iface, done, idx);
    if (want_coop) g_coop = seed_coop(m, iface);
    write_status();
    g_ref->log_info("[dd2coop_net] save_io: %s", g_status.c_str());
}

void init(const REFrameworkPluginInitializeParam* param, const std::string& data_dir) {
    g_ref = param->functions;
    g_log_path = data_dir + "dd2coop_save_io.txt";
    g_data_dir = data_dir;
    // modo do save escolhido antes de abrir o jogo (a tela título lê os saves logo no início)
    if (FILE* f = std::fopen((data_dir + "dd2coop_save_mode.json").c_str(), "rb")) {
        char buf[256] = {};
        std::fread(buf, 1, sizeof(buf) - 1, f);
        std::fclose(f);
        std::string s(buf);
        s.erase(std::remove_if(s.begin(), s.end(), [](char c) { return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D; }), s.end());
        g_coop = s.find("\"coop\":true") != std::string::npos;
    }
    if (FILE* f = std::fopen(g_log_path.c_str(), "w")) std::fclose(f);  // um registro por execução
    const Patch patches[] = {
        { "CreateFileW", reinterpret_cast<void*>(h_CreateFileW), reinterpret_cast<void**>(&o_CreateFileW) },
        { "CreateFile2", reinterpret_cast<void*>(h_CreateFile2), reinterpret_cast<void**>(&o_CreateFile2) },
        { "MoveFileExW", reinterpret_cast<void*>(h_MoveFileExW), reinterpret_cast<void**>(&o_MoveFileExW) },
        { "DeleteFileW", reinterpret_cast<void*>(h_DeleteFileW), reinterpret_cast<void**>(&o_DeleteFileW) },
        { "GetFileAttributesExW", reinterpret_cast<void*>(h_GetFileAttributesExW), reinterpret_cast<void**>(&o_GetFileAttributesExW) },
        { "GetFileAttributesW", reinterpret_cast<void*>(h_GetFileAttributesW), reinterpret_cast<void**>(&o_GetFileAttributesW) },
        { "FindFirstFileExW", reinterpret_cast<void*>(h_FindFirstFileExW), reinterpret_cast<void**>(&o_FindFirstFileExW) },
        { "ReplaceFileW", reinterpret_cast<void*>(h_ReplaceFileW), reinterpret_cast<void**>(&o_ReplaceFileW) },
        { "CreateDirectoryW", reinterpret_cast<void*>(h_CreateDirectoryW), reinterpret_cast<void**>(&o_CreateDirectoryW) },
    };
    const int n = patch_iat(GetModuleHandleA(nullptr), patches, static_cast<int>(sizeof(patches) / sizeof(patches[0])));
    g_ref->log_info("[dd2coop_net] save_io: %d funcoes de arquivo observadas no DD2.exe", n);
}

}  // namespace save_io
