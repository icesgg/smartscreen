// globals.cpp - Global variable definitions
#include "common.h"

// User-configurable settings
DWORD  g_nearLatencyMs    = 300;
DWORD  g_keepAliveSec     = 5;
DWORD  g_scanIntervalSec  = 2;
int    g_idleCountdownSec = 20;
bool   g_unlockAuto       = true;
int    g_unlockDelaySec   = 0;

// Shared state
HWND      g_hWnd           = nullptr;
BTH_ADDR  g_targetAddr     = 0;
std::wstring g_targetName;
bool      g_monitoring     = false;
ProxState g_proxState      = ProxState::Far;
ULONGLONG g_lastNearTick   = 0;
ULONGLONG g_reconnectTick  = 0;
int       g_consecutiveFails = 0;
std::vector<PairedDevice> g_paired;
std::vector<FarEvent>     g_farEvents;

// BlackScreen state
HWND      g_hBlackScreen   = nullptr;
HHOOK     g_hMouseHook     = nullptr;
HHOOK     g_hKeyHook       = nullptr;
int       g_nCountdown     = 20;
bool      g_bBlackActive   = false;
bool      g_bManualLock    = false;
int       g_unlockTimer    = 0;
wchar_t   g_ovlInfo[128]   = L"";
ULONGLONG g_lockStartTick  = 0;

// Fonts
HFONT  g_hFont     = nullptr;
HFONT  g_hFontBold = nullptr;
HFONT  g_hFontBig  = nullptr;
HFONT  g_hFontSmall = nullptr;

// Config: image paths
std::wstring g_centerImagePath;
std::wstring g_bannerImagePath;
