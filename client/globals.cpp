// globals.cpp - Global variable definitions
#include "common.h"

// User-configurable settings
DWORD  g_nearLatencyMs    = 200;
int    g_nearRssiThreshold = -50;  // BLE RSSI 임계값 (dBm). 이 값 이상이면 NEAR
int    g_gattRssiThreshold = -55;  // v2(GATT) 임계값 (dBm). 폰이 측정한 연결 RSSI 기준
bool   g_gattSeen = false;
DWORD  g_gattGraceSec = 90;
ULONGLONG g_monStartTick = 0;
bool   g_bleLostMeansFar = false;  // 기본 false: iPhone은 잠금 시 광고가 멈추므로 끊김을 이탈로 보면 안 됨
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
std::atomic<ULONGLONG> g_lastInputTick{ 0 };
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
