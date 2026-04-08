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

// ---------------------------------------------------------------------------
// Enums & structs
// ---------------------------------------------------------------------------
enum class ProxState { Far, Near };

inline const wchar_t* StateStr(ProxState s) {
    return (s == ProxState::Near) ? L"WITHIN 1M" : L"FAR";
}

struct PairedDevice {
    BTH_ADDR     address;
    std::wstring name;
    bool         connected;
};

struct ProbeResult {
    bool      reachable;
    DWORD     latencyMs;
    int       wsaError;
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

inline std::wstring GetExeDir() {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring s(path);
    return s.substr(0, s.find_last_of(L"\\/") + 1);
}
