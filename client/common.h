// common.h - Shared types, constants, globals
#pragma once

#include <winsock2.h>
#include <ws2bth.h>
#include <bluetoothapis.h>
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <gdiplus.h>
#include <string>
#include <vector>
#include <algorithm>
#include <cstdio>
#include <cmath>
#include <atomic>

// ---------------------------------------------------------------------------
// Enums & structs
// ---------------------------------------------------------------------------
enum class ProxState { Far, Near };

inline const wchar_t* StateStr(ProxState s) {
    return (s == ProxState::Near) ? L"NEAR" : L"FAR";
}

struct PairedDevice {
    BTH_ADDR     address;
    std::wstring name;
    bool         connected;
};

struct ProbeResult {
    bool      reachable;
    DWORD     latencyMs;
    int       rssiDbm;       // BLE RSSI (dBm, 음수값. 예: -65)
    bool      gatt;          // true: v2(GATT 연결) RSSI, false: v1(광고) RSSI
    bool      bleAvailable;  // BLE RSSI 사용 가능 여부
    int       wsaError;
    // 이 샘플을 판정할 때 실제로 쓴 임계값. 히스테리시스 때문에 설정값과 다를 수 있어
    // (FAR에서 돌아올 때는 +4dB) 설정값만 찍으면 로그를 봐도 판정을 재현할 수 없다.
    int       thresholdDbm;
    wchar_t   timeStr[32];
    ProxState state;
    ProxState prevState;
    DWORD     timerRemainMs;
};

struct FarEvent {
    ULONGLONG  tickMs;
    SYSTEMTIME st;
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static constexpr DWORD RFCOMM_CONNECT_TIMEOUT_MS = 5000;
static constexpr DWORD CHART_WINDOW_MS = 30 * 60 * 1000;
static constexpr int   CHART_HEIGHT    = 80;
static constexpr DWORD WARMUP_MS       = 120000;

// ---------------------------------------------------------------------------
// User-configurable settings (global)
// ---------------------------------------------------------------------------
extern DWORD  g_nearLatencyMs;
extern int    g_nearRssiThreshold;  // RSSI 임계값 (dBm, 예: -70)
extern int    g_gattRssiThreshold;  // v2(GATT) RSSI 임계값 - 폰이 측정한 값이라 v1과 별도
extern bool   g_gattSeen;           // 이 PC에서 컴패니언 앱이 연결된 적이 있는지 (config에 저장)
extern DWORD  g_gattGraceSec;       // 모니터링 시작 후 앱 연결을 기다려 주는 시간(초)
extern ULONGLONG g_monStartTick;    // StartMon 시각
extern bool   g_bleLostMeansFar;    // BLE 수신 끊김을 범위 이탈로 볼지 (상시 광고 기기 전용)
extern DWORD  g_keepAliveSec;
extern DWORD  g_scanIntervalSec;
extern int    g_idleCountdownSec;
extern bool   g_unlockAuto;
extern int    g_unlockDelaySec;

// ---------------------------------------------------------------------------
// Shared state (global)
// ---------------------------------------------------------------------------
extern HWND      g_hWnd;
extern BTH_ADDR  g_targetAddr;
extern std::wstring g_targetName;
extern bool      g_monitoring;
extern ProxState g_proxState;
extern ULONGLONG g_lastNearTick;
extern ULONGLONG g_reconnectTick;
extern std::atomic<ULONGLONG> g_lastInputTick;  // 마지막 마우스/키보드 입력 시각
extern int       g_consecutiveFails;
extern std::vector<PairedDevice> g_paired;
extern std::vector<FarEvent>     g_farEvents;

// BlackScreen state
extern HWND      g_hBlackScreen;
extern bool      g_bBlackActive;
extern bool      g_bManualLock;
extern int       g_nCountdown;
extern int       g_unlockTimer;
extern wchar_t   g_ovlInfo[128];
extern ULONGLONG g_lockStartTick;

// Hooks
extern HHOOK     g_hMouseHook;
extern HHOOK     g_hKeyHook;

// Fonts & brushes (shared)
extern HFONT  g_hFont;
extern HFONT  g_hFontBold;
extern HFONT  g_hFontBig;
extern HFONT  g_hFontSmall;

// Config: image paths (personal edition)
extern std::wstring g_centerImagePath;
extern std::wstring g_bannerImagePath;

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------
inline std::wstring FmtAddr(BTH_ADDR a) {
    wchar_t b[32];
    swprintf_s(b, L"%02X:%02X:%02X:%02X:%02X:%02X",
        (int)((a>>40)&0xFF),(int)((a>>32)&0xFF),(int)((a>>24)&0xFF),
        (int)((a>>16)&0xFF),(int)((a>>8)&0xFF),(int)(a&0xFF));
    return b;
}

inline void NowStr(wchar_t* b, int n) {
    SYSTEMTIME s; GetLocalTime(&s);
    swprintf_s(b, n, L"%02d:%02d:%02d", s.wHour, s.wMinute, s.wSecond);
}

inline int LatencyToLevel(DWORD ms, bool reachable) {
    if (!reachable) return 0;
    if (ms <= g_nearLatencyMs) return 4;
    return 3;
}

// RSSI 기반 신호 레벨 (5단계, dBm)
inline int RssiToLevel(int rssi, bool receiving) {
    if (!receiving || rssi <= -100) return 0;  // 신호 없음
    if (rssi >= -50) return 5;  // 매우 강함 (~1m 이내)
    if (rssi >= -60) return 4;  // 강함 (~3m)
    if (rssi >= -70) return 3;  // 보통 (~5-7m)
    if (rssi >= -80) return 2;  // 약함 (~10m)
    return 1;                   // 매우 약함 (>10m)
}

inline const wchar_t* LevelBar(int lv) {
    switch (lv) {
    case 5: return L"\u2588\u2588\u2588\u2588\u2588";
    case 4: return L"\u2588\u2588\u2588\u2588\u2591";
    case 3: return L"\u2588\u2588\u2588\u2591\u2591";
    case 2: return L"\u2588\u2588\u2591\u2591\u2591";
    case 1: return L"\u2588\u2591\u2591\u2591\u2591";
    default: return L"\u2591\u2591\u2591\u2591\u2591";
    }
}

inline const wchar_t* LatencyToDist(DWORD ms) {
    if (ms < 150) return L"< 1m";
    if (ms < 300) return L"~1-2m";
    if (ms < 500) return L"~2-3m";
    if (ms < 1000) return L"~3-5m";
    if (ms < 2000) return L"~5-10m";
    return L"> 10m";
}

// RSSI 기반 거리 추정 (dBm → 거리 문자열)
// Log-distance path loss model 기반
inline const wchar_t* RssiToDist(int rssi) {
    if (rssi >= -45) return L"< 1m";
    if (rssi >= -55) return L"~1-2m";
    if (rssi >= -65) return L"~2-5m";
    if (rssi >= -75) return L"~5-10m";
    if (rssi >= -85) return L"~10-15m";
    return L"> 15m";
}

inline std::wstring GetExeDir() {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring s(path);
    return s.substr(0, s.find_last_of(L"\\/") + 1);
}
