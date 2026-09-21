// SmartScreen - BT Proximity + Screen Saver (Modular)
// client/main.cpp - UI, overlay, worker thread, WinMain

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "bthprops.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "comdlg32.lib")

#include "common.h"
#include "config.h"
#include "bluetooth.h"
#include "blackscreen.h"
#include "ble_rssi.h"
#include "ble_gatt.h"
#include "enterprise/supabase.h"

// ---------------------------------------------------------------------------
// UI IDs
// ---------------------------------------------------------------------------
static constexpr int ID_COMBO        = 201;
static constexpr int ID_REFRESH      = 202;
static constexpr int ID_START        = 203;
static constexpr int ID_STOP         = 204;
static constexpr int ID_CLEAR        = 205;
static constexpr int ID_EDIT_LATENCY = 206;
static constexpr int ID_EDIT_TIMEOUT = 207;
static constexpr int ID_EDIT_INTERVAL= 208;
static constexpr int ID_BT_SETTINGS  = 209;
static constexpr int ID_RECONNECT    = 210;
static constexpr int ID_EDIT_IDLE    = 211;
static constexpr int ID_BTN_BLACKNOW = 212;
static constexpr int ID_COMBO_UNLOCK = 213;
static constexpr int ID_EDIT_DELAY   = 214;
static constexpr int ID_BTN_CENTER_IMG = 215;
static constexpr int ID_BTN_BANNER_IMG = 216;
static constexpr int ID_BTN_ENTERPRISE = 217;
static constexpr UINT WM_SCAN_RESULT = WM_USER + 100;

// New combo IDs for simplified settings
static constexpr int ID_COMBO_DISTANCE = 220;
static constexpr int ID_COMBO_AWAY     = 221;
static constexpr int ID_COMBO_DELAY    = 222;
static constexpr int ID_COMBO_IDLE     = 223;

// Overlay
static constexpr int ID_OVL_EXIT     = 401;
static constexpr int ID_OVL_LOCK     = 402;
static constexpr int ID_OVL_SETTINGS = 403;
#define OVERLAY_CLASS L"SmartScreenOverlay"
static constexpr int OVL_W = 280;
static constexpr int OVL_H = 100;

static constexpr int IDT_COUNTDOWN   = 10;
static constexpr int WINDOW_W = 820;
static constexpr int WINDOW_H = 780;
static constexpr int CHART_H_UI = CHART_HEIGHT;

// ---------------------------------------------------------------------------
// UI Globals
// ---------------------------------------------------------------------------
static HWND   g_hCombo        = nullptr;
static HWND   g_hListView     = nullptr;
static HWND   g_hStatus       = nullptr;
static HWND   g_hStateLabel   = nullptr;
static HWND   g_hBtnStart     = nullptr;
static HWND   g_hBtnStop      = nullptr;
static HWND   g_hBtnReconnect = nullptr;
static HWND   g_hEditLatency  = nullptr;
static HWND   g_hEditTimeout  = nullptr;
static HWND   g_hEditInterval = nullptr;
static HWND   g_hEditIdle     = nullptr;
static HWND   g_hCountdownLabel = nullptr;
static HWND   g_hBtnClear      = nullptr;
static HWND   g_hImgGroup      = nullptr;
static HWND   g_hImgCenterLabel= nullptr;
static HWND   g_hImgCenterBrowse=nullptr;
static HWND   g_hImgBannerLabel= nullptr;
static HWND   g_hImgBannerBrowse=nullptr;
static HWND   g_hBtnEnterprise = nullptr;
static HWND   g_hComboUnlock  = nullptr;
static HWND   g_hEditDelay    = nullptr;
static HWND   g_hChart        = nullptr;
static HWND   g_hOverlay      = nullptr;
static HWND   g_hLabelCenter  = nullptr;
static HWND   g_hLabelBanner  = nullptr;
static HBRUSH g_hBrushNear    = nullptr;
static HBRUSH g_hBrushFar     = nullptr;
static HFONT  g_hFontOvl      = nullptr;
static HFONT  g_hFontOvlBtn   = nullptr;

// New combo handles for simplified settings
static HWND   g_hComboDistance = nullptr;
static HWND   g_hComboAway    = nullptr;
static HWND   g_hComboDelay   = nullptr;
static HWND   g_hComboIdle    = nullptr;

// Section header font
static HFONT  g_hFontSection  = nullptr;
// Overlay device name font
static HFONT  g_hFontOvlName  = nullptr;
// Near/Far/Locked brush for state label
static HBRUSH g_hBrushLocked  = nullptr;
static HBRUSH g_hBrushStopped = nullptr;

static HANDLE g_hThread       = nullptr;
static HANDLE g_hStopEvent    = nullptr;
static int    g_selectedIdx   = -1;
static int    g_logCount      = 0;

// Overlay state text
static wchar_t g_ovlLine1[64] = L"Stopped";
static wchar_t g_ovlLine2[64] = L"";
static COLORREF g_ovlColor = RGB(128, 128, 128);

// ---------------------------------------------------------------------------
// Combo mapping helpers
// ---------------------------------------------------------------------------

// Distance: "가까움" -> 85ms, "보통" -> 200ms, "멀리" -> 500ms
static const int kDistanceValues[] = { 85, 200, 500 };
static const wchar_t* kDistanceLabels[] = {
    L"\xAC00\xAE4C\xC6C0 (1m \xC774\xB0B4)",    // 가까움 (1m 이내)
    L"\xBCF4\xD1B5 (1~2m)",                        // 보통 (1~2m)
    L"\xBA40\xB9AC (2~3m)"                          // 멀리 (2~3m)
};

// Away detection: "빠름" -> 5s, "보통" -> 15s, "느림" -> 30s
static const int kAwayValues[] = { 5, 15, 30 };
static const wchar_t* kAwayLabels[] = {
    L"\xBE60\xB984 (5\xCD08)",    // 빠름 (5초)
    L"\xBCF4\xD1B5 (15\xCD08)",   // 보통 (15초)
    L"\xB290\xB9BC (30\xCD08)"     // 느림 (30초)
};

// Unlock delay: "즉시" -> 0, "10초" -> 10, "30초" -> 30, "1분" -> 60
static const int kDelayValues[] = { 0, 10, 30, 60 };
static const wchar_t* kDelayLabels[] = {
    L"\xC989\xC2DC",         // 즉시
    L"10\xCD08",             // 10초
    L"30\xCD08",             // 30초
    L"1\xBD84"               // 1분
};

// Idle time: "15초" -> 15, "30초" -> 30, "1분" -> 60, "2분" -> 120
static const int kIdleValues[] = { 15, 30, 60, 120 };
static const wchar_t* kIdleLabels[] = {
    L"15\xCD08",             // 15초
    L"30\xCD08",             // 30초
    L"1\xBD84",              // 1분
    L"2\xBD84"               // 2분
};

static int ComboFindValue(const int* values, int count, int target) {
    int best = 0;
    int bestDiff = abs(values[0] - target);
    for (int i = 1; i < count; i++) {
        int d = abs(values[i] - target);
        if (d < bestDiff) { bestDiff = d; best = i; }
    }
    return best;
}

// ---------------------------------------------------------------------------
// Image file picker (personal edition)
// ---------------------------------------------------------------------------
static std::wstring BrowseImage(HWND hParent) {
    wchar_t file[MAX_PATH] = {};
    OPENFILENAMEW ofn = {};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = hParent;
    ofn.lpstrFilter = L"Images & Videos (*.png;*.jpg;*.bmp;*.mp4;*.avi;*.wmv;*.mkv;*.mov;*.webm)\0*.png;*.jpg;*.jpeg;*.bmp;*.mp4;*.avi;*.wmv;*.mkv;*.mov;*.webm\0Images (*.png;*.jpg;*.bmp)\0*.png;*.jpg;*.jpeg;*.bmp\0Videos (*.mp4;*.avi;*.wmv;*.mkv)\0*.mp4;*.avi;*.wmv;*.mkv;*.mov;*.webm\0All Files\0*.*\0";
    ofn.lpstrFile = file;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
    if (GetOpenFileNameW(&ofn)) return file;
    return L"";
}

// ---------------------------------------------------------------------------
// Overlay
// ---------------------------------------------------------------------------
static bool g_ovlDragging = false;
static POINT g_ovlDragStart = {};

static void UpdateOverlayState() {
    if (!g_hOverlay) return;

    // Line 1: device name or "SmartScreen"
    if (g_monitoring && !g_targetName.empty()) {
        swprintf_s(g_ovlLine1, L"\u25A3 %s", g_targetName.c_str());
    } else {
        wcscpy_s(g_ovlLine1, L"\u25A3 SmartScreen");
    }

    // Line 2: status + color
    if (!g_monitoring) {
        wcscpy_s(g_ovlLine2, L"\xC815\xC9C0\xB428");  // 정지됨
        g_ovlColor = RGB(128, 128, 128);
    } else if (g_bBlackActive) {
        if (g_unlockTimer > 0)
            swprintf_s(g_ovlLine2, L"\xC7A0\xAE08  \u2022  %d\xCD08 \xD6C4 \xD574\xC81C", g_unlockTimer);  // 잠금 · Ns 후 해제
        else
            wcscpy_s(g_ovlLine2, L"\xC7A0\xAE08");  // 잠금
        g_ovlColor = RGB(235, 70, 70);
    } else if (g_proxState == ProxState::Near) {
        wcscpy_s(g_ovlLine2, L"\xADFC\xCC98  \u2022  \xBCF4\xD638 \xC911");  // 근처 · 보호 중
        g_ovlColor = RGB(60, 210, 90);
    } else {
        swprintf_s(g_ovlLine2, L"\xBA40\xB9AC  \u2022  %d\xCD08", g_nCountdown);  // 멀리 · Ns
        g_ovlColor = RGB(240, 170, 50);
    }

    InvalidateRect(g_hOverlay, nullptr, TRUE);
}

static LRESULT CALLBACK OverlayProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        // Dark-themed buttons
        HWND hExit = CreateWindowExW(0, L"BUTTON", L"\xC885\xB8CC",  // 종료
            WS_CHILD | WS_VISIBLE | BS_FLAT,
            10, 66, 60, 26, hWnd, (HMENU)(UINT_PTR)ID_OVL_EXIT,
            GetModuleHandle(nullptr), nullptr);
        HWND hLock = CreateWindowExW(0, L"BUTTON", L"\xC7A0\xAE08",  // 잠금
            WS_CHILD | WS_VISIBLE | BS_FLAT,
            78, 66, 60, 26, hWnd, (HMENU)(UINT_PTR)ID_OVL_LOCK,
            GetModuleHandle(nullptr), nullptr);
        HWND hSet = CreateWindowExW(0, L"BUTTON", L"\xC124\xC815",  // 설정
            WS_CHILD | WS_VISIBLE | BS_FLAT,
            146, 66, 60, 26, hWnd, (HMENU)(UINT_PTR)ID_OVL_SETTINGS,
            GetModuleHandle(nullptr), nullptr);
        (void)hExit; (void)hLock; (void)hSet;
        return 0;
    }

    case WM_COMMAND:
        switch (LOWORD(wParam)) {
        case ID_OVL_EXIT:
            if (g_monitoring) {
                SetEvent(g_hStopEvent);
                WaitForSingleObject(g_hThread, 15000);
                CloseProbeSocket();
                CloseHandle(g_hThread); CloseHandle(g_hStopEvent);
                g_hThread = nullptr; g_hStopEvent = nullptr;
                g_monitoring = false;
            }
            g_hOverlay = nullptr;
            DestroyWindow(hWnd);
            DestroyWindow(g_hWnd);
            break;
        case ID_OVL_LOCK:
            if (g_monitoring && !g_bBlackActive) {
                g_bBlackActive = true;
                g_bManualLock = true;
                g_lockStartTick = GetTickCount64();
                int x = GetSystemMetrics(SM_XVIRTUALSCREEN), y = GetSystemMetrics(SM_YVIRTUALSCREEN);
                int w = GetSystemMetrics(SM_CXVIRTUALSCREEN), h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
                g_hBlackScreen = CreateWindowExW(WS_EX_TOPMOST, BLACKSCREEN_CLASS, L"",
                    WS_POPUP, x, y, w, h, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
                ShowWindow(g_hBlackScreen, SW_SHOW); SetForegroundWindow(g_hBlackScreen);
            }
            break;
        case ID_OVL_SETTINGS:
            ShowWindow(g_hWnd, SW_SHOW);
            SetForegroundWindow(g_hWnd);
            break;
        }
        return 0;

    case WM_LBUTTONDOWN:
        g_ovlDragging = true;
        g_ovlDragStart = { (short)LOWORD(lParam), (short)HIWORD(lParam) };
        SetCapture(hWnd); return 0;
    case WM_MOUSEMOVE:
        if (g_ovlDragging) {
            POINT cur = { (short)LOWORD(lParam), (short)HIWORD(lParam) };
            RECT rc; GetWindowRect(hWnd, &rc);
            SetWindowPos(hWnd, nullptr, rc.left + cur.x - g_ovlDragStart.x,
                rc.top + cur.y - g_ovlDragStart.y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
        }
        return 0;
    case WM_LBUTTONUP:
        g_ovlDragging = false; ReleaseCapture(); return 0;

    case WM_ERASEBKGND: {
        HDC hdc = (HDC)wParam;
        RECT rc; GetClientRect(hWnd, &rc);

        // Dark background RGB(20,22,28)
        HBRUSH brBg = CreateSolidBrush(RGB(20, 22, 28));
        FillRect(hdc, &rc, brBg);
        DeleteObject(brBg);

        // Subtle border
        HPEN pen = CreatePen(PS_SOLID, 1, RGB(55, 58, 68));
        HPEN op = (HPEN)SelectObject(hdc, pen);
        MoveToEx(hdc, 0, 0, nullptr);
        LineTo(hdc, rc.right - 1, 0);
        LineTo(hdc, rc.right - 1, rc.bottom - 1);
        LineTo(hdc, 0, rc.bottom - 1);
        LineTo(hdc, 0, 0);
        SelectObject(hdc, op);
        DeleteObject(pen);

        // Color accent bar at left edge
        RECT accent = { 0, 0, 4, rc.bottom };
        HBRUSH brAccent = CreateSolidBrush(g_ovlColor);
        FillRect(hdc, &accent, brAccent);
        DeleteObject(brAccent);

        SetBkMode(hdc, TRANSPARENT);

        // Line 1: device name (white, Segoe UI Semibold)
        HFONT oldF = (HFONT)SelectObject(hdc, g_hFontOvlName);
        SetTextColor(hdc, RGB(220, 222, 228));
        RECT tr1 = { 14, 6, rc.right - 10, 28 };
        DrawTextW(hdc, g_ovlLine1, -1, &tr1, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);

        // Line 2: status (colored, larger)
        SelectObject(hdc, g_hFontOvl);
        SetTextColor(hdc, g_ovlColor);
        RECT tr2 = { 14, 30, rc.right - 10, 56 };
        DrawTextW(hdc, g_ovlLine2, -1, &tr2, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

        // Overlay info line (lock duration etc.)
        if (g_ovlInfo[0]) {
            SelectObject(hdc, g_hFontOvlBtn);
            SetTextColor(hdc, RGB(160, 160, 120));
            RECT ir = { 14, 50, rc.right - 10, 66 };
            DrawTextW(hdc, g_ovlInfo, -1, &ir, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        }

        SelectObject(hdc, oldF);
        return 1;
    }
    case WM_DESTROY: g_hOverlay = nullptr; break;
    }
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// Idle detection hooks
// ---------------------------------------------------------------------------
static void ResetCountdown() {
    g_lastInputTick = GetTickCount64();
    g_nCountdown = g_idleCountdownSec;
    if (g_bBlackActive) {
        // Mouse/keyboard input always unlocks immediately
        DeactivateBlackScreen();
    }
    if (g_ovlInfo[0]) { g_ovlInfo[0] = L'\0'; if (g_hOverlay) InvalidateRect(g_hOverlay, nullptr, TRUE); }
}

static LRESULT CALLBACK LLMouseProc(int nCode, WPARAM w, LPARAM l) {
    if (nCode == HC_ACTION) ResetCountdown();
    return CallNextHookEx(g_hMouseHook, nCode, w, l);
}
static LRESULT CALLBACK LLKeyProc(int nCode, WPARAM w, LPARAM l) {
    if (nCode == HC_ACTION) ResetCountdown();
    return CallNextHookEx(g_hKeyHook, nCode, w, l);
}

// ---------------------------------------------------------------------------
// Reconnect thread
// ---------------------------------------------------------------------------
static DWORD WINAPI ReconnectThread(LPVOID) {
    ReconnectDevice(g_targetAddr);
    g_reconnectTick = GetTickCount64();
    EnableWindow(g_hBtnReconnect, TRUE);
    SetWindowTextW(g_hBtnReconnect, L"\xC7AC\xC5F0\xACB0");  // 재연결
    return 0;
}

// ---------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------
static DWORD WINAPI ScanThread(LPVOID) {
    g_proxState = ProxState::Far;
    g_lastNearTick = 0;
    while (true) {
        bool reachable = false; DWORD latency = 0; int wsaErr = 0;
        bool isNear = false, bleAvail = false, useGatt = false;
        int rssi = -100;

        // 컴패니언 앱이 이 PC에 붙은 적이 있으면(이번 세션 또는 과거), GATT 연결 여부 자체가 "재실 신호".
        // 이 경우 광고/latency 폴백을 쓰지 않는다 - latency는 30~50m까지 닿아서 자리 비움을 놓친다.
        bool gattExpected = g_bleGatt.IsRunning() &&
            (g_bleGatt.EverSubscribed() || (g_gattSeen &&
                (GetTickCount64() - g_monStartTick) > (ULONGLONG)g_gattGraceSec * 1000));

        if (g_bleGatt.IsHealthy()) {
            // v2: 폰 앱이 GATT로 연결되어 ~1Hz로 RSSI를 보고 중 → 최우선 사용
            useGatt = true; bleAvail = true; reachable = true;
            rssi = g_bleGatt.GetSmoothedRssi();
            if (g_bleGatt.CurrentPollIntervalMs() == 0) {
                isNear = true;                               // 입력 중이라 폴링을 쉬는 상태 = 자리에 있음
            } else if (g_bleGatt.ReportAgeMs() == 0xFFFFFFFF) {
                isNear = (g_proxState == ProxState::Near);   // 첫 보고 대기 중: 현재 상태 유지
            } else {
                // 히스테리시스: 잠금은 임계값 미만, 해제는 임계값+4 이상 (경계에서 깜빡임 방지)
                int thr = g_gattRssiThreshold + (g_proxState == ProxState::Near ? 0 : 4);
                isNear = (rssi >= thr);
            }
        } else if (gattExpected) {
            // 앱이 붙어 있어야 하는데 연결이 없음 = 범위 이탈(또는 앱 종료) → 부재로 판정
            useGatt = true; bleAvail = true; reachable = true;
            rssi = -100;
            isNear = false;
        } else {
            // v1: BLE 광고 RSSI (키플 방식) - 컴패니언 앱을 안 쓰거나, 아직 첫 연결 대기 중
            rssi = g_bleScanner.GetSmoothedRssi();
            // BLE 끊김 처리는 기기 종류에 따라 다름:
            //  - 상시 광고 기기(비콘): 끊김 = 범위 이탈 → rssi=-100으로 Far 판정 (g_bleLostMeansFar=true)
            //  - 앱 없는 iPhone: 잠금 상태에서 광고를 멈추므로 끊김 ≠ 이탈 → 수신 중일 때만 RSSI 사용
            bleAvail = g_bleScanner.IsAvailable() &&
                (g_bleLostMeansFar ? g_bleScanner.HasEverReceived() : g_bleScanner.IsReceiving());
            if (bleAvail) {
                // BLE로 판단하는 동안은 RFCOMM 프로브를 생략:
                // 같은 BT 어댑터에서 Classic 연결 시도가 BLE 스캔 시간을 빼앗아 광고 수신율을 떨어뜨림
                reachable = true;
                isNear = (rssi >= g_nearRssiThreshold);
            } else {
                // BLE 불가 → 기존 latency fallback
                DoProbe(g_targetAddr, reachable, latency, wsaErr);
            }
        }

        // 앱이 처음 연결되면 config에 기록 → 다음부터는 미연결을 "부재"로 취급
        if (!g_gattSeen && g_bleGatt.EverSubscribed()) {
            g_gattSeen = true;
            AppConfig sc; LoadAppConfig(sc); sc.gattSeen = true; SaveAppConfig(sc);
            DbgEvent(L"companion app seen - GATT connection is now required for NEAR");
        }

        ULONGLONG now = GetTickCount64();
        ProxState prev = g_proxState;
        if (!bleAvail) {
            bool inWarmup = (g_reconnectTick > 0 && (now - g_reconnectTick) < WARMUP_MS);
            isNear = reachable && (latency <= g_nearLatencyMs || inWarmup);
        }

        if (isNear) {
            g_lastNearTick = now;
            if (g_proxState == ProxState::Far) g_proxState = ProxState::Near;
        } else {
            // BLE 모드: 패킷 사이에는 새 정보가 없으므로(스무딩 값 고정) 유예시간은 지연만 추가함 → 즉시 Far
            // latency 모드: 측정값이 매번 흔들리므로 기존 유예시간 유지
            ULONGLONG holdMs = bleAvail ? 0 : (ULONGLONG)g_keepAliveSec * 1000;
            if (g_proxState == ProxState::Near && (now - g_lastNearTick) >= holdMs)
                g_proxState = ProxState::Far;
        }
        auto* r = new ProbeResult{};
        r->reachable = reachable; r->latencyMs = latency; r->wsaError = wsaErr;
        r->rssiDbm = rssi; r->bleAvailable = bleAvail; r->gatt = useGatt;
        r->state = g_proxState; r->prevState = prev;
        NowStr(r->timeStr, _countof(r->timeStr));
        if (g_proxState == ProxState::Near) {
            DWORD since = (DWORD)(now - g_lastNearTick), keepMs = g_keepAliveSec * 1000;
            r->timerRemainMs = (since < keepMs) ? (keepMs - since) : 0;
        } else r->timerRemainMs = 0;
        PostMessage(g_hWnd, WM_SCAN_RESULT, 0, (LPARAM)r);
        // 대상 기기의 BLE 패킷이 도착하면 주기를 기다리지 않고 즉시 재판정
        HANDLE waits[3] = { g_hStopEvent, g_bleScanner.PacketEvent(), g_bleGatt.ReportEvent() };
        if (WaitForMultipleObjects(3, waits, FALSE, g_scanIntervalSec * 1000) == WAIT_OBJECT_0) break;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// PopulateCombo
// ---------------------------------------------------------------------------
static void PopulateCombo() {
    SendMessageW(g_hCombo, CB_RESETCONTENT, 0, 0);
    EnumPaired();
    if (g_paired.empty()) {
        SendMessageW(g_hCombo, CB_ADDSTRING, 0, (LPARAM)L"(\xD398\xC5B4\xB9C1\xB41C \xAE30\xAE30 \xC5C6\xC74C)");  // (페어링된 기기 없음)
        EnableWindow(g_hBtnStart, FALSE); return;
    }
    for (size_t i = 0; i < g_paired.size(); i++) {
        wchar_t it[256];
        swprintf_s(it, L"%s  [%s]%s", g_paired[i].name.c_str(),
            FmtAddr(g_paired[i].address).c_str(), g_paired[i].connected ? L" *" : L"");
        SendMessageW(g_hCombo, CB_ADDSTRING, 0, (LPARAM)it);
    }
    for (size_t i = 0; i < g_paired.size(); i++) {
        if (g_paired[i].address == g_targetAddr) {
            SendMessageW(g_hCombo, CB_SETCURSEL, i, 0);
            EnableWindow(g_hBtnStart, TRUE); return;
        }
    }
    SendMessageW(g_hCombo, CB_SETCURSEL, 0, 0);
    EnableWindow(g_hBtnStart, TRUE);
}

// ---------------------------------------------------------------------------
// Start / Stop
// ---------------------------------------------------------------------------
static void StartMon() {
    int sel = (int)SendMessageW(g_hCombo, CB_GETCURSEL, 0, 0);
    if (sel < 0 || sel >= (int)g_paired.size()) return;

    // RSSI 임계값 읽기 (에디트 박스에서)
    wchar_t latBuf[16];
    GetWindowTextW(g_hEditLatency, latBuf, _countof(latBuf));
    int latVal = _wtoi(latBuf);
    // RSSI는 음수값 (-30 ~ -100 범위)
    if (latVal > 0) latVal = -latVal;  // 양수 입력시 음수로 변환
    if (latVal > -30) latVal = -30;
    if (latVal < -100) latVal = -100;
    g_nearRssiThreshold = latVal;
    swprintf_s(latBuf, L"%d", latVal); SetWindowTextW(g_hEditLatency, latBuf);
    // latency fallback용 (호환성)
    g_nearLatencyMs = 200;

    int awayIdx = (int)SendMessageW(g_hComboAway, CB_GETCURSEL, 0, 0);
    if (awayIdx < 0) awayIdx = 0;
    g_keepAliveSec = kAwayValues[awayIdx];

    // Interval is hardcoded to 2s
    g_scanIntervalSec = 2;

    int idleIdx = (int)SendMessageW(g_hComboIdle, CB_GETCURSEL, 0, 0);
    if (idleIdx < 0) idleIdx = 1;
    g_idleCountdownSec = kIdleValues[idleIdx];
    g_nCountdown = g_idleCountdownSec;

    // Unlock mode is hardcoded to auto
    g_unlockAuto = true;

    int delayIdx = (int)SendMessageW(g_hComboDelay, CB_GETCURSEL, 0, 0);
    if (delayIdx < 0) delayIdx = 0;
    g_unlockDelaySec = kDelayValues[delayIdx];

    g_selectedIdx = sel;
    g_targetAddr = g_paired[sel].address;
    g_targetName = g_paired[sel].name;
    g_logCount = 0;

    // Save config (load first to preserve enterprise settings)
    AppConfig cfg;
    LoadAppConfig(cfg);

    // BLE RSSI 스캐너 시작 (기기 이름으로 BLE 광고 매칭)
    // config.ini에 bleDebugLog=1 이면 주변 광고를 ble_scan_log.csv로 기록
    // IRK: exe 옆에 irk.txt(1회 추출 파일)가 있으면 config로 가져온 뒤 삭제
    if (cfg.bleIrk.empty()) ImportBleIrkFile(cfg, GetExeDir() + L"irk.txt");
    g_bleScanner.SetIrk(cfg.bleIrk);
    g_bleLostMeansFar = cfg.bleLostMeansFar;
    DbgEvent(L"START thr=%d dBm keepAlive=%lus idle=%ds unlockDelay=%ds bleTimeout=%lus lostMeansFar=%d irk=%d",
        g_nearRssiThreshold, g_keepAliveSec, g_idleCountdownSec, g_unlockDelaySec,
        cfg.bleTimeoutSec, cfg.bleLostMeansFar ? 1 : 0, cfg.bleIrk.empty() ? 0 : 1);
    g_bleScanner.SetTimeoutSec(cfg.bleTimeoutSec);
    g_bleScanner.SetDebugLog(cfg.bleDebugLog ? GetConfigDir() + L"\\ble_scan_log.csv" : L"");
    g_bleScanner.Start(g_targetName, g_targetAddr);

    // v2: GATT 서버 시작 (폰 앱이 연결해 오면 1Hz RSSI 보고를 받음. 실패해도 v1/latency로 동작)
    g_gattRssiThreshold = cfg.gattRssiThreshold;
    g_gattSeen = cfg.gattSeen;
    g_gattGraceSec = cfg.gattGraceSec;
    g_monStartTick = GetTickCount64();
    g_lastInputTick = GetTickCount64();
    if (cfg.bleGattServer) {
        bool ok = g_bleGatt.Start(cfg.bleGattPlain, GetConfigDir() + L"\\gatt_rssi_log.csv");
        DbgEvent(L"GATT server start: %s (plain=%d, thr=%d dBm)",
            ok ? L"OK" : L"FAILED", cfg.bleGattPlain ? 1 : 0, g_gattRssiThreshold);
    } else {
        DbgEvent(L"GATT server disabled by config");
    }
    cfg.btAddress = g_targetAddr;
    cfg.nearLatencyMs = g_nearLatencyMs;
    cfg.nearRssiThreshold = g_nearRssiThreshold;
    cfg.gattSeen = g_gattSeen;
    cfg.keepAliveSec = g_keepAliveSec;
    cfg.scanIntervalSec = g_scanIntervalSec;
    cfg.idleCountdownSec = g_idleCountdownSec;
    cfg.unlockAuto = g_unlockAuto;
    cfg.unlockDelaySec = g_unlockDelaySec;
    cfg.centerImagePath = g_centerImagePath;
    cfg.bannerImagePath = g_bannerImagePath;
    SaveAppConfig(cfg);

    g_hStopEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    g_hThread = CreateThread(nullptr, 0, ScanThread, nullptr, 0, nullptr);
    g_monitoring = true;
    g_hMouseHook = SetWindowsHookExW(WH_MOUSE_LL, LLMouseProc, nullptr, 0);
    g_hKeyHook = SetWindowsHookExW(WH_KEYBOARD_LL, LLKeyProc, nullptr, 0);
    SetTimer(g_hWnd, IDT_COUNTDOWN, 1000, nullptr);

    EnableWindow(g_hBtnStart, FALSE); EnableWindow(g_hBtnStop, TRUE);
    EnableWindow(g_hCombo, FALSE);
    EnableWindow(g_hEditLatency, FALSE); EnableWindow(g_hComboAway, FALSE);
    EnableWindow(g_hComboIdle, FALSE); EnableWindow(g_hComboDelay, FALSE);
}

static void StopMon() {
    if (!g_monitoring) return;
    SetEvent(g_hStopEvent);
    WaitForSingleObject(g_hThread, 15000);
    CloseProbeSocket();
    g_bleScanner.Stop();  // BLE RSSI 스캐너 중지
    g_bleGatt.Stop();
    CloseHandle(g_hThread); CloseHandle(g_hStopEvent);
    g_hThread = nullptr; g_hStopEvent = nullptr;
    g_monitoring = false;
    KillTimer(g_hWnd, IDT_COUNTDOWN);
    if (g_hMouseHook) { UnhookWindowsHookEx(g_hMouseHook); g_hMouseHook = nullptr; }
    if (g_hKeyHook) { UnhookWindowsHookEx(g_hKeyHook); g_hKeyHook = nullptr; }
    if (g_bBlackActive) DeactivateBlackScreen();
    EnableWindow(g_hBtnStart, TRUE); EnableWindow(g_hBtnStop, FALSE);
    EnableWindow(g_hCombo, TRUE);
    EnableWindow(g_hEditLatency, TRUE); EnableWindow(g_hComboAway, TRUE);
    EnableWindow(g_hComboIdle, TRUE); EnableWindow(g_hComboDelay, TRUE);
    SetWindowTextW(g_hStateLabel, L"  \xC815\xC9C0\xB428");  // 정지됨
}

// ---------------------------------------------------------------------------
// Chart
// ---------------------------------------------------------------------------
static void PaintChart(HWND hWnd) {
    PAINTSTRUCT ps; HDC hdc = BeginPaint(hWnd, &ps);
    RECT rc; GetClientRect(hWnd, &rc); int W = rc.right, H = rc.bottom;
    HDC mem = CreateCompatibleDC(hdc);
    HBITMAP bmp = CreateCompatibleBitmap(hdc, W, H);
    HBITMAP ob = (HBITMAP)SelectObject(mem, bmp);
    HBRUSH bg = CreateSolidBrush(RGB(25, 25, 35)); FillRect(mem, &rc, bg); DeleteObject(bg);
    int mL=55,mR=15,mT=22,mB=20,cW=W-mL-mR,cH=H-mT-mB;
    if(cW<50||cH<20){EndPaint(hWnd,&ps);SelectObject(mem,ob);DeleteObject(bmp);DeleteDC(mem);return;}
    HPEN bp=CreatePen(PS_SOLID,1,RGB(80,80,100));SelectObject(mem,bp);
    MoveToEx(mem,mL,mT,0);LineTo(mem,mL+cW,mT);LineTo(mem,mL+cW,mT+cH);
    LineTo(mem,mL,mT+cH);LineTo(mem,mL,mT);DeleteObject(bp);
    SelectObject(mem,g_hFontSmall);SetBkMode(mem,TRANSPARENT);
    SetTextColor(mem,RGB(200,200,220));TextOutW(mem,mL,2,L"30-min Timeline (FAR events)",28);
    ULONGLONG now=GetTickCount64();ULONGLONG ws=(now>CHART_WINDOW_MS)?(now-CHART_WINDOW_MS):0;
    HPEN gp=CreatePen(PS_DOT,1,RGB(60,60,80));SelectObject(mem,gp);
    SetTextColor(mem,RGB(140,140,160));SYSTEMTIME sn;GetLocalTime(&sn);
    for(int m=0;m<=30;m+=5){ULONGLONG t=now-(ULONGLONG)m*60000;if(t<ws)break;
        int x=mL+(int)((double)(t-ws)/CHART_WINDOW_MS*cW);
        MoveToEx(mem,x,mT+1,0);LineTo(mem,x,mT+cH-1);
        FILETIME ft;SystemTimeToFileTime(&sn,&ft);ULARGE_INTEGER u;
        u.LowPart=ft.dwLowDateTime;u.HighPart=ft.dwHighDateTime;
        u.QuadPart-=(ULONGLONG)m*60000*10000;ft.dwLowDateTime=u.LowPart;ft.dwHighDateTime=u.HighPart;
        SYSTEMTIME sl;FileTimeToSystemTime(&ft,&sl);
        wchar_t lb[16];swprintf_s(lb,L"%02d:%02d",sl.wHour,sl.wMinute);
        TextOutW(mem,x-15,mT+cH+3,lb,(int)wcslen(lb));}
    DeleteObject(gp);
    SetTextColor(mem,RGB(0,200,0));TextOutW(mem,4,mT+2,L"NEAR",4);
    SetTextColor(mem,RGB(220,60,60));TextOutW(mem,4,mT+cH-16,L"FAR",3);
    int bY=mT+4,bH=cH-8;
    if(g_monitoring){HBRUSH nb=CreateSolidBrush(RGB(0,120,0));
        RECT br2={mL+1,bY,mL+cW-1,bY+bH};FillRect(mem,&br2,nb);DeleteObject(nb);}
    HPEN fp=CreatePen(PS_SOLID,2,RGB(255,50,50));HBRUSH fb=CreateSolidBrush(RGB(255,50,50));
    SelectObject(mem,fp);SelectObject(mem,fb);
    for(auto&ev:g_farEvents){if(ev.tickMs<ws)continue;
        int x=mL+(int)((double)(ev.tickMs-ws)/CHART_WINDOW_MS*cW);
        MoveToEx(mem,x,bY,0);LineTo(mem,x,bY+bH);
        POINT tri[3]={{x,bY-2},{x-5,bY-10},{x+5,bY-10}};Polygon(mem,tri,3);
        wchar_t tl[16];swprintf_s(tl,L"%02d:%02d:%02d",ev.st.wHour,ev.st.wMinute,ev.st.wSecond);
        SetTextColor(mem,RGB(255,120,120));
        TextOutW(mem,(std::max)(x-24,mL),bY-12,tl,(int)wcslen(tl));}
    DeleteObject(fp);DeleteObject(fb);
    {int x=mL+cW-1;HPEN np=CreatePen(PS_SOLID,2,RGB(255,255,100));SelectObject(mem,np);
     MoveToEx(mem,x,bY,0);LineTo(mem,x,bY+bH);DeleteObject(np);
     SetTextColor(mem,RGB(255,255,100));TextOutW(mem,x-12,bY-12,L"now",3);}
    {int cnt=0;for(auto&e:g_farEvents)if(e.tickMs>=ws)cnt++;
     wchar_t inf[32];swprintf_s(inf,L"FAR: %d",cnt);SetTextColor(mem,RGB(180,180,200));
     TextOutW(mem,mL+cW-60,2,inf,(int)wcslen(inf));}
    BitBlt(hdc,0,0,W,H,mem,0,0,SRCCOPY);
    SelectObject(mem,ob);DeleteObject(bmp);DeleteDC(mem);EndPaint(hWnd,&ps);
}
static LRESULT CALLBACK ChartProc(HWND h,UINT m,WPARAM w,LPARAM l){
    if(m==WM_PAINT){PaintChart(h);return 0;}if(m==WM_ERASEBKGND)return 1;
    return DefWindowProcW(h,m,w,l);}

// ---------------------------------------------------------------------------
// ListView
// ---------------------------------------------------------------------------
static void InitListView(HWND p, int y) {
    INITCOMMONCONTROLSEX ic={sizeof(ic),ICC_LISTVIEW_CLASSES};InitCommonControlsEx(&ic);
    g_hListView=CreateWindowExW(WS_EX_CLIENTEDGE,WC_LISTVIEWW,L"",
        WS_CHILD|WS_VISIBLE|LVS_REPORT|LVS_SINGLESEL|LVS_NOSORTHEADER,
        10,y,WINDOW_W-40,200,p,nullptr,GetModuleHandle(nullptr),nullptr);
    ListView_SetExtendedListViewStyle(g_hListView,
        LVS_EX_FULLROWSELECT|LVS_EX_GRIDLINES|LVS_EX_DOUBLEBUFFER);
    struct C{const wchar_t*t;int w;};
    C cols[]={{L"Time",70},{L"\xC2E0\xD638 \xAC15\xB3C4",70},{L"Signal",80},{L"Distance",80},
              {L"State",80},{L"Timer",55},{L"Event",250}};
    for(int i=0;i<_countof(cols);i++){
        LVCOLUMNW c={};c.mask=LVCF_TEXT|LVCF_WIDTH|LVCF_SUBITEM;
        c.pszText=const_cast<LPWSTR>(cols[i].t);c.cx=cols[i].w;
        ListView_InsertColumn(g_hListView,i,&c);}
}

// ---------------------------------------------------------------------------
// OnResult
// ---------------------------------------------------------------------------
static void OnResult(ProbeResult* r) {
    g_logCount++;
    bool transition = (r->state != r->prevState);
    if (transition)
        DbgEvent(L"STATE %s -> %s  (%s rssi=%d dBm thr=%d, latency=%lums reachable=%d)",
            r->prevState == ProxState::Near ? L"NEAR" : L"FAR", r->state == ProxState::Near ? L"NEAR" : L"FAR",
            r->gatt ? L"GATT" : (r->bleAvailable ? L"adv" : L"latency"), r->rssiDbm,
            r->gatt ? g_gattRssiThreshold : g_nearRssiThreshold, r->latencyMs, r->reachable ? 1 : 0);
    if (transition && r->state == ProxState::Far) {
        FarEvent fe; fe.tickMs=GetTickCount64(); GetLocalTime(&fe.st);
        g_farEvents.push_back(fe);
        ULONGLONG cut=fe.tickMs>CHART_WINDOW_MS?fe.tickMs-CHART_WINDOW_MS:0;
        while(!g_farEvents.empty()&&g_farEvents.front().tickMs<cut)
            g_farEvents.erase(g_farEvents.begin());
        // FAR transition -> activate black screen immediately
        if (!g_bBlackActive) ActivateBlackScreen();
    }
    if(g_hChart)InvalidateRect(g_hChart,nullptr,FALSE);

    // BT NEAR + black screen active -> start unlock delay (both Auto and Manual)
    if (r->state == ProxState::Near && g_bBlackActive && g_unlockTimer <= 0) {
        g_unlockTimer = g_unlockDelaySec;
        if (g_unlockTimer <= 0) DeactivateBlackScreen(); // delay=0 -> instant
    }
    if (r->state == ProxState::Far) g_unlockTimer = 0;
    // NEAR no longer resets idle countdown - only mouse/keyboard does

    if(r->state==ProxState::Near){wchar_t lb[128];
        swprintf_s(lb,L"  \xADFC\xCC98   (\xC720\xD734: %ds)", g_nCountdown);  // 근처 (유휴: Ns)
        SetWindowTextW(g_hStateLabel,lb);
    } else SetWindowTextW(g_hStateLabel,L"  \xBA40\xB9AC");  // 멀리

    wchar_t ev[256]=L"";
    bool inW=(g_reconnectTick>0&&(GetTickCount64()-g_reconnectTick)<WARMUP_MS);
    if(transition&&r->state==ProxState::Near) {
        if(r->bleAvailable) swprintf_s(ev,L">>> ENTERED NEAR (%d dBm%s) <<<",r->rssiDbm,r->gatt?L" GATT":L"");
        else swprintf_s(ev,L">>> ENTERED NEAR (%lums) <<<",r->latencyMs);
    }
    else if(transition&&r->state==ProxState::Far) wcscpy_s(ev,L"<<< LEFT NEAR ZONE >>>");
    else if(!r->reachable&&g_consecutiveFails>=3&&(g_consecutiveFails%5)==0)
        swprintf_s(ev,L"unreachable - reconnecting... (fail=%d)",g_consecutiveFails);
    else if(!r->reachable&&g_consecutiveFails>=3)
        swprintf_s(ev,L"unreachable (fail=%d, err=%d)",g_consecutiveFails,r->wsaError);
    else if(!r->reachable) swprintf_s(ev,L"unreachable (err=%d)",r->wsaError);
    else if(r->bleAvailable) {
        // BLE RSSI 기반 이벤트 메시지
        if(r->state==ProxState::Near&&r->rssiDbm>=g_nearRssiThreshold)
            swprintf_s(ev,L"near (%d dBm, reset %ds)",r->rssiDbm,(int)(r->timerRemainMs/1000));
        else if(r->state==ProxState::Near&&inW)
            swprintf_s(ev,L"near (warmup, %d dBm)",r->rssiDbm);
        else if(r->state==ProxState::Near)
            swprintf_s(ev,L"near (weak %d dBm, %ds)",r->rssiDbm,(int)(r->timerRemainMs/1000));
        else if(r->rssiDbm<=-100) wcscpy_s(ev,L"far (BLE lost)");
        else swprintf_s(ev,L"far (%d dBm)",r->rssiDbm);
    } else {
        // Latency fallback 이벤트 메시지
        if(r->state==ProxState::Near&&r->latencyMs<=g_nearLatencyMs)
            swprintf_s(ev,L"near (reset %ds, %lums)",(int)(r->timerRemainMs/1000),r->latencyMs);
        else if(r->state==ProxState::Near)
            swprintf_s(ev,L"near (weak %lums, %ds)",r->latencyMs,(int)(r->timerRemainMs/1000));
        else swprintf_s(ev,L"far (%lums)",r->latencyMs);
    }

    LVITEMW lv={};lv.mask=LVIF_TEXT;lv.iItem=0;lv.pszText=r->timeStr;
    ListView_InsertItem(g_hListView,&lv);

    // 신호 강도 칼럼: BLE RSSI 또는 latency fallback
    wchar_t lat[32];
    if(!r->reachable) wcscpy_s(lat,L"timeout");
    else if(r->bleAvailable) swprintf_s(lat,r->gatt?L"%d dBm G":L"%d dBm",r->rssiDbm);
    else swprintf_s(lat,L"%lu ms",r->latencyMs);

    // Signal 레벨 바: RSSI 기반 또는 latency fallback
    int lev;
    if(r->bleAvailable) lev=RssiToLevel(r->rssiDbm,r->reachable);
    else lev=LatencyToLevel(r->latencyMs,r->reachable);
    wchar_t sg[32];swprintf_s(sg,L"%s %d",LevelBar(lev),lev);

    // Distance: RSSI 기반 또는 latency fallback
    wchar_t di[32];
    if(!r->reachable) wcscpy_s(di,L"-");
    else if(r->bleAvailable) wcscpy_s(di,RssiToDist(r->rssiDbm));
    else wcscpy_s(di,LatencyToDist(r->latencyMs));

    wchar_t st[16];wcscpy_s(st,StateStr(r->state));
    wchar_t tm[16];if(r->state==ProxState::Near)swprintf_s(tm,L"%ds",(int)(r->timerRemainMs/1000));else wcscpy_s(tm,L"-");
    ListView_SetItemText(g_hListView,0,1,lat);ListView_SetItemText(g_hListView,0,2,sg);
    ListView_SetItemText(g_hListView,0,3,di);ListView_SetItemText(g_hListView,0,4,st);
    ListView_SetItemText(g_hListView,0,5,tm);ListView_SetItemText(g_hListView,0,6,ev);
    int cnt=ListView_GetItemCount(g_hListView);if(cnt>500)ListView_DeleteItem(g_hListView,cnt-1);

    // 상태바: RSSI 또는 latency 표시
    wchar_t status[300];
    const wchar_t* gattSt = !g_bleGatt.IsRunning() ? L"off"
        : (g_bleGatt.IsClientSubscribed() ? L"linked" : L"waiting");
    if(r->bleAvailable)
        swprintf_s(status,L"  \"%s\"  |  %s  |  RSSI: %d dBm%s  |  Near>=%d dBm  |  GATT: %s  |  Idle: %ds",
            g_targetName.c_str(),StateStr(r->state),r->rssiDbm,r->gatt?L" (GATT)":L"",
            r->gatt?g_gattRssiThreshold:g_nearRssiThreshold,gattSt,g_nCountdown);
    else
        swprintf_s(status,L"  \"%s\"  |  %s  |  Latency: %lu ms  |  BLE: N/A  |  GATT: %s  |  Idle: %ds",
            g_targetName.c_str(),StateStr(r->state),r->latencyMs,gattSt,g_nCountdown);
    SetWindowTextW(g_hStatus,status);
    UpdateOverlayState();
}

// ---------------------------------------------------------------------------
// Truncate path for display
// ---------------------------------------------------------------------------
static std::wstring TruncPath(const std::wstring& p, int maxLen = 35) {
    if (p.length() <= (size_t)maxLen) return p;
    return L"..." + p.substr(p.length() - maxLen + 3);
}

// ---------------------------------------------------------------------------
// WndProc (Settings window)
// ---------------------------------------------------------------------------
static constexpr wchar_t CHART_CLS[] = L"SmartScreenChart";

static LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        HINSTANCE hInst = GetModuleHandle(nullptr);
        int y = 0;

        // =================================================================
        // Section 1: Device  (블루투스 기기)
        // =================================================================
        y = 12;
        HWND hDevLabel = CreateWindowExW(0, L"STATIC",
            L"\xBE14\xB8E8\xD22C\xC2A4 \xAE30\xAE30:",  // 블루투스 기기:
            WS_CHILD | WS_VISIBLE, 10, y + 3, 105, 20, hWnd, nullptr, hInst, nullptr);

        g_hCombo = CreateWindowExW(0, L"COMBOBOX", L"",
            WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL,
            115, y, 380, 200, hWnd, (HMENU)(UINT_PTR)ID_COMBO, hInst, nullptr);

        CreateWindowExW(0, L"BUTTON",
            L"\xC0C8\xB85C\xACE0\xCE68",  // 새로고침
            WS_CHILD | WS_VISIBLE, 505, y, 70, 28, hWnd,
            (HMENU)(UINT_PTR)ID_REFRESH, hInst, nullptr);

        g_hBtnStart = CreateWindowExW(0, L"BUTTON",
            L"\xC2DC\xC791",  // 시작
            WS_CHILD | WS_VISIBLE, 585, y, 65, 28, hWnd,
            (HMENU)(UINT_PTR)ID_START, hInst, nullptr);

        g_hBtnStop = CreateWindowExW(0, L"BUTTON",
            L"\xC911\xC9C0",  // 중지
            WS_CHILD | WS_VISIBLE | WS_DISABLED, 658, y, 55, 28, hWnd,
            (HMENU)(UINT_PTR)ID_STOP, hInst, nullptr);

        CreateWindowExW(0, L"BUTTON", L"BT",
            WS_CHILD | WS_VISIBLE, 720, y, 40, 28, hWnd,
            (HMENU)(UINT_PTR)ID_BT_SETTINGS, hInst, nullptr);

        // =================================================================
        // Section 2: Protection Settings  (보호 설정)
        // =================================================================
        y = 48;
        int groupY = y;
        HWND hGroup = CreateWindowExW(0, L"BUTTON",
            L" \xBCF4\xD638 \xC124\xC815 ",  // 보호 설정
            WS_CHILD | WS_VISIBLE | BS_GROUPBOX,
            10, groupY, 760, 130, hWnd, nullptr, hInst, nullptr);

        int row1Y = groupY + 24;
        int row2Y = groupY + 60;
        int labelW = 110;
        int comboW = 150;

        // Row 1: Latency threshold + Away Detection
        CreateWindowExW(0, L"STATIC",
            L"\xC2E0\xD638 \xAC15\xB3C4:",  // 신호 강도:
            WS_CHILD | WS_VISIBLE | SS_RIGHT,
            20, row1Y + 3, 80, 20, hWnd, nullptr, hInst, nullptr);
        g_hEditLatency = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"-50",
            WS_CHILD | WS_VISIBLE | ES_CENTER,
            105, row1Y, 50, 24, hWnd, (HMENU)(UINT_PTR)ID_EDIT_LATENCY, hInst, nullptr);
        CreateWindowExW(0, L"STATIC", L"dBm \xC774\xC0C1",  // dBm 이상
            WS_CHILD | WS_VISIBLE | SS_LEFT,
            160, row1Y + 3, 55, 20, hWnd, nullptr, hInst, nullptr);

        CreateWindowExW(0, L"STATIC",
            L"\xC790\xB9AC\xBE44\xC6C0 \xAC10\xC9C0:",  // 자리비움 감지:
            WS_CHILD | WS_VISIBLE | SS_RIGHT,
            300, row1Y + 3, labelW + 10, 20, hWnd, nullptr, hInst, nullptr);
        g_hComboAway = CreateWindowExW(0, L"COMBOBOX", L"",
            WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST,
            420, row1Y, comboW, 120, hWnd, (HMENU)(UINT_PTR)ID_COMBO_AWAY, hInst, nullptr);
        for (int i = 0; i < 3; i++)
            SendMessageW(g_hComboAway, CB_ADDSTRING, 0, (LPARAM)kAwayLabels[i]);
        SendMessageW(g_hComboAway, CB_SETCURSEL, 0, 0);  // default: 빠름

        // Row 2: Unlock Delay + Idle Time
        CreateWindowExW(0, L"STATIC",
            L"\xC7A0\xAE08 \xD574\xC81C \xC9C0\xC5F0:",  // 잠금 해제 지연:
            WS_CHILD | WS_VISIBLE | SS_RIGHT,
            20, row2Y + 3, labelW, 20, hWnd, nullptr, hInst, nullptr);
        g_hComboDelay = CreateWindowExW(0, L"COMBOBOX", L"",
            WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST,
            135, row2Y, comboW, 120, hWnd, (HMENU)(UINT_PTR)ID_COMBO_DELAY, hInst, nullptr);
        for (int i = 0; i < 4; i++)
            SendMessageW(g_hComboDelay, CB_ADDSTRING, 0, (LPARAM)kDelayLabels[i]);
        SendMessageW(g_hComboDelay, CB_SETCURSEL, 0, 0);  // default: 즉시

        CreateWindowExW(0, L"STATIC",
            L"\xC720\xD734 \xC2DC\xAC04:",  // 유휴 시간:
            WS_CHILD | WS_VISIBLE | SS_RIGHT,
            300, row2Y + 3, labelW + 10, 20, hWnd, nullptr, hInst, nullptr);
        g_hComboIdle = CreateWindowExW(0, L"COMBOBOX", L"",
            WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST,
            420, row2Y, comboW, 120, hWnd, (HMENU)(UINT_PTR)ID_COMBO_IDLE, hInst, nullptr);
        for (int i = 0; i < 4; i++)
            SendMessageW(g_hComboIdle, CB_ADDSTRING, 0, (LPARAM)kIdleLabels[i]);
        SendMessageW(g_hComboIdle, CB_SETCURSEL, 1, 0);  // default: 30초

        // Quick action buttons in the group box
        CreateWindowExW(0, L"BUTTON",
            L"\xC9C0\xAE08 \xC7A0\xAE08",  // 지금 잠금
            WS_CHILD | WS_VISIBLE, 600, row2Y - 2, 80, 26, hWnd,
            (HMENU)(UINT_PTR)ID_BTN_BLACKNOW, hInst, nullptr);

        g_hBtnReconnect = CreateWindowExW(0, L"BUTTON",
            L"\xC7AC\xC5F0\xACB0",  // 재연결
            WS_CHILD | WS_VISIBLE, 688, row2Y - 2, 70, 26, hWnd,
            (HMENU)(UINT_PTR)ID_RECONNECT, hInst, nullptr);

        // Hidden edit controls to maintain IDs (store values internally)
        // (g_hEditLatency는 위의 보이는 "신호 강도" 입력칸을 그대로 사용 - 숨김 컨트롤로 덮어쓰면 입력값이 무시됨)
        g_hEditTimeout  = CreateWindowExW(0, L"EDIT", L"5",   WS_CHILD | ES_NUMBER, 0, 0, 0, 0, hWnd, (HMENU)(UINT_PTR)ID_EDIT_TIMEOUT, hInst, nullptr);
        g_hEditInterval = CreateWindowExW(0, L"EDIT", L"2",   WS_CHILD | ES_NUMBER, 0, 0, 0, 0, hWnd, (HMENU)(UINT_PTR)ID_EDIT_INTERVAL, hInst, nullptr);
        g_hEditIdle     = CreateWindowExW(0, L"EDIT", L"20",  WS_CHILD | ES_NUMBER, 0, 0, 0, 0, hWnd, (HMENU)(UINT_PTR)ID_EDIT_IDLE, hInst, nullptr);
        g_hComboUnlock  = CreateWindowExW(0, L"COMBOBOX", L"", WS_CHILD | CBS_DROPDOWNLIST, 0, 0, 0, 0, hWnd, (HMENU)(UINT_PTR)ID_COMBO_UNLOCK, hInst, nullptr);
        SendMessageW(g_hComboUnlock, CB_ADDSTRING, 0, (LPARAM)L"Auto");
        SendMessageW(g_hComboUnlock, CB_ADDSTRING, 0, (LPARAM)L"Manual");
        SendMessageW(g_hComboUnlock, CB_SETCURSEL, 0, 0);
        g_hEditDelay    = CreateWindowExW(0, L"EDIT", L"0",   WS_CHILD | ES_NUMBER, 0, 0, 0, 0, hWnd, (HMENU)(UINT_PTR)ID_EDIT_DELAY, hInst, nullptr);

        // =================================================================
        // Section 3: Status Banner
        // =================================================================
        y = groupY + 135;
        g_hStateLabel = CreateWindowExW(WS_EX_CLIENTEDGE, L"STATIC",
            L"  \xC815\xC9C0\xB428",  // 정지됨
            WS_CHILD | WS_VISIBLE | SS_LEFT | SS_CENTERIMAGE,
            10, y, 490, 42, hWnd, nullptr, hInst, nullptr);

        g_hBtnClear = CreateWindowExW(0, L"BUTTON",
            L"\xCD08\xAE30\xD654",  // 초기화
            WS_CHILD | WS_VISIBLE, 510, y + 7, 65, 28, hWnd,
            (HMENU)(UINT_PTR)ID_CLEAR, hInst, nullptr);

        g_hCountdownLabel = CreateWindowExW(0, L"STATIC", L"",
            WS_CHILD | WS_VISIBLE | SS_LEFT,
            585, y + 12, 180, 20, hWnd, nullptr, hInst, nullptr);

        // =================================================================
        // Section 4: Log + Chart
        // =================================================================
        int listY = y + 50;
        InitListView(hWnd, listY);

        // Chart
        {WNDCLASSEXW wc={};wc.cbSize=sizeof(wc);wc.lpfnWndProc=ChartProc;
         wc.hInstance=hInst;wc.hCursor=LoadCursor(nullptr,IDC_ARROW);
         wc.lpszClassName=CHART_CLS;RegisterClassExW(&wc);}
        g_hChart = CreateWindowExW(WS_EX_CLIENTEDGE, CHART_CLS, L"",
            WS_CHILD | WS_VISIBLE, 10, listY + 205, WINDOW_W - 40, CHART_H_UI,
            hWnd, nullptr, hInst, nullptr);

        // BlackScreen classes
        RegisterBlackScreenClasses(hInst);

        // =================================================================
        // Section 5: Screen Image Settings  (화면 이미지 설정)
        // =================================================================
        int imgGroupY = listY + 205 + CHART_H_UI + 8;
        g_hImgGroup = CreateWindowExW(0, L"BUTTON",
            L" \xD654\xBA74 \xC774\xBBF8\xC9C0 \xC124\xC815 ",  // 화면 이미지 설정
            WS_CHILD | WS_VISIBLE | BS_GROUPBOX,
            10, imgGroupY, 760, 68, hWnd, nullptr, hInst, nullptr);

        int imgRow1Y = imgGroupY + 20;
        int imgRow2Y = imgGroupY + 42;

        g_hImgCenterLabel = CreateWindowExW(0, L"STATIC",
            L"\xC911\xC559 \xC774\xBBF8\xC9C0:",  // 중앙 이미지:
            WS_CHILD | WS_VISIBLE, 20, imgRow1Y + 2, 85, 20, hWnd, nullptr, hInst, nullptr);
        g_hLabelCenter = CreateWindowExW(0, L"STATIC", L"(\xAE30\xBCF8)",  // (기본)
            WS_CHILD | WS_VISIBLE | SS_LEFT | SS_ENDELLIPSIS,
            108, imgRow1Y + 2, 350, 20, hWnd, nullptr, hInst, nullptr);
        g_hImgCenterBrowse = CreateWindowExW(0, L"BUTTON",
            L"\xCC3E\xC544\xBCF4\xAE30",  // 찾아보기
            WS_CHILD | WS_VISIBLE, 465, imgRow1Y, 65, 22, hWnd,
            (HMENU)(UINT_PTR)ID_BTN_CENTER_IMG, hInst, nullptr);

        g_hImgBannerLabel = CreateWindowExW(0, L"STATIC",
            L"\xBC30\xB108 \xC774\xBBF8\xC9C0:",  // 배너 이미지:
            WS_CHILD | WS_VISIBLE, 20, imgRow2Y + 2, 85, 20, hWnd, nullptr, hInst, nullptr);
        g_hLabelBanner = CreateWindowExW(0, L"STATIC", L"(\xAE30\xBCF8)",  // (기본)
            WS_CHILD | WS_VISIBLE | SS_LEFT | SS_ENDELLIPSIS,
            108, imgRow2Y + 2, 350, 20, hWnd, nullptr, hInst, nullptr);
        g_hImgBannerBrowse = CreateWindowExW(0, L"BUTTON",
            L"\xCC3E\xC544\xBCF4\xAE30",  // 찾아보기
            WS_CHILD | WS_VISIBLE, 465, imgRow2Y, 65, 22, hWnd,
            (HMENU)(UINT_PTR)ID_BTN_BANNER_IMG, hInst, nullptr);

        // Enterprise button
        g_hBtnEnterprise = CreateWindowExW(0, L"BUTTON",
            L"\xAE30\xC5C5\xC6A9 \xB458\xB7EC\xBCF4\xAE30",  // 기업용 둘러보기
            WS_CHILD | WS_VISIBLE, 550, imgGroupY + 16, 150, 40, hWnd,
            (HMENU)(UINT_PTR)ID_BTN_ENTERPRISE, hInst, nullptr);

        // Status bar
        g_hStatus = CreateWindowExW(0, L"STATIC",
            L"  \xAE30\xAE30\xB97C \xC120\xD0DD\xD558\xACE0 \xC2DC\xC791\xC744 \xB204\xB974\xC138\xC694",  // 기기를 선택하고 시작을 누르세요
            WS_CHILD | WS_VISIBLE | SS_LEFT | SS_SUNKEN,
            0, WINDOW_H - 55, WINDOW_W, 25, hWnd, nullptr, hInst, nullptr);

        // =================================================================
        // Fonts
        // =================================================================
        g_hFont = CreateFontW(14, 0, 0, 0, FW_NORMAL, 0, 0, 0,
            DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
        g_hFontBold = CreateFontW(14, 0, 0, 0, FW_BOLD, 0, 0, 0,
            DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
        g_hFontBig = CreateFontW(24, 0, 0, 0, FW_BOLD, 0, 0, 0,
            DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
        g_hFontSmall = CreateFontW(11, 0, 0, 0, FW_NORMAL, 0, 0, 0,
            DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Consolas");
        g_hFontSection = CreateFontW(15, 0, 0, 0, FW_BOLD, 0, 0, 0,
            DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");

        g_hBrushNear = CreateSolidBrush(RGB(46, 160, 67));
        g_hBrushFar = CreateSolidBrush(RGB(200, 200, 200));
        g_hBrushLocked = CreateSolidBrush(RGB(220, 60, 60));
        g_hBrushStopped = CreateSolidBrush(RGB(180, 180, 180));

        // Apply fonts to all children
        EnumChildWindows(hWnd, [](HWND h, LPARAM f) -> BOOL {
            SendMessage(h, WM_SETFONT, (WPARAM)f, TRUE); return TRUE;
        }, (LPARAM)g_hFont);

        // Specific font overrides
        SendMessage(hDevLabel, WM_SETFONT, (WPARAM)g_hFontBold, TRUE);
        SendMessage(g_hStateLabel, WM_SETFONT, (WPARAM)g_hFontBig, TRUE);
        SendMessage(hGroup, WM_SETFONT, (WPARAM)g_hFontSection, TRUE);
        if (g_hImgGroup) SendMessage(g_hImgGroup, WM_SETFONT, (WPARAM)g_hFontSection, TRUE);

        // =================================================================
        // Load config and apply to UI
        // =================================================================
        AppConfig cfg;
        if (LoadAppConfig(cfg)) {
            g_targetAddr = cfg.btAddress;
            g_nearLatencyMs = cfg.nearLatencyMs;
            g_nearRssiThreshold = cfg.nearRssiThreshold;
            g_keepAliveSec = cfg.keepAliveSec;
            g_scanIntervalSec = cfg.scanIntervalSec;
            g_idleCountdownSec = cfg.idleCountdownSec;
            g_unlockAuto = cfg.unlockAuto;
            g_unlockDelaySec = cfg.unlockDelaySec;
            g_centerImagePath = cfg.centerImagePath;
            g_bannerImagePath = cfg.bannerImagePath;

            // Map loaded values to combo selections
            // RSSI 임계값 표시 (dBm)
            { wchar_t lb[16]; swprintf_s(lb, L"%d", g_nearRssiThreshold); SetWindowTextW(g_hEditLatency, lb); }
            SendMessageW(g_hComboAway, CB_SETCURSEL,
                ComboFindValue(kAwayValues, 3, (int)g_keepAliveSec), 0);
            SendMessageW(g_hComboDelay, CB_SETCURSEL,
                ComboFindValue(kDelayValues, 4, g_unlockDelaySec), 0);
            SendMessageW(g_hComboIdle, CB_SETCURSEL,
                ComboFindValue(kIdleValues, 4, g_idleCountdownSec), 0);

            // Update hidden edit controls for compatibility
            wchar_t buf[16];
            swprintf_s(buf, L"%d", g_nearRssiThreshold); SetWindowTextW(g_hEditLatency, buf);
            swprintf_s(buf, L"%lu", g_keepAliveSec); SetWindowTextW(g_hEditTimeout, buf);
            swprintf_s(buf, L"%lu", g_scanIntervalSec); SetWindowTextW(g_hEditInterval, buf);
            swprintf_s(buf, L"%d", g_idleCountdownSec); SetWindowTextW(g_hEditIdle, buf);
            SendMessageW(g_hComboUnlock, CB_SETCURSEL, g_unlockAuto ? 0 : 1, 0);
            swprintf_s(buf, L"%d", g_unlockDelaySec); SetWindowTextW(g_hEditDelay, buf);

            if (!g_centerImagePath.empty())
                SetWindowTextW(g_hLabelCenter, TruncPath(g_centerImagePath).c_str());
            if (!g_bannerImagePath.empty())
                SetWindowTextW(g_hLabelBanner, TruncPath(g_bannerImagePath).c_str());
        }

        PopulateCombo();

        // Enterprise: auto-sync content at startup
        if (cfg.enterpriseRegistered && !cfg.orgId.empty() && !cfg.serverUrl.empty() && !cfg.anonKey.empty()) {
            if (SyncEnterpriseContent(cfg.serverUrl, cfg.anonKey, cfg.orgId)) {
                auto cp = GetEnterpriseCenterPath();
                auto bp = GetEnterpriseBannerPath();
                if (!cp.empty() && g_centerImagePath.empty()) g_centerImagePath = cp;
                if (!bp.empty() && g_bannerImagePath.empty()) g_bannerImagePath = bp;
            }
        }

        // Auto-start if config exists
        if (g_targetAddr != 0) {
            for (size_t i = 0; i < g_paired.size(); i++) {
                if (g_paired[i].address == g_targetAddr) {
                    SendMessageW(g_hCombo, CB_SETCURSEL, i, 0);
                    PostMessage(hWnd, WM_COMMAND, ID_START, 0);
                    break;
                }
            }
        }
        break;
    }

    case WM_TIMER:
        if (wParam == IDT_COUNTDOWN && g_monitoring) {
            if (!g_bBlackActive) {
                // Count down idle timer (both NEAR and FAR)
                if (g_nCountdown > 0) g_nCountdown--;
                if (g_nCountdown == 0) ActivateBlackScreen();
            }
            // Also: if FAR persists beyond timeout, activate immediately
            // (even if idle countdown hasn't started yet)
            if (!g_bBlackActive && g_proxState == ProxState::Far && g_monitoring) {
                ULONGLONG now = GetTickCount64();
                if (g_lastNearTick > 0 && (now - g_lastNearTick) >= (ULONGLONG)(g_keepAliveSec + g_idleCountdownSec) * 1000) {
                    // Device has been FAR for timeout + idle period -> force activate
                    g_nCountdown = 0;
                    ActivateBlackScreen();
                }
            }
            if (g_bBlackActive && g_unlockTimer > 0) {
                g_unlockTimer--;
                if (g_unlockTimer <= 0) DeactivateBlackScreen();
            }
            wchar_t cdl[96];
            if (g_bBlackActive && g_unlockTimer > 0)
                swprintf_s(cdl, L"  \xC7A0\xAE08 - %d\xCD08 \xD6C4 \xD574\xC81C", g_unlockTimer);  // 잠금 - N초 후 해제
            else if (g_bBlackActive)
                swprintf_s(cdl, L"  \xC7A0\xAE08 \xC911");  // 잠금 중
            else if (g_proxState == ProxState::Near)
                wcscpy_s(cdl, L"  \xBCF4\xD638 \xC911");  // 보호 중
            else
                swprintf_s(cdl, L"  %d\xCD08 \xD6C4 \xC7A0\xAE08", g_nCountdown);  // N초 후 잠금
            SetWindowTextW(g_hCountdownLabel, cdl);
            UpdateOverlayState();
        }
        break;

    case WM_CTLCOLORSTATIC: {
        HDC hdc = (HDC)wParam; HWND hc = (HWND)lParam;
        if (hc == g_hStateLabel) {
            if (g_monitoring && g_bBlackActive) {
                SetTextColor(hdc, RGB(255, 255, 255));
                SetBkColor(hdc, RGB(220, 60, 60));
                return (LRESULT)g_hBrushLocked;
            } else if (g_monitoring && g_proxState == ProxState::Near) {
                SetTextColor(hdc, RGB(255, 255, 255));
                SetBkColor(hdc, RGB(46, 160, 67));
                return (LRESULT)g_hBrushNear;
            } else if (g_monitoring) {
                SetTextColor(hdc, RGB(60, 60, 60));
                SetBkColor(hdc, RGB(200, 200, 200));
                return (LRESULT)g_hBrushFar;
            }
        }
        break;
    }

    case WM_COMMAND:
        switch(LOWORD(wParam)){
        case ID_REFRESH: if(!g_monitoring)PopulateCombo(); break;
        case ID_START: StartMon(); break;
        case ID_STOP: StopMon(); break;
        case ID_CLEAR:
            ListView_DeleteAllItems(g_hListView);g_logCount=0;g_farEvents.clear();
            if(g_hChart)InvalidateRect(g_hChart,nullptr,FALSE);break;
        case ID_BT_SETTINGS:
            ShellExecuteW(nullptr,L"open",L"ms-settings:bluetooth",nullptr,nullptr,SW_SHOW);break;
        case ID_RECONNECT:
            if(g_targetAddr!=0){EnableWindow(g_hBtnReconnect,FALSE);
                SetWindowTextW(g_hBtnReconnect,L"...");
                CloseHandle(CreateThread(nullptr,0,ReconnectThread,nullptr,0,nullptr));}break;
        case ID_BTN_BLACKNOW:
            if(g_monitoring && !g_bBlackActive){
                g_bBlackActive=true;g_bManualLock=true;g_lockStartTick=GetTickCount64();
                int x=GetSystemMetrics(SM_XVIRTUALSCREEN),y=GetSystemMetrics(SM_YVIRTUALSCREEN);
                int w=GetSystemMetrics(SM_CXVIRTUALSCREEN),h=GetSystemMetrics(SM_CYVIRTUALSCREEN);
                g_hBlackScreen=CreateWindowExW(WS_EX_TOPMOST,BLACKSCREEN_CLASS,L"",
                    WS_POPUP,x,y,w,h,nullptr,nullptr,GetModuleHandle(nullptr),nullptr);
                ShowWindow(g_hBlackScreen,SW_SHOW);SetForegroundWindow(g_hBlackScreen);
            }break;
        case ID_BTN_CENTER_IMG: {
            auto p = BrowseImage(hWnd);
            if (!p.empty()) {
                g_centerImagePath = p;
                SetWindowTextW(g_hLabelCenter, TruncPath(p).c_str());
                FreeBlackScreenImages();
            }
        } break;
        case ID_BTN_BANNER_IMG: {
            auto p = BrowseImage(hWnd);
            if (!p.empty()) {
                g_bannerImagePath = p;
                SetWindowTextW(g_hLabelBanner, TruncPath(p).c_str());
                FreeBlackScreenImages();
            }
        } break;
        case ID_BTN_ENTERPRISE: {
            // --- Step 1: Premium Enterprise Feature Showcase ---
            int dlgW = 560, dlgH = 520;
            int scrW = GetSystemMetrics(SM_CXSCREEN);
            int scrH = GetSystemMetrics(SM_CYSCREEN);
            int dlgX = (scrW - dlgW) / 2;
            int dlgY = (scrH - dlgH) / 2;

            HWND hInfoDlg = CreateWindowExW(WS_EX_TOPMOST,
                L"#32770", L"SmartScreen Enterprise",
                WS_POPUP | WS_VISIBLE,
                dlgX, dlgY, dlgW, dlgH,
                hWnd, nullptr, GetModuleHandle(nullptr), nullptr);

            // Create the two bottom buttons as real BUTTON controls (owner-draw)
            static constexpr int ID_BTN_OPEN_DASHBOARD = 5020;
            static constexpr int ID_BTN_SETUP_ENTERPRISE = 5021;

            // Dashboard button: left side of bottom area
            HWND hBtnDash = CreateWindowExW(0, L"BUTTON",
                L"\xAD00\xB9AC\xC790 \xB300\xC2DC\xBCF4\xB4DC",  // 관리자 대시보드
                WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                40, dlgH - 75, 220, 40, hInfoDlg, (HMENU)(UINT_PTR)ID_BTN_OPEN_DASHBOARD, nullptr, nullptr);
            // Start button: right side of bottom area
            HWND hBtnSetup = CreateWindowExW(0, L"BUTTON",
                L"\xC9C0\xAE08 \xC2DC\xC791\xD558\xAE30",  // 지금 시작하기
                WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                300, dlgH - 75, 220, 40, hInfoDlg, (HMENU)(UINT_PTR)ID_BTN_SETUP_ENTERPRISE, nullptr, nullptr);

            SetPropW(hInfoDlg, L"hParent", hWnd);

            // Subclass WndProc for dark-themed custom painting
            SetWindowLongPtrW(hInfoDlg, GWLP_WNDPROC, (LONG_PTR)+[](HWND hw, UINT msg, WPARAM wp, LPARAM lp) -> LRESULT {
                // --- Custom painting ---
                if (msg == WM_ERASEBKGND) {
                    HDC hdc = (HDC)wp;
                    RECT rc; GetClientRect(hw, &rc);
                    HBRUSH hBg = CreateSolidBrush(RGB(18, 20, 28));
                    FillRect(hdc, &rc, hBg);
                    DeleteObject(hBg);
                    return 1;
                }
                if (msg == WM_PAINT) {
                    PAINTSTRUCT ps;
                    HDC hdc = BeginPaint(hw, &ps);
                    RECT rc; GetClientRect(hw, &rc);
                    int W = rc.right;

                    // --- Header background (top 80px) ---
                    RECT rcHeader = { 0, 0, W, 80 };
                    HBRUSH hHeaderBg = CreateSolidBrush(RGB(25, 28, 40));
                    FillRect(hdc, &rcHeader, hHeaderBg);
                    DeleteObject(hHeaderBg);

                    SetBkMode(hdc, TRANSPARENT);

                    // Title: "SmartScreen Enterprise"
                    HFONT hFontTitle = CreateFontW(26, 0, 0, 0, FW_BOLD, 0, 0, 0,
                        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
                    HFONT hOld = (HFONT)SelectObject(hdc, hFontTitle);
                    SetTextColor(hdc, RGB(255, 255, 255));
                    RECT rcTitle = { 32, 16, W - 40, 48 };
                    DrawTextW(hdc, L"SmartScreen Enterprise", -1, &rcTitle, DT_LEFT | DT_SINGLELINE);
                    SelectObject(hdc, hOld);
                    DeleteObject(hFontTitle);

                    // Subtitle
                    HFONT hFontSub = CreateFontW(14, 0, 0, 0, FW_NORMAL, 0, 0, 0,
                        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
                    hOld = (HFONT)SelectObject(hdc, hFontSub);
                    SetTextColor(hdc, RGB(140, 150, 170));
                    // 비즈니스를 위한 스마트한 보안
                    RECT rcSub = { 32, 48, W - 40, 68 };
                    DrawTextW(hdc,
                        L"\xBE44\xC988\xB2C8\xC2A4\xB97C \xC704\xD55C \xC2A4\xB9C8\xD2B8\xD55C \xBCF4\xC548",
                        -1, &rcSub, DT_LEFT | DT_SINGLELINE);
                    SelectObject(hdc, hOld);
                    DeleteObject(hFontSub);

                    // Close button "X" in top-right
                    HFONT hFontX = CreateFontW(20, 0, 0, 0, FW_NORMAL, 0, 0, 0,
                        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
                    hOld = (HFONT)SelectObject(hdc, hFontX);
                    SetTextColor(hdc, RGB(140, 150, 170));
                    RECT rcX = { W - 40, 8, W - 8, 36 };
                    DrawTextW(hdc, L"\x2715", -1, &rcX, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
                    SelectObject(hdc, hOld);
                    DeleteObject(hFontX);

                    // --- Feature Cards ---
                    struct CardInfo {
                        COLORREF accent;
                        const wchar_t* title;
                        const wchar_t* desc;
                        const wchar_t* icon;
                    };
                    CardInfo cards[3] = {
                        { RGB(79, 140, 255),
                          // 중앙 집중 관리
                          L"\xC911\xC559 \xC9D1\xC911 \xAD00\xB9AC",
                          // 관리자 대시보드에서 잠금 화면 콘텐츠를 업로드하면\n사내 모든 PC에 자동으로 배포됩니다.
                          L"\xAD00\xB9AC\xC790 \xB300\xC2DC\xBCF4\xB4DC\xC5D0\xC11C \xC7A0\xAE08 \xD654\xBA74 \xCF58\xD150\xCE20\xB97C \xC5C5\xB85C\xB4DC\xD558\xBA74\n\xC0AC\xB0B4 \xBAA8\xB4E0 PC\xC5D0 \xC790\xB3D9\xC73C\xB85C \xBC30\xD3EC\xB429\xB2C8\xB2E4.",
                          L"\xE2\xAC\xA1" },  // icon placeholder
                        { RGB(52, 211, 153),
                          // 기업 브랜딩 & 보안 공지
                          L"\xAE30\xC5C5 \xBE0C\xB79C\xB529 & \xBCF4\xC548 \xACF5\xC9C0",
                          // 회사 로고, 보안 정책, 긴급 공지를 잠금 화면에 표시.\n조직별 콘텐츠 분리로 보안을 강화합니다.
                          L"\xD68C\xC0AC \xB85C\xACE0, \xBCF4\xC548 \xC815\xCC45, \xAE34\xAE09 \xACF5\xC9C0\xB97C \xC7A0\xAE08 \xD654\xBA74\xC5D0 \xD45C\xC2DC.\n\xC870\xC9C1\xBCC4 \xCF58\xD150\xCE20 \xBD84\xB9AC\xB85C \xBCF4\xC548\xC744 \xAC15\xD654\xD569\xB2C8\xB2E4.",
                          L"\xE2\x97\x86" },
                        { RGB(251, 191, 36),
                          // P2P 스마트 배포
                          L"P2P \xC2A4\xB9C8\xD2B8 \xBC30\xD3EC",
                          // 사내 네트워크 P2P 전송으로 서버 부하를 최소화.\n설치 후 조직 ID 하나만 입력하면 자동 연동됩니다.
                          L"\xC0AC\xB0B4 \xB124\xD2B8\xC6CC\xD06C P2P \xC804\xC1A1\xC73C\xB85C \xC11C\xBC84 \xBD80\xD558\xB97C \xCD5C\xC18C\xD654.\n\xC124\xCE58 \xD6C4 \xC870\xC9C1 ID \xD558\xB098\xB9CC \xC785\xB825\xD558\xBA74 \xC790\xB3D9 \xC5F0\xB3D9\xB429\xB2C8\xB2E4.",
                          L"\xE2\x9A\xA1" }
                    };

                    int cardLeft = 32, cardRight = W - 32;
                    int cardW = cardRight - cardLeft;
                    int cardH = 100, cardGap = 8;
                    int cardTop = 92;

                    HFONT hFontCardTitle = CreateFontW(16, 0, 0, 0, FW_BOLD, 0, 0, 0,
                        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
                    HFONT hFontCardDesc = CreateFontW(13, 0, 0, 0, FW_NORMAL, 0, 0, 0,
                        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");

                    for (int i = 0; i < 3; i++) {
                        int y = cardTop + i * (cardH + cardGap);
                        // Card background
                        RECT rcCard = { cardLeft, y, cardRight, y + cardH };
                        HBRUSH hCardBg = CreateSolidBrush(RGB(30, 34, 48));
                        FillRect(hdc, &rcCard, hCardBg);
                        DeleteObject(hCardBg);

                        // Left accent bar (4px wide)
                        RECT rcAccent = { cardLeft, y, cardLeft + 4, y + cardH };
                        HBRUSH hAccent = CreateSolidBrush(cards[i].accent);
                        FillRect(hdc, &rcAccent, hAccent);
                        DeleteObject(hAccent);

                        // Card title
                        hOld = (HFONT)SelectObject(hdc, hFontCardTitle);
                        SetTextColor(hdc, RGB(255, 255, 255));
                        RECT rcCT = { cardLeft + 20, y + 14, cardRight - 50, y + 34 };
                        DrawTextW(hdc, cards[i].title, -1, &rcCT, DT_LEFT | DT_SINGLELINE);
                        SelectObject(hdc, hOld);

                        // Card description
                        hOld = (HFONT)SelectObject(hdc, hFontCardDesc);
                        SetTextColor(hdc, RGB(170, 175, 190));
                        RECT rcCD = { cardLeft + 20, y + 40, cardRight - 20, y + cardH - 8 };
                        DrawTextW(hdc, cards[i].desc, -1, &rcCD, DT_LEFT | DT_WORDBREAK);
                        SelectObject(hdc, hOld);

                        // Right side accent dot (decorative)
                        HFONT hFontIcon = CreateFontW(28, 0, 0, 0, FW_NORMAL, 0, 0, 0,
                            DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
                        hOld = (HFONT)SelectObject(hdc, hFontIcon);
                        SetTextColor(hdc, cards[i].accent);
                        RECT rcIcon = { cardRight - 48, y + 10, cardRight - 8, y + 44 };
                        // Draw a filled circle as icon decoration
                        DrawTextW(hdc, L"\x25CF", -1, &rcIcon, DT_CENTER | DT_SINGLELINE);
                        SelectObject(hdc, hOld);
                        DeleteObject(hFontIcon);
                    }
                    DeleteObject(hFontCardTitle);
                    DeleteObject(hFontCardDesc);

                    // --- Bottom area: trial text ---
                    HFONT hFontTrial = CreateFontW(12, 0, 0, 0, FW_NORMAL, 0, 0, 0,
                        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
                    hOld = (HFONT)SelectObject(hdc, hFontTrial);
                    SetTextColor(hdc, RGB(100, 110, 130));
                    RECT rcTrial = { 0, rc.bottom - 28, W, rc.bottom - 8 };
                    // 무료 체험 · 신용카드 불필요
                    DrawTextW(hdc,
                        L"\xBB34\xB8CC \xCCB4\xD5D8 \x00B7 \xC2E0\xC6A9\xCE74\xB4DC \xBD88\xD544\xC694",
                        -1, &rcTrial, DT_CENTER | DT_SINGLELINE);
                    SelectObject(hdc, hOld);
                    DeleteObject(hFontTrial);

                    EndPaint(hw, &ps);
                    return 0;
                }
                // --- Owner-draw buttons ---
                if (msg == WM_DRAWITEM) {
                    DRAWITEMSTRUCT* dis = (DRAWITEMSTRUCT*)lp;
                    if (dis->CtlID == 5020 || dis->CtlID == 5021) {
                        HDC hdc = dis->hDC;
                        RECT rc = dis->rcItem;
                        SetBkMode(hdc, TRANSPARENT);

                        COLORREF bgColor, textColor;
                        if (dis->CtlID == 5020) {
                            bgColor = RGB(79, 140, 255);
                            textColor = RGB(255, 255, 255);
                        } else {
                            bgColor = RGB(52, 211, 153);
                            textColor = RGB(18, 20, 28);
                        }
                        // Slightly lighter when pressed
                        if (dis->itemState & ODS_SELECTED) {
                            int r = GetRValue(bgColor), g = GetGValue(bgColor), b = GetBValue(bgColor);
                            bgColor = RGB(min(r + 30, 255), min(g + 30, 255), min(b + 30, 255));
                        }

                        // Draw rounded-feel button (fill + round rect via RoundRect)
                        HBRUSH hBtnBrush = CreateSolidBrush(bgColor);
                        HPEN hBtnPen = CreatePen(PS_SOLID, 1, bgColor);
                        HBRUSH hOldBr = (HBRUSH)SelectObject(hdc, hBtnBrush);
                        HPEN hOldPen = (HPEN)SelectObject(hdc, hBtnPen);
                        RoundRect(hdc, rc.left, rc.top, rc.right, rc.bottom, 8, 8);
                        SelectObject(hdc, hOldBr);
                        SelectObject(hdc, hOldPen);
                        DeleteObject(hBtnBrush);
                        DeleteObject(hBtnPen);

                        // Button text
                        HFONT hBtnFont = CreateFontW(15, 0, 0, 0, FW_BOLD, 0, 0, 0,
                            DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
                        HFONT hOldFont = (HFONT)SelectObject(hdc, hBtnFont);
                        SetTextColor(hdc, textColor);
                        wchar_t btnText[64];
                        GetWindowTextW(dis->hwndItem, btnText, 64);
                        DrawTextW(hdc, btnText, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
                        SelectObject(hdc, hOldFont);
                        DeleteObject(hBtnFont);
                        return TRUE;
                    }
                }
                // --- Close button hit test (top-right X) ---
                if (msg == WM_LBUTTONDOWN) {
                    int mx = LOWORD(lp), my = HIWORD(lp);
                    RECT rc; GetClientRect(hw, &rc);
                    if (mx >= rc.right - 40 && mx <= rc.right - 8 && my >= 8 && my <= 36) {
                        DestroyWindow(hw);
                        return 0;
                    }
                }
                // --- Button click handlers ---
                if (msg == WM_COMMAND && LOWORD(wp) == 5020) {
                    // Open admin dashboard
                    ShellExecuteW(nullptr, L"open", L"https://icesgg.github.io/smartscreen/dashboard.html", nullptr, nullptr, SW_SHOWNORMAL);
                    return 0;
                }
                if (msg == WM_COMMAND && LOWORD(wp) == 5021) {
                    // --- Step 2: Guided Setup Dialog ---
                    HWND hParent = (HWND)GetPropW(hw, L"hParent");
                    DestroyWindow(hw);  // Close info dialog first

                    // Open dashboard in browser automatically
                    ShellExecuteW(nullptr, L"open", L"https://icesgg.github.io/smartscreen/dashboard.html", nullptr, nullptr, SW_SHOWNORMAL);

                    AppConfig ecfg;
                    LoadAppConfig(ecfg);

                    wchar_t orgBuf[128] = {};
                    if (!ecfg.orgId.empty()) wcsncpy_s(orgBuf, ecfg.orgId.c_str(), _TRUNCATE);

                    int dlgW = 460, dlgH = 380;
                    int sx = (GetSystemMetrics(SM_CXSCREEN) - dlgW) / 2;
                    int sy = (GetSystemMetrics(SM_CYSCREEN) - dlgH) / 2;

                    HWND hDlg = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_TOPMOST,
                        L"#32770", L"\xBB34\xB8CC \xCCB4\xD5D8 \xC2DC\xC791",  // 무료 체험 시작
                        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
                        sx, sy, dlgW, dlgH,
                        hParent, nullptr, GetModuleHandle(nullptr), nullptr);

                    // Step-by-step guide
                    CreateWindowExW(0, L"STATIC",
                        L"\xBE0C\xB77C\xC6B0\xC800\xC5D0\xC11C \xB300\xC2DC\xBCF4\xB4DC\xAC00 \xC5F4\xB838\xC2B5\xB2C8\xB2E4.",  // 브라우저에서 대시보드가 열렸습니다.
                        WS_CHILD | WS_VISIBLE | SS_LEFT,
                        20, 16, 400, 20, hDlg, nullptr, nullptr, nullptr);

                    CreateWindowExW(0, L"STATIC",
                        L"\xC544\xB798 \xC21C\xC11C\xB300\xB85C \xC9C4\xD589\xD558\xC138\xC694:",  // 아래 순서대로 진행하세요:
                        WS_CHILD | WS_VISIBLE | SS_LEFT,
                        20, 40, 400, 20, hDlg, nullptr, nullptr, nullptr);

                    CreateWindowExW(0, L"STATIC",
                        L"  1. Google \xACC4\xC815\xC73C\xB85C \xB85C\xADF8\xC778\n"  // 1. Google 계정으로 로그인
                        L"  2. \xC870\xC9C1 \xC774\xB984\xC744 \xC785\xB825\xD558\xACE0 \xC870\xC9C1 \xC0DD\xC131\n"  // 2. 조직 이름을 입력하고 조직 생성
                        L"  3. \xC7A0\xAE08 \xD654\xBA74\xC5D0 \xD45C\xC2DC\xD560 \xC774\xBBF8\xC9C0/\xB3D9\xC601\xC0C1 \xC5C5\xB85C\xB4DC\n"  // 3. 잠금 화면에 표시할 이미지/동영상 업로드
                        L"  4. \xC870\xC9C1 ID\xB97C \xBCF5\xC0AC\xD558\xC5EC \xC544\xB798\xC5D0 \xBD99\xC5EC\xB123\xAE30",  // 4. 조직 ID를 복사하여 아래에 붙여넣기
                        WS_CHILD | WS_VISIBLE | SS_LEFT,
                        20, 68, 410, 80, hDlg, nullptr, nullptr, nullptr);

                    // Separator line
                    CreateWindowExW(0, L"STATIC", L"",
                        WS_CHILD | WS_VISIBLE | SS_ETCHEDHORZ,
                        20, 160, 400, 2, hDlg, nullptr, nullptr, nullptr);

                    CreateWindowExW(0, L"STATIC",
                        L"\xC870\xC9C1 ID:",  // 조직 ID:
                        WS_CHILD | WS_VISIBLE | SS_LEFT,
                        20, 175, 60, 20, hDlg, nullptr, nullptr, nullptr);
                    HWND hOrg = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", orgBuf,
                        WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
                        85, 172, 330, 26, hDlg, (HMENU)5003, nullptr, nullptr);

                    CreateWindowExW(0, L"BUTTON",
                        L"\xC5F0\xACB0 \xBC0F \xB3D9\xAE30\xD654",  // 연결 및 동기화
                        WS_CHILD | WS_VISIBLE, 20, 215, 140, 36, hDlg, (HMENU)5010, nullptr, nullptr);
                    HWND hStatus2 = CreateWindowExW(0, L"STATIC", L"",
                        WS_CHILD | WS_VISIBLE, 170, 223, 250, 20, hDlg, (HMENU)5011, nullptr, nullptr);

                    // Help link
                    CreateWindowExW(0, L"STATIC",
                        L"\xB300\xC2DC\xBCF4\xB4DC\xAC00 \xC5F4\xB9AC\xC9C0 \xC54A\xC558\xB098\xC694?",  // 대시보드가 열리지 않았나요?
                        WS_CHILD | WS_VISIBLE | SS_LEFT,
                        20, 268, 200, 16, hDlg, nullptr, nullptr, nullptr);
                    CreateWindowExW(0, L"BUTTON",
                        L"\xB300\xC2DC\xBCF4\xB4DC \xC5F4\xAE30",  // 대시보드 열기
                        WS_CHILD | WS_VISIBLE, 20, 288, 120, 28, hDlg, (HMENU)5025, nullptr, nullptr);

                    SetPropW(hDlg, L"hOrg", hOrg);
                    SetPropW(hDlg, L"hStatus", hStatus2);
                    SetPropW(hDlg, L"hParent", hParent);

                    SetWindowLongPtrW(hDlg, GWLP_WNDPROC, (LONG_PTR)+[](HWND hw2, UINT msg2, WPARAM wp2, LPARAM lp2) -> LRESULT {
                        if (msg2 == WM_COMMAND && LOWORD(wp2) == 5010) {
                            HWND ho = (HWND)GetPropW(hw2, L"hOrg");
                            HWND hs = (HWND)GetPropW(hw2, L"hStatus");

                            wchar_t o[128];
                            GetWindowTextW(ho, o, 128);

                            if (!wcslen(o)) {
                                SetWindowTextW(hs, L"\xC870\xC9C1 ID\xB97C \xC785\xB825\xD558\xC138\xC694.");  // 조직 ID를 입력하세요.
                                return 0;
                            }

                            AppConfig sc;
                            LoadAppConfig(sc);
                            sc.serverUrl = L"https://vnonoschrzbgvyeduosm.supabase.co";
                            sc.anonKey = L"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZub25vc2NocnpiZ3Z5ZWR1b3NtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU2NzkyNjQsImV4cCI6MjA5MTI1NTI2NH0.KqkmH7UtcR4ihFDMmAMfWRH0O2P2s__Jglzr5QWIzfc";
                            sc.orgId = o;
                            sc.enterpriseRegistered = true;
                            SaveAppConfig(sc);

                            SetWindowTextW(hs, L"\xC5F0\xACB0 \xC911...");  // 연결 중...
                            UpdateWindow(hw2);

                            bool ok = SyncEnterpriseContent(sc.serverUrl, sc.anonKey, sc.orgId);
                            if (ok) {
                                auto cp = GetEnterpriseCenterPath();
                                auto bp = GetEnterpriseBannerPath();
                                if (!cp.empty()) g_centerImagePath = cp;
                                if (!bp.empty()) g_bannerImagePath = bp;
                                FreeBlackScreenImages();
                                SetWindowTextW(hs, L"\xC5F0\xACB0 \xC644\xB8CC!");  // 연결 완료!
                            } else {
                                SetWindowTextW(hs, L"\xC5F0\xACB0 \xC2E4\xD328 - ID\xB97C \xD655\xC778\xD558\xC138\xC694");  // 연결 실패 - ID를 확인하세요
                            }
                            return 0;
                        }
                        if (msg2 == WM_COMMAND && LOWORD(wp2) == 5025) {
                            ShellExecuteW(nullptr, L"open", L"https://icesgg.github.io/smartscreen/dashboard.html", nullptr, nullptr, SW_SHOWNORMAL);
                            return 0;
                        }
                        if (msg2 == WM_CLOSE) { DestroyWindow(hw2); return 0; }
                        if (msg2 == WM_DESTROY) {
                            RemovePropW(hw2, L"hOrg"); RemovePropW(hw2, L"hStatus");
                            RemovePropW(hw2, L"hParent");
                            return 0;
                        }
                        return DefWindowProcW(hw2, msg2, wp2, lp2);
                    });

                    // Run modal loop for the setup dialog
                    EnableWindow(hParent, FALSE);
                    MSG dm;
                    while (IsWindow(hDlg) && GetMessage(&dm, nullptr, 0, 0)) {
                        TranslateMessage(&dm);
                        DispatchMessage(&dm);
                    }
                    EnableWindow(hParent, TRUE);
                    SetForegroundWindow(hParent);
                    return 0;
                }
                if (msg == WM_CLOSE) { DestroyWindow(hw); return 0; }
                if (msg == WM_DESTROY) {
                    RemovePropW(hw, L"hParent");
                    return 0;
                }
                return DefWindowProcW(hw, msg, wp, lp);
            });

            EnableWindow(hWnd, FALSE);
            MSG dm;
            while (IsWindow(hInfoDlg) && GetMessage(&dm, nullptr, 0, 0)) {
                TranslateMessage(&dm);
                DispatchMessage(&dm);
            }
            EnableWindow(hWnd, TRUE);
            SetForegroundWindow(hWnd);
        } break;
        }break;

    case WM_SCAN_RESULT:{
        auto*r=(ProbeResult*)lParam;OnResult(r);
        InvalidateRect(g_hStateLabel,nullptr,TRUE);delete r;break;
    }

    case WM_SIZE:{
        int w=LOWORD(lParam),h=HIWORD(lParam);
        int sH=25;
        int cH=CHART_H_UI;
        // Status banner at y=183
        int stateY = 183;
        int listY = stateY + 50;
        // Calculate remaining space for list + chart + image group + status bar
        int imgGroupH = 68;
        int bottomPad = sH + 8 + imgGroupH + 8;
        int availH = h - listY - bottomPad - cH - 8;
        int lH = availH;
        if (lH < 60) lH = 60;
        int chartY = listY + lH + 4;
        int imgGroupY = chartY + cH + 8;

        if(g_hStateLabel)MoveWindow(g_hStateLabel,10,stateY,w-290,42,TRUE);
        if(g_hBtnClear)MoveWindow(g_hBtnClear,w-270,stateY+7,65,28,TRUE);
        if(g_hCountdownLabel)MoveWindow(g_hCountdownLabel,w-195,stateY+12,180,20,TRUE);
        if(g_hListView)MoveWindow(g_hListView,10,listY,w-20,lH,TRUE);
        if(g_hChart)MoveWindow(g_hChart,10,chartY,w-20,cH,TRUE);
        // Image group below chart, above status bar
        if(g_hImgGroup)MoveWindow(g_hImgGroup,10,imgGroupY,w-20,68,TRUE);
        {int r1=imgGroupY+20, r2=imgGroupY+42;
         int entW=140, entX=w-entW-20;
         int browseX=entX-75, labelW=browseX-115;
         if(g_hImgCenterLabel)MoveWindow(g_hImgCenterLabel,20,r1+2,85,20,TRUE);
         if(g_hLabelCenter)MoveWindow(g_hLabelCenter,108,r1+2,labelW,20,TRUE);
         if(g_hImgCenterBrowse)MoveWindow(g_hImgCenterBrowse,browseX,r1,65,22,TRUE);
         if(g_hImgBannerLabel)MoveWindow(g_hImgBannerLabel,20,r2+2,85,20,TRUE);
         if(g_hLabelBanner)MoveWindow(g_hLabelBanner,108,r2+2,labelW,20,TRUE);
         if(g_hImgBannerBrowse)MoveWindow(g_hImgBannerBrowse,browseX,r2,65,22,TRUE);
         if(g_hBtnEnterprise)MoveWindow(g_hBtnEnterprise,entX,imgGroupY+16,entW,40,TRUE);}
        if(g_hStatus)MoveWindow(g_hStatus,0,h-sH-3,w,sH,TRUE);
        break;
    }

    case WM_GETMINMAXINFO:((MINMAXINFO*)lParam)->ptMinTrackSize={700,600};break;

    case WM_CLOSE:
        if (g_hOverlay && g_monitoring) { ShowWindow(hWnd, SW_HIDE); return 0; }
        if(g_monitoring)StopMon();
        if(g_hOverlay){DestroyWindow(g_hOverlay);g_hOverlay=nullptr;}
        DestroyWindow(hWnd);break;

    case WM_DESTROY:
        if(g_hFont)DeleteObject(g_hFont);if(g_hFontBold)DeleteObject(g_hFontBold);
        if(g_hFontBig)DeleteObject(g_hFontBig);if(g_hFontSmall)DeleteObject(g_hFontSmall);
        if(g_hFontSection)DeleteObject(g_hFontSection);
        if(g_hBrushNear)DeleteObject(g_hBrushNear);if(g_hBrushFar)DeleteObject(g_hBrushFar);
        if(g_hBrushLocked)DeleteObject(g_hBrushLocked);if(g_hBrushStopped)DeleteObject(g_hBrushStopped);
        if(g_hFontOvl)DeleteObject(g_hFontOvl);if(g_hFontOvlBtn)DeleteObject(g_hFontOvlBtn);
        if(g_hFontOvlName)DeleteObject(g_hFontOvlName);
        PostQuitMessage(0);break;

    default:return DefWindowProcW(hWnd,msg,wParam,lParam);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// WinMain
// ---------------------------------------------------------------------------
int WINAPI wWinMain(HINSTANCE hI, HINSTANCE, LPWSTR, int nS) {
    HANDLE hMutex = CreateMutexW(nullptr, TRUE, L"SmartScreen_Mutex_v1");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        MessageBoxW(nullptr, L"SmartScreen is already running.", L"SmartScreen", MB_OK|MB_ICONINFORMATION);
        return 0;
    }

    WSADATA wd; WSAStartup(MAKEWORD(2, 2), &wd);

    // GDI+
    ULONG_PTR gdipToken = 0;
    Gdiplus::GdiplusStartupInput gdipIn;
    Gdiplus::GdiplusStartup(&gdipToken, &gdipIn, nullptr);

    // Main window class
    WNDCLASSEXW wc = {}; wc.cbSize = sizeof(wc); wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc; wc.hInstance = hI;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"SmartScreenBT";
    wc.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
    RegisterClassExW(&wc);

    int sx = GetSystemMetrics(SM_CXSCREEN), sy = GetSystemMetrics(SM_CYSCREEN);
    g_hWnd = CreateWindowExW(0, L"SmartScreenBT",
        L"SmartScreen - \xC124\xC815",  // SmartScreen - 설정
        WS_OVERLAPPEDWINDOW,
        (sx - WINDOW_W) / 2, (sy - WINDOW_H) / 2, WINDOW_W, WINDOW_H,
        nullptr, nullptr, hI, nullptr);

    if (!g_hWnd) { MessageBoxW(nullptr, L"Failed", L"Error", MB_ICONERROR); return 1; }

    // Overlay
    {WNDCLASSEXW oc = {}; oc.cbSize = sizeof(oc); oc.lpfnWndProc = OverlayProc;
     oc.hInstance = hI; oc.hCursor = LoadCursor(nullptr, IDC_ARROW);
     oc.lpszClassName = OVERLAY_CLASS; RegisterClassExW(&oc);}
    g_hOverlay = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
        OVERLAY_CLASS, L"SmartScreen", WS_POPUP | WS_VISIBLE,
        sx - OVL_W - 20, 20, OVL_W, OVL_H, nullptr, nullptr, hI, nullptr);
    SetLayeredWindowAttributes(g_hOverlay, 0, 200, LWA_ALPHA);

    g_hFontOvl = CreateFontW(20, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI Semibold");
    g_hFontOvlName = CreateFontW(14, 0, 0, 0, FW_NORMAL, 0, 0, 0,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_hFontOvlBtn = CreateFontW(13, 0, 0, 0, FW_NORMAL, 0, 0, 0,
        DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    if (g_hOverlay) {
        EnumChildWindows(g_hOverlay, [](HWND h, LPARAM f) -> BOOL {
            SendMessage(h, WM_SETFONT, (WPARAM)f, TRUE); return TRUE;
        }, (LPARAM)g_hFontOvlBtn);
    }

    // Show settings if no config, hide if auto-starting
    AppConfig chk;
    if (LoadAppConfig(chk) && chk.btAddress != 0) {
        ShowWindow(g_hWnd, SW_HIDE);
    } else {
        ShowWindow(g_hWnd, nS);
    }
    UpdateWindow(g_hWnd);

    MSG msg;
    while (GetMessage(&msg, nullptr, 0, 0)) { TranslateMessage(&msg); DispatchMessage(&msg); }

    FreeBlackScreenImages();
    if (gdipToken) Gdiplus::GdiplusShutdown(gdipToken);
    WSACleanup();
    if (hMutex) CloseHandle(hMutex);
    return (int)msg.wParam;
}
