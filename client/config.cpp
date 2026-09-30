// config.cpp - JSON config persistence
// Simple key=value format (no external JSON library needed)
#include "config.h"
#include <fstream>
#include <sstream>
#include <map>
#include <cctype>
#include <cstdarg>
#include <mutex>
#include <io.h>       // _commit
#include <share.h>    // _SH_DENYNO

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
    // 광고 콜백/틱 스레드/UI가 동시에 호출한다. 공유 모드로 열지 않으면
    // 동시 호출 시 한쪽의 _wfsopen이 실패해 메시지가 조용히 사라진다.
    static std::mutex mx;
    std::lock_guard<std::mutex> lock(mx);
    FILE* f = _wfsopen((GetConfigDir() + L"\\events.log").c_str(), L"a,ccs=UTF-8", _SH_DENYNO);
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

// config.ini 를 읽거나 바꿔 끼우는 동안 잡는다. 이 프로세스 안의 스레드끼리만
// 막아 준다 - 로그인 스레드가 읽는 순간과 UI 스레드가 새 파일을 끼우는 순간이
// 겹치지 않게. 다른 프로세스(--import-irk, --clip-test)와 겹치는 것은 아래의
// 재시도가 맡는다.
static std::mutex s_cfgFileMx;
// 읽기 실패는 상태가 바뀔 때만 적는다. 간단 창이 1초에 두 번 읽으므로 읽을 때마다
// 적으면 못 읽는 동안 로그가 그것으로 찬다. s_cfgFileMx 가 지킨다.
static bool s_readFailing = false;

// "파일이 없다" 와 "있는데 못 읽었다" 를 가른다. 예전에는 둘 다 빈 맵이었고,
// 부르는 쪽은 둘 다 "설정이 없다" 로 읽어 기본값을 그 위에 저장했다 (config.h).
enum class IniRead { Loaded, Absent, Failed };

// Simple INI-style read/write (UTF-16)
static IniRead ReadIni(const std::wstring& path, std::map<std::wstring, std::wstring>& m,
                       DWORD& outErr) {
    m.clear();
    outErr = 0;
    FILE* f = nullptr;
    // 못 열었으면 조금 기다렸다가 다시 연다. 겹치는 상대(다른 프로세스가 새 파일을
    // 끼우는 순간, 백신)는 파일을 마이크로초 단위로만 잡는다. 오래 기다리지 않는
    // 이유: 이 함수는 UI 스레드의 1초 타이머에서도 불린다.
    for (int attempt = 0; attempt < 5 && !f; attempt++) {
        if (attempt) Sleep(10);
        // events.log 와 같은 이유로 공유 모드로 연다 (위 DbgEvent 주석).
        f = _wfsopen(path.c_str(), L"r,ccs=UTF-8", _SH_DENYNO);
        if (f) break;
        outErr = GetLastError();
        if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
            DWORD e = GetLastError();
            if (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND) return IniRead::Absent;
        }
    }
    if (!f) return IniRead::Failed;
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
    // 읽다가 끊겼으면 앞부분만 들고 있는 것이다. 그것을 "설정" 으로 돌려주면
    // 뒤쪽 키들이 기본값으로 저장된다.
    bool readErr = (ferror(f) != 0);
    fclose(f);
    if (readErr) {
        m.clear();
        outErr = ERROR_READ_FAULT;
        return IniRead::Failed;
    }
    // 열렸는데 키가 하나도 없는 파일은 없는 것과 같다 (잃을 것이 없다).
    return m.empty() ? IniRead::Absent : IniRead::Loaded;
}

// config.ini.tmp 에 다 쓴 뒤 config.ini 자리에 끼운다.
//
// 예전에는 config.ini 를 "w" 로 열어 그 자리에서 잘라 내고 다시 썼다. 여는 순간
// 파일이 비므로 닫기 전에 죽으면(전원, 크래시) 빈 파일이나 반쪽 파일이 남았고,
// 못 열면 아무 말 없이 돌아가서 저장이 사라진 것을 아무도 몰랐다.
// 지금은 이름을 바꿔 끼우기 전까지 원래 파일에 손대지 않는다.
static bool WriteIni(const std::wstring& path, const std::map<std::wstring, std::wstring>& m,
                     const wchar_t*& outStage, DWORD& outErr) {
    const std::wstring tmp = path + L".tmp";
    outStage = L"";
    outErr = 0;

    FILE* f = nullptr;
    _wfopen_s(&f, tmp.c_str(), L"w,ccs=UTF-8");
    if (!f) {
        outErr = GetLastError();
        outStage = L"open config.ini.tmp";
        return false;
    }
    bool ok = true;
    for (auto& [k, v] : m) {
        if (fwprintf(f, L"%s=%s\n", k.c_str(), v.c_str()) < 0) ok = false;
    }
    if (fflush(f) != 0) ok = false;
    // 내용이 디스크에 닿은 뒤에 이름을 바꾼다. 순서가 반대면 전원이 나갔을 때
    // 이름은 바뀌었는데 내용은 없는 파일이 남을 수 있다.
    if (ok) _commit(_fileno(f));
    if (fclose(f) != 0) ok = false;
    if (!ok) {
        outErr = GetLastError();
        outStage = L"write config.ini.tmp";
        DeleteFileW(tmp.c_str());
        return false;
    }

    // 누가 config.ini 를 읽으려고 열고 있는 순간에는 바꿔 끼우기가 거절된다
    // (CRT 는 FILE_SHARE_DELETE 를 주지 않는다). 읽는 쪽은 금방 닫으므로 다시 해 본다.
    for (int attempt = 0; attempt < 10; attempt++) {
        if (attempt) Sleep(15);
        if (MoveFileExW(tmp.c_str(), path.c_str(),
                        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            return true;
        outErr = GetLastError();
    }
    outStage = L"replace config.ini";
    DeleteFileW(tmp.c_str());
    return false;
}

bool LoadAppConfig(AppConfig& cfg) {
    std::map<std::wstring, std::wstring> m;
    IniRead rd;
    DWORD err = 0;
    bool changed = false;
    {
        std::lock_guard<std::mutex> lock(s_cfgFileMx);
        rd = ReadIni(GetConfigPath(), m, err);
        bool failing = (rd == IniRead::Failed);
        if (failing != s_readFailing) { s_readFailing = failing; changed = true; }
    }
    cfg.loadFailed = (rd == IniRead::Failed);
    if (changed) {
        if (rd == IniRead::Failed)
            DbgEvent(L"config: config.ini is there but could not be read (err=%lu) - "
                     L"using defaults for now and refusing to save over it", err);
        else
            DbgEvent(L"config: config.ini can be read again");
    }
    if (rd != IniRead::Loaded) return false;

    if (m.count(L"btAddress")) {
        swscanf_s(m[L"btAddress"].c_str(), L"%llu", &cfg.btAddress);
    }
    if (m.count(L"nearLatencyMs")) cfg.nearLatencyMs = _wtoi(m[L"nearLatencyMs"].c_str());
    if (m.count(L"nearRssiThreshold")) cfg.nearRssiThreshold = _wtoi(m[L"nearRssiThreshold"].c_str());
    if (m.count(L"bleDebugLog")) cfg.bleDebugLog = (_wtoi(m[L"bleDebugLog"].c_str()) != 0);
    if (m.count(L"bleIrk")) cfg.bleIrk = m[L"bleIrk"];
    if (m.count(L"phoneToken")) cfg.phoneToken = m[L"phoneToken"];
    if (m.count(L"phoneOvfBit")) cfg.phoneOvfBit = _wtoi(m[L"phoneOvfBit"].c_str());
    if (m.count(L"bleTimeoutSec")) cfg.bleTimeoutSec = _wtoi(m[L"bleTimeoutSec"].c_str());
    if (m.count(L"bleGattServer")) cfg.bleGattServer = (_wtoi(m[L"bleGattServer"].c_str()) != 0);
    if (m.count(L"bleGattEncrypt")) cfg.bleGattEncrypt = (_wtoi(m[L"bleGattEncrypt"].c_str()) != 0);
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
    if (m.count(L"measuredBaseRssi")) cfg.measuredBaseRssi = _wtoi(m[L"measuredBaseRssi"].c_str());
    if (m.count(L"authRefresh")) cfg.authRefresh = m[L"authRefresh"];
    if (m.count(L"authUserId")) cfg.authUserId = m[L"authUserId"];
    if (m.count(L"authEmail")) cfg.authEmail = m[L"authEmail"];
    if (m.count(L"clipSync")) cfg.clipSync = (_wtoi(m[L"clipSync"].c_str()) != 0);
    if (m.count(L"clipMaxKB")) {
        // 서버가 받는 크기에 맞춘다: 텍스트 8 MiB, 그림 16 MiB (supabase/hardening.sql).
        // 그보다 크게 두면 올리기만 거절당한다. 0 은 예전에 "상한 없음" 이었는데,
        // 받는 쪽에도 상한이 생긴 지금은 "서버가 받는 만큼" 이다.
        int v = _wtoi(m[L"clipMaxKB"].c_str());
        cfg.clipMaxKB = (v <= 0 || v > 8192) ? 8192 : (DWORD)v;
    }
    if (m.count(L"orgId")) cfg.orgId = m[L"orgId"];
    if (m.count(L"serverUrl")) cfg.serverUrl = m[L"serverUrl"];
    if (m.count(L"anonKey")) cfg.anonKey = m[L"anonKey"];
    if (m.count(L"enterpriseRegistered")) cfg.enterpriseRegistered = (_wtoi(m[L"enterpriseRegistered"].c_str()) != 0);
    if (m.count(L"updateCheck")) cfg.updateCheck = (_wtoi(m[L"updateCheck"].c_str()) != 0);
    if (m.count(L"updateChannel")) {
        // 모르는 값이면 stable. 오타 하나로 업데이트가 조용히 멎으면 안 된다.
        cfg.updateChannel = (m[L"updateChannel"] == L"beta") ? L"beta" : L"stable";
    }

    // "읽을 설정이 있었는가". 예전에는 btAddress != 0 을 돌려줬는데,
    // 등록된 폰을 쓰면 Classic 주소가 없어 0이라 그때 설정 전체가 무시됐다.
    return true;
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

bool SaveAppConfig(const AppConfig& cfg) {
    // 읽지 못한 구조체는 기본값뿐이다. 그대로 쓰면 폰 토큰, 로그인, 조직 등록이
    // 전부 기본값으로 덮인다 - 파일을 잠깐 못 연 것뿐인데. 부르는 쪽 대부분이
    // Load 의 결과를 보지 않으므로 여기서 막는다.
    if (cfg.loadFailed) {
        DbgEvent(L"config: save refused - this copy came from a failed read; "
                 L"writing it would replace config.ini with defaults");
        return false;
    }
    std::map<std::wstring, std::wstring> m;
    wchar_t buf[64];
    swprintf_s(buf, L"%llu", cfg.btAddress); m[L"btAddress"] = buf;
    swprintf_s(buf, L"%lu", cfg.nearLatencyMs); m[L"nearLatencyMs"] = buf;
    swprintf_s(buf, L"%d", cfg.nearRssiThreshold); m[L"nearRssiThreshold"] = buf;
    m[L"bleDebugLog"] = cfg.bleDebugLog ? L"1" : L"0";
    m[L"bleIrk"] = cfg.bleIrk;
    m[L"phoneToken"] = cfg.phoneToken;
    swprintf_s(buf, L"%d", cfg.phoneOvfBit); m[L"phoneOvfBit"] = buf;
    swprintf_s(buf, L"%lu", cfg.bleTimeoutSec); m[L"bleTimeoutSec"] = buf;
    m[L"bleGattServer"] = cfg.bleGattServer ? L"1" : L"0";
    m[L"bleGattEncrypt"] = cfg.bleGattEncrypt ? L"1" : L"0";
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
    swprintf_s(buf, L"%d", cfg.measuredBaseRssi); m[L"measuredBaseRssi"] = buf;
    m[L"authRefresh"] = cfg.authRefresh;
    m[L"authUserId"] = cfg.authUserId;
    m[L"authEmail"] = cfg.authEmail;
    m[L"clipSync"] = cfg.clipSync ? L"1" : L"0";
    swprintf_s(buf, L"%lu", cfg.clipMaxKB); m[L"clipMaxKB"] = buf;
    m[L"orgId"] = cfg.orgId;
    m[L"serverUrl"] = cfg.serverUrl;
    m[L"anonKey"] = cfg.anonKey;
    m[L"enterpriseRegistered"] = cfg.enterpriseRegistered ? L"1" : L"0";
    m[L"updateCheck"] = cfg.updateCheck ? L"1" : L"0";
    m[L"updateChannel"] = cfg.updateChannel;

    const wchar_t* stage = L"";
    DWORD err = 0;
    bool ok;
    {
        std::lock_guard<std::mutex> lock(s_cfgFileMx);
        ok = WriteIni(GetConfigPath(), m, stage, err);
    }
    // 예전에는 못 써도 아무 흔적이 없었다. 저장이 사라진 것을 다음 실행에서야 알았다.
    if (!ok) DbgEvent(L"config: save FAILED at %s (err=%lu) - config.ini is unchanged", stage, err);
    return ok;
}
