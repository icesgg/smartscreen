// SmartScreen - Bluetooth Proximity Monitor + Screen Saver
//
// 1. First launch: setup wizard to select paired BT device
// 2. After setup: BT proximity monitoring + idle screensaver
// 3. Black screen activates only when: user idle AND device FAR
// 4. Black screen auto-deactivates when device returns to NEAR
//
// Dual-socket approach:
//   Socket 1 (SerialPort): persistent connection (iPhone "connected")
//   Socket 2 (OBEX Push):  connect/close every 2s for latency

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "bthprops.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "shell32.lib")

#include <winsock2.h>
#include <ws2bth.h>
#include <bluetoothapis.h>
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <string>
#include <vector>
#include <algorithm>
#include <cstdio>
#include <cmath>

// ---------------------------------------------------------------------------
// IDs
// ---------------------------------------------------------------------------
static constexpr int WINDOW_W = 820;
static constexpr int WINDOW_H = 720;

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
static constexpr UINT WM_SCAN_RESULT = WM_USER + 100;

// BlackScreen
static constexpr int IDC_BTN_RELEASE = 301;
static constexpr int IDT_COUNTDOWN   = 10;
#define BLACKSCREEN_CLASS L"BSBlackWnd"

// Classic BT
static constexpr DWORD RFCOMM_CONNECT_TIMEOUT_MS = 5000;

// User-configurable
static DWORD  g_nearLatencyMs    = 300;
static DWORD  g_keepAliveSec     = 5;
static DWORD  g_scanIntervalSec  = 2;
static int    g_idleCountdownSec = 20;    // screensaver idle seconds

// ---------------------------------------------------------------------------
// Enums & structs
// ---------------------------------------------------------------------------
enum class ProxState { Far, Near };

static const wchar_t* StateStr(ProxState s) {
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

// Chart
static constexpr DWORD CHART_WINDOW_MS = 30 * 60 * 1000;
static constexpr int   CHART_HEIGHT    = 80;
struct FarEvent { ULONGLONG tickMs; SYSTEMTIME st; };
static constexpr wchar_t CHART_CLASS[] = L"SmartScreenChart";

// Warmup
static ULONGLONG g_reconnectTick = 0;
static constexpr DWORD WARMUP_MS = 120000;

// ---------------------------------------------------------------------------
// Globals - UI
// ---------------------------------------------------------------------------
static HWND   g_hWnd          = nullptr;
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
static HWND   g_hChart        = nullptr;
static HFONT  g_hFont         = nullptr;
static HFONT  g_hFontBold     = nullptr;
static HFONT  g_hFontBig      = nullptr;
static HFONT  g_hFontSmall    = nullptr;
static HBRUSH g_hBrushNear    = nullptr;
static HBRUSH g_hBrushFar     = nullptr;

// ---------------------------------------------------------------------------
// Globals - BT state
// ---------------------------------------------------------------------------
static std::vector<PairedDevice> g_paired;
static int           g_selectedIdx  = -1;
static BTH_ADDR      g_targetAddr   = 0;
static std::wstring  g_targetName;
static bool          g_monitoring   = false;
static HANDLE        g_hThread      = nullptr;
static HANDLE        g_hStopEvent   = nullptr;
static int           g_logCount     = 0;

static ProxState g_proxState     = ProxState::Far;
static ULONGLONG g_lastNearTick  = 0;

static std::vector<FarEvent> g_farEvents;

// ---------------------------------------------------------------------------
// Globals - BlackScreen / Idle
// ---------------------------------------------------------------------------
static HWND      g_hBlackScreen  = nullptr;
static HHOOK     g_hMouseHook    = nullptr;
static HHOOK     g_hKeyHook      = nullptr;
static int       g_nCountdown    = 20;
static bool      g_bBlackActive  = false;

// ---------------------------------------------------------------------------
// Config persistence
// ---------------------------------------------------------------------------
static std::wstring GetConfigPath() {
    wchar_t appdata[MAX_PATH];
    SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, appdata);
    std::wstring dir = std::wstring(appdata) + L"\\SmartScreen";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\config.dat";
}

static bool LoadConfig(BTH_ADDR& addr) {
    FILE* f = nullptr;
    _wfopen_s(&f, GetConfigPath().c_str(), L"rb");
    if (!f) return false;
    bool ok = fread(&addr, sizeof(addr), 1, f) == 1;
    fclose(f);
    return ok && addr != 0;
}

static void SaveConfig(BTH_ADDR addr) {
    FILE* f = nullptr;
    _wfopen_s(&f, GetConfigPath().c_str(), L"wb");
    if (!f) return;
    fwrite(&addr, sizeof(addr), 1, f);
    fclose(f);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static std::wstring FmtAddr(BTH_ADDR a) {
    wchar_t b[32];
    swprintf_s(b, L"%02X:%02X:%02X:%02X:%02X:%02X",
        (int)((a>>40)&0xFF),(int)((a>>32)&0xFF),(int)((a>>24)&0xFF),
        (int)((a>>16)&0xFF),(int)((a>>8)&0xFF),(int)(a&0xFF));
    return b;
}

static void NowStr(wchar_t* b, int n) {
    SYSTEMTIME s; GetLocalTime(&s);
    swprintf_s(b, n, L"%02d:%02d:%02d", s.wHour, s.wMinute, s.wSecond);
}

static int LatencyToLevel(DWORD ms, bool reachable) {
    if (!reachable) return 0;
    if (ms <= g_nearLatencyMs) return 4;
    return 3;
}

static const wchar_t* LevelBar(int lv) {
    switch (lv) {
    case 5: return L"\u2588\u2588\u2588\u2588\u2588";
    case 4: return L"\u2588\u2588\u2588\u2588\u2591";
    case 3: return L"\u2588\u2588\u2588\u2591\u2591";
    case 2: return L"\u2588\u2588\u2591\u2591\u2591";
    case 1: return L"\u2588\u2591\u2591\u2591\u2591";
    default: return L"\u2591\u2591\u2591\u2591\u2591";
    }
}

static const wchar_t* LatencyToDist(DWORD ms) {
    if (ms < 150) return L"< 1m";
    if (ms < 300) return L"~1-2m";
    if (ms < 500) return L"~2-3m";
    if (ms < 1000) return L"~3-5m";
    if (ms < 2000) return L"~5-10m";
    return L"> 10m";
}

// ---------------------------------------------------------------------------
// BlackScreen: activation / deactivation
// ---------------------------------------------------------------------------
static LRESULT CALLBACK BlackScreenProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
    case WM_CREATE: {
        int sw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        HWND hBtn = CreateWindowW(L"BUTTON", L"해제",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            sw - 125, 15, 110, 42,
            hWnd, (HMENU)(UINT_PTR)IDC_BTN_RELEASE, GetModuleHandle(nullptr), nullptr);
        if (g_hFont) SendMessage(hBtn, WM_SETFONT, (WPARAM)g_hFont, TRUE);
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wParam) == IDC_BTN_RELEASE) {
            g_bBlackActive = false;
            g_nCountdown = g_idleCountdownSec;
            DestroyWindow(hWnd);
            g_hBlackScreen = nullptr;
            if (g_hCountdownLabel) InvalidateRect(g_hCountdownLabel, nullptr, TRUE);
        }
        return 0;
    case WM_ERASEBKGND: {
        HDC hdc = (HDC)wParam; RECT rc; GetClientRect(hWnd, &rc);
        FillRect(hdc, &rc, (HBRUSH)GetStockObject(BLACK_BRUSH));
        return 1;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC hdc = BeginPaint(hWnd, &ps);
        RECT rc; GetClientRect(hWnd, &rc);
        FillRect(hdc, &rc, (HBRUSH)GetStockObject(BLACK_BRUSH));
        EndPaint(hWnd, &ps); return 0;
    }
    case WM_CLOSE: return 0;
    }
    return DefWindowProc(hWnd, uMsg, wParam, lParam);
}

static void ActivateBlackScreen() {
    if (g_bBlackActive) return;
    if (g_proxState == ProxState::Near) {
        g_nCountdown = g_idleCountdownSec; // suppress
        return;
    }
    g_bBlackActive = true;

    int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);

    g_hBlackScreen = CreateWindowExW(WS_EX_TOPMOST, BLACKSCREEN_CLASS, L"",
        WS_POPUP, x, y, w, h, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
    ShowWindow(g_hBlackScreen, SW_SHOW);
    SetForegroundWindow(g_hBlackScreen);
}

static void DeactivateBlackScreen() {
    if (!g_bBlackActive) return;
    g_bBlackActive = false;
    g_nCountdown = g_idleCountdownSec;
    if (g_hBlackScreen) {
        DestroyWindow(g_hBlackScreen);
        g_hBlackScreen = nullptr;
    }
    if (g_hCountdownLabel) InvalidateRect(g_hCountdownLabel, nullptr, TRUE);
}

// ---------------------------------------------------------------------------
// Idle detection hooks
// ---------------------------------------------------------------------------
static void ResetCountdown() {
    g_nCountdown = g_idleCountdownSec;
    if (g_bBlackActive) DeactivateBlackScreen();
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
// Reconnect
// ---------------------------------------------------------------------------
static bool IsOsConnected(BTH_ADDR target) {
    BLUETOOTH_FIND_RADIO_PARAMS rp = { sizeof(rp) };
    HANDLE hRadio = nullptr;
    HBLUETOOTH_RADIO_FIND hFind = BluetoothFindFirstRadio(&rp, &hRadio);
    if (!hFind) return false;
    BLUETOOTH_DEVICE_INFO di = {}; di.dwSize = sizeof(di); di.Address.ullLong = target;
    DWORD ret = BluetoothGetDeviceInfo(hRadio, &di);
    CloseHandle(hRadio); BluetoothFindRadioClose(hFind);
    return (ret == ERROR_SUCCESS && di.fConnected);
}

static void ReconnectDevice(BTH_ADDR target) {
    BLUETOOTH_FIND_RADIO_PARAMS rp = { sizeof(rp) };
    HANDLE hRadio = nullptr;
    HBLUETOOTH_RADIO_FIND hFind = BluetoothFindFirstRadio(&rp, &hRadio);
    if (!hFind) return;

    BLUETOOTH_DEVICE_SEARCH_PARAMS sp = {};
    sp.dwSize = sizeof(sp);
    sp.fReturnAuthenticated = TRUE; sp.fReturnRemembered = TRUE;
    sp.fReturnConnected = TRUE; sp.fIssueInquiry = TRUE;
    sp.hRadio = hRadio; sp.cTimeoutMultiplier = 2;
    BLUETOOTH_DEVICE_INFO di = {}; di.dwSize = sizeof(di);
    HBLUETOOTH_DEVICE_FIND hDev = BluetoothFindFirstDevice(&sp, &di);
    if (hDev) { do { } while (BluetoothFindNextDevice(hDev, &di)); BluetoothFindDeviceClose(hDev); }

    di = {}; di.dwSize = sizeof(di); di.Address.ullLong = target;
    BluetoothGetDeviceInfo(hRadio, &di);
    BluetoothAuthenticateDeviceEx(nullptr, hRadio, &di, nullptr, MITMProtectionNotRequiredBonding);
    Sleep(2000);
    GUID hfp = HandsfreeServiceClass_UUID;
    BluetoothSetServiceState(hRadio, &di, &hfp, BLUETOOTH_SERVICE_ENABLE);
    GUID a2dp = AudioSinkServiceClass_UUID;
    BluetoothSetServiceState(hRadio, &di, &a2dp, BLUETOOTH_SERVICE_ENABLE);
    CloseHandle(hRadio); BluetoothFindRadioClose(hFind);
}

static DWORD WINAPI ReconnectThread(LPVOID) {
    ReconnectDevice(g_targetAddr);
    g_reconnectTick = GetTickCount64();
    EnableWindow(g_hBtnReconnect, TRUE);
    SetWindowTextW(g_hBtnReconnect, L"Reconnect");
    return 0;
}

// ---------------------------------------------------------------------------
// Dual-socket BT probe
// ---------------------------------------------------------------------------
static int g_consecutiveFails = 0;
static SOCKET g_persistSocket = INVALID_SOCKET;

static bool IsSocketAlive() {
    if (g_persistSocket == INVALID_SOCKET) return false;
    char buf;
    int r = recv(g_persistSocket, &buf, 1, MSG_PEEK);
    if (r == 0 || (r == SOCKET_ERROR && WSAGetLastError() != WSAEWOULDBLOCK
                                     && WSAGetLastError() != WSAETIMEDOUT)) {
        closesocket(g_persistSocket); g_persistSocket = INVALID_SOCKET; return false;
    }
    return true;
}

static DWORD MeasureLatency(BTH_ADDR target) {
    SOCKET s = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
    if (s == INVALID_SOCKET) return 9999;
    DWORD to = RFCOMM_CONNECT_TIMEOUT_MS;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (char*)&to, sizeof(to));
    SOCKADDR_BTH sa = {};
    sa.addressFamily = AF_BTH; sa.btAddr = target;
    sa.serviceClassId = OBEXObjectPushServiceClass_UUID; sa.port = 0;
    LARGE_INTEGER freq, t1, t2;
    QueryPerformanceFrequency(&freq); QueryPerformanceCounter(&t1);
    connect(s, (SOCKADDR*)&sa, sizeof(sa));
    QueryPerformanceCounter(&t2);
    closesocket(s);
    return (DWORD)((t2.QuadPart - t1.QuadPart) * 1000 / freq.QuadPart);
}

static bool EstablishPersist(BTH_ADDR target, DWORD& outLatency, int& outErr) {
    SOCKET s = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
    if (s == INVALID_SOCKET) { outErr = WSAGetLastError(); return false; }
    DWORD to = RFCOMM_CONNECT_TIMEOUT_MS;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (char*)&to, sizeof(to));
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char*)&to, sizeof(to));
    SOCKADDR_BTH sa = {};
    sa.addressFamily = AF_BTH; sa.btAddr = target;
    sa.serviceClassId = SerialPortServiceClass_UUID; sa.port = 0;
    LARGE_INTEGER freq, t1, t2;
    QueryPerformanceFrequency(&freq); QueryPerformanceCounter(&t1);
    int ret = connect(s, (SOCKADDR*)&sa, sizeof(sa));
    QueryPerformanceCounter(&t2);
    outLatency = (DWORD)((t2.QuadPart - t1.QuadPart) * 1000 / freq.QuadPart);
    if (ret == 0) {
        DWORD rv = 100; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char*)&rv, sizeof(rv));
        g_persistSocket = s; return true;
    }
    outErr = WSAGetLastError(); closesocket(s);
    return (outErr == WSAECONNREFUSED || outErr == WSAECONNRESET);
}

static void DoProbe(BTH_ADDR target, bool& outReachable, DWORD& outLatency, int& outErr) {
    outReachable = false; outLatency = 0; outErr = 0;
    if (g_persistSocket != INVALID_SOCKET) {
        if (IsSocketAlive()) {
            outReachable = true;
            outLatency = MeasureLatency(target);
            g_consecutiveFails = 0;
            return;
        }
    }
    bool connected = EstablishPersist(target, outLatency, outErr);
    if (connected || outErr == WSAECONNREFUSED || outErr == WSAECONNRESET) {
        outReachable = true;
        if (g_consecutiveFails >= 3) g_reconnectTick = GetTickCount64();
        g_consecutiveFails = 0;
    } else {
        g_consecutiveFails++;
    }
}

static void CloseProbeSocket() {
    if (g_persistSocket != INVALID_SOCKET) { closesocket(g_persistSocket); g_persistSocket = INVALID_SOCKET; }
}

// ---------------------------------------------------------------------------
// Enumerate paired devices
// ---------------------------------------------------------------------------
static void EnumPaired() {
    g_paired.clear();
    BLUETOOTH_FIND_RADIO_PARAMS rp = { sizeof(rp) };
    HANDLE hR = nullptr;
    HBLUETOOTH_RADIO_FIND hF = BluetoothFindFirstRadio(&rp, &hR);
    if (!hF) return;
    do {
        BLUETOOTH_DEVICE_SEARCH_PARAMS sp = {}; sp.dwSize = sizeof(sp);
        sp.fReturnAuthenticated = TRUE; sp.fReturnRemembered = TRUE;
        sp.fReturnConnected = TRUE; sp.fIssueInquiry = FALSE; sp.hRadio = hR;
        BLUETOOTH_DEVICE_INFO di = {}; di.dwSize = sizeof(di);
        HBLUETOOTH_DEVICE_FIND hD = BluetoothFindFirstDevice(&sp, &di);
        if (hD) {
            do { g_paired.push_back({ di.Address.ullLong, di.szName, di.fConnected != 0 }); }
            while (BluetoothFindNextDevice(hD, &di));
            BluetoothFindDeviceClose(hD);
        }
        CloseHandle(hR); hR = nullptr;
    } while (BluetoothFindNextRadio(hF, &hR));
    BluetoothFindRadioClose(hF);
}

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
    // Auto-select saved device
    for (size_t i = 0; i < g_paired.size(); i++) {
        if (g_paired[i].address == g_targetAddr) {
            SendMessageW(g_hCombo, CB_SETCURSEL, i, 0);
            EnableWindow(g_hBtnStart, TRUE);
            return;
        }
    }
    SendMessageW(g_hCombo, CB_SETCURSEL, 0, 0);
    EnableWindow(g_hBtnStart, TRUE);
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
            if (g_proxState == ProxState::Near) {
                if ((now - g_lastNearTick) >= (ULONGLONG)g_keepAliveSec * 1000)
                    g_proxState = ProxState::Far;
            }
        }

        auto* r = new ProbeResult{};
        r->reachable = reachable; r->latencyMs = latency; r->wsaError = wsaErr;
        r->state = g_proxState; r->prevState = prev;
        NowStr(r->timeStr, _countof(r->timeStr));
        if (g_proxState == ProxState::Near) {
            DWORD since = (DWORD)(now - g_lastNearTick);
            DWORD keepMs = g_keepAliveSec * 1000;
            r->timerRemainMs = (since < keepMs) ? (keepMs - since) : 0;
        } else { r->timerRemainMs = 0; }

        PostMessage(g_hWnd, WM_SCAN_RESULT, 0, (LPARAM)r);

        if (WaitForSingleObject(g_hStopEvent, g_scanIntervalSec * 1000) == WAIT_OBJECT_0) break;
    }
    return 0;
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

    g_selectedIdx = sel;
    g_targetAddr = g_paired[sel].address;
    g_targetName = g_paired[sel].name;
    g_logCount = 0;
    SaveConfig(g_targetAddr);

    g_hStopEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    g_hThread = CreateThread(nullptr, 0, ScanThread, nullptr, 0, nullptr);
    g_monitoring = true;

    // Install idle hooks
    g_hMouseHook = SetWindowsHookExW(WH_MOUSE_LL, LLMouseProc, nullptr, 0);
    g_hKeyHook = SetWindowsHookExW(WH_KEYBOARD_LL, LLKeyProc, nullptr, 0);
    // Start countdown timer
    SetTimer(g_hWnd, IDT_COUNTDOWN, 1000, nullptr);

    EnableWindow(g_hBtnStart, FALSE); EnableWindow(g_hBtnStop, TRUE);
    EnableWindow(g_hCombo, FALSE);
    EnableWindow(g_hEditLatency, FALSE); EnableWindow(g_hEditTimeout, FALSE);
    EnableWindow(g_hEditInterval, FALSE); EnableWindow(g_hEditIdle, FALSE);
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
    SetWindowTextW(g_hStateLabel, L"  STOPPED");
    SetWindowTextW(g_hStatus, L"  Stopped");
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
    if(cW<50||cH<20){EndPaint(hWnd,&ps);return;}
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
        u.QuadPart-=(ULONGLONG)m*60000*10000;
        ft.dwLowDateTime=u.LowPart;ft.dwHighDateTime=u.HighPart;
        SYSTEMTIME sl;FileTimeToSystemTime(&ft,&sl);
        wchar_t lb[16];swprintf_s(lb,L"%02d:%02d",sl.wHour,sl.wMinute);
        TextOutW(mem,x-15,mT+cH+3,lb,(int)wcslen(lb));}
    DeleteObject(gp);
    SetTextColor(mem,RGB(0,200,0));TextOutW(mem,4,mT+2,L"NEAR",4);
    SetTextColor(mem,RGB(220,60,60));TextOutW(mem,4,mT+cH-16,L"FAR",3);
    int bY=mT+4,bH=cH-8;
    if(g_monitoring){HBRUSH nb=CreateSolidBrush(RGB(0,120,0));
        RECT br={mL+1,bY,mL+cW-1,bY+bH};FillRect(mem,&br,nb);DeleteObject(nb);}
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
        10,160,WINDOW_W-40,200,p,nullptr,GetModuleHandle(nullptr),nullptr);
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
// Process probe result
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
    }
    if(g_hChart)InvalidateRect(g_hChart,nullptr,FALSE);

    // Auto-deactivate black screen when device returns to NEAR
    if (transition && r->state == ProxState::Near && g_bBlackActive)
        DeactivateBlackScreen();
    // If NEAR, suppress countdown
    if (r->state == ProxState::Near)
        g_nCountdown = g_idleCountdownSec;

    if(r->state==ProxState::Near){
        wchar_t lb[128];
        swprintf_s(lb,L"  WITHIN 1M   (timer: %ds)",(int)(r->timerRemainMs/1000));
        SetWindowTextW(g_hStateLabel,lb);
    } else { SetWindowTextW(g_hStateLabel,L"  FAR"); }

    wchar_t ev[256]=L"";
    bool inWarmupNow=(g_reconnectTick>0&&(GetTickCount64()-g_reconnectTick)<WARMUP_MS);
    if(transition&&r->state==ProxState::Near)
        swprintf_s(ev,L">>> ENTERED 1M (%lums) <<<",r->latencyMs);
    else if(transition&&r->state==ProxState::Far) wcscpy_s(ev,L"<<< LEFT 1M ZONE >>>");
    else if(!r->reachable&&g_consecutiveFails>=3&&(g_consecutiveFails%5)==0)
        swprintf_s(ev,L"unreachable - reconnecting... (fail=%d)",g_consecutiveFails);
    else if(!r->reachable&&g_consecutiveFails>=3)
        swprintf_s(ev,L"unreachable (fail=%d, err=%d)",g_consecutiveFails,r->wsaError);
    else if(!r->reachable)
        swprintf_s(ev,L"unreachable (err=%d, %lums)",r->wsaError,r->latencyMs);
    else if(r->state==ProxState::Near&&r->latencyMs<=g_nearLatencyMs)
        swprintf_s(ev,L"near (reset %ds)",(int)(r->timerRemainMs/1000));
    else if(r->state==ProxState::Near&&inWarmupNow)
        swprintf_s(ev,L"near (warmup %ds, %lums)",
            (int)((WARMUP_MS-(GetTickCount64()-g_reconnectTick))/1000),r->latencyMs);
    else if(r->state==ProxState::Near)
        swprintf_s(ev,L"near (weak %lums, %ds)",r->latencyMs,(int)(r->timerRemainMs/1000));
    else swprintf_s(ev,L"far (%lums)",r->latencyMs);

    LVITEMW lv={};lv.mask=LVIF_TEXT;lv.iItem=0;lv.pszText=r->timeStr;
    ListView_InsertItem(g_hListView,&lv);
    wchar_t lat[32];if(r->reachable)swprintf_s(lat,L"%lu ms",r->latencyMs);else wcscpy_s(lat,L"timeout");
    int lev=LatencyToLevel(r->latencyMs,r->reachable);
    wchar_t sg[32];swprintf_s(sg,L"%s %d",LevelBar(lev),lev);
    wchar_t di[32];if(r->reachable)wcscpy_s(di,LatencyToDist(r->latencyMs));else wcscpy_s(di,L"-");
    wchar_t st[16];wcscpy_s(st,StateStr(r->state));
    wchar_t tm[16];if(r->state==ProxState::Near)swprintf_s(tm,L"%ds",(int)(r->timerRemainMs/1000));
    else wcscpy_s(tm,L"-");
    ListView_SetItemText(g_hListView,0,1,lat);ListView_SetItemText(g_hListView,0,2,sg);
    ListView_SetItemText(g_hListView,0,3,di);ListView_SetItemText(g_hListView,0,4,st);
    ListView_SetItemText(g_hListView,0,5,tm);ListView_SetItemText(g_hListView,0,6,ev);
    int cnt=ListView_GetItemCount(g_hListView);if(cnt>500)ListView_DeleteItem(g_hListView,cnt-1);

    wchar_t status[300];
    swprintf_s(status,L"  \"%s\"  |  %s  |  Latency: %lu ms  |  Near<=%lu ms  |  Idle: %ds",
        g_targetName.c_str(),StateStr(r->state),r->latencyMs,g_nearLatencyMs,g_nCountdown);
    SetWindowTextW(g_hStatus,status);
}

// ---------------------------------------------------------------------------
// WndProc
// ---------------------------------------------------------------------------
static LRESULT CALLBACK WndProc(HWND hWnd,UINT msg,WPARAM wParam,LPARAM lParam){
    switch(msg){
    case WM_CREATE:{
        HWND hl=CreateWindowExW(0,L"STATIC",L"Paired device:",
            WS_CHILD|WS_VISIBLE,10,15,110,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hCombo=CreateWindowExW(0,L"COMBOBOX",L"",
            WS_CHILD|WS_VISIBLE|CBS_DROPDOWNLIST|WS_VSCROLL,
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

        // Settings row 1
        CreateWindowExW(0,L"STATIC",L"Near<=",WS_CHILD|WS_VISIBLE,10,94,48,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hEditLatency=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"300",WS_CHILD|WS_VISIBLE|ES_NUMBER|ES_CENTER,
            58,92,45,22,hWnd,(HMENU)(UINT_PTR)ID_EDIT_LATENCY,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"ms  Timeout:",WS_CHILD|WS_VISIBLE,108,94,85,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hEditTimeout=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"5",WS_CHILD|WS_VISIBLE|ES_NUMBER|ES_CENTER,
            193,92,30,22,hWnd,(HMENU)(UINT_PTR)ID_EDIT_TIMEOUT,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"s  Interval:",WS_CHILD|WS_VISIBLE,228,94,80,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hEditInterval=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"2",WS_CHILD|WS_VISIBLE|ES_NUMBER|ES_CENTER,
            308,92,25,22,hWnd,(HMENU)(UINT_PTR)ID_EDIT_INTERVAL,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"s",WS_CHILD|WS_VISIBLE,338,94,15,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);

        // Settings row 2: idle + countdown
        CreateWindowExW(0,L"STATIC",L"Idle:",WS_CHILD|WS_VISIBLE,10,118,38,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        g_hEditIdle=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"20",WS_CHILD|WS_VISIBLE|ES_NUMBER|ES_CENTER,
            48,116,35,22,hWnd,(HMENU)(UINT_PTR)ID_EDIT_IDLE,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"STATIC",L"sec",WS_CHILD|WS_VISIBLE,88,118,28,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);
        CreateWindowExW(0,L"BUTTON",L"Black Now",WS_CHILD|WS_VISIBLE,125,116,80,22,hWnd,
            (HMENU)(UINT_PTR)ID_BTN_BLACKNOW,GetModuleHandle(nullptr),nullptr);
        g_hCountdownLabel=CreateWindowExW(0,L"STATIC",L"",
            WS_CHILD|WS_VISIBLE|SS_LEFT,215,118,250,20,hWnd,nullptr,GetModuleHandle(nullptr),nullptr);

        // ListView
        InitListView(hWnd);

        // Chart
        {WNDCLASSEXW wc={};wc.cbSize=sizeof(wc);wc.lpfnWndProc=ChartProc;
         wc.hInstance=GetModuleHandle(nullptr);wc.hCursor=LoadCursor(nullptr,IDC_ARROW);
         wc.lpszClassName=CHART_CLASS;RegisterClassExW(&wc);}
        g_hChart=CreateWindowExW(WS_EX_CLIENTEDGE,CHART_CLASS,L"",
            WS_CHILD|WS_VISIBLE,10,400,WINDOW_W-40,CHART_HEIGHT,
            hWnd,nullptr,GetModuleHandle(nullptr),nullptr);

        // BlackScreen class
        {WNDCLASSW wc={};wc.hInstance=GetModuleHandle(nullptr);wc.hCursor=LoadCursor(nullptr,IDC_ARROW);
         wc.hbrBackground=(HBRUSH)GetStockObject(BLACK_BRUSH);wc.lpfnWndProc=BlackScreenProc;
         wc.lpszClassName=BLACKSCREEN_CLASS;RegisterClassW(&wc);}

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

        PopulateCombo();

        // Auto-start if config exists
        BTH_ADDR saved = 0;
        if (LoadConfig(saved)) {
            g_targetAddr = saved;
            PopulateCombo();
            // Find and select the device, then auto-start
            for (size_t i = 0; i < g_paired.size(); i++) {
                if (g_paired[i].address == saved) {
                    SendMessageW(g_hCombo, CB_SETCURSEL, i, 0);
                    PostMessage(hWnd, WM_COMMAND, ID_START, 0);
                    break;
                }
            }
        }
        break;
    }

    case WM_TIMER:
        if (wParam == IDT_COUNTDOWN && g_monitoring && !g_bBlackActive) {
            if (g_proxState == ProxState::Near) {
                g_nCountdown = g_idleCountdownSec; // suppress
            } else if (g_nCountdown > 0) {
                g_nCountdown--;
            }
            if (g_nCountdown == 0) ActivateBlackScreen();

            // Update countdown label
            wchar_t cdl[64];
            if (g_proxState == ProxState::Near)
                wcscpy_s(cdl, L"  Screen saver: suppressed (NEAR)");
            else if (g_bBlackActive)
                wcscpy_s(cdl, L"  Screen saver: ACTIVE");
            else
                swprintf_s(cdl, L"  Screen saver in: %d sec", g_nCountdown);
            SetWindowTextW(g_hCountdownLabel, cdl);
        }
        break;

    case WM_CTLCOLORSTATIC:{
        HDC hdc=(HDC)wParam;HWND hc=(HWND)lParam;
        if(hc==g_hStateLabel&&g_monitoring){
            if(g_proxState==ProxState::Near){
                SetTextColor(hdc,RGB(255,255,255));SetBkColor(hdc,RGB(0,180,0));return(LRESULT)g_hBrushNear;
            }else{
                SetTextColor(hdc,RGB(60,60,60));SetBkColor(hdc,RGB(180,180,180));return(LRESULT)g_hBrushFar;
            }
        }
        break;
    }

    case WM_COMMAND:
        switch(LOWORD(wParam)){
        case ID_REFRESH:if(!g_monitoring)PopulateCombo();break;
        case ID_START:StartMon();break;
        case ID_STOP:StopMon();break;
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
            if(g_monitoring){g_nCountdown=0;ActivateBlackScreen();}break;
        }break;

    case WM_SCAN_RESULT:{
        auto*r=(ProbeResult*)lParam;OnResult(r);
        InvalidateRect(g_hStateLabel,nullptr,TRUE);delete r;break;
    }

    case WM_SIZE:{
        int w=LOWORD(lParam),h=HIWORD(lParam);
        int sH=25,cH=CHART_HEIGHT,cY=h-sH-cH-8;
        int lH=cY-160-4;if(lH<60)lH=60;
        if(g_hStateLabel)MoveWindow(g_hStateLabel,10,48,w-210,38,TRUE);
        if(g_hListView)MoveWindow(g_hListView,10,160,w-20,lH,TRUE);
        if(g_hChart)MoveWindow(g_hChart,10,cY,w-20,cH,TRUE);
        if(g_hStatus)MoveWindow(g_hStatus,0,h-sH-3,w,sH,TRUE);
        break;
    }

    case WM_GETMINMAXINFO:((MINMAXINFO*)lParam)->ptMinTrackSize={700,550};break;
    case WM_CLOSE:if(g_monitoring)StopMon();DestroyWindow(hWnd);break;
    case WM_DESTROY:
        if(g_hFont)DeleteObject(g_hFont);if(g_hFontBold)DeleteObject(g_hFontBold);
        if(g_hFontBig)DeleteObject(g_hFontBig);if(g_hFontSmall)DeleteObject(g_hFontSmall);
        if(g_hBrushNear)DeleteObject(g_hBrushNear);if(g_hBrushFar)DeleteObject(g_hBrushFar);
        PostQuitMessage(0);break;
    default:return DefWindowProcW(hWnd,msg,wParam,lParam);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// WinMain
// ---------------------------------------------------------------------------
int WINAPI wWinMain(HINSTANCE hI,HINSTANCE,LPWSTR,int nS){
    // Mutex: single instance
    HANDLE hMutex = CreateMutexW(nullptr, TRUE, L"SmartScreen_Mutex_v1");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        MessageBoxW(nullptr, L"SmartScreen is already running.", L"SmartScreen", MB_OK|MB_ICONINFORMATION);
        return 0;
    }

    WSADATA wd;WSAStartup(MAKEWORD(2,2),&wd);

    WNDCLASSEXW wc={};wc.cbSize=sizeof(wc);wc.style=CS_HREDRAW|CS_VREDRAW;
    wc.lpfnWndProc=WndProc;wc.hInstance=hI;wc.hCursor=LoadCursor(nullptr,IDC_ARROW);
    wc.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);wc.lpszClassName=L"SmartScreenBT";
    wc.hIcon=LoadIcon(nullptr,IDI_APPLICATION);RegisterClassExW(&wc);

    int sx=GetSystemMetrics(SM_CXSCREEN),sy=GetSystemMetrics(SM_CYSCREEN);
    g_hWnd=CreateWindowExW(0,L"SmartScreenBT",
        L"SmartScreen - BT Proximity + Screen Saver",
        WS_OVERLAPPEDWINDOW,
        (sx-WINDOW_W)/2,(sy-WINDOW_H)/2,WINDOW_W,WINDOW_H,
        nullptr,nullptr,hI,nullptr);

    if(!g_hWnd){MessageBoxW(nullptr,L"Failed",L"Error",MB_ICONERROR);return 1;}
    ShowWindow(g_hWnd,nS);UpdateWindow(g_hWnd);

    MSG msg;
    while(GetMessage(&msg,nullptr,0,0)){TranslateMessage(&msg);DispatchMessage(&msg);}

    WSACleanup();
    if(hMutex)CloseHandle(hMutex);
    return(int)msg.wParam;
}
