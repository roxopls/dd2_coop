// DD2 Co-op: launcher. Instala/atualiza o mod pela última Release do GitHub e abre o jogo.
//
// 1. Acha o Dragon's Dogma 2 nas bibliotecas da Steam (registro + libraryfolders.vdf) ou na
//    pasta do próprio launcher.
// 2. Recusa mexer com o jogo aberto (o DLL do plugin não troca com o jogo rodando).
// 3. REFramework: se faltar dinput8.dll, baixa a nightly fixada (kRefUrl) e confere o SHA256.
// 4. Mod: lê a última Release de kRepo; versão diferente da instalada
//    (reframework\data\dd2coop_version.txt) baixa DD2Coop.zip, confere com DD2Coop.zip.sha256
//    e instala por cima (scripts dd2coop_*.lua antigos são apagados antes, para não sobrar
//    script renomeado/removido). Arquivos de estado do mod em reframework\data ficam.
// 5. Abre o jogo pela Steam.
// Sem internet ou sem Release: abre o jogo com o que já está instalado.

#include <windows.h>
#include <bcrypt.h>
#include <winhttp.h>
#include <shellapi.h>
#include <psapi.h>

#include <cstdio>
#include <string>
#include <vector>

namespace {

const wchar_t* kTitle = L"DD2 Co-op";
const char* kRepo = "roxopls/dd2_coop";
// REFramework nightly usada no desenvolvimento (plugin API 1.15)
const wchar_t* kRefUrl = L"https://github.com/praydog/REFramework-nightly/releases/download/"
    L"nightly-01432-d052e8fd3fd41d0a1a33394fcf6e6c19be39b1ee/REFramework.zip";
const char* kRefSha = "27376e1da177ddcde9c46b3541bdc6fa1ad54a11d0cab9f7782eff0481455e94";

std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
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

std::wstring reg_string(HKEY root, const wchar_t* key, const wchar_t* value) {
    wchar_t buf[MAX_PATH];
    DWORD size = sizeof(buf);
    if (RegGetValueW(root, key, value, RRF_RT_REG_SZ, nullptr, buf, &size) != ERROR_SUCCESS) return {};
    return buf;
}

std::wstring find_game() {
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    std::wstring here = self;
    here = here.substr(0, here.find_last_of(L"\\/"));
    if (exists(here + L"\\DD2.exe")) return here;
    std::wstring steam = reg_string(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath");
    if (steam.empty()) return {};
    std::vector<std::wstring> libs{ steam };
    // libraryfolders.vdf: "path"		"A:\\SteamLibrary"
    std::string vdf = read_file(steam + L"\\steamapps\\libraryfolders.vdf");
    for (size_t at = vdf.find("\"path\""); at != std::string::npos; at = vdf.find("\"path\"", at + 1)) {
        size_t q1 = vdf.find('"', at + 6), q2 = q1 == std::string::npos ? q1 : vdf.find('"', q1 + 1);
        if (q2 == std::string::npos) break;
        std::string p = vdf.substr(q1 + 1, q2 - q1 - 1), clean;
        for (size_t i = 0; i < p.size(); ++i) {
            if (p[i] == '\\' && i + 1 < p.size() && p[i + 1] == '\\') ++i;
            clean += p[i];
        }
        libs.push_back(widen(clean));
    }
    for (const auto& lib : libs) {
        std::wstring dir = lib + L"\\steamapps\\common\\Dragons Dogma 2";
        if (exists(dir + L"\\DD2.exe")) return dir;
    }
    return {};
}

bool game_running() {
    // só pelo processo DD2.exe: pelo título da janela, a página do jogo na Steam também batia
    bool found = false;
    DWORD pids[4096], bytes = 0;
    if (!EnumProcesses(pids, sizeof(pids), &bytes)) return false;
    for (DWORD i = 0; i < bytes / sizeof(DWORD) && !found; ++i) {
        HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pids[i]);
        if (!p) continue;
        wchar_t name[MAX_PATH];
        DWORD n = MAX_PATH;
        if (QueryFullProcessImageNameW(p, 0, name, &n)) {
            std::wstring s = name;
            found = s.size() >= 8 && _wcsicmp(s.c_str() + s.size() - 8, L"\\DD2.exe") == 0;
        }
        CloseHandle(p);
    }
    return found;
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

bool install_reframework(const std::wstring& game, std::wstring& err) {
    std::string zip;
    if (!http_get(kRefUrl, zip)) { err = L"nao consegui baixar o REFramework"; return false; }
    if (sha256_hex(zip) != kRefSha) { err = L"REFramework baixado nao confere (SHA256)"; return false; }
    std::wstring tmp = temp_dir(), path = tmp + L"\\REFramework.zip", out = tmp + L"\\ref";
    CreateDirectoryW(out.c_str(), nullptr);
    if (!write_file(path, zip) || !unzip(path, out)) { err = L"falha ao extrair o REFramework"; return false; }
    if (!CopyFileW((out + L"\\dinput8.dll").c_str(), (game + L"\\dinput8.dll").c_str(), FALSE)) {
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

// 0 = já atualizado, 1 = atualizado, -1 = erro (err), -2 = sem acesso à Release
int update_mod(const std::wstring& game, std::wstring& version, std::wstring& err) {
    std::string release;
    std::string api = std::string("https://api.github.com/repos/") + kRepo + "/releases/latest";
    if (!http_get(widen(api), release)) return -2;
    const std::string tag = json_str(release, "tag_name");
    if (tag.empty()) return -2;
    version = widen(tag);
    const std::wstring vfile = game + L"\\reframework\\data\\dd2coop_version.txt";
    if (trim(read_file(vfile)) == tag && exists(game + L"\\reframework\\plugins\\dd2coop_net.dll")) return 0;
    const std::string zip_url = asset_url(release, "DD2Coop.zip"), sha_url = asset_url(release, "DD2Coop.zip.sha256");
    if (zip_url.empty() || sha_url.empty()) { err = L"Release sem DD2Coop.zip/.sha256"; return -1; }
    std::string zip, sha;
    if (!http_get(widen(sha_url), sha) || !http_get(widen(zip_url), zip)) { err = L"falha ao baixar a versao " + version; return -1; }
    if (sha256_hex(zip) != trim(sha).substr(0, 64)) { err = L"pacote baixado nao confere (SHA256); nada foi instalado"; return -1; }
    std::wstring tmp = temp_dir(), path = tmp + L"\\DD2Coop.zip", out = tmp + L"\\mod";
    remove_tree(out);
    CreateDirectoryW(out.c_str(), nullptr);
    if (!write_file(path, zip) || !unzip(path, out)) { err = L"falha ao extrair o pacote"; return -1; }
    if (!exists(out + L"\\reframework\\plugins\\dd2coop_net.dll")) { err = L"pacote incompleto"; return -1; }
    delete_old_scripts(game);
    if (!copy_tree(out, game)) { err = L"falha ao copiar arquivos para a pasta do jogo"; return -1; }
    return 1;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    const std::wstring game = find_game();
    if (game.empty()) {
        message(L"Nao achei o Dragon's Dogma 2. Coloque este launcher na pasta do jogo (onde fica o DD2.exe).",
            MB_ICONERROR);
        return 1;
    }
    if (game_running()) {
        message(L"Feche o Dragon's Dogma 2 antes de abrir o launcher.", MB_ICONWARNING);
        return 1;
    }
    std::wstring err;
    if (!exists(game + L"\\dinput8.dll") && !install_reframework(game, err)) {
        message(L"REFramework: " + err, MB_ICONERROR);
        return 1;
    }
    std::wstring version;
    const int r = update_mod(game, version, err);
    if (r == -1) {
        message(L"Atualizacao falhou: " + err + L"\nO jogo vai abrir com a versao instalada.", MB_ICONWARNING);
    } else if (r == -2 && !exists(game + L"\\reframework\\plugins\\dd2coop_net.dll")) {
        message(L"Sem acesso ao GitHub e o mod nao esta instalado.", MB_ICONERROR);
        return 1;
    } else if (r == 1) {
        message(L"DD2 Co-op atualizado para " + version + L".");
    }
    ShellExecuteW(nullptr, L"open", L"steam://rungameid/2054970", nullptr, nullptr, SW_SHOWNORMAL);
    return 0;
}
