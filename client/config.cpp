// config.cpp - JSON config persistence
// Simple key=value format (no external JSON library needed)
#include "config.h"
#include <fstream>
#include <sstream>
#include <map>
#include <cctype>
#include <cstdarg>

std::wstring GetConfigDir() {
    wchar_t appdata[MAX_PATH];
    SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, appdata);
    std::wstring dir = std::wstring(appdata) + L"\\SmartScreen";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

bool g_debugEvents = true;

void DbgEvent(const wchar_t* fmt, ...) {
    if (!g_debugEvents) return;
    FILE* f = _wfsopen((GetConfigDir() + L"\\events.log").c_str(), L"a,ccs=UTF-8", _SH_DENYWR);
    if (!f) return;
    SYSTEMTIME st; GetLocalTime(&st);
    fwprintf(f, L"%02d:%02d:%02d ", st.wHour, st.wMinute, st.wSecond);
    va_list ap; va_start(ap, fmt);
    vfwprintf(f, fmt, ap);
    va_end(ap);
    fwprintf(f, L"\n");
    fclose(f);
}

static std::wstring GetConfigPath() {
    return GetConfigDir() + L"\\config.ini";
}

// Simple INI-style read/write (UTF-16)
static std::map<std::wstring, std::wstring> ReadIni(const std::wstring& path) {
    std::map<std::wstring, std::wstring> m;
    FILE* f = nullptr;
    _wfopen_s(&f, path.c_str(), L"r,ccs=UTF-8");
    if (!f) return m;
    wchar_t line[1024];
    while (fgetws(line, _countof(line), f)) {
        std::wstring s(line);
        // Remove newline
        while (!s.empty() && (s.back() == L'\n' || s.back() == L'\r')) s.pop_back();
        auto eq = s.find(L'=');
        if (eq != std::wstring::npos) {
            m[s.substr(0, eq)] = s.substr(eq + 1);
        }
    }
    fclose(f);
    return m;
}

static void WriteIni(const std::wstring& path, const std::map<std::wstring, std::wstring>& m) {
    FILE* f = nullptr;
    _wfopen_s(&f, path.c_str(), L"w,ccs=UTF-8");
    if (!f) return;
    for (auto& [k, v] : m) {
        fwprintf(f, L"%s=%s\n", k.c_str(), v.c_str());
    }
    fclose(f);
}

bool LoadAppConfig(AppConfig& cfg) {
    auto m = ReadIni(GetConfigPath());
    if (m.empty()) return false;

    if (m.count(L"btAddress")) {
        swscanf_s(m[L"btAddress"].c_str(), L"%llu", &cfg.btAddress);
    }
    if (m.count(L"nearLatencyMs")) cfg.nearLatencyMs = _wtoi(m[L"nearLatencyMs"].c_str());
    if (m.count(L"nearRssiThreshold")) cfg.nearRssiThreshold = _wtoi(m[L"nearRssiThreshold"].c_str());
    if (m.count(L"bleDebugLog")) cfg.bleDebugLog = (_wtoi(m[L"bleDebugLog"].c_str()) != 0);
    if (m.count(L"bleIrk")) cfg.bleIrk = m[L"bleIrk"];
    if (m.count(L"bleTimeoutSec")) cfg.bleTimeoutSec = _wtoi(m[L"bleTimeoutSec"].c_str());
    if (m.count(L"bleGattServer")) cfg.bleGattServer = (_wtoi(m[L"bleGattServer"].c_str()) != 0);
    if (m.count(L"bleGattPlain")) cfg.bleGattPlain = (_wtoi(m[L"bleGattPlain"].c_str()) != 0);
    if (m.count(L"gattSeen")) cfg.gattSeen = (_wtoi(m[L"gattSeen"].c_str()) != 0);
    if (m.count(L"gattGraceSec")) cfg.gattGraceSec = _wtoi(m[L"gattGraceSec"].c_str());
    if (m.count(L"gattRssiThreshold")) cfg.gattRssiThreshold = _wtoi(m[L"gattRssiThreshold"].c_str());
    if (m.count(L"bleLostMeansFar")) cfg.bleLostMeansFar = (_wtoi(m[L"bleLostMeansFar"].c_str()) != 0);
    if (m.count(L"keepAliveSec")) cfg.keepAliveSec = _wtoi(m[L"keepAliveSec"].c_str());
    if (m.count(L"scanIntervalSec")) cfg.scanIntervalSec = _wtoi(m[L"scanIntervalSec"].c_str());
    if (m.count(L"idleCountdownSec")) cfg.idleCountdownSec = _wtoi(m[L"idleCountdownSec"].c_str());
    if (m.count(L"unlockAuto")) cfg.unlockAuto = (_wtoi(m[L"unlockAuto"].c_str()) != 0);
    if (m.count(L"unlockDelaySec")) cfg.unlockDelaySec = _wtoi(m[L"unlockDelaySec"].c_str());
    if (m.count(L"centerImagePath")) cfg.centerImagePath = m[L"centerImagePath"];
    if (m.count(L"bannerImagePath")) cfg.bannerImagePath = m[L"bannerImagePath"];
    if (m.count(L"orgId")) cfg.orgId = m[L"orgId"];
    if (m.count(L"serverUrl")) cfg.serverUrl = m[L"serverUrl"];
    if (m.count(L"anonKey")) cfg.anonKey = m[L"anonKey"];
    if (m.count(L"enterpriseRegistered")) cfg.enterpriseRegistered = (_wtoi(m[L"enterpriseRegistered"].c_str()) != 0);

    return cfg.btAddress != 0;
}

bool ImportBleIrkFile(AppConfig& cfg, const std::wstring& path) {
    FILE* f = nullptr;
    _wfopen_s(&f, path.c_str(), L"rb");
    if (!f) return false;
    char buf[2048] = {};
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    std::string s(buf, n);

    // "    IRK    REG_BINARY    <32 hex>" 형식에서 hex 토큰 추출
    std::wstring hex;
    auto pos = s.find("REG_BINARY");
    if (pos != std::string::npos) {
        pos += 10;
        while (pos < s.size() && (s[pos] == ' ' || s[pos] == '\t')) pos++;
        while (pos < s.size() && isxdigit((unsigned char)s[pos])) hex += (wchar_t)s[pos++];
    }
    SecureZeroMemory(buf, sizeof(buf));
    if (hex.size() != 32) return false;

    cfg.bleIrk = hex;
    DeleteFileW(path.c_str());
    return true;
}

void SaveAppConfig(const AppConfig& cfg) {
    std::map<std::wstring, std::wstring> m;
    wchar_t buf[64];
    swprintf_s(buf, L"%llu", cfg.btAddress); m[L"btAddress"] = buf;
    swprintf_s(buf, L"%lu", cfg.nearLatencyMs); m[L"nearLatencyMs"] = buf;
    swprintf_s(buf, L"%d", cfg.nearRssiThreshold); m[L"nearRssiThreshold"] = buf;
    m[L"bleDebugLog"] = cfg.bleDebugLog ? L"1" : L"0";
    m[L"bleIrk"] = cfg.bleIrk;
    swprintf_s(buf, L"%lu", cfg.bleTimeoutSec); m[L"bleTimeoutSec"] = buf;
    m[L"bleGattServer"] = cfg.bleGattServer ? L"1" : L"0";
    m[L"bleGattPlain"] = cfg.bleGattPlain ? L"1" : L"0";
    m[L"gattSeen"] = cfg.gattSeen ? L"1" : L"0";
    swprintf_s(buf, L"%lu", cfg.gattGraceSec); m[L"gattGraceSec"] = buf;
    swprintf_s(buf, L"%d", cfg.gattRssiThreshold); m[L"gattRssiThreshold"] = buf;
    m[L"bleLostMeansFar"] = cfg.bleLostMeansFar ? L"1" : L"0";
    swprintf_s(buf, L"%lu", cfg.keepAliveSec); m[L"keepAliveSec"] = buf;
    swprintf_s(buf, L"%lu", cfg.scanIntervalSec); m[L"scanIntervalSec"] = buf;
    swprintf_s(buf, L"%d", cfg.idleCountdownSec); m[L"idleCountdownSec"] = buf;
    m[L"unlockAuto"] = cfg.unlockAuto ? L"1" : L"0";
    swprintf_s(buf, L"%d", cfg.unlockDelaySec); m[L"unlockDelaySec"] = buf;
    m[L"centerImagePath"] = cfg.centerImagePath;
    m[L"bannerImagePath"] = cfg.bannerImagePath;
    m[L"orgId"] = cfg.orgId;
    m[L"serverUrl"] = cfg.serverUrl;
    m[L"anonKey"] = cfg.anonKey;
    m[L"enterpriseRegistered"] = cfg.enterpriseRegistered ? L"1" : L"0";
    WriteIni(GetConfigPath(), m);
}
