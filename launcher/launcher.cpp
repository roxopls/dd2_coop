// DD2 Co-op: launcher. Instala/atualiza o mod pela última Release do GitHub e abre o jogo.
//
// 1. Launcher: se a Release tem DD2Coop_Launcher.exe com SHA256 (DD2Coop_Launcher.exe.sha256)
//    diferente do próprio, baixa, confere, troca o próprio .exe (o antigo vira .old) e reabre.
// 2. Acha o Dragon's Dogma 2, nesta ordem: pasta salva (%APPDATA%\DD2Coop\launcher.ini), pasta
//    do próprio launcher, bibliotecas da Steam (registro + libraryfolders.vdf + installdir do
//    appmanifest_2054970.acf). Na primeira vez confirma a pasta achada; sem achar, ou abrindo
//    com Shift apertado (ou --pasta), pede a pasta. Toda pasta precisa ter DD2.exe.
// 3. Recusa mexer com o jogo aberto (o DLL do plugin não troca com o jogo rodando).
// 4. REFramework: versão pedida pela Release (reframework.txt: url= e sha256= do zip; sem ele,
//    kRefUrl/kRefSha). Instala se faltar dinput8.dll ou se o SHA256 instalado (launcher.ini)
//    for outro; um dinput8.dll que não foi o launcher que pôs vira dinput8.dll.bak_dd2coop.
// 5. Mod: versão diferente da instalada (reframework\data\dd2coop_version.txt) baixa
//    DD2Coop.zip, confere com DD2Coop.zip.sha256 e instala por cima (scripts dd2coop_*.lua
//    antigos são apagados antes, para não sobrar script renomeado/removido). Arquivos de
//    estado do mod em reframework\data ficam.
// 6. Abre o jogo pela Steam e espera ele fechar. Versão (mod e REFramework) que rodou 10 min
//    ou fechou sem crash vira "boa". Crash (reframework_crash.dmp novo ou código de exceção)
//    antes disso com versão ainda não boa: volta para a última boa e marca a nova como ruim
//    (não reinstala até sair outra).
// Sem internet ou sem Release: abre o jogo com o que já está instalado.

#include <windows.h>
#include <bcrypt.h>
#include <winhttp.h>
#include <shellapi.h>
#include <shlobj.h>
#include <psapi.h>

#include <cstdio>
#include <map>
#include <string>
#include <vector>

namespace {

const wchar_t* kTitle = L"DD2 Co-op";
const char* kRepo = "roxopls/dd2_coop";
// REFramework padrão, quando a Release não traz reframework.txt (plugin API 1.15)
const char* kRefUrl = "https://github.com/praydog/REFramework-nightly/releases/download/"
    "nightly-01432-d052e8fd3fd41d0a1a33394fcf6e6c19be39b1ee/REFramework.zip";
const char* kRefSha = "27376e1da177ddcde9c46b3541bdc6fa1ad54a11d0cab9f7782eff0481455e94";
const ULONGLONG kGoodAfterMs = 10 * 60 * 1000;  // rodou isso sem crash: versão boa
HANDLE g_mutex = nullptr;  // um launcher por vez

std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

void message(const std::wstring& text, UINT icon = MB_ICONINFORMATION) {
    MessageBoxW(nullptr, text.c_str(), kTitle, MB_OK | icon);
}

bool exists(const std::wstring& p) { return GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES; }

std::string read_file(const std::wstring& p) {
    std::string s;
    FILE* f = _wfopen(p.c_str(), L"rb");
    if (!f) return s;
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) s.append(buf, n);
    fclose(f);
    return s;
}

bool write_file(const std::wstring& p, const std::string& data) {
    FILE* f = _wfopen(p.c_str(), L"wb");
    if (!f) return false;
    const bool ok = fwrite(data.data(), 1, data.size(), f) == data.size();
    fclose(f);
    return ok;
}

std::string trim(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) s.pop_back();
    while (!s.empty() && (s.front() == ' ' || s.front() == '\xEF' || s.front() == '\xBB' || s.front() == '\xBF')) s.erase(0, 1);
    return s;
}

// GET https (segue redirecionamentos do GitHub para o armazenamento dos arquivos)
bool http_get(const std::wstring& url, std::string& out) {
    URL_COMPONENTS uc{ sizeof(uc) };
    wchar_t host[256], path[2048];
    uc.lpszHostName = host; uc.dwHostNameLength = 256;
    uc.lpszUrlPath = path; uc.dwUrlPathLength = 2048;
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return false;
    HINTERNET s = WinHttpOpen(L"dd2coop-launcher", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nullptr, nullptr, 0);
    if (!s) return false;
    HINTERNET c = WinHttpConnect(s, host, uc.nPort, 0);
    HINTERNET r = nullptr;
    if (c) r = WinHttpOpenRequest(c, L"GET", path, nullptr, nullptr, nullptr, WINHTTP_FLAG_SECURE);
    bool ok = r && WinHttpSendRequest(r, L"Accept: */*\r\n", (DWORD)-1, nullptr, 0, 0, 0) &&
        WinHttpReceiveResponse(r, nullptr);
    DWORD status = 0, len = sizeof(status);
    if (ok) {
        WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nullptr, &status, &len, nullptr);
        ok = status == 200;
    }
    out.clear();
    while (ok) {
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(r, &avail)) { ok = false; break; }
        if (avail == 0) break;
        std::string chunk(avail, '\0');
        DWORD got = 0;
        if (!WinHttpReadData(r, chunk.data(), avail, &got)) { ok = false; break; }
        out.append(chunk.data(), got);
    }
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
    return ok;
}

std::string sha256_hex(const std::string& data) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE h = nullptr;
    unsigned char digest[32];
    std::string hex;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return hex;
    if (BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0) == 0 &&
        BCryptHashData(h, (PUCHAR)data.data(), (ULONG)data.size(), 0) == 0 &&
        BCryptFinishHash(h, digest, sizeof(digest), 0) == 0) {
        char b[3];
        for (unsigned char x : digest) { snprintf(b, sizeof(b), "%02x", x); hex += b; }
    }
    if (h) BCryptDestroyHash(h);
    BCryptCloseAlgorithmProvider(alg, 0);
    return hex;
}

// "chave": "valor" (primeira ocorrência a partir de from)
std::string json_str(const std::string& s, const std::string& key, size_t from = 0) {
    size_t k = s.find("\"" + key + "\"", from);
    if (k == std::string::npos) return {};
    size_t c = s.find(':', k), q1 = s.find('"', c + 1), q2 = s.find('"', q1 + 1);
    if (c == std::string::npos || q1 == std::string::npos || q2 == std::string::npos) return {};
    return s.substr(q1 + 1, q2 - q1 - 1);
}

// URL de download de um arquivo da Release pelo nome
std::string asset_url(const std::string& release, const std::string& name) {
    for (size_t at = release.find("\"browser_download_url\""); at != std::string::npos;
         at = release.find("\"browser_download_url\"", at + 1)) {
        std::string url = json_str(release, "browser_download_url", at);
        if (url.size() >= name.size() && url.compare(url.size() - name.size(), name.size(), name) == 0 &&
            url[url.size() - name.size() - 1] == '/') return url;
    }
    return {};
}

// "latest" ou "tags/<tag>"
bool get_release(const std::string& which, std::string& out) {
    return http_get(widen(std::string("https://api.github.com/repos/") + kRepo + "/releases/" + which), out) &&
        !json_str(out, "tag_name").empty();
}

// texto de um arquivo da Release (o .sha256 vem só com os 64 hex)
std::string asset_text(const std::string& release, const std::string& name) {
    const std::string url = asset_url(release, name);
    std::string s;
    if (url.empty() || !http_get(widen(url), s)) return {};
    return trim(s);
}

// linhas chave=valor
using Kv = std::map<std::string, std::string>;
Kv parse_kv(const std::string& text) {
    Kv kv;
    size_t at = 0;
    while (at < text.size()) {
        size_t end = text.find('\n', at);
        if (end == std::string::npos) end = text.size();
        const std::string line = trim(text.substr(at, end - at));
        const size_t eq = line.find('=');
        if (eq != std::string::npos) kv[line.substr(0, eq)] = line.substr(eq + 1);
        at = end + 1;
    }
    return kv;
}

// estado em %APPDATA%\DD2Coop\launcher.ini (UTF-8):
//   game=<pasta>, mod=<tag instalada>, mod_good=, mod_bad=, ref_url=, ref_sha=, ref_good_url=,
//   ref_good_sha=, ref_bad=
std::wstring config_dir() {
    wchar_t* app = nullptr;
    std::wstring d;
    if (SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &app) == S_OK) d = std::wstring(app) + L"\\DD2Coop";
    CoTaskMemFree(app);
    return d;
}

Kv load_state() {
    const std::wstring d = config_dir();
    return d.empty() ? Kv{} : parse_kv(read_file(d + L"\\launcher.ini"));
}

void save_state(const Kv& st) {
    const std::wstring d = config_dir();
    if (d.empty()) return;
    CreateDirectoryW(d.c_str(), nullptr);
    std::string s;
    for (const auto& [k, v] : st) if (!v.empty()) s += k + "=" + v + "\n";
    write_file(d + L"\\launcher.ini", s);
}

std::wstring self_path() {
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    return self;
}

// troca o próprio .exe pelo da Release; true = reabriu a versão nova (sair)
bool self_update(const std::string& release, const std::wstring& cmd) {
    const std::string want = asset_text(release, "DD2Coop_Launcher.exe.sha256").substr(0, 64);
    const std::wstring self = self_path(), old = self + L".old";
    if (want.size() != 64 || sha256_hex(read_file(self)) == want) return false;
    std::string exe;
    const std::string url = asset_url(release, "DD2Coop_Launcher.exe");
    if (url.empty() || !http_get(widen(url), exe) || sha256_hex(exe) != want) return false;
    DeleteFileW(old.c_str());
    // o .exe rodando pode ser renomeado, não sobrescrito
    if (!MoveFileExW(self.c_str(), old.c_str(), MOVEFILE_REPLACE_EXISTING)) return false;
    if (!write_file(self, exe)) { MoveFileExW(old.c_str(), self.c_str(), MOVEFILE_REPLACE_EXISTING); return false; }
    // solta o "um launcher por vez" para a versão nova abrir
    ReleaseMutex(g_mutex);
    CloseHandle(g_mutex);
    std::wstring line = L"\"" + self + L"\" " + cmd + L" --atualizado";
    STARTUPINFOW si{ sizeof(si) };
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr, line.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) return false;
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return true;
}

std::wstring reg_string(HKEY root, const wchar_t* key, const wchar_t* value) {
    wchar_t buf[MAX_PATH];
    DWORD size = sizeof(buf);
    if (RegGetValueW(root, key, value, RRF_RT_REG_SZ, nullptr, buf, &size) != ERROR_SUCCESS) return {};
    return buf;
}

bool is_game(const std::wstring& dir) { return !dir.empty() && exists(dir + L"\\DD2.exe"); }

// valores de "chave"		"valor" num .vdf/.acf da Steam (\\ vira \)
std::vector<std::string> vdf_values(const std::string& vdf, const std::string& key) {
    std::vector<std::string> out;
    const std::string k = "\"" + key + "\"";
    for (size_t at = vdf.find(k); at != std::string::npos; at = vdf.find(k, at + 1)) {
        size_t q1 = vdf.find('"', at + k.size()), q2 = q1 == std::string::npos ? q1 : vdf.find('"', q1 + 1);
        if (q2 == std::string::npos) break;
        std::string p = vdf.substr(q1 + 1, q2 - q1 - 1), clean;
        for (size_t i = 0; i < p.size(); ++i) {
            if (p[i] == '\\' && i + 1 < p.size() && p[i + 1] == '\\') ++i;
            clean += p[i];
        }
        out.push_back(clean);
    }
    return out;
}

// procura sem perguntar: pasta do launcher, depois as bibliotecas da Steam
std::wstring find_game() {
    std::wstring here = self_path();
    here = here.substr(0, here.find_last_of(L"\\/"));
    if (is_game(here)) return here;
    std::wstring steam = reg_string(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath");
    if (steam.empty()) return {};
    std::vector<std::wstring> libs{ steam };
    // libraryfolders.vdf: "path"		"A:\\SteamLibrary"
    for (const auto& p : vdf_values(read_file(steam + L"\\steamapps\\libraryfolders.vdf"), "path")) libs.push_back(widen(p));
    for (const auto& lib : libs) {
        // appmanifest_2054970.acf: "installdir"		"Dragons Dogma 2"
        auto dirs = vdf_values(read_file(lib + L"\\steamapps\\appmanifest_2054970.acf"), "installdir");
        std::wstring name = dirs.empty() ? L"Dragons Dogma 2" : widen(dirs[0]);
        std::wstring dir = lib + L"\\steamapps\\common\\" + name;
        if (is_game(dir)) return dir;
    }
    return {};
}

// janela de escolher pasta; repete até ter DD2.exe ou a pessoa cancelar
std::wstring pick_game(const std::wstring& start) {
    for (;;) {
        BROWSEINFOW bi{};
        bi.lpszTitle = L"Escolha a pasta do Dragon's Dogma 2 (onde fica o DD2.exe)";
        bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
        bi.lpfn = [](HWND h, UINT msg, LPARAM, LPARAM data) -> int {
            if (msg == BFFM_INITIALIZED && data) SendMessageW(h, BFFM_SETSELECTIONW, TRUE, data);
            return 0;
        };
        bi.lParam = start.empty() ? 0 : (LPARAM)start.c_str();
        PIDLIST_ABSOLUTE id = SHBrowseForFolderW(&bi);
        if (!id) return {};
        wchar_t path[MAX_PATH] = {};
        const bool ok = SHGetPathFromIDListW(id, path);
        CoTaskMemFree(id);
        if (ok && is_game(path)) return path;
        message(L"Essa pasta nao tem o DD2.exe. Escolha a pasta do jogo.", MB_ICONWARNING);
    }
}

// pasta do jogo: salva > achada (confirma na 1ª vez) > escolhida; vazio = cancelou
std::wstring resolve_game(Kv& st, bool choose) {
    std::wstring dir = widen(st["game"]);
    if (!choose && is_game(dir)) return dir;
    std::wstring found = find_game();
    if (!choose && !found.empty()) {
        const int r = MessageBoxW(nullptr, (L"Achei o Dragon's Dogma 2 em:\n" + found +
            L"\n\nInstalar o mod nessa pasta?\n(Nao = escolher outra pasta)").c_str(), kTitle, MB_YESNOCANCEL | MB_ICONQUESTION);
        if (r == IDCANCEL) return {};
        if (r == IDYES) dir = found;
        else dir = pick_game(found);
    } else {
        dir = pick_game(is_game(dir) ? dir : found);
    }
    if (!dir.empty()) { st["game"] = narrow(dir); save_state(st); }
    return dir;
}

// pid do DD2.exe rodando (0 = nenhum); só pelo processo: pelo título da janela, a página do
// jogo na Steam também batia
DWORD game_pid() {
    DWORD pids[4096], bytes = 0;
    if (!EnumProcesses(pids, sizeof(pids), &bytes)) return 0;
    for (DWORD i = 0; i < bytes / sizeof(DWORD); ++i) {
        HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pids[i]);
        if (!p) continue;
        wchar_t name[MAX_PATH];
        DWORD n = MAX_PATH;
        bool found = false;
        if (QueryFullProcessImageNameW(p, 0, name, &n)) {
            std::wstring s = name;
            found = s.size() >= 8 && _wcsicmp(s.c_str() + s.size() - 8, L"\\DD2.exe") == 0;
        }
        CloseHandle(p);
        if (found) return pids[i];
    }
    return 0;
}

// extrai um zip com o tar do Windows (bsdtar, Windows 10+)
bool unzip(const std::wstring& zip, const std::wstring& dest) {
    wchar_t sys[MAX_PATH];
    GetSystemDirectoryW(sys, MAX_PATH);
    std::wstring cmd = L"\"" + std::wstring(sys) + L"\\tar.exe\" -xf \"" + zip + L"\" -C \"" + dest + L"\"";
    STARTUPINFOW si{ sizeof(si) };
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) return false;
    WaitForSingleObject(pi.hProcess, 120000);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return code == 0;
}

std::wstring temp_dir() {
    wchar_t t[MAX_PATH];
    GetTempPathW(MAX_PATH, t);
    std::wstring d = std::wstring(t) + L"dd2coop_launcher";
    CreateDirectoryW(d.c_str(), nullptr);
    return d;
}

void remove_tree(const std::wstring& dir) {
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            std::wstring name = fd.cFileName;
            if (name == L"." || name == L"..") continue;
            std::wstring p = dir + L"\\" + name;
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) remove_tree(p);
            else DeleteFileW(p.c_str());
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryW(dir.c_str());
}

// REFramework pedido pela Release (reframework.txt) ou o padrão
void wanted_ref(const std::string& release, std::string& url, std::string& sha) {
    Kv kv = parse_kv(release.empty() ? std::string() : asset_text(release, "reframework.txt"));
    url = kv["url"], sha = kv["sha256"];
    if (url.empty() || sha.size() != 64) url = kRefUrl, sha = kRefSha;
}

bool install_reframework(const std::wstring& game, const std::string& url, const std::string& sha,
                         bool backup_foreign, std::wstring& err) {
    std::string zip;
    if (!http_get(widen(url), zip)) { err = L"nao consegui baixar o REFramework"; return false; }
    if (sha256_hex(zip) != sha) { err = L"REFramework baixado nao confere (SHA256)"; return false; }
    std::wstring tmp = temp_dir(), path = tmp + L"\\REFramework.zip", out = tmp + L"\\ref";
    remove_tree(out);
    CreateDirectoryW(out.c_str(), nullptr);
    if (!write_file(path, zip) || !unzip(path, out)) { err = L"falha ao extrair o REFramework"; return false; }
    const std::wstring dll = game + L"\\dinput8.dll";
    if (backup_foreign && exists(dll)) CopyFileW(dll.c_str(), (dll + L".bak_dd2coop").c_str(), FALSE);
    if (!CopyFileW((out + L"\\dinput8.dll").c_str(), dll.c_str(), FALSE)) {
        err = L"falha ao copiar dinput8.dll para a pasta do jogo"; return false;
    }
    return true;
}

// copia a árvore src por cima de dst
bool copy_tree(const std::wstring& src, const std::wstring& dst) {
    CreateDirectoryW(dst.c_str(), nullptr);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((src + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    bool ok = true;
    do {
        std::wstring name = fd.cFileName;
        if (name == L"." || name == L"..") continue;
        std::wstring s = src + L"\\" + name, d = dst + L"\\" + name;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ok = copy_tree(s, d) && ok;
        else ok = CopyFileW(s.c_str(), d.c_str(), FALSE) && ok;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return ok;
}

void delete_old_scripts(const std::wstring& game) {
    std::wstring dir = game + L"\\reframework\\autorun";
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\dd2coop_*.lua").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do { DeleteFileW((dir + L"\\" + fd.cFileName).c_str()); } while (FindNextFileW(h, &fd));
    FindClose(h);
}

std::string installed_mod(const std::wstring& game) {
    if (!exists(game + L"\\reframework\\plugins\\dd2coop_net.dll")) return {};
    return trim(read_file(game + L"\\reframework\\data\\dd2coop_version.txt"));
}

// instala o pacote de uma Release
bool install_mod(const std::wstring& game, const std::string& release, std::wstring& err) {
    const std::wstring version = widen(json_str(release, "tag_name"));
    const std::string zip_url = asset_url(release, "DD2Coop.zip");
    const std::string sha = asset_text(release, "DD2Coop.zip.sha256").substr(0, 64);
    if (zip_url.empty() || sha.size() != 64) { err = L"Release " + version + L" sem DD2Coop.zip/.sha256"; return false; }
    std::string zip;
    if (!http_get(widen(zip_url), zip)) { err = L"falha ao baixar a versao " + version; return false; }
    if (sha256_hex(zip) != sha) { err = L"pacote baixado nao confere (SHA256); nada foi instalado"; return false; }
    std::wstring tmp = temp_dir(), path = tmp + L"\\DD2Coop.zip", out = tmp + L"\\mod";
    remove_tree(out);
    CreateDirectoryW(out.c_str(), nullptr);
    if (!write_file(path, zip) || !unzip(path, out)) { err = L"falha ao extrair o pacote"; return false; }
    if (!exists(out + L"\\reframework\\plugins\\dd2coop_net.dll")) { err = L"pacote incompleto"; return false; }
    delete_old_scripts(game);
    if (!copy_tree(out, game)) { err = L"falha ao copiar arquivos para a pasta do jogo"; return false; }
    return true;
}

ULONGLONG file_time(const std::wstring& p) {
    WIN32_FILE_ATTRIBUTE_DATA a;
    if (!GetFileAttributesExW(p.c_str(), GetFileExInfoStandard, &a)) return 0;
    return ((ULONGLONG)a.ftLastWriteTime.dwHighDateTime << 32) | a.ftLastWriteTime.dwLowDateTime;
}

ULONGLONG now_time() {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    return ((ULONGLONG)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
}

// espera o jogo abrir (até 3 min) e fechar; false = não abriu. A Steam pode reabrir o DD2.exe
// logo em seguida: só conta como fechado se nenhum aparecer em 10 s.
bool watch_game(ULONGLONG& ran_ms, DWORD& code) {
    DWORD pid = 0;
    for (int i = 0; i < 180 && !(pid = game_pid()); ++i) Sleep(1000);
    if (!pid) return false;
    const ULONGLONG start = GetTickCount64();
    code = 0;
    while (pid) {
        HANDLE p = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (p) {
            WaitForSingleObject(p, INFINITE);
            GetExitCodeProcess(p, &code);
            CloseHandle(p);
        } else {
            Sleep(1000);
        }
        pid = 0;
        for (int i = 0; i < 10 && !(pid = game_pid()); ++i) Sleep(1000);
    }
    ran_ms = GetTickCount64() - start;
    return true;
}

// depois do jogo fechar: marca a versão como boa ou volta para a última boa
void after_game(const std::wstring& game, Kv& st, ULONGLONG launched) {
    ULONGLONG ran = 0;
    DWORD code = 0;
    if (!watch_game(ran, code)) return;
    const bool crashed = file_time(game + L"\\reframework_crash.dmp") > launched || code >= 0xC0000000;
    if (!crashed || ran >= kGoodAfterMs) {
        st["mod_good"] = st["mod"];
        st["ref_good_url"] = st["ref_url"], st["ref_good_sha"] = st["ref_sha"];
        save_state(st);
        return;
    }
    const bool mod_new = !st["mod"].empty() && st["mod"] != st["mod_good"];
    const bool ref_new = !st["ref_sha"].empty() && st["ref_sha"] != st["ref_good_sha"];
    if (!mod_new && !ref_new) return;  // crash com versão que já funcionou: não é da atualização
    std::wstring done, err;
    if (mod_new && !st["mod_good"].empty()) {
        std::string rel;
        if (get_release("tags/" + st["mod_good"], rel) && install_mod(game, rel, err)) {
            done += L"\nmod: " + widen(st["mod"]) + L" -> " + widen(st["mod_good"]);
            st["mod_bad"] = st["mod"], st["mod"] = st["mod_good"];
        }
    }
    if (ref_new && !st["ref_good_sha"].empty() &&
        install_reframework(game, st["ref_good_url"], st["ref_good_sha"], false, err)) {
        done += L"\nREFramework voltou para a versao anterior";
        st["ref_bad"] = st["ref_sha"], st["ref_url"] = st["ref_good_url"], st["ref_sha"] = st["ref_good_sha"];
    }
    save_state(st);
    if (!done.empty()) {
        message(L"O jogo crashou logo depois da atualizacao. Voltei para a versao que funcionava:" + done +
            L"\n\nA versao nova nao sera instalada de novo ate sair outra.", MB_ICONWARNING);
    } else {
        message(L"O jogo crashou logo depois da atualizacao e nao ha versao anterior conhecida para voltar." +
            (err.empty() ? std::wstring() : L"\n" + err), MB_ICONWARNING);
    }
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR cmd_line, int) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const std::wstring cmd = cmd_line ? cmd_line : L"";
    DeleteFileW((self_path() + L".old").c_str());
    // um launcher por vez (o anterior pode estar esperando o jogo fechar)
    g_mutex = CreateMutexW(nullptr, TRUE, L"Local\\DD2CoopLauncher");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        message(L"O launcher ja esta aberto (ele espera o jogo fechar para conferir crash).", MB_ICONWARNING);
        return 1;
    }
    std::string release;
    const bool online = get_release("latest", release);
    if (online && cmd.find(L"--atualizado") == std::wstring::npos && self_update(release, cmd)) return 0;

    Kv st = load_state();
    // Shift apertado ao abrir, ou --pasta: escolher outra pasta do jogo
    const bool choose = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0 || cmd.find(L"--pasta") != std::wstring::npos;
    const std::wstring game = resolve_game(st, choose);
    if (game.empty()) {
        message(L"Pasta do Dragon's Dogma 2 nao escolhida; nada foi instalado.", MB_ICONWARNING);
        return 1;
    }
    if (game_pid()) {
        message(L"Feche o Dragon's Dogma 2 antes de abrir o launcher.", MB_ICONWARNING);
        return 1;
    }

    std::wstring err, notes;
    std::string ref_url, ref_sha;
    wanted_ref(online ? release : std::string(), ref_url, ref_sha);
    const bool has_dll = exists(game + L"\\dinput8.dll");
    // sem internet não troca um REFramework que já está lá
    const bool ref_wanted = !has_dll || (online && st["ref_sha"] != ref_sha && st["ref_bad"] != ref_sha);
    if (ref_wanted) {
        if (install_reframework(game, ref_url, ref_sha, st["ref_sha"].empty(), err)) {
            st["ref_url"] = ref_url, st["ref_sha"] = ref_sha;
            save_state(st);
            if (has_dll) notes += L"\nREFramework atualizado.";
        } else if (!has_dll) {
            message(L"REFramework: " + err, MB_ICONERROR);
            return 1;
        } else {
            message(L"REFramework: " + err + L"\nO jogo vai abrir com o REFramework instalado.", MB_ICONWARNING);
        }
    }

    const std::string tag = online ? json_str(release, "tag_name") : std::string();
    std::string have = installed_mod(game);
    if (!have.empty() && st["mod"] != have) { st["mod"] = have; save_state(st); }
    if (!tag.empty() && tag != have && tag != st["mod_bad"]) {
        if (install_mod(game, release, err)) {
            st["mod"] = tag;
            save_state(st);
            notes += L"\nDD2 Co-op atualizado para " + widen(tag) + L".";
        } else {
            message(L"Atualizacao falhou: " + err + L"\nO jogo vai abrir com a versao instalada.", MB_ICONWARNING);
        }
    } else if (tag.empty() && have.empty()) {
        message(L"Sem acesso ao GitHub e o mod nao esta instalado.", MB_ICONERROR);
        return 1;
    }
    if (!notes.empty()) {
        message(notes.substr(1) + L"\n\nPasta: " + game + L"\nPara trocar a pasta, abra o launcher segurando Shift.");
    }

    const ULONGLONG launched = now_time();
    ShellExecuteW(nullptr, L"open", L"steam://rungameid/2054970", nullptr, nullptr, SW_SHOWNORMAL);
    after_game(game, st, launched);
    return 0;
}
