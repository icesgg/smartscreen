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

// Overlay
static constexpr int ID_OVL_EXIT     = 401;
static constexpr int ID_OVL_LOCK     = 402;
static constexpr int ID_OVL_SETTINGS = 403;
#define OVERLAY_CLASS L"SmartScreenOverlay"
static constexpr int OVL_W = 260;
static constexpr int OVL_H = 90;

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

static HANDLE g_hThread       = nullptr;
static HANDLE g_hStopEvent    = nullptr;
static int    g_selectedIdx   = -1;
static int    g_logCount      = 0;

// Overlay state text
static wchar_t g_ovlText[64] = L"Stopped";
static COLORREF g_ovlColor = RGB(200, 200, 200);

// ---------------------------------------------------------------------------
// Image file picker (personal edition)
// ---------------------------------------------------------------------------
static std::wstring BrowseImage(HWND hParent) {
    wchar_t file[MAX_PATH] = {};
    OPENFILENAMEW ofn = {};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = hParent;
    ofn.lpstrFilter = L"Images (*.png;*.jpg;*.bmp)\0*.png;*.jpg;*.jpeg;*.bmp\0All Files\0*.*\0";
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
    if (!g_monitoring) { wcscpy_s(g_ovlText, L"Stopped"); g_ovlColor = RGB(160, 160, 160); }
    else if (g_bBlackActive) { wcscpy_s(g_ovlText, L"LOCKED"); g_ovlColor = RGB(255, 80, 80); }
    else if (g_proxState == ProxState::Near) { wcscpy_s(g_ovlText, L"NEAR"); g_ovlColor = RGB(0, 230, 0); }
    else { swprintf_s(g_ovlText, L"FAR  %ds", g_nCountdown); g_ovlColor = RGB(255, 180, 50); }
    InvalidateRect(g_hOverlay, nullptr, TRUE);
}

static LRESULT CALLBACK OverlayProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE:
        CreateWindowExW(0, L"BUTTON", L"Exit", WS_CHILD | WS_VISIBLE,
            8, 56, 55, 25, hWnd, (HMENU)(UINT_PTR)ID_OVL_EXIT, GetModuleHandle(nullptr), nullptr);
        CreateWindowExW(0, L"BUTTON", L"Lock", WS_CHILD | WS_VISIBLE,
            70, 56, 55, 25, hWnd, (HMENU)(UINT_PTR)ID_OVL_LOCK, GetModuleHandle(nullptr), nullptr);
        CreateWindowExW(0, L"BUTTON", L"Settings", WS_CHILD | WS_VISIBLE,
            132, 56, 70, 25, hWnd, (HMENU)(UINT_PTR)ID_OVL_SETTINGS, GetModuleHandle(nullptr), nullptr);
        return 0;

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
        HDC hdc = (HDC)wParam; RECT rc; GetClientRect(hWnd, &rc);
        HBRUSH br = CreateSolidBrush(RGB(30, 30, 30));
        FillRect(hdc, &rc, br); DeleteObject(br);
        HPEN pen = CreatePen(PS_SOLID, 1, RGB(80, 80, 80));
        HPEN op = (HPEN)SelectObject(hdc, pen);
        MoveToEx(hdc, 0, 0, nullptr); LineTo(hdc, rc.right - 1, 0);
        LineTo(hdc, rc.right - 1, rc.bottom - 1); LineTo(hdc, 0, rc.bottom - 1); LineTo(hdc, 0, 0);
        SelectObject(hdc, op); DeleteObject(pen);
        SetBkMode(hdc, TRANSPARENT); SetTextColor(hdc, g_ovlColor);
        HFONT oldF = (HFONT)SelectObject(hdc, g_hFontOvl);
        RECT tr = { 10, 3, rc.right - 10, 28 };
        DrawTextW(hdc, g_ovlText, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        if (g_ovlInfo[0]) {
            SelectObject(hdc, g_hFontOvlBtn);
            SetTextColor(hdc, RGB(180, 180, 120));
            RECT ir = { 10, 30, rc.right - 10, 50 };
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
    g_nCountdown = g_idleCountdownSec;
    if (g_bBlackActive) {
        // Delay applies to both Auto and Manual
        if (g_unlockDelaySec > 0 && g_lockStartTick > 0) {
            DWORD elapsed = (DWORD)((GetTickCount64() - g_lockStartTick) / 1000);
            if (elapsed < (DWORD)g_unlockDelaySec) return;
        }
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
    SetWindowTextW(g_hBtnReconnect, L"Reconnect");
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
        DoProbe(g_targetAddr, reachable, latency, wsaErr);
        ULONGLONG now = GetTickCount64();
        ProxState prev = g_proxState;
        bool inWarmup = (g_reconnectTick > 0 && (now - g_reconnectTick) < WARMUP_MS);
        bool isNear = reachable && (latency <= g_nearLatencyMs || inWarmup);
        if (isNear) {
            g_lastNearTick = now;
            if (g_proxState == ProxState::Far) g_proxState = ProxState::Near;
        } else {
            if (g_proxState == ProxState::Near && (now - g_lastNearTick) >= (ULONGLONG)g_keepAliveSec * 1000)
                g_proxState = ProxState::Far;
        }
        auto* r = new ProbeResult{};
        r->reachable = reachable; r->latencyMs = latency; r->wsaError = wsaErr;
        r->state = g_proxState; r->prevState = prev;
        NowStr(r->timeStr, _countof(r->timeStr));
        if (g_proxState == ProxState::Near) {
            DWORD since = (DWORD)(now - g_lastNearTick), keepMs = g_keepAliveSec * 1000;
            r->timerRemainMs = (since < keepMs) ? (keepMs - since) : 0;
        } else r->timerRemainMs = 0;
        PostMessage(g_hWnd, WM_SCAN_RESULT, 0, (LPARAM)r);
        if (WaitForSingleObject(g_hStopEvent, g_scanIntervalSec * 1000) == WAIT_OBJECT_0) break;
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
        SendMessageW(g_hCombo, CB_ADDSTRING, 0, (LPARAM)L"(no paired devices)");
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

    wchar_t buf[16]; int v;
    GetWindowTextW(g_hEditLatency, buf, _countof(buf));
    v = _wtoi(buf); if (v < 50) v = 50; if (v > 5000) v = 5000;
    g_nearLatencyMs = v; swprintf_s(buf, L"%d", v); SetWindowTextW(g_hEditLatency, buf);
    GetWindowTextW(g_hEditTimeout, buf, _countof(buf));
    v = _wtoi(buf); if (v < 5) v = 5; if (v > 300) v = 300;
    g_keepAliveSec = v; swprintf_s(buf, L"%d", v); SetWindowTextW(g_hEditTimeout, buf);
    GetWindowTextW(g_hEditInterval, buf, _countof(buf));
    v = _wtoi(buf); if (v < 1) v = 1; if (v > 60) v = 60;
    g_scanIntervalSec = v; swprintf_s(buf, L"%d", v); SetWindowTextW(g_hEditInterval, buf);
    GetWindowTextW(g_hEditIdle, buf, _countof(buf));
    v = _wtoi(buf); if (v < 5) v = 5; if (v > 600) v = 600;
    g_idleCountdownSec = v; g_nCountdown = v;
    swprintf_s(buf, L"%d", v); SetWindowTextW(g_hEditIdle, buf);
    g_unlockAuto = (SendMessageW(g_hComboUnlock, CB_GETCURSEL, 0, 0) == 0);
    GetWindowTextW(g_hEditDelay, buf, _countof(buf));
    v = _wtoi(buf); if (v < 0) v = 0; if (v > 300) v = 300;
    g_unlockDelaySec = v; swprintf_s(buf, L"%d", v); SetWindowTextW(g_hEditDelay, buf);

    g_selectedIdx = sel;
    g_targetAddr = g_paired[sel].address;
    g_targetName = g_paired[sel].name;
    g_logCount = 0;

    // Save config
    AppConfig cfg;
    cfg.btAddress = g_targetAddr;
    cfg.nearLatencyMs = g_nearLatencyMs;
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
    EnableWindow(g_hEditLatency, FALSE); EnableWindow(g_hEditTimeout, FALSE);
    EnableWindow(g_hEditInterval, FALSE); EnableWindow(g_hEditIdle, FALSE);
    EnableWindow(g_hComboUnlock, FALSE); EnableWindow(g_hEditDelay, FALSE);
}

static void StopMon() {
    if (!g_monitoring) return;
    SetEvent(g_hStopEvent);
    WaitForSingleObject(g_hThread, 15000);
    CloseProbeSocket();
    CloseHandle(g_hThread); CloseHandle(g_hStopEvent);
    g_hThread = nullptr; g_hStopEvent = nullptr;
    g_monitoring = false;
    KillTimer(g_hWnd, IDT_COUNTDOWN);
    if (g_hMouseHook) { UnhookWindowsHookEx(g_hMouseHook); g_hMouseHook = nullptr; }
    if (g_hKeyHook) { UnhookWindowsHookEx(g_hKeyHook); g_hKeyHook = nullptr; }
    if (g_bBlackActive) DeactivateBlackScreen();
    EnableWindow(g_hBtnStart, TRUE); EnableWindow(g_hBtnStop, FALSE);
    EnableWindow(g_hCombo, TRUE);
    EnableWindow(g_hEditLatency, TRUE); EnableWindow(g_hEditTimeout, TRUE);
    EnableWindow(g_hEditInterval, TRUE); EnableWindow(g_hEditIdle, TRUE);
    EnableWindow(g_hComboUnlock, TRUE); EnableWindow(g_hEditDelay, TRUE);
    SetWindowTextW(g_hStateLabel, L"  STOPPED");
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
static void InitListView(HWND p) {
    INITCOMMONCONTROLSEX ic={sizeof(ic),ICC_LISTVIEW_CLASSES};InitCommonControlsEx(&ic);
    g_hListView=CreateWindowExW(WS_EX_CLIENTEDGE,WC_LISTVIEWW,L"",
        WS_CHILD|WS_VISIBLE|LVS_REPORT|LVS_SINGLESEL|LVS_NOSORTHEADER,
        10,180,WINDOW_W-40,200,p,nullptr,GetModuleHandle(nullptr),nullptr);
    ListView_SetExtendedListViewStyle(g_hListView,
        LVS_EX_FULLROWSELECT|LVS_EX_GRIDLINES|LVS_EX_DOUBLEBUFFER);
    struct C{const wchar_t*t;int w;};
    C cols[]={{L"Time",70},{L"Latency",70},{L"Signal",80},{L"Distance",80},
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
    if (r->state == ProxState::Near) g_nCountdown = g_idleCountdownSec;

    if(r->state==ProxState::Near){wchar_t lb[128];
        swprintf_s(lb,L"  WITHIN 1M   (timer: %ds)",(int)(r->timerRemainMs/1000));
        SetWindowTextW(g_hStateLabel,lb);
    } else SetWindowTextW(g_hStateLabel,L"  FAR");

    wchar_t ev[256]=L"";
    bool inW=(g_reconnectTick>0&&(GetTickCount64()-g_reconnectTick)<WARMUP_MS);
    if(transition&&r->state==ProxState::Near) swprintf_s(ev,L">>> ENTERED 1M (%lums) <<<",r->latencyMs);
    else if(transition&&r->state==ProxState::Far) wcscpy_s(ev,L"<<< LEFT 1M ZONE >>>");
    else if(!r->reachable&&g_consecutiveFails>=3&&(g_consecutiveFails%5)==0)
        swprintf_s(ev,L"unreachable - reconnecting... (fail=%d)",g_consecutiveFails);
    else if(!r->reachable&&g_consecutiveFails>=3)
        swprintf_s(ev,L"unreachable (fail=%d, err=%d)",g_consecutiveFails,r->wsaError);
    else if(!r->reachable) swprintf_s(ev,L"unreachable (err=%d, %lums)",r->wsaError,r->latencyMs);
    else if(r->state==ProxState::Near&&r->latencyMs<=g_nearLatencyMs) swprintf_s(ev,L"near (reset %ds)",(int)(r->timerRemainMs/1000));
    else if(r->state==ProxState::Near&&inW) swprintf_s(ev,L"near (warmup, %lums)",r->latencyMs);
    else if(r->state==ProxState::Near) swprintf_s(ev,L"near (weak %lums, %ds)",r->latencyMs,(int)(r->timerRemainMs/1000));
    else swprintf_s(ev,L"far (%lums)",r->latencyMs);

    LVITEMW lv={};lv.mask=LVIF_TEXT;lv.iItem=0;lv.pszText=r->timeStr;
    ListView_InsertItem(g_hListView,&lv);
    wchar_t lat[32];if(r->reachable)swprintf_s(lat,L"%lu ms",r->latencyMs);else wcscpy_s(lat,L"timeout");
    int lev=LatencyToLevel(r->latencyMs,r->reachable);
    wchar_t sg[32];swprintf_s(sg,L"%s %d",LevelBar(lev),lev);
    wchar_t di[32];if(r->reachable)wcscpy_s(di,LatencyToDist(r->latencyMs));else wcscpy_s(di,L"-");
    wchar_t st[16];wcscpy_s(st,StateStr(r->state));
    wchar_t tm[16];if(r->state==ProxState::Near)swprintf_s(tm,L"%ds",(int)(r->timerRemainMs/1000));else wcscpy_s(tm,L"-");
    ListView_SetItemText(g_hListView,0,1,lat);ListView_SetItemText(g_hListView,0,2,sg);
    ListView_SetItemText(g_hListView,0,3,di);ListView_SetItemText(g_hListView,0,4,st);
    ListView_SetItemText(g_hListView,0,5,tm);ListView_SetItemText(g_hListView,0,6,ev);
    int cnt=ListView_GetItemCount(g_hListView);if(cnt>500)ListView_DeleteItem(g_hListView,cnt-1);

    wchar_t status[300];
    swprintf_s(status,L"  \"%s\"  |  %s  |  Latency: %lu ms  |  Near<=%lu ms  |  Idle: %ds",
        g_targetName.c_str(),StateStr(r->state),r->latencyMs,g_nearLatencyMs,g_nCountdown);
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
        HWND hl=CreateWindowExW(0,L"STATIC",L"Paired device:",WS_CHILD|WS_VISIBLE,
            10,15,110,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hCombo=CreateWindowExW(0,L"COMBOBOX",L"",WS_CHILD|WS_VISIBLE|CBS_DROPDOWNLIST|WS_VSCROLL,
            120,12,400,200,hWnd,(HMENU)(UINT_PTR)ID_COMBO,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"BUTTON",L"Refresh",WS_CHILD|WS_VISIBLE,
            530,10,70,28,hWnd,(HMENU)(UINT_PTR)ID_REFRESH,GetModuleHandle(nullptr),nullptr);
        g_hBtnStart=CreateWindowExW(0,L"BUTTON",L"Start",WS_CHILD|WS_VISIBLE,
            610,10,80,28,hWnd,(HMENU)(UINT_PTR)ID_START,GetModuleHandle(nullptr),nullptr);
        g_hBtnStop=CreateWindowExW(0,L"BUTTON",L"Stop",WS_CHILD|WS_VISIBLE|WS_DISABLED,
            700,10,60,28,hWnd,(HMENU)(UINT_PTR)ID_STOP,GetModuleHandle(nullptr),nullptr);

        g_hStateLabel=CreateWindowExW(WS_EX_CLIENTEDGE,L"STATIC",L"  STOPPED",
            WS_CHILD|WS_VISIBLE|SS_LEFT|SS_CENTERIMAGE,
            10,48,570,38,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"BUTTON",L"Clear",WS_CHILD|WS_VISIBLE,
            590,52,55,28,hWnd,(HMENU)(UINT_PTR)ID_CLEAR,GetModuleHandle(nullptr),nullptr);
        g_hBtnReconnect=CreateWindowExW(0,L"BUTTON",L"Reconnect",WS_CHILD|WS_VISIBLE,
            650,52,75,28,hWnd,(HMENU)(UINT_PTR)ID_RECONNECT,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"BUTTON",L"BT",WS_CHILD|WS_VISIBLE,
            730,52,40,28,hWnd,(HMENU)(UINT_PTR)ID_BT_SETTINGS,GetModuleHandle(nullptr),nullptr);

        // Row 1: BT settings
        CreateWindowExW(0,L"STATIC",L"Near<=",WS_CHILD|WS_VISIBLE,10,94,48,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hEditLatency=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"200",WS_CHILD|WS_VISIBLE|ES_NUMBER|ES_CENTER,
            58,92,45,22,hWnd,(HMENU)(UINT_PTR)ID_EDIT_LATENCY,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"ms  Timeout:",WS_CHILD|WS_VISIBLE,108,94,85,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hEditTimeout=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"5",WS_CHILD|WS_VISIBLE|ES_NUMBER|ES_CENTER,
            193,92,30,22,hWnd,(HMENU)(UINT_PTR)ID_EDIT_TIMEOUT,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"s  Interval:",WS_CHILD|WS_VISIBLE,228,94,80,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hEditInterval=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"2",WS_CHILD|WS_VISIBLE|ES_NUMBER|ES_CENTER,
            308,92,25,22,hWnd,(HMENU)(UINT_PTR)ID_EDIT_INTERVAL,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"s",WS_CHILD|WS_VISIBLE,338,94,15,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);

        // Row 2: Idle + Unlock
        CreateWindowExW(0,L"STATIC",L"Idle:",WS_CHILD|WS_VISIBLE,10,118,38,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hEditIdle=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"20",WS_CHILD|WS_VISIBLE|ES_NUMBER|ES_CENTER,
            48,116,35,22,hWnd,(HMENU)(UINT_PTR)ID_EDIT_IDLE,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"s",WS_CHILD|WS_VISIBLE,88,118,12,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"Unlock:",WS_CHILD|WS_VISIBLE,108,118,50,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hComboUnlock=CreateWindowExW(0,L"COMBOBOX",L"",WS_CHILD|WS_VISIBLE|CBS_DROPDOWNLIST,
            158,115,65,120,hWnd,(HMENU)(UINT_PTR)ID_COMBO_UNLOCK,GetModuleHandle(nullptr),nullptr);
        SendMessageW(g_hComboUnlock,CB_ADDSTRING,0,(LPARAM)L"Auto");
        SendMessageW(g_hComboUnlock,CB_ADDSTRING,0,(LPARAM)L"Manual");
        SendMessageW(g_hComboUnlock,CB_SETCURSEL,0,0);
        CreateWindowExW(0,L"STATIC",L"Delay:",WS_CHILD|WS_VISIBLE,230,118,45,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hEditDelay=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"0",WS_CHILD|WS_VISIBLE|ES_NUMBER|ES_CENTER,
            275,116,25,22,hWnd,(HMENU)(UINT_PTR)ID_EDIT_DELAY,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"s",WS_CHILD|WS_VISIBLE,303,118,12,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"BUTTON",L"Black Now",WS_CHILD|WS_VISIBLE,325,116,75,22,hWnd,
            (HMENU)(UINT_PTR)ID_BTN_BLACKNOW,GetModuleHandle(nullptr),nullptr);
        g_hCountdownLabel=CreateWindowExW(0,L"STATIC",L"",WS_CHILD|WS_VISIBLE|SS_LEFT,
            410,118,350,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);

        // Row 3: Image paths (personal edition)
        CreateWindowExW(0,L"STATIC",L"Center image:",WS_CHILD|WS_VISIBLE,10,142,95,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hLabelCenter=CreateWindowExW(0,L"STATIC",L"(default)",WS_CHILD|WS_VISIBLE|SS_LEFT,
            105,142,420,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"BUTTON",L"Browse",WS_CHILD|WS_VISIBLE,530,140,60,22,hWnd,
            (HMENU)(UINT_PTR)ID_BTN_CENTER_IMG,GetModuleHandle(nullptr),nullptr);

        CreateWindowExW(0,L"STATIC",L"Banner image:",WS_CHILD|WS_VISIBLE,10,166,95,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hLabelBanner=CreateWindowExW(0,L"STATIC",L"(default)",WS_CHILD|WS_VISIBLE|SS_LEFT,
            105,166,420,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"BUTTON",L"Browse",WS_CHILD|WS_VISIBLE,530,164,60,22,hWnd,
            (HMENU)(UINT_PTR)ID_BTN_BANNER_IMG,GetModuleHandle(nullptr),nullptr);

        // Enterprise button
        CreateWindowExW(0,L"BUTTON",L"\xAE30\xC5C5\xC6A9 \xB458\xB7EC\xBCF4\xAE30",  // 기업용 둘러보기
            WS_CHILD|WS_VISIBLE,600,140,160,46,hWnd,
            (HMENU)(UINT_PTR)ID_BTN_ENTERPRISE,GetModuleHandle(nullptr),nullptr);

        // ListView (Y=190)
        InitListView(hWnd);

        // Chart
        {WNDCLASSEXW wc={};wc.cbSize=sizeof(wc);wc.lpfnWndProc=ChartProc;
         wc.hInstance=GetModuleHandle(nullptr);wc.hCursor=LoadCursor(nullptr,IDC_ARROW);
         wc.lpszClassName=CHART_CLS;RegisterClassExW(&wc);}
        g_hChart=CreateWindowExW(WS_EX_CLIENTEDGE,CHART_CLS,L"",WS_CHILD|WS_VISIBLE,
            10,450,WINDOW_W-40,CHART_H_UI,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);

        // BlackScreen classes
        RegisterBlackScreenClasses(GetModuleHandle(nullptr));

        // Status
        g_hStatus=CreateWindowExW(0,L"STATIC",L"  Select a paired device and press Start",
            WS_CHILD|WS_VISIBLE|SS_LEFT|SS_SUNKEN,0,WINDOW_H-55,WINDOW_W,25,
            hWnd,nullptr,GetModuleHandle(nullptr),nullptr);

        // Fonts
        g_hFont=CreateFontW(14,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Consolas");
        g_hFontBold=CreateFontW(14,0,0,0,FW_BOLD,0,0,0,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
        g_hFontBig=CreateFontW(24,0,0,0,FW_BOLD,0,0,0,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
        g_hFontSmall=CreateFontW(11,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Consolas");
        g_hBrushNear=CreateSolidBrush(RGB(0,180,0));
        g_hBrushFar=CreateSolidBrush(RGB(180,180,180));

        EnumChildWindows(hWnd,[](HWND h,LPARAM f)->BOOL{
            SendMessage(h,WM_SETFONT,(WPARAM)f,TRUE);return TRUE;},(LPARAM)g_hFont);
        SendMessage(hl,WM_SETFONT,(WPARAM)g_hFontBold,TRUE);
        SendMessage(g_hStateLabel,WM_SETFONT,(WPARAM)g_hFontBig,TRUE);

        // Load config and apply to UI
        AppConfig cfg;
        if (LoadAppConfig(cfg)) {
            g_targetAddr = cfg.btAddress;
            g_nearLatencyMs = cfg.nearLatencyMs;
            g_keepAliveSec = cfg.keepAliveSec;
            g_scanIntervalSec = cfg.scanIntervalSec;
            g_idleCountdownSec = cfg.idleCountdownSec;
            g_unlockAuto = cfg.unlockAuto;
            g_unlockDelaySec = cfg.unlockDelaySec;
            g_centerImagePath = cfg.centerImagePath;
            g_bannerImagePath = cfg.bannerImagePath;

            wchar_t buf[16];
            swprintf_s(buf, L"%lu", g_nearLatencyMs); SetWindowTextW(g_hEditLatency, buf);
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
                if (g_proxState == ProxState::Near) {
                    g_nCountdown = g_idleCountdownSec; // suppress when nearby
                } else {
                    // FAR: count down to black screen
                    if (g_nCountdown > 0) g_nCountdown--;
                    if (g_nCountdown == 0) ActivateBlackScreen();
                }
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
                swprintf_s(cdl, L"  LOCKED - unlock in %d sec", g_unlockTimer);
            else if (g_bBlackActive)
                swprintf_s(cdl, L"  LOCKED (%s)", g_unlockAuto ? L"auto" : L"manual");
            else if (g_proxState == ProxState::Near) wcscpy_s(cdl, L"  Screen saver: suppressed (NEAR)");
            else swprintf_s(cdl, L"  Screen saver in: %d sec", g_nCountdown);
            SetWindowTextW(g_hCountdownLabel, cdl);
            UpdateOverlayState();
        }
        break;

    case WM_CTLCOLORSTATIC: {
        HDC hdc=(HDC)wParam;HWND hc=(HWND)lParam;
        if(hc==g_hStateLabel&&g_monitoring){
            if(g_proxState==ProxState::Near){
                SetTextColor(hdc,RGB(255,255,255));SetBkColor(hdc,RGB(0,180,0));return(LRESULT)g_hBrushNear;
            } else {
                SetTextColor(hdc,RGB(60,60,60));SetBkColor(hdc,RGB(180,180,180));return(LRESULT)g_hBrushFar;
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
        case ID_BTN_ENTERPRISE:
            ShellExecuteW(nullptr, L"open", L"https://icesgg.github.io/smartscreen/", nullptr, nullptr, SW_SHOW);
            break;
        }break;

    case WM_SCAN_RESULT:{
        auto*r=(ProbeResult*)lParam;OnResult(r);
        InvalidateRect(g_hStateLabel,nullptr,TRUE);delete r;break;
    }

    case WM_SIZE:{
        int w=LOWORD(lParam),h=HIWORD(lParam);
        int sH=25,cH=CHART_H_UI,cY=h-sH-cH-8;
        int lH=cY-190-4;if(lH<60)lH=60;
        if(g_hStateLabel)MoveWindow(g_hStateLabel,10,48,w-210,38,TRUE);
        if(g_hListView)MoveWindow(g_hListView,10,190,w-20,lH,TRUE);
        if(g_hChart)MoveWindow(g_hChart,10,cY,w-20,cH,TRUE);
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
        if(g_hBrushNear)DeleteObject(g_hBrushNear);if(g_hBrushFar)DeleteObject(g_hBrushFar);
        if(g_hFontOvl)DeleteObject(g_hFontOvl);if(g_hFontOvlBtn)DeleteObject(g_hFontOvlBtn);
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
        L"SmartScreen - Settings",
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
    SetLayeredWindowAttributes(g_hOverlay, 0, 128, LWA_ALPHA);

    g_hFontOvl = CreateFontW(18, 0, 0, 0, FW_BOLD, 0, 0, 0,
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
