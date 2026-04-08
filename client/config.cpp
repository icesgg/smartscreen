// config.cpp - JSON config persistence
// Simple key=value format (no external JSON library needed)
#include "config.h"
#include <fstream>
#include <sstream>
#include <map>

std::wstring GetConfigDir() {
    wchar_t appdata[MAX_PATH];
    SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, appdata);
    std::wstring dir = std::wstring(appdata) + L"\\SmartScreen";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
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
    if (m.count(L"keepAliveSec")) cfg.keepAliveSec = _wtoi(m[L"keepAliveSec"].c_str());
    if (m.count(L"scanIntervalSec")) cfg.scanIntervalSec = _wtoi(m[L"scanIntervalSec"].c_str());
    if (m.count(L"idleCountdownSec")) cfg.idleCountdownSec = _wtoi(m[L"idleCountdownSec"].c_str());
    if (m.count(L"unlockAuto")) cfg.unlockAuto = (_wtoi(m[L"unlockAuto"].c_str()) != 0);
    if (m.count(L"unlockDelaySec")) cfg.unlockDelaySec = _wtoi(m[L"unlockDelaySec"].c_str());
    if (m.count(L"centerImagePath")) cfg.centerImagePath = m[L"centerImagePath"];
    if (m.count(L"bannerImagePath")) cfg.bannerImagePath = m[L"bannerImagePath"];
    if (m.count(L"orgId")) cfg.orgId = m[L"orgId"];
    if (m.count(L"serverUrl")) cfg.serverUrl = m[L"serverUrl"];
    if (m.count(L"enterpriseRegistered")) cfg.enterpriseRegistered = (_wtoi(m[L"enterpriseRegistered"].c_str()) != 0);

    return cfg.btAddress != 0;
}

void SaveAppConfig(const AppConfig& cfg) {
    std::map<std::wstring, std::wstring> m;
    wchar_t buf[64];
    swprintf_s(buf, L"%llu", cfg.btAddress); m[L"btAddress"] = buf;
    swprintf_s(buf, L"%lu", cfg.nearLatencyMs); m[L"nearLatencyMs"] = buf;
    swprintf_s(buf, L"%lu", cfg.keepAliveSec); m[L"keepAliveSec"] = buf;
    swprintf_s(buf, L"%lu", cfg.scanIntervalSec); m[L"scanIntervalSec"] = buf;
    swprintf_s(buf, L"%d", cfg.idleCountdownSec); m[L"idleCountdownSec"] = buf;
    m[L"unlockAuto"] = cfg.unlockAuto ? L"1" : L"0";
    swprintf_s(buf, L"%d", cfg.unlockDelaySec); m[L"unlockDelaySec"] = buf;
    m[L"centerImagePath"] = cfg.centerImagePath;
    m[L"bannerImagePath"] = cfg.bannerImagePath;
    m[L"orgId"] = cfg.orgId;
    m[L"serverUrl"] = cfg.serverUrl;
    m[L"enterpriseRegistered"] = cfg.enterpriseRegistered ? L"1" : L"0";
    WriteIni(GetConfigPath(), m);
}
