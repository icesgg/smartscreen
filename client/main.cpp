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
#include "irk.h"
#include "ble_ident.h"
#include "enterprise/supabase.h"
#include "enterprise/auth.h"
#include "enterprise/session.h"
#include "clipsync.h"
#include "update.h"
#include "version.h"
#include <mutex>

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
static constexpr int ID_BTN_IMPORT_IRK = 218;
static constexpr int ID_BTN_REGISTER_PHONE = 219;
static constexpr UINT WM_SCAN_RESULT = WM_USER + 100;
// 구글 로그인은 사용자가 브라우저에서 시간을 쓰므로 몇 분이 걸린다.
// UI 스레드에서 부르면 그동안 창이 멎으므로 작업 스레드에서 돌리고 결과만 보낸다.
static constexpr UINT WM_LOGIN_RESULT = WM_USER + 101;
// 세션이 갱신되면서 refresh 토큰이 바뀌었다. WPARAM/LPARAM 대신 전역에 두고
// 부르는 이유는 아래 OnSessionRotated 주석 참고.
static constexpr UINT WM_SESSION_ROTATED = WM_USER + 102;
// 업데이트 작업 스레드가 상태를 바꿨다 (client/update.h). 확인·내려받기가
// 끝났을 때 오고, 받는 쪽(UpdateTick)이 적용 여부를 정한다.
static constexpr UINT WM_UPDATE_STATE = WM_USER + 103;
// 켤 때의 기업 콘텐츠 동기화가 끝났다. LPARAM = new EnterpriseSyncResult*.
// 동기화는 네트워크를 타고 파일을 받으므로 작업 스레드에서 돌고, 결과를 화면
// 이미지 경로와 config 에 반영하는 일만 UI 스레드가 한다.
static constexpr UINT WM_ENTERPRISE_SYNC = WM_USER + 104;
// 스캔 스레드가 컴패니언 앱의 첫 연결을 봤다. gattSeen 을 config 에 적는 일을 UI
// 스레드로 넘긴다. 예전에는 스캔 스레드가 직접 Load -> Save 했고, 그것이 "설정
// 쓰기는 한 스레드에서만" (아래 OnSessionRotated 주석) 의 유일한 예외였다.
static constexpr UINT WM_GATT_SEEN = WM_USER + 105;

// 기본으로 열리는 간단 창. 만드는 곳과 창 프로시저는 아래 "간단 화면" 절에 있다.
// 오버레이의 [설정] 이 이 창을 열기 때문에 여기서 미리 알려 둔다.
HWND g_hSimple = nullptr;
static void SimpleRefresh();
// 업데이트 상태를 보고 할 일을 한다: 주기 확인, 준비된 것 적용. UI 스레드.
static void UpdateTick(bool fromNotify);
static ULONGLONG g_updLastCheck = 0;
static constexpr ULONGLONG kUpdateEveryMs = 60ULL * 60 * 1000;   // 한 시간

// 제품이 쓰는 Supabase 프로젝트. config 에 값이 있으면 그쪽이 이긴다.
// anon key 가 여기 박혀 있는 것은 설계대로다 - 공개되도록 만들어진 값이고,
// device_tokens 를 지키는 것은 키가 아니라 RLS 다 (supabase/device_tokens.sql).
static const wchar_t* kDefaultSupabaseUrl =
    L"https://vnonoschrzbgvyeduosm.supabase.co";
static const wchar_t* kDefaultAnonKey =
    L"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZub25vc2NocnpiZ3Z5ZWR1b3NtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU2NzkyNjQsImV4cCI6MjA5MTI1NTI2NH0.KqkmH7UtcR4ihFDMmAMfWRH0O2P2s__Jglzr5QWIzfc";

// 로그인 스레드가 UI 로 돌려보내는 결과
struct LoginResult {
    bool         ok = false;
    std::wstring err;
    std::wstring email;
    std::wstring userId;
    std::wstring refresh;    // DPAPI 로 봉해진 값
    std::wstring phoneToken; // 비어 있으면 "폰에서 아직 로그인 안 함"
};

// ---------------------------------------------------------------------------
// 세션 갱신으로 refresh 토큰이 회전했을 때
// ---------------------------------------------------------------------------
// Supabase 는 갱신할 때마다 새 refresh 토큰을 주고 예전 것을 무효로 만든다.
// 저장하지 않으면 지금 실행은 잘 돌다가 다음 실행에서 로그인이 풀리고, 증상이
// 하루 뒤에 나타나므로 원인을 찾기 어렵다.
//
// 콜백은 일꾼 스레드에서 불린다. 거기서 SaveAppConfig 를 부르면 UI 스레드의
// 저장과 겹쳐 서로의 변경을 덮어쓸 수 있다 (파일을 통째로 다시 쓰기 때문에).
// 그래서 값만 전역에 놓고 UI 스레드로 넘긴다 - 설정 쓰기는 한 스레드에서만.
static std::mutex   g_rotatedMx;
static std::wstring g_rotatedSealed;

static void OnSessionRotated(const std::wstring& sealed) {
    {
        std::lock_guard<std::mutex> lock(g_rotatedMx);
        g_rotatedSealed = sealed;
    }
    if (g_hWnd) PostMessageW(g_hWnd, WM_SESSION_ROTATED, 0, 0);
}

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
static constexpr int IDT_UPDATE      = 11;   // 1분마다 UpdateTick
static constexpr int IDT_AUTHSAVE    = 12;   // 못 쓴 계정 값을 다시 쓴다 (FlushAuthSave)
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
        // 기기 이름은 상대 기기가 정한다 (최대 248자). swprintf_s 는 넘치면 잘라 쓰지
        // 않고 프로세스를 끝낸다 - 이름이 긴 기기를 고르면 검은 화면째 죽는다.
        _snwprintf_s(g_ovlLine1, _countof(g_ovlLine1), _TRUNCATE, L"\u25A3 %s", g_targetName.c_str());
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
        else if (g_bManualLock)
            wcscpy_s(g_ovlLine2, L"잠금  •  [해제] 를 눌러야 풀립니다");
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
            // 간단 창이 사용자가 보는 창이다. 고급 창은 거기서 연다.
            if (g_hSimple) {
                ShowWindow(g_hSimple, SW_SHOW); SetForegroundWindow(g_hSimple); SimpleRefresh();
            } else {
                ShowWindow(g_hWnd, SW_SHOW); SetForegroundWindow(g_hWnd);
            }
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
// 지금 무엇으로 폰을 알아보고 있는지. 화면에는 어느 쪽이든 똑같이 NEAR 로
// 보여서, 등록을 건너뛴 PC 가 예전 IRK 경로로 돌고 있는 것을 아무도 못 알아챘다.
static bool g_hasToken = false;
static bool g_hasIrk = false;

static DWORD WINAPI ScanThread(LPVOID) {
    g_proxState = ProxState::Far;
    g_lastNearTick = 0;
    // RFCOMM 프로브 결과 캐시 (폰 연결 대기 중에는 프로브를 띄엄띄엄 돌린다)
    ULONGLONG lastProbeTick = 0;
    bool  cachedReachable = false;
    DWORD cachedLatency = 0;
    int   cachedErr = 0;
    // 임계값 미만이 연속 몇 "샘플" 이어졌는지. 시간이 아니라 샘플 수로 센다.
    int       belowCount = 0;
    ULONGLONG belowFirstTick = 0;   // 이 구간의 첫 미만 샘플 시각 (상한 계산용)
    ULONGLONG belowSampleTick = 0;  // 마지막으로 센 샘플의 식별자 (같으면 다시 세지 않는다)
    while (true) {
        bool reachable = false; DWORD latency = 0; int wsaErr = 0;
        bool isNear = false, bleAvail = false, useGatt = false;
        int rssi = -100;
        int effThr = g_nearRssiThreshold;   // 이 샘플을 판정한 실효 임계값 (로그용)

        // 컴패니언 앱이 이 PC에 붙은 적이 있으면(이번 세션 또는 과거), GATT 연결이 끊긴 것
        // 자체가 자리 비움의 단서다. 다만 단서일 뿐이라 광고가 폰을 듣고 있으면 그쪽을 쓴다.
        // latency 폴백만은 이 경우에도 쓰지 않는다 - 30~50m까지 닿아서 자리 비움을 놓친다.
        bool gattExpected = g_bleGatt.IsRunning() &&
            (g_bleGatt.EverSubscribed() || (g_gattSeen &&
                (GetTickCount64() - g_monStartTick) > (ULONGLONG)g_gattGraceSec * 1000));

        if (g_bleGatt.IsHealthy()) {
            // v2: 폰 앱이 GATT로 연결되어 ~1Hz로 RSSI를 보고 중 → 최우선 사용
            useGatt = true; bleAvail = true; reachable = true;
            rssi = g_bleGatt.GetSmoothedRssi();
            // 아래 두 갈래는 임계값을 안 본다. 그래도 effThr 은 이 경로의 설정값으로
            // 둔다 - 기본값(광고 임계값)인 채로 두면 STATE 줄이 "GATT rssi=-65 thr=-67"
            // 처럼 다른 경로의 숫자를 찍어서, 로그만 보고는 왜 NEAR 가 됐는지 알 수 없다.
            effThr = g_gattRssiThreshold;
            if (g_bleGatt.CurrentPollIntervalMs() == 0) {
                isNear = true;                               // 입력 중이라 폴링을 쉬는 상태 = 자리에 있음
            } else if (g_bleGatt.ReportAgeMs() == 0xFFFFFFFF) {
                isNear = (g_proxState == ProxState::Near);   // 첫 보고 대기 중: 현재 상태 유지
            } else {
                // 히스테리시스: 잠금은 임계값 미만, 해제는 임계값+4 이상 (경계에서 깜빡임 방지)
                int thr = g_gattRssiThreshold + (g_proxState == ProxState::Near ? 0 : 4);
                effThr = thr;
                isNear = (rssi >= thr);
            }
        } else if (gattExpected && !(g_bleScanner.IsAvailable() && g_bleScanner.IsReceiving())) {
            // 앱이 붙어 있어야 하는데 연결도 없고 광고도 안 들린다 → 부재로 판정.
            //
            // 광고가 들리면 이쪽으로 오지 않는다. 예전에는 GATT가 끊기기만 하면
            // RSSI를 보지도 않고 부재로 단정했는데, 앱이 잠깐 떨어져 나간 것만으로
            // -46dBm 으로 들리는 폰을 두고 화면을 잠갔다.
            // 못 믿을 것은 latency 폴백(30~50m까지 닿아 자리 비움을 놓친다)이지
            // 광고 RSSI가 아니다. 광고는 이 제품의 주력 경로다.
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
                // 히스테리시스: 잠금은 임계값 미만, 해제는 임계값+4 이상.
                // GATT 경로에만 있었는데, 실측에서 착석 분포의 아래 꼬리가 임계값에
                // 닿으면 1dB 흔들림에 NEAR/FAR 이 뒤집혔다. 같은 이유로 여기에도 필요하다.
                effThr = g_nearRssiThreshold + (g_proxState == ProxState::Near ? 0 : 4);
                isNear = (rssi >= effThr);
            } else if (g_targetAddr == 0) {
                // 등록된 폰은 Classic 주소가 없다. 여기서 RFCOMM 을 찔러 봐야
                // 붙을 상대도 없고 같은 라디오의 BLE 슬롯만 빼앗는다 (PROXIMITY.md 참고).
                reachable = false;
                latency = 0;
            } else {
                // BLE 불가 → 기존 latency fallback.
                // 단, GATT 서버가 폰을 기다리는 중이면 프로브 간격을 늘린다:
                // 같은 라디오에서 2초마다 Classic 연결을 시도하면 BLE 광고/연결이 밀려
                // 폰이 PC를 찾지 못한다. (iPhone은 PAN이 붙어 있지 않으면 RFCOMM도 실패)
                bool gattWaiting = g_bleGatt.IsRunning() && !g_bleGatt.EverSubscribed();
                ULONGLONG tick = GetTickCount64();
                if (!gattWaiting || lastProbeTick == 0 || (tick - lastProbeTick) >= 20000) {
                    lastProbeTick = tick;
                    DoProbe(g_targetAddr, reachable, latency, wsaErr);
                    cachedReachable = reachable; cachedLatency = latency; cachedErr = wsaErr;
                } else {
                    reachable = cachedReachable; latency = cachedLatency; wsaErr = cachedErr;
                }
            }
        }

        // 앱이 처음 연결되면 config에 기록 → 다음부터는 미연결을 "부재"로 취급
        if (!g_gattSeen && g_bleGatt.EverSubscribed()) {
            g_gattSeen = true;
            // 저장은 UI 스레드가 한다 (WM_GATT_SEEN). 여기서 직접 Load -> Save 하면
            // 그 사이에 UI 스레드가 쓴 값(회전한 refresh 토큰 등)을 낡은 사본으로 덮는다.
            PostMessage(g_hWnd, WM_GATT_SEEN, 0, 0);
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
            belowCount = 0; belowFirstTick = 0; belowSampleTick = 0;
            if (g_proxState == ProxState::Far) g_proxState = ProxState::Near;
        } else if (g_proxState == ProxState::Near) {
            bool goFar;
            if (!bleAvail) {
                // latency 모드: 측정값이 매번 흔들리므로 기존 유예시간 유지
                goFar = (now - g_lastNearTick) >= (ULONGLONG)g_keepAliveSec * 1000;
            } else if (rssi <= -100) {
                // 약한 게 아니라 신호가 아예 없다 (수신 타임아웃, 또는 연결도 광고도 없음).
                // 이건 페이딩이 아니라 부재이므로 기다릴 이유가 없다.
                goFar = true;
            } else {
                // 패킷 사이에는 새 정보가 없다 - 그래서 시간 유예는 지연만 늘린다.
                // 하지만 두 번째 패킷은 실제로 새 정보다. 그래서 시간이 아니라 샘플을 센다:
                // 새 샘플이 연속 두 번 임계값 미만일 때만 잠근다. 단발 페이딩으로
                // 앉아 있는 사람 앞에서 화면이 꺼지던 것이 이걸로 사라진다.
                ULONGLONG sampleTick = useGatt ? g_bleGatt.LastReportTick()
                                               : g_bleScanner.LastReceivedTick();
                if (sampleTick != belowSampleTick) {
                    if (belowCount == 0) belowFirstTick = now;
                    belowSampleTick = sampleTick;
                    ++belowCount;
                }
                // 두 번째 샘플을 무한정 기다리면 안 된다: 걸어나가면서 신호가 끊기면
                // 다음 샘플이 영영 안 오고, 수신 타임아웃은 90초다. 상한을 둔다.
                goFar = (belowCount >= 2) ||
                        (now - belowFirstTick) >= BELOW_SAMPLE_CAP_MS;
            }
            if (goFar) g_proxState = ProxState::Far;
        }
        auto* r = new ProbeResult{};
        r->reachable = reachable; r->latencyMs = latency; r->wsaError = wsaErr;
        r->rssiDbm = rssi; r->bleAvailable = bleAvail; r->gatt = useGatt;
        r->thresholdDbm = effThr;
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
// 구글 로그인 (작업 스레드)
// ---------------------------------------------------------------------------
// 브라우저에서 사용자가 쓰는 시간이 있어 최악 몇 분이다. UI 스레드에서 부르면
// 그동안 설정 창이 통째로 멎으므로, 여기서 돌리고 결과만 창으로 보낸다.
static volatile bool g_loginBusy = false;

static DWORD WINAPI LoginThread(LPVOID) {
    AppConfig cfg;
    LoadAppConfig(cfg);
    std::wstring url = cfg.serverUrl.empty() ? kDefaultSupabaseUrl : cfg.serverUrl;
    std::wstring key = cfg.anonKey.empty() ? kDefaultAnonKey : cfg.anonKey;

    auto* r = new LoginResult{};
    AuthSession s;
    if (!SignInWithGoogle(url, key, s, r->err)) {
        PostMessage(g_hWnd, WM_LOGIN_RESULT, 0, (LPARAM)r);
        return 0;
    }
    // 여기까지 왔으면 로그인은 됐다. 뒤에서 무엇이 실패하든 세션은 저장할 값이다.
    r->ok = true;
    r->email = s.email;
    r->userId = s.userId;
    ProtectSecret(s.refreshToken, r->refresh);

    // 살아 있는 세션으로 심는다. 이게 없으면 방금 로그인해도 클립보드 동기화는
    // 앱을 다시 켤 때까지 "로그인하지 않았다" 로 남는다 - 로그인한 사람에게
    // 로그인하라고 말하는 상태가 된다.
    SessionAdopt(s);

    std::wstring token, err;
    if (!FetchDeviceToken(url, key, s, token, err)) r->err = err;
    else r->phoneToken = token;   // 빈 값일 수 있다 = 폰에서 아직 로그인 안 함

    PostMessage(g_hWnd, WM_LOGIN_RESULT, 0, (LPARAM)r);
    return 0;
}

// ---------------------------------------------------------------------------
// 계정 값을 config 에 쓰기 (UI 스레드에서만)
// ---------------------------------------------------------------------------
// 회전한 refresh 토큰과 로그인 결과는 "썼다" 를 확인해야 하는 값이다. 못 쓰면
// 지금 실행은 멀쩡하다가 다음 실행에서 로그인이 풀린다.
//
// 예전에는 Load 의 결과도 Save 의 결과도 보지 않았고, 로그는 어느 쪽이든
// "rotated, saved" 였다. 못 쓴 값은 그 자리에서 버려졌다. 지금은 못 쓴 값을
// 여기 들고 있다가 타이머(IDT_AUTHSAVE)로 다시 쓴다.
struct AuthSave {
    bool         pending = false;   // 아래에 아직 못 쓴 것이 있다
    std::wstring refresh;           // 봉한 refresh 토큰. 빈 값이면 authRefresh 를 덮지 않는다
    bool         login = false;     // 로그인 결과도 같이 쓴다 (아래 셋)
    std::wstring userId, email, phoneToken;
    int          tries = 0;         // 연달아 실패한 횟수 (다시 쓰는 간격을 벌린다)
};
static AuthSave g_authSave;

// g_authSave 를 config 에 쓴다. 썼으면 true. 못 썼으면 타이머를 걸어 둔다.
static bool FlushAuthSave() {
    if (!g_authSave.pending) return true;

    // Load 가 "파일이 없다" 로 false 인 것은 괜찮다 - 처음 로그인하는 PC 다.
    // "있는데 못 읽었다" 면 SaveAppConfig 가 거절하고, 그러면 아래에서 다시 건다.
    AppConfig c; LoadAppConfig(c);
    if (g_authSave.login) {
        // 서버 주소/키는 여기서 적지 않는다. 예전에는 로그인할 때 exe 의 기본값을
        // config.ini 에 적어 넣었고, 한 번 적힌 값은 exe 의 기본값이 바뀌어도 그 PC 에
        // 남았다. 읽는 쪽은 전부 비어 있으면 기본값을 쓴다 (kDefaultSupabaseUrl 주석).
        //
        // 봉인(DPAPI)이 실패해 새 토큰이 없을 때: 저장돼 있던 토큰을 빈 값으로
        // 덮지 않는다 - 같은 계정이면 아직 살아 있을 수 있다. 다른 계정의 것이면
        // 지운다. 남겨 두면 다음 실행에서 화면은 새 계정인데 세션은 예전 계정이 된다.
        if (g_authSave.refresh.empty() && c.authUserId != g_authSave.userId)
            c.authRefresh.clear();
        c.authUserId = g_authSave.userId;
        c.authEmail  = g_authSave.email;
        if (!g_authSave.phoneToken.empty()) {
            c.phoneToken  = g_authSave.phoneToken;
            c.phoneOvfBit = -1;   // 비트는 잠긴 폰을 처음 탐색할 때 배운다
        }
    }
    if (!g_authSave.refresh.empty()) c.authRefresh = g_authSave.refresh;

    if (SaveAppConfig(c)) {
        g_authSave = AuthSave{};
        KillTimer(g_hWnd, IDT_AUTHSAVE);
        return true;
    }
    // 30초, 1분, 2분 ... 10분. 파일이 계속 안 써지는 PC(읽기 전용, 권한)에서 로그가
    // 이것으로 차지 않게 벌린다. 실패 사유는 SaveAppConfig 가 적는다.
    UINT waitMs = 30000;
    for (int i = 0; i < g_authSave.tries && waitMs < 600000; i++) waitMs *= 2;
    if (waitMs > 600000) waitMs = 600000;
    g_authSave.tries++;
    SetTimer(g_hWnd, IDT_AUTHSAVE, waitMs, nullptr);
    return false;
}

// ---------------------------------------------------------------------------
// PopulateCombo
//
// 목록은 원래 "페어링된 기기"였다. 등록된 폰은 페어링할 필요가 없는 것이 요점이라
// (ble_ident.h) 목록에 없고, 그대로 두면 엉뚱한 페어링 기기가 대상으로 잡힌다.
// 그래서 토큰이 등록돼 있으면 맨 앞에 "등록된 폰" 항목을 넣고 기본으로 고른다.
// ---------------------------------------------------------------------------
static bool g_comboPhoneEntry = false;   // 목록 0번이 "등록된 폰"인지

// 콤보 선택을 g_paired 인덱스로 바꾼다. "등록된 폰" 항목이거나 범위 밖이면 -1
static int ComboSelToPaired(int sel) {
    if (g_comboPhoneEntry) sel -= 1;
    return (sel >= 0 && sel < (int)g_paired.size()) ? sel : -1;
}
static bool ComboIsPhoneEntry(int sel) { return g_comboPhoneEntry && sel == 0; }

static void PopulateCombo() {
    SendMessageW(g_hCombo, CB_RESETCONTENT, 0, 0);
    EnumPaired();

    AppConfig ccfg; LoadAppConfig(ccfg);
    g_comboPhoneEntry = !ccfg.phoneToken.empty();
    if (g_comboPhoneEntry) {
        std::wstring head = ccfg.phoneToken.substr(0, (std::min)((size_t)8, ccfg.phoneToken.size()));
        std::wstring it = L"등록된 폰  [토큰 " + head + L"]";  // 등록된 폰 [토큰 ...]
        SendMessageW(g_hCombo, CB_ADDSTRING, 0, (LPARAM)it.c_str());
    }

    if (g_paired.empty() && !g_comboPhoneEntry) {
        SendMessageW(g_hCombo, CB_ADDSTRING, 0, (LPARAM)L"(\xD398\xC5B4\xB9C1\xB41C \xAE30\xAE30 \xC5C6\xC74C)");  // (페어링된 기기 없음)
        EnableWindow(g_hBtnStart, FALSE); return;
    }
    for (size_t i = 0; i < g_paired.size(); i++) {
        wchar_t it[256];
        // 이름은 상대 기기가 정한 값이다 (UpdateOverlayState 의 같은 주석)
        _snwprintf_s(it, _countof(it), _TRUNCATE, L"%s  [%s]%s", g_paired[i].name.c_str(),
            FmtAddr(g_paired[i].address).c_str(), g_paired[i].connected ? L" *" : L"");
        SendMessageW(g_hCombo, CB_ADDSTRING, 0, (LPARAM)it);
    }
    EnableWindow(g_hBtnStart, TRUE);

    // 저장된 주소가 0이면 등록된 폰을 쓰던 것이다 → 0번(등록된 폰)이 그대로 기본이 된다
    if (g_targetAddr != 0) {
        for (size_t i = 0; i < g_paired.size(); i++) {
            if (g_paired[i].address == g_targetAddr) {
                SendMessageW(g_hCombo, CB_SETCURSEL, i + (g_comboPhoneEntry ? 1 : 0), 0);
                return;
            }
        }
    }
    SendMessageW(g_hCombo, CB_SETCURSEL, 0, 0);
}

// ---------------------------------------------------------------------------
// Start / Stop
// ---------------------------------------------------------------------------
static void StartMon() {
    int sel = (int)SendMessageW(g_hCombo, CB_GETCURSEL, 0, 0);
    int pairedIdx = ComboSelToPaired(sel);
    if (!ComboIsPhoneEntry(sel) && pairedIdx < 0) return;

    // RSSI 임계값 읽기 (에디트 박스에서)
    wchar_t latBuf[16];
    GetWindowTextW(g_hEditLatency, latBuf, _countof(latBuf));
    int latVal = _wtoi(latBuf);
    // RSSI는 음수값 (-30 ~ -100 범위)
    if (latVal > 0) latVal = -latVal;  // 양수 입력시 음수로 변환
    if (latVal > -30) latVal = -30;
    if (latVal < -100) latVal = -100;
    g_nearRssiThreshold = latVal;
    // 연결(GATT) 경로도 같은 값이다. 처음에는 "폰이 잰 값이라 눈금이 다르다" 고 따로
    // 뒀지만, 실측에서 두 경로는 2dB 안에서 같이 움직였고(PROXIMITY.md) 간단 창의
    // 슬라이더는 이미 둘을 같이 바꾼다. 이 칸만 광고 쪽을 바꾸게 두면 폰 앱이 붙어
    // 있는 PC 는 화면에 보이는 것과 다른 값으로 판정한다 - 실제로 광고 -67 / 연결 -61
    // 로 갈라진 채 앉은 자리에서 잠겼다 (2026-10-01).
    g_gattRssiThreshold = latVal;
    swprintf_s(latBuf, L"%d", latVal); SetWindowTextW(g_hEditLatency, latBuf);
    // latency fallback용 (호환성)
    g_nearLatencyMs = 200;

    // 콤보를 없앴으므로 config 값을 그대로 쓴다 (기본 5초)
    int awayIdx = g_hComboAway ? (int)SendMessageW(g_hComboAway, CB_GETCURSEL, 0, 0) : -1;
    if (awayIdx < 0) awayIdx = 0;
    if (awayIdx >= 0 && awayIdx < 3) g_keepAliveSec = kAwayValues[awayIdx];

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
    if (ComboIsPhoneEntry(sel)) {
        // 신원은 토큰으로만 확인한다. 주소나 이름으로도 매칭하게 두면
        // 이름이 겹치는 남의 기기 광고가 같은 칼만 필터에 섞여 들어온다.
        g_targetAddr = 0;
        g_targetName = L"등록된 폰";   // 표시용. 광고 이름과는 절대 안 맞는다
    } else {
        g_targetAddr = g_paired[pairedIdx].address;
        g_targetName = g_paired[pairedIdx].name;
    }
    g_logCount = 0;

    // Save config (load first to preserve enterprise settings)
    AppConfig cfg;
    LoadAppConfig(cfg);

    // BLE RSSI 스캐너 시작 (기기 이름으로 BLE 광고 매칭)
    // config.ini에 bleDebugLog=1 이면 주변 광고를 ble_scan_log.csv로 기록
    // IRK: exe 옆에 irk.txt(1회 추출 파일)가 있으면 config로 가져온 뒤 삭제
    // config 를 못 읽은 채로는 가져오지 않는다: 가져오면 irk.txt 가 지워지는데,
    // 못 읽은 구조체는 저장되지 않으므로(SaveAppConfig) 키가 그대로 사라진다.
    if (cfg.bleIrk.empty() && !cfg.loadFailed) ImportBleIrkFile(cfg, GetExeDir() + L"irk.txt");
    g_bleScanner.SetIrk(cfg.bleIrk);
    g_bleLostMeansFar = cfg.bleLostMeansFar;
    DbgEvent(L"START thr=%d dBm keepAlive=%lus idle=%ds unlockDelay=%ds bleTimeout=%lus lostMeansFar=%d irk=%d",
        g_nearRssiThreshold, g_keepAliveSec, g_idleCountdownSec, g_unlockDelaySec,
        cfg.bleTimeoutSec, cfg.bleLostMeansFar ? 1 : 0, cfg.bleIrk.empty() ? 0 : 1);
    DbgEvent(L"ident: token=%d ovfBit=%d",
        cfg.phoneToken.empty() ? 0 : 1, cfg.phoneOvfBit);
    // v2: GATT 서버를 먼저 시작 (폰 앱이 연결해 오면 1Hz RSSI 보고를 받음. 실패해도 v1/latency로 동작)
    // g_gattRssiThreshold 는 위에서 "신호 강도" 칸의 값으로 맞췄다. config 의
    // gattRssiThreshold 는 그 값의 사본일 뿐이라 여기서 다시 읽지 않는다.
    g_gattSeen = cfg.gattSeen;
    g_gattGraceSec = cfg.gattGraceSec;
    g_monStartTick = GetTickCount64();
    g_lastInputTick = GetTickCount64();
    if (cfg.bleGattServer) {
        // 진단 로그는 bleDebugLog 를 따른다. 예전에는 경로를 조건 없이 넘겨서
        // 광고 로그만 꺼지고 이쪽은 계속 자랐다 - 끈 줄 알고 둔 채로.
        bool ok = g_bleGatt.Start(!cfg.bleGattEncrypt,
            cfg.bleDebugLog ? GetConfigDir() + L"\\gatt_rssi_log.csv" : L"");
        DbgEvent(L"GATT server start: %s (encrypt=%d, thr=%d dBm)",
            ok ? L"OK" : L"FAILED", cfg.bleGattEncrypt ? 1 : 0, g_gattRssiThreshold);
    } else {
        DbgEvent(L"GATT server disabled by config");
    }

    // v1 광고 스캔은 항상 켠다.
    // 라디오를 나눠 쓰는 게 걱정되어 껐던 적이 있는데, 그 뒤로 어떤 USB 동글에서는
    // 광고 자체가 폰에 잡히지 않았다. 스캔이 도는 동안에만 BLE 송신이 제대로 되는
    // 드라이버가 있는 것으로 보인다. 폴백 데이터도 얻을 수 있어 켜 두는 편이 안전하다.
    DbgEvent(L"v1 advertisement scan: on");
    // 연결으로 신원을 확인하는 경로 (IRK 없이 동작). 등록된 토큰이 있을 때만 켜진다.
    // 탐색 하한은 임계값보다 10dB 낮게 — 그보다 멀면 어차피 자리 판정에 쓸 수 없어
    // 남의 폰에 연결을 시도할 이유가 없다.
    g_hasToken = !cfg.phoneToken.empty();
    g_hasIrk = !cfg.bleIrk.empty();
    g_bleScanner.SetIdentity(cfg.phoneToken, cfg.phoneOvfBit, g_nearRssiThreshold - 10);
    g_bleScanner.SetTimeoutSec(cfg.bleTimeoutSec);
    g_bleScanner.SetDebugLog(cfg.bleDebugLog ? GetConfigDir() + L"\\ble_scan_log.csv" : L"");
    g_bleScanner.Start(g_targetName, g_targetAddr);

    cfg.btAddress = g_targetAddr;
    cfg.nearLatencyMs = g_nearLatencyMs;
    cfg.nearRssiThreshold = g_nearRssiThreshold;
    cfg.gattRssiThreshold = g_gattRssiThreshold;   // 같은 값 (위 주석)
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
    EnableWindow(g_hEditLatency, FALSE); if (g_hComboAway) EnableWindow(g_hComboAway, FALSE);
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
    EnableWindow(g_hEditLatency, TRUE); if (g_hComboAway) EnableWindow(g_hComboAway, TRUE);
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
        DbgEvent(L"STATE %s -> %s  (%s rssi=%d dBm thr=%d set=%d, latency=%lums reachable=%d)",
            r->prevState == ProxState::Near ? L"NEAR" : L"FAR", r->state == ProxState::Near ? L"NEAR" : L"FAR",
            r->gatt ? L"GATT" : (r->bleAvailable ? L"adv" : L"latency"), r->rssiDbm,
            r->thresholdDbm,                                          // 히스테리시스 적용된 실효값
            r->gatt ? g_gattRssiThreshold : g_nearRssiThreshold,      // 설정값
            r->latencyMs, r->reachable ? 1 : 0);
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

    // 폰이 돌아오면 자동으로 풀어 준다. 단 사용자가 직접 잠근 것은 예외다 -
    // 그건 "자리에 있어도 가려 두겠다"는 명시적 의사라, 폰이 곁에 있다는
    // 이유로 되돌리면 그 의사를 뒤집는 것이 된다. 풀려면 [해제] 를 누른다.
    //
    // g_bManualLock 은 두 잠금 버튼이 세팅해 왔지만 아무도 읽지 않았다.
    // 그래서 지금까지 수동 잠금도 자동으로 풀렸다.
    if (r->state == ProxState::Near && g_bBlackActive && !g_bManualLock && g_unlockTimer <= 0) {
        g_unlockTimer = g_unlockDelaySec;
        if (g_unlockTimer <= 0) DeactivateBlackScreen(); // delay=0 -> instant
    }
    if (r->state == ProxState::Far) g_unlockTimer = 0;
    // NEAR no longer resets idle countdown - only mouse/keyboard does

    if(r->state==ProxState::Near){wchar_t lb[128];
        swprintf_s(lb,L"  \xADFC\xCC98   (\xC720\xD734: %ds)", g_nCountdown);  // 근처 (유휴: Ns)
        SetWindowTextW(g_hStateLabel,lb);
    } else if (r->bleAvailable && r->rssiDbm <= -100) {
        // 신호가 약해서가 아니라 폰 신호가 아예 끊긴 경우.
        // 앱을 위로 밀어 종료했거나 iOS가 앱을 내린 상황이라 사용자가 알아야 한다.
        SetWindowTextW(g_hStateLabel, L"  멀리  (폰 신호 없음 - 앱 확인)");
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
    // 잠긴 아이폰을 특정하는 수단. 둘 다 없으면 특정할 방법이 원천적으로 없고,
    // 그래도 화면은 멀쩡해 보이므로 여기에 드러내 둔다.
    const wchar_t* idSt =
        (!g_hasToken && !g_hasIrk)             ? L"없음!"
        : !g_hasToken                          ? L"IRK"
        : (g_bleScanner.BoundAddress() == 0)   ? (g_hasIrk ? L"IRK/토큰 대기" : L"토큰 대기")
        :                                        (g_hasIrk ? L"토큰+IRK" : L"토큰");
    if(r->bleAvailable)
        // 초당 수신 건수: 신호가 얼마나 촘촘한지 보면서 임계값을 잡을 수 있다
        // g_targetName 은 상대 기기가 정한 이름이라 길이를 믿을 수 없다 - _TRUNCATE 로 쓴다
        _snwprintf_s(status,_countof(status),_TRUNCATE,L"  \"%s\"  |  %s  |  RSSI: %d dBm%s  |  %.1f/s  |  Near>=%d dBm  |  ID: %s  |  GATT: %s  |  Idle: %ds",
            g_targetName.c_str(),StateStr(r->state),r->rssiDbm,r->gatt?L" (GATT)":L"",
            g_bleScanner.RecentPacketRate(),
            r->gatt?g_gattRssiThreshold:g_nearRssiThreshold,idSt,gattSt,g_nCountdown);
    else
        _snwprintf_s(status,_countof(status),_TRUNCATE,L"  \"%s\"  |  %s  |  Latency: %lu ms  |  BLE: N/A  |  ID: %s  |  GATT: %s  |  Idle: %ds",
            g_targetName.c_str(),StateStr(r->state),r->latencyMs,idSt,gattSt,g_nCountdown);
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
// 기업 콘텐츠 동기화
// ---------------------------------------------------------------------------
// 켤 때의 동기화는 작업 스레드에서 돈다. 예전에는 WM_CREATE 안에서, UI 스레드로,
// 창이 하나도 뜨기 전에 돌았다. 서버가 느리거나 닿지 않으면 WinHTTP 의 제한
// 시간만큼 앱이 안 뜬 것처럼 보였고, 자동 시작(자리비움 감지)도 그 뒤로 밀렸다.
// 구글 로그인과 같은 모양으로, 여기서 돌리고 결과만 창으로 보낸다.
struct EnterpriseSyncJob {
    HWND         hWnd;
    std::wstring url, key, org;
};
struct EnterpriseSyncResult {
    EnterpriseSync outcome = EnterpriseSync::RequestFailed;
    std::wstring   org;              // 어느 조직으로 돌렸나. 도는 사이에 등록이 바뀔 수 있다
    std::wstring   center, banner;   // 자리마다 받은 파일. 빈 값 = 그 자리에 쓸 것이 없다
};

static DWORD WINAPI EnterpriseSyncThread(LPVOID param) {
    auto* job = (EnterpriseSyncJob*)param;
    auto* r = new EnterpriseSyncResult{};
    r->org = job->org;
    r->outcome = SyncEnterpriseContentEx(job->url, job->key, job->org, r->center, r->banner);
    // g_hWnd 가 아니라 받은 핸들로 보낸다. 이 스레드는 WM_CREATE 에서 시작하는데
    // 그때 g_hWnd 는 아직 비어 있다 (CreateWindowExW 가 돌아와야 채워진다).
    if (!PostMessageW(job->hWnd, WM_ENTERPRISE_SYNC, 0, (LPARAM)r)) delete r;   // 창이 이미 닫혔다
    delete job;
    return 0;
}

// 동기화 결과를 화면 이미지 경로에 반영한다. UI 스레드에서만 부른다 (config 를 쓴다).
// 바뀐 것이 있으면 true.
//
// 경로의 주인: enterprise_content 폴더 안을 가리키는 경로는 동기화의 것이다. 서버에
// 물어본 결과가 나올 때마다 그 자리의 새 경로로 바꾸고, 서버에 그 자리 것이 없으면
// 비운다. 사용자가 다른 곳에서 고른 그림은 건드리지 않고, 빈 자리는 채운다.
//
// 예전에는 "비어 있을 때만 채운다" 였다. 그런데 한 번 채운 경로는 config.ini 에
// 저장되므로(StartMon) 다음 실행부터는 비어 있는 적이 없었고, 관리자가 콘텐츠를
// 바꾸거나 송출을 멈춰도 PC 는 처음 받은 파일을 계속 띄웠다.
//
// 요청이 실패했으면 아무것도 건드리지 않는다 - 오프라인인 PC 는 갖고 있던 것을
// 계속 보여 준다.
static bool ApplyEnterpriseSync(EnterpriseSync outcome,
                                const std::wstring& center, const std::wstring& banner) {
    if (outcome == EnterpriseSync::RequestFailed) return false;

    bool changed = false;
    auto apply = [&changed](std::wstring& cur, const std::wstring& synced, HWND hLabel) {
        if (!cur.empty() && !IsEnterpriseContentPath(cur)) return;   // 사용자가 고른 그림
        if (cur == synced) return;
        cur = synced;
        std::wstring text = synced.empty() ? std::wstring(L"(기본)") : TruncPath(synced);
        if (hLabel) SetWindowTextW(hLabel, text.c_str());
        changed = true;
    };
    apply(g_centerImagePath, center, g_hLabelCenter);
    apply(g_bannerImagePath, banner, g_hLabelBanner);
    if (!changed) return false;

    // 올려 둔 그림을 버린다 (LoadBlackScreenImages 는 이미 올린 것이 있으면 다시
    // 읽지 않는다). 단, 잠금 화면이 떠 있는 동안에는 건드리지 않는다 - 동기화가 작업
    // 스레드로 가면서 결과가 잠금 중에 도착할 수 있게 됐는데, 영상은 그 창의
    // WM_CREATE 에서만 시작하므로 여기서 그림만 버리면 (새 경로가 영상이거나 비었을
    // 때) 다음에 그려질 때 그림도 영상도 없이 개발용 자리표시자가 나온다. 지금 잠금은
    // 보여 주던 것을 그대로 보여 주고, 풀릴 때 DeactivateBlackScreen 이 버린다.
    if (!g_bBlackActive) FreeBlackScreenImages();

    // StartMon 이 저장하는 것과 같은 두 값이다. 여기서도 저장해야 감시를 다시
    // 시작하지 않아도 다음 실행에 남는다.
    AppConfig c;
    if (LoadAppConfig(c)) {
        c.centerImagePath = g_centerImagePath;
        c.bannerImagePath = g_bannerImagePath;
        SaveAppConfig(c);
    }
    return true;
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
            115, y, 290, 200, hWnd, (HMENU)(UINT_PTR)ID_COMBO, hInst, nullptr);

        CreateWindowExW(0, L"BUTTON",
            L"\xC0C8\xB85C\xACE0\xCE68",  // 새로고침
            WS_CHILD | WS_VISIBLE, 412, y, 64, 28, hWnd,
            (HMENU)(UINT_PTR)ID_REFRESH, hInst, nullptr);

        g_hBtnStart = CreateWindowExW(0, L"BUTTON",
            L"\xC2DC\xC791",  // 시작
            WS_CHILD | WS_VISIBLE, 480, y, 58, 28, hWnd,
            (HMENU)(UINT_PTR)ID_START, hInst, nullptr);

        g_hBtnStop = CreateWindowExW(0, L"BUTTON",
            L"\xC911\xC9C0",  // 중지
            WS_CHILD | WS_VISIBLE | WS_DISABLED, 542, y, 52, 28, hWnd,
            (HMENU)(UINT_PTR)ID_STOP, hInst, nullptr);

        CreateWindowExW(0, L"BUTTON", L"BT",
            WS_CHILD | WS_VISIBLE, 598, y, 34, 28, hWnd,
            (HMENU)(UINT_PTR)ID_BT_SETTINGS, hInst, nullptr);

        // 폰이 내주는 토큰으로 신원을 잡는다. Phone Link 설정도 IRK 도 필요 없다.
        CreateWindowExW(0, L"BUTTON", L"폰 등록",
            WS_CHILD | WS_VISIBLE, 636, y, 74, 28, hWnd,
            (HMENU)(UINT_PTR)ID_BTN_REGISTER_PHONE, hInst, nullptr);

        // 예전 방식: 레지스트리의 IRK 로 랜덤 주소를 푼다.
        // 그 PC 에서 LE 본딩이 한 번 있어야 해서 '폰 등록' 이 안 될 때의 대비책이다.
        CreateWindowExW(0, L"BUTTON", L"기기 키",
            WS_CHILD | WS_VISIBLE, 714, y, 66, 28, hWnd,
            (HMENU)(UINT_PTR)ID_BTN_IMPORT_IRK, hInst, nullptr);

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
        g_hEditLatency = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"-65",
            WS_CHILD | WS_VISIBLE | ES_CENTER,
            105, row1Y, 50, 24, hWnd, (HMENU)(UINT_PTR)ID_EDIT_LATENCY, hInst, nullptr);
        CreateWindowExW(0, L"STATIC", L"dBm \xC774\xC0C1",  // dBm 이상
            WS_CHILD | WS_VISIBLE | SS_LEFT,
            160, row1Y + 3, 55, 20, hWnd, nullptr, hInst, nullptr);

        // "자리비움 감지" 는 여기 있었다. 없앴다: keepAliveSec 에 물려 있는데
        // 그 값은 latency 경로에서만 쓰이고, 컴패니언 앱으로 도는 정상 구성은
        // 그 경로를 타지 않는다. 조작해도 아무 일이 안 일어나는 설정을 보여
        // 주는 것은, 없는 것보다 나쁘다 - 안 되는 이유를 여기서 찾게 된다.
        // 값과 코드는 남겨 둔다. 앱 없이 쓰는 구성에서는 실제로 쓰인다.
        // 창에 보이지 않으므로 콤보는 만들지 않는다 (g_hComboAway 는 계속 nullptr).

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
            if (g_hComboAway)
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
        //
        // 결과를 기록한다. 예전에는 조용히 실패했고, 서버가 몇 달간 닿지 않는
        // 동안에도 로그에 아무 흔적이 없었다 - 고장을 알 방법이 없었다.
        //
        // 여기서는 시작만 시킨다. 결과는 WM_ENTERPRISE_SYNC 로 오고 기록도 거기서
        // 한다 (위 "기업 콘텐츠 동기화" 참고). 그때까지는 config 에 저장돼 있던
        // 경로로 뜬다 - 위에서 이미 g_centerImagePath / g_bannerImagePath 에 넣었다.
        if (cfg.enterpriseRegistered && !cfg.orgId.empty()) {
            // config 에 주소/키가 없으면 exe 의 기본값으로 묻는다 (kDefaultSupabaseUrl 주석).
            // 예전에는 셋이 다 config 에 있어야 돌았고, 그래서 등록할 때 기본값을 config.ini 에
            // 적어 넣었다 - 한 번 적힌 값은 exe 의 기본값이 바뀌어도 그 PC 에 남는다.
            std::wstring eurl = cfg.serverUrl.empty() ? kDefaultSupabaseUrl : cfg.serverUrl;
            std::wstring ekey = cfg.anonKey.empty()   ? kDefaultAnonKey     : cfg.anonKey;
            auto* job = new EnterpriseSyncJob{ hWnd, eurl, ekey, cfg.orgId };
            HANDLE hSync = CreateThread(nullptr, 0, EnterpriseSyncThread, job, 0, nullptr);
            if (hSync) {
                CloseHandle(hSync);
            } else {
                delete job;
                DbgEvent(L"enterprise sync: FAILED - could not start the worker thread");
            }
        } else if (cfg.enterpriseRegistered) {
            DbgEvent(L"enterprise sync: skipped - 설정이 비어 있다");
        }

        // Auto-start if config exists.
        // 등록된 폰을 쓰던 경우 btAddress 는 0이라 아래 루프가 아니라 이쪽으로 걸린다.
        if (g_targetAddr == 0 && g_comboPhoneEntry) {
            SendMessageW(g_hCombo, CB_SETCURSEL, 0, 0);
            PostMessage(hWnd, WM_COMMAND, ID_START, 0);
        } else if (g_targetAddr != 0) {
            for (size_t i = 0; i < g_paired.size(); i++) {
                if (g_paired[i].address == g_targetAddr) {
                    SendMessageW(g_hCombo, CB_SETCURSEL, i + (g_comboPhoneEntry ? 1 : 0), 0);
                    PostMessage(hWnd, WM_COMMAND, ID_START, 0);
                    break;
                }
            }
        }
        break;
    }

    case WM_TIMER:
        if (wParam == IDT_UPDATE) { UpdateTick(false); break; }
        if (wParam == IDT_AUTHSAVE) {
            // 못 쓴 계정 값을 다시 쓴다. 실패하면 FlushAuthSave 가 간격을 벌려 다시 건다.
            if (!g_authSave.pending) { KillTimer(hWnd, IDT_AUTHSAVE); break; }
            if (FlushAuthSave()) DbgEvent(L"session: account values saved on retry");
            break;
        }
        if (wParam == IDT_COUNTDOWN && g_monitoring) {
            // 프로버가 잠긴 폰을 찾아내면서 overflow 비트를 새로 배웠으면 저장한다.
            // 다음 실행 때 후보를 훨씬 빨리 좁힌다 (없어도 동작은 한다).
            int learned = g_bleScanner.TakeLearnedOverflowBit();
            if (learned >= 0) {
                AppConfig bcfg; LoadAppConfig(bcfg);
                bcfg.phoneOvfBit = learned;
                SaveAppConfig(bcfg);
            }
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
            // 잠긴 뒤에 원격으로 붙었다면 풀어 준다. 자리를 비웠다가 원격으로
            // 들어오는 것이 흔한 순서인데, 안 풀면 원격 화면이 검은 채로 시작한다.
            // 직접 잠근 것은 건드리지 않는다 - 원격이든 아니든 그 의사가 우선이다.
            if (g_bBlackActive && !g_bManualLock && IsRemoteSession()) {
                DbgEvent(L"원격 세션이 감지되어 잠금을 푼다");
                DeactivateBlackScreen();
            }
            if (g_bBlackActive && g_unlockTimer > 0) {
                g_unlockTimer--;
                if (g_unlockTimer <= 0) DeactivateBlackScreen();
            }
            wchar_t cdl[96];
            if (g_bBlackActive && g_unlockTimer > 0)
                swprintf_s(cdl, L"  \xC7A0\xAE08 - %d\xCD08 \xD6C4 \xD574\xC81C", g_unlockTimer);  // 잠금 - N초 후 해제
            else if (g_bBlackActive && g_bManualLock)
                wcscpy_s(cdl, L"  직접 잠금 - [해제] 필요");
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
        case ID_BTN_REGISTER_PHONE: {
            // 등록하는 방법이 둘이다. 목적이 같으므로 버튼을 늘리지 않고 여기서 고른다.
            //  - 계정: 폰과 PC 가 같은 구글 계정으로 로그인하면 서버가 같은 토큰을 준다.
            //          블루투스도, 앱을 화면에 띄울 필요도 없다.
            //  - 블루투스: 예전 방식. 인터넷이 없어도 되고 서버가 죽어도 된다.
            int how = MessageBoxW(hWnd,
                L"어떻게 등록할까요?\n\n"
                L"[예]  구글 계정으로 등록  (권장)\n"
                L"       아이폰 앱에서도 같은 계정으로 로그인하면 끝납니다.\n"
                L"       폰을 가까이 둘 필요도, 앱을 띄울 필요도 없습니다.\n\n"
                L"[아니오]  블루투스로 직접 등록\n"
                L"       앱을 화면에 띄우고 폰을 PC 가까이 두세요.\n"
                L"       인터넷 없이 됩니다.",
                L"폰 등록", MB_YESNOCANCEL | MB_ICONQUESTION);
            if (how == IDCANCEL) break;
            if (how == IDYES) {
                if (g_loginBusy) {
                    MessageBoxW(hWnd, L"이미 로그인 중입니다.\n브라우저 창을 확인하세요.",
                                L"폰 등록", MB_OK | MB_ICONINFORMATION);
                    break;
                }
                MessageBoxW(hWnd,
                    L"브라우저가 열립니다. 구글 계정으로 로그인하세요.\n\n"
                    L"로그인이 끝나면 브라우저 창을 닫고 여기로 돌아오면 됩니다.",
                    L"폰 등록", MB_OK | MB_ICONINFORMATION);
                g_loginBusy = true;
                EnableWindow(GetDlgItem(hWnd, ID_BTN_REGISTER_PHONE), FALSE);
                // 브라우저에서 보내는 시간이 있어 UI 스레드에서 부르면 창이 멎는다
                CloseHandle(CreateThread(nullptr, 0, LoginThread, nullptr, 0, nullptr));
                break;
            }
            // 폰이 GATT 로 내주는 토큰을 한 번 읽어 저장해 둔다 (ble_ident.h).
            // 앱을 화면에 띄워 두는 것이 조건이다 - 포그라운드 광고에만 이름과
            // 서비스 UUID 가 실려 후보가 모호하지 않다. 잠긴 폰으로 등록하면 남의 폰을 집을 수 있다.
            if (g_monitoring) {
                MessageBoxW(hWnd,
                    L"먼저 중지를 누른 뒤 등록하세요.\n"
                    L"스캔과 연결이 같은 안테나를 나눠 쓰면 연결이 실패합니다.",
                    L"폰 등록", MB_OK | MB_ICONINFORMATION);
                break;
            }
            if (MessageBoxW(hWnd,
                    L"아이폰에서 SSBeacon 앱을 실행해 화면에 띄우세요.\n"
                    L"폰을 PC 가까이 두고, 준비되면 확인을 누르세요.",
                    L"폰 등록", MB_OKCANCEL | MB_ICONINFORMATION) != IDOK) break;
            HCURSOR oldCur = SetCursor(LoadCursor(nullptr, IDC_WAIT));
            std::wstring token, why;
            bool ok = RegisterPhone(6, token, why);
            SetCursor(oldCur);
            DbgEvent(L"register phone: %s", ok ? L"OK" : why.c_str());
            if (ok) {
                AppConfig pcfg; LoadAppConfig(pcfg);
                pcfg.phoneToken = token;
                pcfg.phoneOvfBit = -1;   // 비트는 잠긴 폰을 처음 탐색할 때 배운다
                SaveAppConfig(pcfg);
                // 목록 맨 앞에 "등록된 폰"이 생기도록 다시 채우고 그것을 고른다
                g_targetAddr = 0;
                PopulateCombo();
                std::wstring head = token.substr(0, (std::min)((size_t)8, token.size()));
                MessageBoxW(hWnd,
                    (L"폰을 등록했습니다.\n\n기기 토큰 " + head +
                     L"\n\n앱 화면에 같은 값이 보이는지 확인하세요.\n"
                     L"이제 Phone Link 설정이나 기기 키 없이도 이 폰을 알아봅니다.").c_str(),
                    L"폰 등록", MB_OK | MB_ICONINFORMATION);
            } else {
                MessageBoxW(hWnd,
                    (L"등록하지 못했습니다.\n\n" + why +
                     L"\n\n앱이 화면에 떠 있는지, 폰이 PC 가까이 있는지 확인하세요.").c_str(),
                    L"폰 등록", MB_OK | MB_ICONWARNING);
            }
            break;
        }
        case ID_BTN_IMPORT_IRK: {
            // 레지스트리의 IRK는 SYSTEM만 읽을 수 있어 승격이 필요하다 (irk.h 참고)
            // IRK 는 페어링된 기기에만 있으므로 "등록된 폰" 항목으로는 가져올 수 없다.
            int sel = (int)SendMessageW(g_hCombo, CB_GETCURSEL, 0, 0);
            int pidx = ComboSelToPaired(sel);
            std::wstring name = (pidx >= 0) ? g_paired[pidx].name
                              : (ComboIsPhoneEntry(sel) ? L"" : g_targetName);
            if (name.empty()) {
                MessageBoxW(hWnd, L"목록에서 페어링된 기기를 선택하세요.\n"
                                  L"'등록된 폰'은 페어링이 없어 기기 키를 가져올 수 없습니다.",
                            L"기기 키 가져오기", MB_OK | MB_ICONINFORMATION);
                break;
            }
            HCURSOR oldCur = SetCursor(LoadCursor(nullptr, IDC_WAIT));
            std::wstring msg;
            bool ok = RequestIrkImport(name, msg);
            SetCursor(oldCur);
            DbgEvent(L"IRK import for %s: %s", name.c_str(), ok ? L"OK" : L"failed");
            MessageBoxW(hWnd, msg.c_str(), L"기기 키 가져오기",
                        MB_OK | (ok ? MB_ICONINFORMATION : MB_ICONWARNING));
            break;
        }
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
                    // 이미 등록된 PC 에서는 돌아가는 길을 여기에 적어 둔다. 단추가 하나뿐이라
                    // 적어 두지 않으면 해제할 수 있다는 것을 알 방법이 없다.
                    HWND hStatus2 = CreateWindowExW(0, L"STATIC",
                        ecfg.enterpriseRegistered ? L"해제: 칸을 비우고 누르기" : L"",
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
                            // 붙여 넣은 값에는 앞뒤 공백이나 줄바꿈이 딸려 온다.
                            std::wstring typed = o;
                            auto isSp = [](wchar_t ch) {
                                return ch == L' ' || ch == L'\t' || ch == L'\r' || ch == L'\n';
                            };
                            while (!typed.empty() && isSp(typed.back())) typed.pop_back();
                            while (!typed.empty() && isSp(typed.front())) typed.erase(typed.begin());

                            AppConfig sc;
                            LoadAppConfig(sc);

                            // ---- 돌아가는 길: 빈 칸 + 같은 단추 = 등록 해제 ----
                            // 예전에는 enterpriseRegistered 를 끄는 코드가 어디에도 없었다.
                            // 한 번 눌러 본 개인 사용자는 config.ini 를 손으로 고치기 전에는
                            // 기업 PC 로 남았고, 그 PC 의 업데이트는 없는 관리자의 승인을
                            // 영영 기다렸다.
                            if (typed.empty()) {
                                if (!sc.enterpriseRegistered) {
                                    SetWindowTextW(hs, L"\xC870\xC9C1 ID\xB97C \xC785\xB825\xD558\xC138\xC694.");  // 조직 ID를 입력하세요.
                                    return 0;
                                }
                                if (MessageBoxW(hw2,
                                        L"조직 ID 칸이 비어 있어요.\n\n"
                                        L"이 PC 의 기업 등록을 해제할까요?\n"
                                        L"잠금 화면에서 조직 콘텐츠가 빠지고, 저장된 조직 ID 도 지워져요.",
                                        L"기업 등록 해제",
                                        MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES)
                                    return 0;

                                LoadAppConfig(sc);   // 묻는 동안 다른 저장이 있었을 수 있다
                                sc.enterpriseRegistered = false;
                                sc.orgId.clear();
                                if (IsEnterpriseContentPath(sc.centerImagePath)) sc.centerImagePath.clear();
                                if (IsEnterpriseContentPath(sc.bannerImagePath)) sc.bannerImagePath.clear();
                                // 저장이 먼저다. 못 썼으면 해제된 것이 아니다 - 다음 실행에 다시
                                // 기업 PC 로 뜬다. 화면을 바꾸기 전에 그렇게 말하고 그만둔다.
                                if (!SaveAppConfig(sc)) {
                                    DbgEvent(L"enterprise: unregister NOT saved - nothing changed");
                                    SetWindowTextW(hs, L"설정을 저장하지 못했어요");
                                    return 0;
                                }
                                // 동기화가 넣어 둔 경로만 지운다. 사용자가 고른 그림은 그대로다.
                                bool dropped = false;
                                if (IsEnterpriseContentPath(g_centerImagePath)) {
                                    g_centerImagePath.clear();
                                    SetWindowTextW(g_hLabelCenter, L"(기본)");
                                    dropped = true;
                                }
                                if (IsEnterpriseContentPath(g_bannerImagePath)) {
                                    g_bannerImagePath.clear();
                                    SetWindowTextW(g_hLabelBanner, L"(기본)");
                                    dropped = true;
                                }
                                if (dropped && !g_bBlackActive) FreeBlackScreenImages();
                                DbgEvent(L"enterprise: unregistered by the user");
                                SetWindowTextW(hs, L"등록을 해제했어요");
                                // UpdateInit 은 켤 때 한 번 조직 id 를 받는다 (wWinMain). 그래서
                                // 이번 실행의 업데이트 확인은 아직 그 조직의 승인 목록을 본다.
                                if (UpdateEnabled())
                                    MessageBoxW(hw2,
                                        L"기업 등록을 해제했어요.\n\n"
                                        L"프로그램 업데이트는 SmartScreen 을 다시 켠 뒤부터\n"
                                        L"조직의 승인을 기다리지 않고 받아요.",
                                        L"기업 등록 해제", MB_OK | MB_ICONINFORMATION);
                                return 0;
                            }

                            // ---- 등록 ----
                            // 조직 id 는 URL 에 그대로 들어가는 값이다. uuid 가 아니면 서버에
                            // 묻지도 저장하지도 않는다 (대시보드의 다른 복사 단추가 주는
                            // API URL 을 붙여 넣는 일이 실제로 생긴다).
                            std::wstring org;
                            if (!NormalizeOrgId(typed, org)) {
                                SetWindowTextW(hs, L"36자 조직 ID 가 아니에요");
                                return 0;
                            }

                            // config 에 값이 있으면 그쪽이 이긴다 (kDefaultSupabaseUrl 주석).
                            // 예전에는 여기서 기본값을 다시 적어 넣어 직접 바꿔 둔 서버 주소를
                            // 덮어썼다.
                            std::wstring url = sc.serverUrl.empty() ? kDefaultSupabaseUrl : sc.serverUrl;
                            std::wstring key = sc.anonKey.empty()   ? kDefaultAnonKey     : sc.anonKey;

                            SetWindowTextW(hs, L"\xC5F0\xACB0 \xC911...");  // 연결 중...
                            UpdateWindow(hw2);

                            // 예전에는 서버에 묻기 **전에** 저장했고 실패해도 되돌리지 않았다.
                            // 오타 하나로 없는 조직에 등록된 채 남았고, 그 전에 맞게 들어 있던
                            // 조직 id 도 같이 사라졌다. 지금은 확인이 끝난 뒤에만 저장한다.
                            //
                            // -1 (알 수 없다) 은 계속 간다: org_exists 가 아직 서버에 없을 수
                            // 있고, 서버에 닿지 못한 것이라면 바로 아래 동기화가 가려 준다.
                            int exists = CheckOrgExists(url, key, org);
                            if (exists == 0) {
                                DbgEvent(L"enterprise: register refused - no such org (%s)", org.c_str());
                                SetWindowTextW(hs, L"그런 조직이 없어요");
                                return 0;
                            }

                            std::wstring cp, bp;
                            EnterpriseSync outcome = SyncEnterpriseContentEx(url, key, org, cp, bp);
                            if (outcome == EnterpriseSync::RequestFailed) {
                                DbgEvent(L"enterprise: register failed - server not reached (%s)", org.c_str());
                                SetWindowTextW(hs, L"서버에 닿지 못했어요");
                                return 0;
                            }

                            // 조직이 있는지 확인하지 못했고 (org_exists 가 서버에 아직 없거나
                            // 그 요청만 실패했다) 받을 콘텐츠도 없다면, 이 id 가 맞다는 근거가
                            // 하나도 없다. 그 상태로 이미 등록된 다른 조직을 덮어쓰면 오타
                            // 하나로 맞는 id 가 사라지고 화면의 콘텐츠도 빠진다. 묻고 나서 한다.
                            if (exists < 0 && outcome == EnterpriseSync::NoContent) {
                                AppConfig cur;
                                LoadAppConfig(cur);
                                std::wstring curOrg;
                                if (cur.enterpriseRegistered && NormalizeOrgId(cur.orgId, curOrg) &&
                                    curOrg != org &&
                                    MessageBoxW(hw2,
                                        L"이 ID 의 조직이 실제로 있는지 서버에서 확인하지 못했고, 받을 콘텐츠도 없어요.\n\n"
                                        L"지금 등록된 조직을 이 ID 로 바꿀까요?",
                                        L"기업 등록", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) != IDYES) {
                                    SetWindowTextW(hs, L"바꾸지 않았어요");
                                    return 0;
                                }
                            }

                            AppConfig nc;
                            LoadAppConfig(nc);       // 동기화하는 동안 다른 저장이 있었을 수 있다
                            const bool orgChanged = !nc.enterpriseRegistered ||
                                                    _wcsicmp(nc.orgId.c_str(), org.c_str()) != 0;
                            nc.orgId = org;
                            nc.enterpriseRegistered = true;
                            // 못 썼으면 등록된 것이 아니다 - 다음 실행에 남지 않는다.
                            // "연결 완료" 라고 말하기 전에 그만둔다.
                            if (!SaveAppConfig(nc)) {
                                DbgEvent(L"enterprise: register NOT saved (%s)", org.c_str());
                                SetWindowTextW(hs, L"설정을 저장하지 못했어요");
                                return 0;
                            }
                            SetWindowTextW(ho, org.c_str());   // 저장된 그대로 (다듬은 값) 보여 준다

                            ApplyEnterpriseSync(outcome, cp, bp);
                            // 받은 것이 있는데 그 자리가 다른 경로면, 사용자가 고른 그림이 남은 것이다.
                            const bool keptOwn = (!cp.empty() && g_centerImagePath != cp) ||
                                                 (!bp.empty() && g_bannerImagePath != bp);
                            const bool found = (outcome == EnterpriseSync::Ready);
                            DbgEvent(L"enterprise: registered org=%s (org_exists=%d, center=%d banner=%d)",
                                     org.c_str(), exists, cp.empty() ? 0 : 1, bp.empty() ? 0 : 1);

                            SetWindowTextW(hs, found ? L"연결 완료 - 콘텐츠 받음"
                                                     : L"연결 완료 - 콘텐츠 없음");

                            std::wstring more;
                            if (!found) {
                                more += L"이 조직에 송출 중인 콘텐츠가 아직 없어요.\n"
                                        L"대시보드에서 올리고 [송출 중] 으로 바꾼 뒤 이 단추를 다시 누르세요.\n\n";
                                if (exists < 0)
                                    more += L"조직이 실제로 있는지는 서버에서 확인하지 못했어요.\n"
                                            L"ID 를 잘못 넣었다면 콘텐츠가 오지 않아요.\n\n";
                            }
                            if (keptOwn)
                                more += L"직접 고른 그림이 있는 자리는 그 그림을 그대로 써요.\n\n";
                            // UpdateInit 은 켤 때 한 번 조직 id 를 받는다 (wWinMain). 이번
                            // 실행의 업데이트 확인은 등록하기 전 그대로다.
                            if (orgChanged && UpdateEnabled())
                                more += L"프로그램 업데이트는 SmartScreen 을 다시 켠 뒤부터\n"
                                        L"이 조직 관리자의 승인을 따라요.\n";
                            if (!more.empty())
                                MessageBoxW(hw2, (L"연결 완료.\n\n" + more).c_str(),
                                            L"기업 등록", MB_OK | MB_ICONINFORMATION);
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
    case WM_UPDATE_STATE:
        UpdateTick(true);
        break;

    case WM_ENTERPRISE_SYNC: {
        auto* r = (EnterpriseSyncResult*)lParam;
        // 도는 사이에 등록이 바뀌었으면 (해제했거나 다른 조직으로 다시 등록) 이
        // 결과는 지금의 조직 것이 아니다. 반영하면 방금 비운 경로를 되살린다.
        AppConfig c;
        bool current = LoadAppConfig(c) && c.enterpriseRegistered &&
                       _wcsicmp(c.orgId.c_str(), r->org.c_str()) == 0;
        if (!current) {
            DbgEvent(L"enterprise sync: result dropped - registration changed while it ran");
        } else if (r->outcome == EnterpriseSync::RequestFailed) {
            // 아무것도 건드리지 않는다. 오프라인인 PC 는 갖고 있던 것을 계속 보여 준다.
            DbgEvent(L"enterprise sync: FAILED (org=%.40s) - keeping what this PC already shows",
                     r->org.c_str());
        } else {
            bool changed = ApplyEnterpriseSync(r->outcome, r->center, r->banner);
            DbgEvent(L"enterprise sync: %s (center=%d banner=%d)%s",
                     r->outcome == EnterpriseSync::Ready ? L"OK" : L"no active content",
                     r->center.empty() ? 0 : 1, r->banner.empty() ? 0 : 1,
                     changed ? L" - image paths updated" : L"");
        }
        delete r;
        break;
    }

    case WM_GATT_SEEN: {
        // 스캔 스레드 대신 여기서 쓴다 (WM_GATT_SEEN 주석). 못 써도 다시 걸지 않는다 -
        // 다음에 감시를 시작할 때 g_gattSeen 이 config 에서 다시 읽히고, 앱이 붙으면
        // 이 메시지가 또 온다.
        AppConfig sc; LoadAppConfig(sc);
        if (!sc.gattSeen) {
            sc.gattSeen = true;
            if (!SaveAppConfig(sc))
                DbgEvent(L"companion app seen - gattSeen NOT saved (it will be set again on a later run)");
        }
        break;
    }

    case WM_SESSION_ROTATED: {
        // 설정 쓰기는 이 스레드에서만 한다 (OnSessionRotated 주석 참고).
        std::wstring sealed;
        {
            std::lock_guard<std::mutex> lock(g_rotatedMx);
            sealed.swap(g_rotatedSealed);
        }
        if (!sealed.empty()) {
            // 아직 못 쓴 로그인 결과가 있으면 같이 나간다 (g_authSave 의 다른 칸은 그대로 둔다).
            g_authSave.refresh = sealed;
            g_authSave.pending = true;
            // 예전에는 결과를 보지 않고 "rotated, saved" 라고 적었다. 못 썼는데도
            // 로그는 매번 성공이었다.
            if (FlushAuthSave())
                DbgEvent(L"session: refresh token rotated, saved");
            else
                DbgEvent(L"session: refresh token rotated but NOT saved - will retry "
                         L"(if the app exits first, the next start may need a new login)");
        }
        break;
    }
    case WM_LOGIN_RESULT: {
        auto* r = (LoginResult*)lParam;
        g_loginBusy = false;
        EnableWindow(GetDlgItem(hWnd, ID_BTN_REGISTER_PHONE), TRUE);

        if (!r->ok) {
            DbgEvent(L"google login failed: %s", r->err.c_str());
            MessageBoxW(hWnd,
                (L"로그인하지 못했습니다.\n\n" + r->err).c_str(),
                L"폰 등록", MB_OK | MB_ICONWARNING);
            delete r; break;
        }

        // 봉인(DPAPI)이 실패했으면 r->refresh 가 비어 있다 (LoginThread 의 ProtectSecret).
        // 예전에는 그 빈 값을 authRefresh 에 그대로 써서 저장돼 있던 토큰까지 지웠고,
        // 로그에는 아무것도 남지 않았다. 지금은 덮지 않는다 (FlushAuthSave).
        if (r->refresh.empty())
            DbgEvent(L"google login: could not seal the refresh token (DPAPI) - "
                     L"this login will not survive a restart");

        // 새 로그인이 앞의 것을 대신한다. 못 쓴 채 남아 있던 예전 세션의 값은 버린다.
        g_authSave = AuthSave{};
        g_authSave.pending    = true;
        g_authSave.login      = true;
        g_authSave.refresh    = r->refresh;
        g_authSave.userId     = r->userId;
        g_authSave.email      = r->email;
        g_authSave.phoneToken = r->phoneToken;
        bool saved = FlushAuthSave();
        DbgEvent(L"google login: %s (phone token: %s)%s", r->email.c_str(),
                 r->phoneToken.empty() ? L"none yet" : L"received",
                 saved ? L"" : L" - NOT saved to config.ini yet, will retry");

        // 돌고 있는 스캐너에도 알려 준다. 계정 등록은 블루투스 등록과 달리
        // 감시를 멈추지 않고 할 수 있어서 StartMon 을 다시 지나지 않는다 -
        // 여기서 알리지 않으면 "등록했습니다" 라고 말한 뒤에도 config 에만
        // 토큰이 있고, 스캐너는 끝까지 폰을 확인하지 못한다.
        if (!r->phoneToken.empty()) {
            g_hasToken = true;
            // 비트는 -1: FlushAuthSave 가 config 에 쓰는 값과 같다
            g_bleScanner.SetIdentity(r->phoneToken, -1,
                                     g_nearRssiThreshold - 10);
        }

        if (!r->err.empty()) {
            // 로그인은 됐는데 토큰 조회가 실패했다. 다시 로그인시킬 일은 아니다.
            MessageBoxW(hWnd,
                (L"" + r->email + L" 로 로그인했습니다.\n\n"
                 L"다만 폰 정보를 가져오지 못했습니다:\n" + r->err +
                 L"\n\n잠시 뒤 다시 시도하세요.").c_str(),
                L"폰 등록", MB_OK | MB_ICONWARNING);
        } else if (r->phoneToken.empty()) {
            // 오류가 아니다. 순서상 폰이 아직 안 올라온 것뿐이라 그렇게 말해 준다.
            MessageBoxW(hWnd,
                (L"" + r->email + L" 로 로그인했습니다.\n\n"
                 L"아직 이 계정에 등록된 폰이 없습니다.\n"
                 L"아이폰에서 SSBeacon 앱을 열고 같은 계정으로 로그인한 뒤,\n"
                 L"여기서 다시 [폰 등록] 을 누르세요.").c_str(),
                L"폰 등록", MB_OK | MB_ICONINFORMATION);
        } else {
            g_targetAddr = 0;
            PopulateCombo();
            std::wstring head = r->phoneToken.substr(
                0, (std::min)((size_t)8, r->phoneToken.size()));
            MessageBoxW(hWnd,
                (L"폰을 등록했습니다.\n\n계정 " + r->email +
                 L"\n기기 토큰 " + head +
                 L"\n\n이 계정으로 로그인하면 다른 PC 에서도 같은 폰을 알아봅니다.").c_str(),
                L"폰 등록", MB_OK | MB_ICONINFORMATION);
        }
        delete r; break;
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
        // 못 쓴 계정 값이 남아 있으면 나가기 전에 한 번 더 써 본다. 타이머는 창과
        // 함께 사라지므로 이것이 마지막 기회다.
        if (g_authSave.pending && !FlushAuthSave())
            DbgEvent(L"session: account values still NOT saved at exit - the next start may need a new login");
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
// 간단 화면
// ---------------------------------------------------------------------------
// 기본으로 열리는 창. 지금까지의 설정 창은 [고급 설정] 으로 물러난다.
//
// 그 창은 dBm 과 이벤트 표를 그대로 보여주는데, 그건 이 프로그램을 만든
// 사람에게나 읽히는 화면이다. 쓰는 사람이 정해야 하는 것은 사실 셋뿐이다:
// 내 폰이 무엇이고, 얼마나 멀어지면 가리고, 몇 초 뒤에 가리는가.
//
// 명령은 대부분 고급 창으로 넘긴다. 폰 등록이나 그림 고르기를 여기서 다시
// 구현하면 두 벌이 되고, 한쪽만 고쳐지는 날이 온다.
// 클립보드 공유 한 칸이 늘어 654 -> 750 이 됐다. 이 창은 세로로 자라기만 해
// 왔고, 다음에 또 늘릴 일이 생기면 그때는 접기나 스크롤을 넣어야 한다 -
// 1200 짜리 화면에서도 작업 표시줄까지 치면 여유가 얼마 남지 않았다.
static constexpr int SW_W = 430, SW_H = 750;
// 업데이트 띠. 보일 때만 창이 이만큼 자란다 - 상시로 늘릴 자리가 없다 (위 주석).
static constexpr int SW_UPD_H = 100;
static constexpr int IDS_ADVANCED   = 601;
static constexpr int IDS_PHONE      = 602;
static constexpr int IDS_DIST       = 603;   // 트랙바
static constexpr int IDS_MEASURE    = 604;
static constexpr int IDS_IDLE_BASE  = 610;   // 610..613 = 바로/15초/30초/1분
static constexpr int IDS_IMAGE      = 620;
static constexpr int IDS_LOCKNOW    = 621;
static constexpr int IDS_GUARD      = 622;
static constexpr int IDS_CLIP       = 623;   // 클립보드 공유 켜기/끄기
static constexpr int IDS_UPD_CHECK  = 624;   // 머리의 "버전 x.y.z · 업데이트 확인"
static constexpr int IDS_UPD_APPLY  = 625;   // 띠의 [업데이트] / [다시 시도]
static constexpr int IDS_UPD_LATER  = 626;   // 띠의 [나중에]
static constexpr int IDT_SIMPLE     = 30;

static HWND g_hSimplePhone = nullptr, g_hSimpleDist = nullptr;
static HWND g_hSimpleIdle[4] = {};
static HWND g_hSimpleMeasure = nullptr;
static HWND g_hSimpleClipMsg = nullptr;
static HWND g_hSimpleUpdMsg = nullptr;

// 몇 초 뒤에 가릴지. 고급 창의 kIdleValues 와 같은 값이어야 한다.
static const int kSimpleIdle[4] = { 0, 15, 30, 60 };
static const wchar_t* kSimpleIdleLabel[4] = { L"바로", L"15초", L"30초", L"1분" };

// 거리 3단계.
//
// 절대 dBm 으로 못 박을 수 없다. 같은 "보통"이 자리와 어댑터에 따라 10~20 dB
// 씩 달라지기 때문이다 (docs/PROXIMITY.md). 그래서 재보기로 기준을 한 번
// 잡고, 3단계는 그 기준에서의 오프셋으로 둔다. 재보기 전에는 대략값을 쓰되
// 화면에서 재보기를 권한다.
static const int kDistOffset[3] = { +6, 0, -6 };   // 가까이 / 보통 / 멀리
static constexpr int kDistFallbackBase = -64;

// 윈도우 11 빠른 설정 패널의 생김새를 따른다. 기본 Win32 버튼은 회색 입체
// 테두리라 옆에 두면 20년쯤 낡아 보인다. 둥근 사각형에 평면 색으로 직접 그린다.
static constexpr COLORREF kPanelBg   = RGB(0xF3, 0xF3, 0xF3);
static constexpr COLORREF kTileBg    = RGB(0xFB, 0xFB, 0xFB);
static constexpr COLORREF kTileEdge  = RGB(0xE1, 0xE1, 0xE1);
static constexpr COLORREF kTilePress = RGB(0xEA, 0xEA, 0xEA);
static constexpr COLORREF kAccent    = RGB(0x00, 0x67, 0xC0);
static constexpr COLORREF kAccentDn  = RGB(0x00, 0x55, 0x9E);
static constexpr COLORREF kInk       = RGB(0x1A, 0x1A, 0x1A);
static constexpr COLORREF kInkSoft   = RGB(0x5D, 0x5D, 0x5D);
static HBRUSH g_hPanelBrush = nullptr;

// 둥근 타일 하나. 테두리 없이 칠하면 흰 타일이 흰 배경에 묻히므로 항상 그린다.
static void DrawTile(HDC hdc, RECT rc, COLORREF fill, COLORREF edge,
                     COLORREF ink, const wchar_t* text, HFONT font, int radius = 14) {
    HBRUSH br = CreateSolidBrush(fill);
    HPEN   pn = CreatePen(PS_SOLID, 1, edge);
    HBRUSH ob = (HBRUSH)SelectObject(hdc, br);
    HPEN   op = (HPEN)SelectObject(hdc, pn);
    RoundRect(hdc, rc.left, rc.top, rc.right, rc.bottom, radius, radius);
    SelectObject(hdc, ob); SelectObject(hdc, op);
    DeleteObject(br); DeleteObject(pn);

    if (text && *text) {
        HFONT of = (HFONT)SelectObject(hdc, font ? font : g_hFont);
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, ink);
        DrawTextW(hdc, text, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
        SelectObject(hdc, of);
    }
}

static int SimpleBaseRssi() {
    AppConfig c;
    LoadAppConfig(c);
    return c.measuredBaseRssi != 0 ? c.measuredBaseRssi : kDistFallbackBase;
}

// 지금 임계값에 가장 가까운 단계를 고른다. 고급 창에서 dBm 을 직접 고쳤을 때도
// 슬라이더가 엉뚱한 곳을 가리키지 않게 하려는 것이다.
static int SimpleDistStep() {
    int base = SimpleBaseRssi(), best = 1, bestD = 9999;
    for (int i = 0; i < 3; i++) {
        int d = abs((base + kDistOffset[i]) - g_nearRssiThreshold);
        if (d < bestD) { bestD = d; best = i; }
    }
    return best;
}

static void SimpleApplyDist(int step) {
    if (step < 0 || step > 2) return;
    g_nearRssiThreshold = SimpleBaseRssi() + kDistOffset[step];
    g_gattRssiThreshold = g_nearRssiThreshold;   // 두 경로를 따로 물어볼 화면이 아니다
    AppConfig c; LoadAppConfig(c);
    c.nearRssiThreshold = g_nearRssiThreshold;
    c.gattRssiThreshold = g_gattRssiThreshold;
    SaveAppConfig(c);
    DbgEvent(L"간단 화면: 거리 %d단계 -> %d dBm", step + 1, g_nearRssiThreshold);
}

// 업데이트 상태를 보고 할 일을 한다 (UI 스레드). 1분 타이머와 WM_UPDATE_STATE 가
// 부른다. 준비된 것이 있어도 화면을 가리는 중이면 적용하지 않는다 - 다시 시작하는
// 사이에 검은 화면이 사라지기 때문이다 (update.h 머리말).
static void UpdateTick(bool fromNotify) {
    ULONGLONG now = GetTickCount64();
    if (!fromNotify && g_updLastCheck && now - g_updLastCheck >= kUpdateEveryMs && !UpdateBusy()) {
        g_updLastCheck = now;
        UpdateCheckAsync(false);
    }
    UpdateStatus us = UpdateGetStatus();
    // 개인 PC: 설정이 끝난 PC 에서 간단 창은 숨겨져 있다. 띠가 거기에만 뜨면 아무도
    // 못 본다. 새 버전마다 한 번, 초점을 빼앗지 않고 창을 띄운다. 기업 PC 는 묻지
    // 않고 적용하므로 띄울 이유가 없다.
    // 지난번 적용 실패(failed-<버전>.txt)도 마찬가지다 - 그 기록은 대화상자를 대신하는
    // 것이라, 숨은 창에만 쓰면 아무도 못 본다. 이건 기업 PC 도 봐야 한다.
    static std::wstring shownFor;
    bool wantShow = (us.phase == UpdatePhase::Available && !us.autoApply) ||
                    (us.phase == UpdatePhase::Failed && us.fromMarker);
    std::wstring showKey = us.version + (us.phase == UpdatePhase::Failed ? L"|F" : L"|A");
    if (wantShow && !us.dismissed && g_hSimple && shownFor != showKey &&
        !g_bBlackActive && !g_measuring) {
        shownFor = showKey;
        // 최소화된 창도 '보이는' 창이다 - 복원까지 해야 한다 (SW_SHOWNOACTIVATE 가 복원한다)
        if (!IsWindowVisible(g_hSimple) || IsIconic(g_hSimple)) ShowWindow(g_hSimple, SW_SHOWNOACTIVATE);
    }
    if (us.phase == UpdatePhase::Ready) {
        if (g_bBlackActive || g_measuring || g_loginBusy) {
            // 나중에 다시 - 타이머가 1분마다 여기로 온다
        } else {
            std::wstring err;
            if (UpdateLaunchApplier(err)) {
                DbgEvent(L"update: exiting to apply %s", us.version.c_str());
                // 오버레이의 [종료] 와 같은 길로 나간다 - 그게 유일한 정상 종료 경로다.
                if (g_hOverlay) SendMessageW(g_hOverlay, WM_COMMAND, ID_OVL_EXIT, 0);
                else { if (g_monitoring) StopMon(); DestroyWindow(g_hWnd); }
                return;
            }
            DbgEvent(L"update: could not launch applier - %s", err.c_str());
        }
    }
    SimpleRefresh();
}

static void SimpleRefresh() {
    if (!g_hSimple) return;

    AppConfig c; LoadAppConfig(c);
    wchar_t buf[192];
    if (!c.phoneToken.empty()) {
        std::wstring head = c.phoneToken.substr(0, (std::min)((size_t)8, c.phoneToken.size()));
        // 메일 주소는 로그인 응답에서 온 값이 config.ini 에 그대로 들어간 것이다.
        // swprintf_s 는 넘치면 프로세스를 끝내는데, 이 함수는 1초마다 그리고 켤 때
        // 메시지 루프보다 먼저 불린다 - 183자 넘는 주소 하나로 앱이 다시는 안 뜬다.
        if (!c.authEmail.empty())
            _snwprintf_s(buf, _countof(buf), _TRUNCATE, L"%s 계정으로 등록됨", c.authEmail.c_str());
        else
            _snwprintf_s(buf, _countof(buf), _TRUNCATE, L"등록됨 (토큰 %s)", head.c_str());
    } else {
        wcscpy_s(buf, L"아직 등록하지 않았어요");
    }
    SetWindowTextW(g_hSimplePhone, buf);
    // 등록하기 전에 "바꾸기" 라고 쓰여 있으면 무엇을 누르라는 건지 알 수 없다
    HWND phoneBtn = GetDlgItem(g_hSimple, IDS_PHONE);
    if (phoneBtn) SetWindowTextW(phoneBtn, c.phoneToken.empty() ? L"등록하기" : L"바꾸기");

    SendMessageW(g_hSimpleDist, TBM_SETPOS, TRUE, SimpleDistStep());

    // 재본 적이 없으면 그렇다고 말해 준다. 3단계가 근거 없는 값이라는 뜻이다.
    SetWindowTextW(g_hSimpleMeasure,
        c.measuredBaseRssi != 0 ? L"내 자리에 맞게 다시 재기" : L"내 자리에 맞게 재보기  (아직 안 했어요)");

    // 클립보드 공유 상태 한 줄. 서버를 타는 기능이라 "켜 뒀는데 안 넘어간다" 가
    // 가능하고, 그때 볼 것이 여기 말고는 events.log 뿐이다.
    if (g_hSimpleClipMsg) {
        ClipSyncStatus cs = ClipSyncGetStatus();
        wchar_t cb[256];
        if (!cs.running) {
            wcscpy_s(cb, SessionHasAccount() ? L"꺼져 있어요"
                                             : L"계정으로 로그인하면 쓸 수 있어요");
        } else if (cs.lastMsg.empty()) {
            swprintf_s(cb, L"기다리는 중  ·  보냄 %d / 받음 %d", cs.sent, cs.received);
        } else {
            // lastMsg 에는 서버가 준 오류 문구(세션 갱신 실패)가 그대로 실릴 수 있다.
            // 아래 업데이트 띠와 같은 이유로 _TRUNCATE 로 쓴다 - 이 줄만 빠져 있었다.
            _snwprintf_s(cb, _countof(cb), _TRUNCATE, L"%s%s  ·  보냄 %d / 받음 %d",
                         cs.lastOk ? L"" : L"안 됨: ", cs.lastMsg.c_str(),
                         cs.sent, cs.received);
        }
        SetWindowTextW(g_hSimpleClipMsg, cb);
    }

    // 프로그램 업데이트 (client/update.h). 머리의 버전 단추와, 필요할 때만 나타나는
    // 아래 띠. 창은 띠가 보일 때만 SW_UPD_H 만큼 자란다.
    {
        UpdateStatus us = UpdateGetStatus();
        // swprintf_s 는 넘치면 잘라 쓰지 않고 프로세스를 끝낸다. 메모와 오류 문구는
        // 서버에서 오는 값이라 길이를 믿을 수 없다 - 여기 전부 _TRUNCATE 로 쓴다.
        wchar_t ub[384];
        ULONGLONG now = GetTickCount64();
        if (!UpdateEnabled())
            wcscpy_s(ub, L"버전 " SS_VERSION_STR L" · 자동 업데이트 꺼짐");
        else if (us.phase == UpdatePhase::Checking)
            wcscpy_s(ub, L"업데이트 확인 중…");
        else if (us.phase == UpdatePhase::UpToDate && now - us.checkedTick < 6000)
            wcscpy_s(ub, L"최신 버전이에요 · " SS_VERSION_STR);
        else
            wcscpy_s(ub, L"버전 " SS_VERSION_STR L" · 업데이트 확인");
        if (HWND h = GetDlgItem(g_hSimple, IDS_UPD_CHECK)) {
            wchar_t cur[384] = L""; GetWindowTextW(h, cur, _countof(cur));
            if (wcscmp(cur, ub) != 0) { SetWindowTextW(h, ub); InvalidateRect(h, nullptr, TRUE); }
        }

        bool show = false, showApply = false, showLater = false;
        const wchar_t* applyLabel = L"업데이트";
        std::wstring note = us.notes.substr(0, us.notes.find_first_of(L"\r\n"));
        // 글 칸이 세 줄(한글 약 78자)이다. 그 안에 들어갈 만큼만 - 넘치면 잘려 보이지도 않는다.
        // 메모는 첫 줄("새 버전 …") 뒤 두 줄. 기록에서 온 문구는 우리 것이라(영문이 섞여 짧게
        // 그려진다) 조금 길어도 되고, 서버 오류 문구는 앞에 "업데이트 실패: " 가 붙는다.
        if (note.size() > 48) note = note.substr(0, 48) + L"…";
        std::wstring msg = us.msg;
        size_t cap = us.fromMarker ? 96 : 68;
        if (msg.size() > cap) msg = msg.substr(0, cap) + L"…";
        switch (us.phase) {
        case UpdatePhase::Available:
            show = !us.dismissed;
            if (us.autoApply) _snwprintf_s(ub, _countof(ub), _TRUNCATE, L"관리자가 승인한 %s 를 받아요", us.version.c_str());
            else {
                _snwprintf_s(ub, _countof(ub), _TRUNCATE, L"새 버전 %s 이 있어요%s%s", us.version.c_str(),
                             note.empty() ? L"" : L"\n", note.c_str());
                showApply = showLater = true;
            }
            break;
        case UpdatePhase::Pending:
            show = !us.dismissed; showLater = true;
            _snwprintf_s(ub, _countof(ub), _TRUNCATE, L"새 버전 %s 이 있어요 · 관리자 승인을 기다려요", us.version.c_str());
            break;
        case UpdatePhase::Downloading:
            show = true;
            _snwprintf_s(ub, _countof(ub), _TRUNCATE, L"%s 내려받는 중 · %d%%", us.version.c_str(), us.progressPct);
            break;
        case UpdatePhase::Ready:
            show = true;
            _snwprintf_s(ub, _countof(ub), _TRUNCATE,
                         (g_bBlackActive || g_measuring || g_loginBusy) ? L"%s 준비됨 · 화면이 풀리면 적용해요"
                                                                        : L"%s 준비됨 · 곧 다시 시작해요",
                         us.version.c_str());
            break;
        case UpdatePhase::Applying:
            show = true; wcscpy_s(ub, L"다시 시작하는 중…");
            break;
        case UpdatePhase::Failed:
            show = !us.dismissed; showApply = showLater = true; applyLabel = L"다시 시도";
            // 기록에서 온 문구는 이미 "지난번 적용 실패: " 로 시작한다
            _snwprintf_s(ub, _countof(ub), _TRUNCATE, us.fromMarker ? L"%s" : L"업데이트 실패: %s", msg.c_str());
            break;
        default: break;
        }
        if (g_hSimpleUpdMsg) {
            wchar_t cur[384] = L""; GetWindowTextW(g_hSimpleUpdMsg, cur, _countof(cur));
            if (wcscmp(cur, show ? ub : L"") != 0) SetWindowTextW(g_hSimpleUpdMsg, show ? ub : L"");
            ShowWindow(g_hSimpleUpdMsg, show ? SW_SHOW : SW_HIDE);
        }
        if (HWND ha = GetDlgItem(g_hSimple, IDS_UPD_APPLY)) {
            wchar_t cur[64] = L""; GetWindowTextW(ha, cur, _countof(cur));
            if (wcscmp(cur, applyLabel) != 0) SetWindowTextW(ha, applyLabel);   // 매초 다시 그리지 않게
            ShowWindow(ha, (show && showApply) ? SW_SHOW : SW_HIDE);
        }
        if (HWND hl = GetDlgItem(g_hSimple, IDS_UPD_LATER))
            ShowWindow(hl, (show && showLater) ? SW_SHOW : SW_HIDE);

        // 최소화된 창의 크기는 만지지 않는다 - 복원될 때 이상한 크기가 된다.
        if (!IsIconic(g_hSimple)) {
            RECT wr; GetWindowRect(g_hSimple, &wr);
            int wantH = SW_H + (show ? SW_UPD_H : 0);
            if (wr.bottom - wr.top != wantH)
                SetWindowPos(g_hSimple, nullptr, 0, 0, SW_W, wantH,
                             SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }

    HWND guard = GetDlgItem(g_hSimple, IDS_GUARD);
    if (guard) InvalidateRect(guard, nullptr, TRUE);
    HWND clip = GetDlgItem(g_hSimple, IDS_CLIP);
    if (clip) InvalidateRect(clip, nullptr, TRUE);
    for (int i = 0; i < 4; i++)
        if (g_hSimpleIdle[i]) InvalidateRect(g_hSimpleIdle[i], nullptr, TRUE);
    InvalidateRect(g_hSimple, nullptr, FALSE);
}

// ---------------------------------------------------------------------------
// 재보기 마법사
// ---------------------------------------------------------------------------
// 거리 3단계가 근거를 갖게 만드는 곳이다. 같은 "보통"이 자리와 어댑터에 따라
// 10~20 dB 달라져서, 재보지 않으면 3단계는 그냥 임의의 숫자다.
//
// 재는 김에 어댑터도 본다. 값싼 동글 중에 신호 세기를 제대로 내주지 않는 것이
// 있는데, 드라이버는 멀쩡하다고 보고하므로 (docs/PROXIMITY.md 의 어댑터 표:
// BARROT 두 종이 지원한다고 보고하고 동작하지 않았다) 실제로 재 보는 것
// 말고는 확인할 방법이 없다. 여기서 안 걸러지면 사용자는 "왜 안 잠기지"를
// 영영 알 수 없다.
static constexpr int WZ_W = 440, WZ_H = 330;
static constexpr int IDW_NEXT = 701, IDW_CANCEL = 702;
static constexpr int IDT_WIZ = 31;

// 폰을 들고 나가게 하면 2·3단계 안내를 읽을 사람이 화면 앞에 없다. 그래서
// 폰만 두고 돌아오게 하고, 다 왔는지는 버튼으로 받는다 - 걸어갔다 오는 시간을
// 초로 못박으면 자리가 먼 사람에게는 모자라고 가까운 사람은 기다리기만 한다.
//
// 놓아둔 폰은 몸에 지닌 폰보다 세게 잡힌다. 그래도 임계값은 착석 구간의
// 최저값으로 정해지므로 값이 헐거워지지는 않고, 겹침 판정만 엄해진다.
static constexpr int kWzSeated = 60, kWzAway = 45;

static HWND g_hWiz = nullptr, g_hWizProg = nullptr, g_hWizNext = nullptr;
static int  g_wzPhase = 0;      // 0 안내 / 1 착석 / 2 이동 / 3 비움 / 4 결과
static int  g_wzLeft = 0;
static std::vector<int> g_wzSeated, g_wzAway;
static ULONGLONG g_wzLastTick = 0;
static std::wstring g_wzTitle, g_wzBody;
static int  g_wzBase = 0;
static bool g_wzOk = false;

static void WzRange(const std::vector<int>& v, int& lo, int& hi) {
    lo = 999; hi = -999;
    for (int x : v) { lo = (std::min)(lo, x); hi = (std::max)(hi, x); }
}

// 새 패킷이 왔을 때만 한 번 센다. 같은 값을 반복해서 담으면 표본이 부풀어
// 어댑터가 멀쩡한 것처럼 보인다 - 바로 그걸 찾으려는 참인데.
static void WzCollect(std::vector<int>* into) {
    ULONGLONG tick; int rssi;
    if (g_bleGatt.IsHealthy() && g_bleGatt.LastReportTick() != 0) {
        tick = g_bleGatt.LastReportTick(); rssi = g_bleGatt.GetRawRssi();
    } else {
        tick = g_bleScanner.LastReceivedTick(); rssi = g_bleScanner.GetRawRssi();
    }
    if (tick == 0 || tick == g_wzLastTick) return;
    g_wzLastTick = tick;
    if (rssi <= -100 || rssi >= 0) return;   // 측정값이 아니라 표식이다
    if (into) into->push_back(rssi);
}

static void WzJudge() {
    int sLo, sHi, aLo, aHi;
    WzRange(g_wzSeated, sLo, sHi);
    WzRange(g_wzAway, aLo, aHi);
    int sn = (int)g_wzSeated.size(), an = (int)g_wzAway.size();
    g_wzOk = false;
    wchar_t buf[512];

    if (sn < 15 || an < 8) {
        g_wzTitle = L"신호를 거의 못 받았어요";
        swprintf_s(buf,
            L"앉아 있을 때 %d번, 비웠을 때 %d번밖에 못 받았어요.\n\n"
            L"폰에서 SSBeacon 앱이 켜져 있는지, 그리고 이 컴퓨터의 블루투스가 "
            L"켜져 있는지 확인해 주세요.", sn, an);
        g_wzBody = buf;
        DbgEvent(L"재보기: 표본 부족 (착석 %d, 비움 %d)", sn, an);
        return;
    }

    // 값이 전혀 흔들리지 않으면 재고 있는 게 아니다. 진짜 무선 신호는 아무도
    // 움직이지 않아도 1분이면 몇 dB 는 흔들린다.
    if ((sHi - sLo) <= 1) {
        g_wzTitle = L"이 블루투스 장치는 세기를 못 재요";
        swprintf_s(buf,
            L"1분 동안 %d번을 받았는데 값이 %d dBm 에서 거의 움직이지 않았어요.\n\n"
            L"진짜로 재는 장치라면 가만히 있어도 값이 몇 칸은 흔들립니다. "
            L"이 장치는 신호 세기를 흉내만 내고 있어서 거리로 쓸 수 없어요.\n\n"
            L"다른 블루투스 동글로 바꾸는 게 좋습니다.", sn, sLo);
        g_wzBody = buf;
        DbgEvent(L"재보기: 어댑터가 세기를 안 낸다 (착석 %d개, %d..%d dBm)", sn, sLo, sHi);
        return;
    }

    // 앉았을 때와 비웠을 때가 안 갈리면, 이 자리에서는 신호만으로 판단할 수 없다.
    if (sLo - 2 <= aHi) {
        g_wzTitle = L"앉아 있을 때와 비울 때가 구분되지 않아요";
        swprintf_s(buf,
            L"앉아 있을 때 %d~%d, 비웠을 때 %d~%d 로 겹칩니다.\n\n"
            L"폰을 둔 곳이 책상과 너무 가까웠어요. 더 멀리 두고 다시 해 보세요.",
            sLo, sHi, aLo, aHi);
        g_wzBody = buf;
        DbgEvent(L"재보기: 구간이 겹친다 (착석 %d..%d, 비움 %d..%d)", sLo, sHi, aLo, aHi);
        return;
    }

    // "보통" 은 앉아 있을 때의 가장 약한 값보다 낮게 잡는다. 평균이 아니라
    // 끝값을 보는 이유는, 한 번만 밑돌아도 앉은 사람 앞에서 화면이 꺼지기 때문이다.
    g_wzBase = sLo - 2;
    g_wzOk = true;
    g_wzTitle = L"다 됐어요";
    swprintf_s(buf,
        L"앉아 있을 때  %d ~ %d\n"
        L"자리 비웠을 때  %d ~ %d\n\n"
        L"이 자리에 맞게 \"보통\" 을 맞췄어요. "
        L"\"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다.",
        sLo, sHi, aLo, aHi);
    g_wzBody = buf;
    DbgEvent(L"재보기: 착석 %d..%d (%d개), 비움 %d..%d (%d개) -> 기준 %d dBm",
             sLo, sHi, sn, aLo, aHi, an, g_wzBase);
}

static void WzSetPhase(int ph) {
    g_wzPhase = ph;
    // 스캐너에 남아 있던 직전 패킷을 새 구간의 첫 표본으로 세지 않는다.
    g_wzLastTick = g_bleGatt.IsHealthy() ? g_bleGatt.LastReportTick()
                                         : g_bleScanner.LastReceivedTick();
    switch (ph) {
    case 1: g_wzLeft = kWzSeated; break;
    case 3: g_wzLeft = kWzAway;   break;
    case 4: WzJudge();            break;
    }
    if (g_hWizProg) {
        SendMessageW(g_hWizProg, PBM_SETRANGE32, 0, (ph == 1 ? kWzSeated : kWzAway));
        SendMessageW(g_hWizProg, PBM_SETPOS, 0, 0);
        ShowWindow(g_hWizProg, (ph == 1 || ph == 3) ? SW_SHOW : SW_HIDE);
    }
    if (g_hWizNext) {
        const wchar_t* lbl = ph == 0 ? L"시작하기"
                           : ph == 2 ? L"폰을 두고 왔어요"
                           : ph == 4 ? (g_wzOk ? L"이대로 쓰기" : L"닫기") : L"";
        SetWindowTextW(g_hWizNext, lbl);
        ShowWindow(g_hWizNext, (ph == 0 || ph == 2 || ph == 4) ? SW_SHOW : SW_HIDE);
    }
    if (g_hWiz) InvalidateRect(g_hWiz, nullptr, TRUE);
}

static LRESULT CALLBACK WizProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        HINSTANCE hI = GetModuleHandle(nullptr);
        g_hWizProg = CreateWindowExW(0, PROGRESS_CLASS, L"",
            WS_CHILD | PBS_SMOOTH, 26, 186, WZ_W - 72, 8, hWnd, nullptr, hI, nullptr);
        SendMessageW(g_hWizProg, PBM_SETBARCOLOR, 0, (LPARAM)kAccent);
        SendMessageW(g_hWizProg, PBM_SETBKCOLOR, 0, (LPARAM)RGB(0xC4, 0xC4, 0xC4));

        g_hWizNext = CreateWindowExW(0, L"BUTTON", L"시작하기",
            WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, 26, WZ_H - 96, WZ_W - 72, 42,
            hWnd, (HMENU)(UINT_PTR)IDW_NEXT, hI, nullptr);
        CreateWindowExW(0, L"BUTTON", L"그만두기",
            WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, WZ_W - 140, 14, 100, 30,
            hWnd, (HMENU)(UINT_PTR)IDW_CANCEL, hI, nullptr);

        EnumChildWindows(hWnd, [](HWND h, LPARAM f) -> BOOL {
            SendMessage(h, WM_SETFONT, (WPARAM)f, TRUE); return TRUE;
        }, (LPARAM)g_hFont);
        SetTimer(hWnd, IDT_WIZ, 500, nullptr);
        return 0;
    }

    case WM_ERASEBKGND: {
        RECT rc; GetClientRect(hWnd, &rc);
        if (!g_hPanelBrush) g_hPanelBrush = CreateSolidBrush(kPanelBg);
        FillRect((HDC)wParam, &rc, g_hPanelBrush);
        return 1;
    }

    case WM_PAINT: {
        PAINTSTRUCT ps; HDC hdc = BeginPaint(hWnd, &ps);
        const wchar_t* title; const wchar_t* body;
        wchar_t live[96] = L"";
        switch (g_wzPhase) {
        case 0:
            title = L"내 자리에 맞게 재보기";
            body  = L"2분쯤 걸려요. 순서는 이렇습니다.\n\n"
                    L"1.  폰을 평소 두는 자리에 두고 1분 동안 앉아 있기\n"
                    L"2.  폰만 \"화면이 꺼지길 원하는 곳\" 에 두고 오기\n"
                    L"3.  자리에 앉아서 45초 기다리기";
            break;
        case 1:
            title = L"1/3  자리에 앉아 계세요";
            body  = L"폰은 평소 두는 자리에 그대로 두세요.\n"
                    L"컴퓨터는 건드리지 않아도 돼요.";
            swprintf_s(live, L"%d초 남음   ·   %d번 받음", g_wzLeft, (int)g_wzSeated.size());
            break;
        case 2:
            title = L"2/3  폰을 두고 오세요";
            body  = L"화면이 꺼지길 원하는 곳에 폰을 두고,\n"
                    L"자리로 돌아와서 아래 버튼을 눌러 주세요.\n\n"
                    L"폰은 가져오지 마세요. 재는 동안 거기 있어야 해요.";
            break;
        case 3:
            title = L"3/3  거의 다 됐어요";
            body  = L"그대로 기다려 주세요.\n폰을 가지러 가지 마세요.";
            swprintf_s(live, L"%d초 남음   ·   %d번 받음", g_wzLeft, (int)g_wzAway.size());
            break;
        default:
            title = g_wzTitle.c_str();
            body  = g_wzBody.c_str();
            break;
        }

        SetBkMode(hdc, TRANSPARENT);
        RECT t = { 26, 56, WZ_W - 46, 96 };
        HFONT of = (HFONT)SelectObject(hdc, g_hFontBig ? g_hFontBig : g_hFont);
        SetTextColor(hdc, g_wzPhase == 4 && !g_wzOk ? RGB(0xC0, 0x30, 0x30) : kInk);
        DrawTextW(hdc, title, -1, &t, DT_LEFT | DT_WORDBREAK);

        SelectObject(hdc, g_hFont);
        SetTextColor(hdc, kInkSoft);
        RECT b = { 26, 104, WZ_W - 46, WZ_H - 110 };
        DrawTextW(hdc, body, -1, &b, DT_LEFT | DT_WORDBREAK);

        if (live[0]) {
            SetTextColor(hdc, kAccent);
            RECT l = { 26, 202, WZ_W - 46, 226 };
            DrawTextW(hdc, live, -1, &l, DT_LEFT | DT_SINGLELINE);
        }
        SelectObject(hdc, of);
        EndPaint(hWnd, &ps); return 0;
    }

    case WM_DRAWITEM: {
        auto* di = (DRAWITEMSTRUCT*)lParam;
        if (di->CtlType != ODT_BUTTON) break;
        bool down = (di->itemState & ODS_SELECTED) != 0;
        bool accent = (di->CtlID == IDW_NEXT);
        wchar_t label[64] = L"";
        GetWindowTextW(di->hwndItem, label, _countof(label));
        COLORREF fill = accent ? (down ? kAccentDn : kAccent) : (down ? kTilePress : kPanelBg);
        COLORREF edge = accent ? fill : kTileEdge;
        COLORREF ink  = accent ? RGB(255, 255, 255) : kInkSoft;
        DrawTile(di->hDC, di->rcItem, fill, edge, ink, label, g_hFont, accent ? 14 : 10);
        return TRUE;
    }

    case WM_TIMER: {
        if (wParam != IDT_WIZ) break;
        if (g_wzPhase == 1) WzCollect(&g_wzSeated);
        else if (g_wzPhase == 3) WzCollect(&g_wzAway);
        else if (g_wzPhase == 2) WzCollect(nullptr);   // 옮기는 중: 버린다

        if (g_wzPhase == 1 || g_wzPhase == 3) {
            static int half = 0;
            if (++half >= 2) {   // 타이머는 0.5초, 카운트다운은 1초
                half = 0;
                if (--g_wzLeft <= 0) WzSetPhase(g_wzPhase + 1);
                else {
                    int total = (g_wzPhase == 1 ? kWzSeated : kWzAway);
                    SendMessageW(g_hWizProg, PBM_SETPOS, total - g_wzLeft, 0);
                }
            }
        }
        InvalidateRect(hWnd, nullptr, TRUE);
        return 0;
    }

    case WM_COMMAND:
        if (LOWORD(wParam) == IDW_CANCEL) { DestroyWindow(hWnd); return 0; }
        if (LOWORD(wParam) == IDW_NEXT) {
            if (g_wzPhase == 0) {
                g_wzSeated.clear(); g_wzAway.clear();
                WzSetPhase(1);
            } else if (g_wzPhase == 2) {
                WzSetPhase(3);
            } else if (g_wzPhase == 4) {
                if (g_wzOk) {
                    AppConfig c; LoadAppConfig(c);
                    c.measuredBaseRssi = g_wzBase;
                    SaveAppConfig(c);
                    // 방금 잰 값이 "보통" 이다. 여기서 SimpleDistStep() 을 쓰면
                    // 안 된다 - 그건 예전 절대 임계값에 가장 가까운 단계를 찾는데,
                    // 기준이 방금 바뀌었으니 그 비교는 뜻이 없다. 실제로 연달아
                    // 재면 "가까이" 가 잡혔고, 그 값은 착석 최저값보다 위여서
                    // 앉아 있는 사람 앞에서 화면이 꺼진다.
                    SimpleApplyDist(1);
                    SimpleRefresh();
                }
                DestroyWindow(hWnd);
            }
        }
        return 0;

    case WM_CLOSE: DestroyWindow(hWnd); return 0;

    case WM_DESTROY:
        KillTimer(hWnd, IDT_WIZ);
        g_hWiz = nullptr; g_hWizProg = nullptr; g_hWizNext = nullptr;
        g_measuring = false;      // 다시 잠길 수 있게
        if (g_hSimple) { EnableWindow(g_hSimple, TRUE); SetForegroundWindow(g_hSimple); }
        return 0;
    }
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

static void OpenWizard(HWND parent) {
    if (g_hWiz) { SetForegroundWindow(g_hWiz); return; }
    // 폰을 모르면 잴 것이 없다. 스캐너가 어느 광고가 내 폰인지 가려내지
    // 못하면 표본이 하나도 안 쌓이고, 마법사는 "신호를 거의 못 받았어요" 로
    // 끝난다 - 원인이 등록인데 엉뚱한 곳을 보게 된다.
    {
        AppConfig pc; LoadAppConfig(pc);
        if (pc.phoneToken.empty()) {
            if (MessageBoxW(parent,
                    L"먼저 폰을 등록해야 해요.\n\n"
                    L"어느 신호가 내 폰인지 알아야 거리를 잴 수 있어요.\n"
                    L"지금 등록할까요?",
                    L"내 자리에 맞게 재보기", MB_OKCANCEL | MB_ICONINFORMATION) == IDOK)
                SendMessageW(parent, WM_COMMAND, IDS_PHONE, 0);
            return;
        }
    }
    if (!g_monitoring) {
        MessageBoxW(parent,
            L"먼저 보호를 켜야 신호를 받을 수 있어요.\n[고급 설정] 에서 시작을 눌러 주세요.",
            L"내 자리에 맞게 재보기", MB_OK | MB_ICONINFORMATION);
        return;
    }
    static bool reg = false;
    if (!reg) {
        WNDCLASSEXW wc = {}; wc.cbSize = sizeof(wc); wc.style = CS_HREDRAW | CS_VREDRAW;
        wc.lpfnWndProc = WizProc; wc.hInstance = GetModuleHandle(nullptr);
        wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        wc.lpszClassName = L"SmartScreenWizard";
        RegisterClassExW(&wc); reg = true;
    }
    RECT pr; GetWindowRect(parent, &pr);
    g_wzPhase = 0; g_wzOk = false;
    g_wzSeated.clear(); g_wzAway.clear();
    // 재는 동안 화면이 꺼지면 측정이 끊긴다. 자리를 비우는 것이 절차의 일부라
    // 그냥 두면 반드시 꺼진다.
    g_measuring = true;
    g_hWiz = CreateWindowExW(0, L"SmartScreenWizard", L"내 자리에 맞게 재보기",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        pr.left + 20, pr.top + 60, WZ_W, WZ_H,
        parent, nullptr, GetModuleHandle(nullptr), nullptr);
    if (g_hWiz) { ShowWindow(g_hWiz, SW_SHOW); WzSetPhase(0); }
    else g_measuring = false;
}

static LRESULT CALLBACK SimpleProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        HINSTANCE hI = GetModuleHandle(nullptr);
        int x = 22, w = SW_W - 62, y = 14;

        CreateWindowExW(0, L"BUTTON", L"고급 설정",
            WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, SW_W - 132, y, 92, 28,
            hWnd, (HMENU)(UINT_PTR)IDS_ADVANCED, hI, nullptr);

        // 상태 카드는 WM_PAINT 가 그린다
        y = 150;
        // 윈도우 11 의 wifi·블루투스 타일과 같은 규칙: 켜져 있으면 파랗다.
        CreateWindowExW(0, L"BUTTON", L"", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
            x, y, w, 44, hWnd, (HMENU)(UINT_PTR)IDS_GUARD, hI, nullptr);

        y += 58;
        CreateWindowExW(0, L"STATIC", L"내 폰", WS_CHILD | WS_VISIBLE,
            x, y, 200, 18, hWnd, nullptr, hI, nullptr);
        y += 22;
        g_hSimplePhone = CreateWindowExW(0, L"STATIC", L"",
            WS_CHILD | WS_VISIBLE | SS_PATHELLIPSIS, x, y + 5, w - 96, 20,
            hWnd, nullptr, hI, nullptr);
        CreateWindowExW(0, L"BUTTON", L"바꾸기", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
            x + w - 88, y, 88, 32, hWnd, (HMENU)(UINT_PTR)IDS_PHONE, hI, nullptr);

        y += 48;
        CreateWindowExW(0, L"STATIC", L"얼마나 멀어지면 가릴까요?", WS_CHILD | WS_VISIBLE,
            x, y, 300, 18, hWnd, nullptr, hI, nullptr);
        y += 22;
        g_hSimpleDist = CreateWindowExW(0, TRACKBAR_CLASS, L"",
            WS_CHILD | WS_VISIBLE | TBS_NOTICKS | TBS_TRANSPARENTBKGND,
            x, y, w, 32, hWnd, (HMENU)(UINT_PTR)IDS_DIST, hI, nullptr);
        SendMessageW(g_hSimpleDist, TBM_SETRANGE, TRUE, MAKELPARAM(0, 2));
        SendMessageW(g_hSimpleDist, TBM_SETPAGESIZE, 0, 1);
        y += 32;
        CreateWindowExW(0, L"STATIC", L"가까이", WS_CHILD | WS_VISIBLE,
            x, y, 60, 16, hWnd, nullptr, hI, nullptr);
        CreateWindowExW(0, L"STATIC", L"보통", WS_CHILD | WS_VISIBLE | SS_CENTER,
            x + w / 2 - 30, y, 60, 16, hWnd, nullptr, hI, nullptr);
        CreateWindowExW(0, L"STATIC", L"멀리", WS_CHILD | WS_VISIBLE | SS_RIGHT,
            x + w - 60, y, 60, 16, hWnd, nullptr, hI, nullptr);

        y += 24;
        g_hSimpleMeasure = CreateWindowExW(0, L"BUTTON", L"",
            WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, x, y, w, 36,
            hWnd, (HMENU)(UINT_PTR)IDS_MEASURE, hI, nullptr);

        y += 50;
        CreateWindowExW(0, L"STATIC", L"자리를 뜨고 몇 초 뒤에 가릴까요?",
            WS_CHILD | WS_VISIBLE, x, y, 320, 18, hWnd, nullptr, hI, nullptr);
        y += 22;
        for (int i = 0; i < 4; i++) {
            g_hSimpleIdle[i] = CreateWindowExW(0, L"BUTTON", kSimpleIdleLabel[i],
                WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                x + i * (w / 4), y, w / 4 - 8, 38,
                hWnd, (HMENU)(UINT_PTR)(IDS_IDLE_BASE + i), hI, nullptr);
        }

        y += 50;
        CreateWindowExW(0, L"STATIC", L"가릴 때 보여줄 그림", WS_CHILD | WS_VISIBLE,
            x, y, 300, 18, hWnd, nullptr, hI, nullptr);
        y += 22;
        CreateWindowExW(0, L"BUTTON", L"그림 고르기", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
            x, y, 150, 36, hWnd, (HMENU)(UINT_PTR)IDS_IMAGE, hI, nullptr);

        y += 52;
        CreateWindowExW(0, L"BUTTON", L"지금 가리기", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
            x, y, w, 42, hWnd, (HMENU)(UINT_PTR)IDS_LOCKNOW, hI, nullptr);

        // ---- 클립보드 공유 (client/clipsync.h) ----
        // 자리비움 감지와 아무 상관이 없는 기능이지만, 이 앱으로 돌아오는 길이
        // 이 창뿐이라(트레이 아이콘이 없다) 여기 둔다. 상태 한 줄을 반드시
        // 같이 둔다 - 서버를 타는 기능이라 조용히 실패할 수 있고, 그러면
        // 사용자는 "켰는데 안 된다" 외에 할 말이 없다.
        y += 54;
        CreateWindowExW(0, L"STATIC", L"다른 PC 와 클립보드 공유", WS_CHILD | WS_VISIBLE,
            x, y, 300, 18, hWnd, nullptr, hI, nullptr);
        y += 22;
        CreateWindowExW(0, L"BUTTON", L"", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
            x, y, w, 44, hWnd, (HMENU)(UINT_PTR)IDS_CLIP, hI, nullptr);
        y += 48;
        g_hSimpleClipMsg = CreateWindowExW(0, L"STATIC", L"",
            WS_CHILD | WS_VISIBLE | SS_LEFT | SS_ENDELLIPSIS, x, y, w, 18,
            hWnd, nullptr, hI, nullptr);

        // ---- 프로그램 업데이트 (client/update.h) ----
        // 머리의 버전 단추는 늘 있다 - 어느 PC 가 어느 버전인지가 이걸로 보인다.
        // 아래 띠는 새 버전이 있을 때만 나타나고, 그때만 창이 SW_UPD_H 만큼 자란다
        // (SimpleRefresh). 만들 때는 숨겨 둔다.
        CreateWindowExW(0, L"BUTTON", L"", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
            x, 14, 210, 28, hWnd, (HMENU)(UINT_PTR)IDS_UPD_CHECK, hI, nullptr);
        y += 24;
        // 글은 폭 전체를 쓴다 (세 줄까지). 실패 이유가 여기 뜨는데, 단추 옆 좁은 칸에서는
        // 뒷부분 - 대개 "어떻게 하라" 는 부분 - 이 잘려 나갔다. 단추는 그 아래 줄.
        // SS_NOPREFIX: 서버에서 온 글의 '&' 를 단축키 표시로 먹지 않게
        g_hSimpleUpdMsg = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | SS_LEFT | SS_NOPREFIX,
            x, y + 4, w, 54, hWnd, nullptr, hI, nullptr);
        CreateWindowExW(0, L"BUTTON", L"", WS_CHILD | BS_OWNERDRAW,
            x + w - 176, y + 62, 84, 30, hWnd, (HMENU)(UINT_PTR)IDS_UPD_APPLY, hI, nullptr);
        CreateWindowExW(0, L"BUTTON", L"나중에", WS_CHILD | BS_OWNERDRAW,
            x + w - 84, y + 62, 84, 30, hWnd, (HMENU)(UINT_PTR)IDS_UPD_LATER, hI, nullptr);

        EnumChildWindows(hWnd, [](HWND h, LPARAM f) -> BOOL {
            SendMessage(h, WM_SETFONT, (WPARAM)f, TRUE); return TRUE;
        }, (LPARAM)g_hFont);

        SetTimer(hWnd, IDT_SIMPLE, 1000, nullptr);
        return 0;
    }

    case WM_PAINT: {
        PAINTSTRUCT ps; HDC hdc = BeginPaint(hWnd, &ps);
        RECT rc = { 22, 58, SW_W - 40, 136 };

        COLORREF bg; const wchar_t* line1; const wchar_t* line2;
        if (!g_monitoring) {
            bg = RGB(120, 120, 120); line1 = L"꺼져 있어요";
            line2 = L"아래 [보호 꺼짐] 을 누르면 시작해요";
        } else if (g_bBlackActive) {
            bg = RGB(200, 60, 60);  line1 = L"화면을 가리는 중";
            line2 = g_bManualLock ? L"검은 화면의 [해제] 를 누르면 돌아와요"
                                  : L"폰이 돌아오면 저절로 풀려요";
        } else if (g_proxState == ProxState::Near) {
            bg = RGB(46, 160, 67);  line1 = L"지키는 중";
            line2 = L"자리를 비우면 화면을 가려요";
        } else {
            bg = RGB(230, 145, 40); line1 = L"폰이 안 보여요";
            line2 = L"곧 화면을 가릴 거예요";
        }

        HBRUSH br = CreateSolidBrush(bg);
        HPEN pn = CreatePen(PS_SOLID, 1, bg);
        HBRUSH ob = (HBRUSH)SelectObject(hdc, br);
        HPEN op = (HPEN)SelectObject(hdc, pn);
        RoundRect(hdc, rc.left, rc.top, rc.right, rc.bottom, 16, 16);
        SelectObject(hdc, ob); SelectObject(hdc, op);
        DeleteObject(br); DeleteObject(pn);
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, RGB(255, 255, 255));
        RECT t1 = { rc.left + 18, rc.top + 14, rc.right - 18, rc.top + 48 };
        HFONT of = (HFONT)SelectObject(hdc, g_hFontBig ? g_hFontBig : g_hFont);
        DrawTextW(hdc, line1, -1, &t1, DT_LEFT | DT_SINGLELINE);
        SelectObject(hdc, g_hFont);
        RECT t2 = { rc.left + 18, rc.top + 48, rc.right - 18, rc.bottom - 8 };
        DrawTextW(hdc, line2, -1, &t2, DT_LEFT | DT_WORDBREAK);
        SelectObject(hdc, of);
        EndPaint(hWnd, &ps); return 0;
    }

    case WM_ERASEBKGND: {
        RECT rc; GetClientRect(hWnd, &rc);
        if (!g_hPanelBrush) g_hPanelBrush = CreateSolidBrush(kPanelBg);
        FillRect((HDC)wParam, &rc, g_hPanelBrush);
        return 1;
    }

    case WM_CTLCOLORSTATIC: {
        // 이걸 안 두면 DefWindowProc 이 COLOR_BTNFACE 를 돌려줘서, 패널 위에
        // 라벨마다 회색 상자가 얹힌다.
        SetBkMode((HDC)wParam, TRANSPARENT);
        SetTextColor((HDC)wParam, kInkSoft);
        if (!g_hPanelBrush) g_hPanelBrush = CreateSolidBrush(kPanelBg);
        return (LRESULT)g_hPanelBrush;
    }

    case WM_NOTIFY: {
        // 기본 트랙바는 가는 홈에 각진 손잡이라, 옆의 둥근 타일과 안 어울린다.
        // 굵은 막대와 동그란 손잡이로 직접 그린다.
        auto* nh = (NMHDR*)lParam;
        if (nh->code != NM_CUSTOMDRAW || nh->hwndFrom != g_hSimpleDist) break;
        auto* cd = (NMCUSTOMDRAW*)lParam;
        if (cd->dwDrawStage == CDDS_PREPAINT) return CDRF_NOTIFYITEMDRAW;
        if (cd->dwDrawStage != CDDS_ITEMPREPAINT) return CDRF_DODEFAULT;

        if (cd->dwItemSpec == TBCD_TICS) return CDRF_SKIPDEFAULT;

        if (cd->dwItemSpec == TBCD_CHANNEL) {
            RECT tr{}; SendMessageW(g_hSimpleDist, TBM_GETTHUMBRECT, 0, (LPARAM)&tr);
            int mid = (cd->rc.top + cd->rc.bottom) / 2;
            RECT rest = { cd->rc.left, mid - 2, cd->rc.right, mid + 2 };
            HBRUSH b1 = CreateSolidBrush(RGB(0xC4, 0xC4, 0xC4));
            FillRect(cd->hdc, &rest, b1); DeleteObject(b1);
            // 손잡이까지는 강조색으로 채운다 - 어디까지 왔는지가 보인다
            RECT done = { cd->rc.left, mid - 2, (tr.left + tr.right) / 2, mid + 2 };
            HBRUSH b2 = CreateSolidBrush(kAccent);
            FillRect(cd->hdc, &done, b2); DeleteObject(b2);
            return CDRF_SKIPDEFAULT;
        }

        if (cd->dwItemSpec == TBCD_THUMB) {
            int cx = (cd->rc.left + cd->rc.right) / 2;
            int cy = (cd->rc.top + cd->rc.bottom) / 2;
            HBRUSH br = CreateSolidBrush(kAccent);
            HPEN   pn = CreatePen(PS_SOLID, 3, RGB(0xFF, 0xFF, 0xFF));
            HBRUSH ob = (HBRUSH)SelectObject(cd->hdc, br);
            HPEN   op = (HPEN)SelectObject(cd->hdc, pn);
            Ellipse(cd->hdc, cx - 9, cy - 9, cx + 9, cy + 9);
            SelectObject(cd->hdc, ob); SelectObject(cd->hdc, op);
            DeleteObject(br); DeleteObject(pn);
            return CDRF_SKIPDEFAULT;
        }
        return CDRF_DODEFAULT;
    }

    case WM_DRAWITEM: {
        auto* di = (DRAWITEMSTRUCT*)lParam;
        if (di->CtlType != ODT_BUTTON) break;
        bool down = (di->itemState & ODS_SELECTED) != 0;
        int  id = (int)di->CtlID;

        wchar_t label[192] = L"";
        GetWindowTextW(di->hwndItem, label, _countof(label));

        // 파란 타일은 둘뿐이다: 지금 고른 시간과, 이 화면의 주 동작.
        // 전부 파랗게 하면 무엇이 켜져 있는지가 안 보인다.
        if (id == IDS_GUARD)
            wcscpy_s(label, g_monitoring ? L"보호 켜짐" : L"보호 꺼짐");
        if (id == IDS_CLIP)
            wcscpy_s(label, ClipSyncRunning() ? L"클립보드 공유 켜짐" : L"클립보드 공유 꺼짐");

        bool accent = (id == IDS_GUARD && g_monitoring) ||
                      (id == IDS_CLIP && ClipSyncRunning()) ||
                      (id == IDS_UPD_APPLY) ||
                      (id >= IDS_IDLE_BASE && id < IDS_IDLE_BASE + 4 &&
                       g_idleCountdownSec == kSimpleIdle[id - IDS_IDLE_BASE]);
        bool ghost = (id == IDS_ADVANCED || id == IDS_UPD_CHECK || id == IDS_UPD_LATER);

        COLORREF fill, edge, ink;
        if (accent)     { fill = down ? kAccentDn : kAccent; edge = fill;      ink = RGB(255,255,255); }
        else if (ghost) { fill = down ? kTilePress : kPanelBg; edge = kTileEdge; ink = kInkSoft; }
        else            { fill = down ? kTilePress : kTileBg;  edge = kTileEdge; ink = kInk; }

        DrawTile(di->hDC, di->rcItem, fill, edge, ink, label, g_hFont, ghost ? 10 : 14);
        return TRUE;
    }

    case WM_HSCROLL:
        if ((HWND)lParam == g_hSimpleDist) {
            SimpleApplyDist((int)SendMessageW(g_hSimpleDist, TBM_GETPOS, 0, 0));
        }
        return 0;

    case WM_TIMER:
        if (wParam == IDT_SIMPLE) SimpleRefresh();
        return 0;

    case WM_COMMAND: {
        int id = LOWORD(wParam);
        if (id >= IDS_IDLE_BASE && id < IDS_IDLE_BASE + 4) {
            g_idleCountdownSec = kSimpleIdle[id - IDS_IDLE_BASE];
            g_nCountdown = g_idleCountdownSec;
            AppConfig c; LoadAppConfig(c);
            c.idleCountdownSec = g_idleCountdownSec; SaveAppConfig(c);
            return 0;
        }
        switch (id) {
        case IDS_ADVANCED:
            ShowWindow(g_hWnd, SW_SHOW);
            SetForegroundWindow(g_hWnd);
            break;
        // 아래 셋은 고급 창이 이미 하는 일이다. 여기서 다시 구현하면 두 벌이 된다.
        case IDS_PHONE:   SendMessageW(g_hWnd, WM_COMMAND, ID_BTN_REGISTER_PHONE, 0); SimpleRefresh(); break;
        case IDS_IMAGE:   SendMessageW(g_hWnd, WM_COMMAND, ID_BTN_CENTER_IMG, 0); break;
        case IDS_LOCKNOW: SendMessageW(g_hWnd, WM_COMMAND, ID_BTN_BLACKNOW, 0); break;
        case IDS_GUARD:
            SendMessageW(g_hWnd, WM_COMMAND, g_monitoring ? ID_STOP : ID_START, 0);
            SimpleRefresh();
            break;
        case IDS_MEASURE: OpenWizard(hWnd); break;
        case IDS_UPD_CHECK:
            if (UpdateEnabled()) UpdateCheckAsync(true);   // 꺼져 있으면 단추 글이 이미 그렇게 말한다
            SimpleRefresh();
            break;
        case IDS_UPD_APPLY: {
            // 실패한 뒤 후보(버전·경로·해시)가 없으면 다시 묻는 것부터. 있으면 다시 받는다.
            // version 만 보고 가르면 안 된다 - Pending 은 version 은 있고 후보는 없다.
            UpdateStatus us = UpdateGetStatus();
            if (us.phase == UpdatePhase::Failed && !UpdateHasCandidate()) UpdateCheckAsync(true);
            else UpdateDownloadAsync();
            SimpleRefresh();
            break;
        }
        case IDS_UPD_LATER:
            UpdateDismiss();
            SimpleRefresh();
            break;
        case IDS_CLIP: {
            AppConfig c; LoadAppConfig(c);
            if (ClipSyncRunning()) {
                ClipSyncStop();
                c.clipSync = false;
                SaveAppConfig(c);
            } else {
                // 로그인이 먼저다. 그 말을 여기서 하지 않으면 타일만 안 켜지고
                // 이유가 어디에도 안 뜬다.
                if (!SessionHasAccount()) {
                    MessageBoxW(hWnd,
                        L"먼저 구글 계정으로 로그인하세요.\n\n"
                        L"[내 폰] 의 [등록하기] 에서 계정으로 등록하면 로그인됩니다.\n"
                        L"다른 PC 에서도 같은 계정으로 로그인해야 서로 주고받습니다.",
                        L"클립보드 공유", MB_OK | MB_ICONINFORMATION);
                    break;
                }
                std::wstring surl = c.serverUrl.empty() ? kDefaultSupabaseUrl : c.serverUrl;
                std::wstring skey = c.anonKey.empty()   ? kDefaultAnonKey     : c.anonKey;
                if (ClipSyncStart(surl, skey, c.clipMaxKB * 1024)) {
                    c.clipSync = true;
                    SaveAppConfig(c);
                    MessageBoxW(hWnd,
                        L"클립보드 공유를 켰습니다.\n\n"
                        L"복사한 그림과 글이 이 계정의 다른 PC 로 넘어갑니다.\n"
                        L"복사한 내용이 서버를 지나가므로, 필요할 때만 켜 두세요.",
                        L"클립보드 공유", MB_OK | MB_ICONINFORMATION);
                }
            }
            SimpleRefresh();
            break;
        }
        }
        return 0;
    }

    case WM_CLOSE:
        ShowWindow(hWnd, SW_HIDE);   // 오버레이의 [설정] 로 다시 열 수 있다
        return 0;

    case WM_DESTROY:
        KillTimer(hWnd, IDT_SIMPLE);
        g_hSimple = nullptr;
        return 0;
    }
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// WinMain
// ---------------------------------------------------------------------------
int WINAPI wWinMain(HINSTANCE hI, HINSTANCE, LPWSTR, int nS) {
    // IRK 가져오기용 보조 모드. UI 없이 실행하고 바로 끝난다.
    // 뮤텍스보다 먼저 처리해야 본 프로그램이 떠 있어도 동작한다.
    {
        int argc = 0;
        LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        if (argv) {
            int rc = -1;
            if (argc >= 3 && wcscmp(argv[1], L"--dump-irk") == 0) {
                // SYSTEM 권한으로 실행됨: 레지스트리를 덤프하고 끝
                rc = (DumpIrkFromRegistry(argv[2]) > 0) ? 0 : 1;
            } else if (argc >= 3 && wcscmp(argv[1], L"--import-irk") == 0) {
                // 관리자 권한으로 실행됨: SYSTEM 작업을 돌려 config에 저장
                std::wstring m;
                rc = ImportIrkElevated(argv[2], m) ? 0 : 1;
            } else if (argc >= 5 && wcscmp(argv[1], L"--apply-update") == 0) {
                // 업데이트 적용 (update.h). 복사본 exe 로 실행되며, 원래 프로세스가
                // 아직 살아 있을 때 시작되므로 뮤텍스보다 먼저여야 한다.
                rc = UpdateApplyMain(argc, argv);
            } else if (argc >= 2 && wcscmp(argv[1], L"--clip-test") == 0) {
                // 클립보드 왕복 진단 (clipsync.h). 여기 있는 이유는 위와 같다 -
                // 앱이 떠 있는 채로 돌려 봐야 쓸모가 있다. 그래서 winsock 과
                // GDI+ 를 이 블록에서 따로 올린다.
                WSADATA wd2; WSAStartup(MAKEWORD(2, 2), &wd2);
                ULONG_PTR tok = 0;
                Gdiplus::GdiplusStartupInput gi;
                Gdiplus::GdiplusStartup(&tok, &gi, nullptr);

                AppConfig c; LoadAppConfig(c);
                std::wstring surl = c.serverUrl.empty() ? kDefaultSupabaseUrl : c.serverUrl;
                std::wstring skey = c.anonKey.empty()   ? kDefaultAnonKey     : c.anonKey;
                std::wstring serr, report;
                bool ok = false;
                SessionStart(surl, skey, c.authRefresh, serr);
                if (!serr.empty()) report = L"[X] 세션: " + serr + L"\n";
                else ok = ClipSyncRoundTrip(surl, skey, report);

                // 파일로도 남긴다. 창에 뜬 글자를 손으로 옮겨 적게 만들면
                // 아무도 그러지 않고, 실패한 줄의 상태코드가 그대로 사라진다.
                std::wstring path = GetConfigDir() + L"\\clip-test.txt";
                if (FILE* f = nullptr; _wfopen_s(&f, path.c_str(), L"w, ccs=UTF-8") == 0 && f) {
                    fputws(report.c_str(), f);
                    fclose(f);
                    report += L"\n이 내용을 파일로도 적어 두었습니다:\n" + path + L"\n";
                }
                MessageBoxW(nullptr, report.c_str(), L"클립보드 왕복 진단",
                            MB_OK | (ok ? MB_ICONINFORMATION : MB_ICONWARNING));

                if (tok) Gdiplus::GdiplusShutdown(tok);
                WSACleanup();
                rc = ok ? 0 : 1;
            }
            LocalFree(argv);
            if (rc >= 0) return rc;
        }
    }

    HANDLE hMutex = CreateMutexW(nullptr, TRUE, L"SmartScreen_Mutex_v1");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        // 업데이트 직후다: updater 가 예전 프로세스의 종료를 기다렸다 해도 뮤텍스가
        // 풀리는 데 잠깐 걸릴 수 있다. 바로 "이미 실행 중" 으로 끝내면 새 버전이
        // 아무 말 없이 안 뜬 것처럼 보인다. 몇 초는 기다려 준다.
        DWORD w = WaitForSingleObject(hMutex, 10000);
        if (w != WAIT_OBJECT_0 && w != WAIT_ABANDONED) {
            MessageBoxW(nullptr, L"SmartScreen is already running.", L"SmartScreen", MB_OK|MB_ICONINFORMATION);
            return 0;
        }
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

    // 간단 창. 고급 창(g_hWnd)은 만들어는 두되 숨겨 둔다 - 자동 시작이나
    // 기업 콘텐츠 동기화 같은 일이 전부 그 창의 WM_CREATE 에 들어 있어서,
    // 안 만들면 프로그램이 뜨지 않는 것과 같다.
    {WNDCLASSEXW sc = {}; sc.cbSize = sizeof(sc); sc.style = CS_HREDRAW | CS_VREDRAW;
     sc.lpfnWndProc = SimpleProc; sc.hInstance = hI;
     sc.hCursor = LoadCursor(nullptr, IDC_ARROW);
     sc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
     sc.lpszClassName = L"SmartScreenSimple";
     sc.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
     RegisterClassExW(&sc);}
    g_hSimple = CreateWindowExW(0, L"SmartScreenSimple", L"SmartScreen " SS_VERSION_STR,
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        (sx - SW_W) / 2, (sy - SW_H) / 2, SW_W, SW_H,
        nullptr, nullptr, hI, nullptr);

    // 설정이 없으면 창을 띄워 안내하고, 있으면 트레이에서 조용히 시작한다.
    // 등록된 폰을 쓰면 btAddress 는 0이므로 토큰 쪽도 같이 본다.
    ShowWindow(g_hWnd, SW_HIDE);
    AppConfig chk;
    bool configured = LoadAppConfig(chk) && (chk.btAddress != 0 || !chk.phoneToken.empty());

    // ---- 계정 세션과 클립보드 동기화 -------------------------------------
    // 창을 만든 뒤에 한다. SessionStart 가 네트워크를 타므로 실패하면 여기서
    // 몇 초를 쓰는데, 그동안 창이 하나도 없으면 사용자에게는 앱이 안 뜬 것이다.
    {
        std::wstring surl = chk.serverUrl.empty() ? kDefaultSupabaseUrl : chk.serverUrl;
        std::wstring skey = chk.anonKey.empty()   ? kDefaultAnonKey     : chk.anonKey;
        SessionOnRotated(OnSessionRotated);

        std::wstring serr;
        if (SessionStart(surl, skey, chk.authRefresh, serr)) {
            DbgEvent(L"session: restored (%s)", SessionEmail().c_str());
        } else if (!serr.empty()) {
            // 로그인한 적은 있는데 되살리지 못했다. 앱을 막을 일은 아니다 -
            // 자리비움 감지는 계정과 무관하게 돌아간다.
            DbgEvent(L"session: restore failed - %s", serr.c_str());
        } else {
            DbgEvent(L"session: no account yet");
        }

        // 클립보드 동기화는 "세션을 되살렸는가" 가 아니라 "계정이 있는가" 로 켠다.
        // 예전에는 SessionStart 가 true 일 때만 켰다. 켜는 순간 네트워크가 아직 없거나
        // 서버가 잠깐 5xx 를 주면 그 실행 내내 꺼진 채였고, 타일은 오류도 없이
        // "꺼져 있어요" 였다. 일꾼은 세션이 없으면 30초마다 다시 물어보게 돼 있으므로
        // (clipsync.cpp WorkerThread) 띄워 두기만 하면 네트워크가 돌아올 때 이어진다.
        //
        // refresh 토큰이 정말로 죽은 경우(폐기)에도 이 길로 온다. 그때는 일꾼이 30초마다
        // 갱신을 다시 시도하고 타일에 "안 됨: <사유>" 가 뜬다 - 말없이 꺼져 있는 것보다
        // 낫다. 다른 PC 의 config 를 복사해 와 봉인이 안 풀리는 경우는 계정이 없는
        // 것으로 남으므로(SessionStart) 여기서 켜지 않는다.
        if (chk.clipSync && SessionHasAccount())
            ClipSyncStart(surl, skey, chk.clipMaxKB * 1024);
    }

    // ---- 프로그램 업데이트 (client/update.h) --------------------------------
    // 확인은 작업 스레드에서 돌고 결과는 WM_UPDATE_STATE 로 온다. 기업 등록 PC 는
    // 조직 id 를 넘겨 승인된 버전만 받게 한다.
    DbgEvent(L"start: SmartScreen %s", SS_VERSION_STR);
    UpdateCleanupAfterStart();
    if (chk.updateCheck) {
        std::wstring surl = chk.serverUrl.empty() ? kDefaultSupabaseUrl : chk.serverUrl;
        std::wstring skey = chk.anonKey.empty()   ? kDefaultAnonKey     : chk.anonKey;
        UpdateInit(surl, skey, chk.enterpriseRegistered ? chk.orgId : L"",
                   chk.updateChannel, g_hWnd, WM_UPDATE_STATE);
        g_updLastCheck = GetTickCount64();
        UpdateCheckAsync(false);
        SetTimer(g_hWnd, IDT_UPDATE, 60 * 1000, nullptr);
    } else {
        DbgEvent(L"update: checks disabled (updateCheck=0)");
    }
    if (g_hSimple) {
        ShowWindow(g_hSimple, configured ? SW_HIDE : SW_SHOW);
        SimpleRefresh();
    } else if (!configured) {
        ShowWindow(g_hWnd, nS);   // 간단 창이 안 만들어졌으면 예전대로
    }
    UpdateWindow(g_hWnd);

    MSG msg;
    while (GetMessage(&msg, nullptr, 0, 0)) { TranslateMessage(&msg); DispatchMessage(&msg); }

    // GdiplusShutdown 보다 먼저. 클립보드 스레드가 PNG 를 굽는 중이면
    // 셧다운 뒤의 GDI+ 호출이 된다.
    ClipSyncStop();
    UpdateShutdown();
    FreeBlackScreenImages();
    if (gdipToken) Gdiplus::GdiplusShutdown(gdipToken);
    WSACleanup();
    if (hMutex) CloseHandle(hMutex);
    return (int)msg.wParam;
}
