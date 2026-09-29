// blackscreen.cpp - Black screen window, image/video rendering, activation
#include "blackscreen.h"
#include "config.h"
#include "video/player.h"
#include <vector>

static constexpr int IDC_BTN_RELEASE = 301;
static constexpr int IDT_VIDEO_TICK  = 20;
static bool s_videoMode = false;
// 원격이라 건너뛰었다는 기록을 한 번만 남기기 위한 것. 이게 없으면
// 자리를 비운 내내 2초마다 같은 줄이 쌓인다.
static bool s_remoteNoted = false;

static Gdiplus::Image* s_imgCenter = nullptr;
static Gdiplus::Image* s_imgBanner = nullptr;
static std::vector<HWND> s_banners;     // 모니터마다 하나
static HWND s_hVideoHost = nullptr;     // 영상은 모니터 하나에 가둬서 튼다
extern HWND g_hBlackScreen;

// ---------------------------------------------------------------------------
// 모니터 목록
// ---------------------------------------------------------------------------
// 검은 화면은 가상 화면 전체를 덮는 창 하나다. 콘텐츠를 그 창 한가운데에
// 그리면 모니터가 둘일 때 경계에 걸친다 - 실제로 두 화면 사이에 광고가
// 반씩 잘려 나왔다. 그래서 모니터마다 영역을 받아 그 안에 따로 배치한다.
struct MonArea {
    RECT rc;         // 창의 클라이언트 좌표 (가상 화면 원점을 뺀 값)
    bool primary;
};

static BOOL CALLBACK CollectMonitor(HMONITOR hMon, HDC, LPRECT, LPARAM lp) {
    MONITORINFO mi{}; mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(hMon, &mi)) return TRUE;
    int ox = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int oy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    MonArea m;
    m.rc = { mi.rcMonitor.left - ox, mi.rcMonitor.top - oy,
             mi.rcMonitor.right - ox, mi.rcMonitor.bottom - oy };
    m.primary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;
    ((std::vector<MonArea>*)lp)->push_back(m);
    return TRUE;
}

static std::vector<MonArea> MonitorAreas() {
    std::vector<MonArea> v;
    EnumDisplayMonitors(nullptr, nullptr, CollectMonitor, (LPARAM)&v);
    if (v.empty()) {
        // 열거가 실패해도 화면은 가려야 한다. 예전처럼 가상 화면 하나로 취급한다.
        MonArea m{ { 0, 0, GetSystemMetrics(SM_CXVIRTUALSCREEN),
                     GetSystemMetrics(SM_CYVIRTUALSCREEN) }, true };
        v.push_back(m);
    }
    return v;
}

// ---------------------------------------------------------------------------
// Image loading - uses config paths (personal) or exe/images fallback
// ---------------------------------------------------------------------------
void LoadBlackScreenImages() {
    const wchar_t* exts[] = { L"png", L"jpg", L"bmp", L"jpeg" };

    // Center image: try config path first, then exe/images/center.*
    if (!s_imgCenter && !g_centerImagePath.empty()) {
        auto* img = new Gdiplus::Image(g_centerImagePath.c_str());
        if (img->GetLastStatus() == Gdiplus::Ok) s_imgCenter = img;
        else delete img;
    }
    if (!s_imgCenter) {
        std::wstring dir = GetExeDir() + L"images\\";
        for (auto ext : exts) {
            auto* img = new Gdiplus::Image((dir + L"center." + ext).c_str());
            if (img->GetLastStatus() == Gdiplus::Ok) { s_imgCenter = img; break; }
            delete img;
        }
    }

    // Banner image
    if (!s_imgBanner && !g_bannerImagePath.empty()) {
        auto* img = new Gdiplus::Image(g_bannerImagePath.c_str());
        if (img->GetLastStatus() == Gdiplus::Ok) s_imgBanner = img;
        else delete img;
    }
    if (!s_imgBanner) {
        std::wstring dir = GetExeDir() + L"images\\";
        for (auto ext : exts) {
            auto* img = new Gdiplus::Image((dir + L"banner." + ext).c_str());
            if (img->GetLastStatus() == Gdiplus::Ok) { s_imgBanner = img; break; }
            delete img;
        }
    }

}

void FreeBlackScreenImages() {
    if (s_imgCenter) { delete s_imgCenter; s_imgCenter = nullptr; }
    if (s_imgBanner) { delete s_imgBanner; s_imgBanner = nullptr; }
}

// ---------------------------------------------------------------------------
// Banner popup
// ---------------------------------------------------------------------------
static LRESULT CALLBACK BannerProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC hdc = BeginPaint(hWnd, &ps);
        RECT rc; GetClientRect(hWnd, &rc);
        // 이 창은 이미지가 있을 때만 만들어진다. 그래도 방어적으로 검게 채운다 -
        // 예전처럼 자리표시자를 그리면, 만드는 조건이 나중에 바뀌었을 때
        // 사용자 화면에 개발용 상자가 뜬다.
        if (s_imgBanner) {
            Gdiplus::Graphics gfx(hdc);
            gfx.DrawImage(s_imgBanner, 0, 0, rc.right, rc.bottom);
        } else {
            FillRect(hdc, &rc, (HBRUSH)GetStockObject(BLACK_BRUSH));
        }
        EndPaint(hWnd, &ps); return 0;
    }
    case WM_ERASEBKGND: return 1;
    }
    return DefWindowProc(hWnd, uMsg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// BlackScreen window
// ---------------------------------------------------------------------------
static LRESULT CALLBACK BlackScreenProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
    case WM_CREATE: {
        LoadBlackScreenImages();
        auto mons = MonitorAreas();

        // [해제] 와 배너는 모니터마다 하나씩. 버튼이 한쪽에만 있으면
        // 다른 화면을 보던 사람은 빠져나갈 곳이 안 보인다.
        s_banners.clear();
        for (const auto& m : mons) {
            int mw = m.rc.right - m.rc.left;
            HWND hBtn = CreateWindowW(L"BUTTON", L"\xD574\xC81C", // 해제
                WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                m.rc.left + mw - 125, m.rc.top + 15, 110, 42,
                hWnd, (HMENU)(UINT_PTR)IDC_BTN_RELEASE, GetModuleHandle(nullptr), nullptr);
            if (g_hFont) SendMessage(hBtn, WM_SETFONT, (WPARAM)g_hFont, TRUE);

            // 배너는 이미지가 있을 때만 만든다. 없으면 자리만 차지하는 빈 상자가
            // 화면 오른쪽에 남는데, 그건 설정이 비었다는 개발용 표시였지
            // 사용자에게 보일 것이 아니다.
            if (s_imgBanner) {
                int bannerW = 300, bannerH = 400;
                POINT pt = { m.rc.left + mw - bannerW - 40, m.rc.top + 80 };
                ClientToScreen(hWnd, &pt);
                HWND hb = CreateWindowExW(
                    WS_EX_TOPMOST | WS_EX_TOOLWINDOW, BANNER_CLASS, L"",
                    WS_POPUP | WS_VISIBLE | WS_BORDER,
                    pt.x, pt.y, bannerW, bannerH,
                    hWnd, nullptr, GetModuleHandle(nullptr), nullptr);
                if (hb) s_banners.push_back(hb);
            }
        }

        // 영상은 MFPlay 가 호스트 창을 가득 채우는 방식이라, 큰 창에 그대로
        // 태우면 두 모니터에 걸쳐 늘어난다. 모니터 하나 크기의 자식 창을 만들어
        // 거기에 가둔다. 플레이어가 한 개짜리라 영상은 주 모니터에만 나온다.
        s_videoMode = false;
        s_hVideoHost = nullptr;
        if (!g_centerImagePath.empty() && IsVideoFile(g_centerImagePath)) {
            const MonArea* host = &mons[0];
            for (const auto& m : mons) if (m.primary) { host = &m; break; }
            s_hVideoHost = CreateWindowW(L"STATIC", L"",
                WS_CHILD | WS_VISIBLE,
                host->rc.left, host->rc.top,
                host->rc.right - host->rc.left, host->rc.bottom - host->rc.top,
                hWnd, nullptr, GetModuleHandle(nullptr), nullptr);
            if (s_hVideoHost && VideoInit() && VideoPlay(s_hVideoHost, g_centerImagePath)) {
                s_videoMode = true;
                SetTimer(hWnd, IDT_VIDEO_TICK, 500, nullptr); // loop check
            } else if (s_hVideoHost) {
                DestroyWindow(s_hVideoHost); s_hVideoHost = nullptr;
            }
        }
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wParam) == IDC_BTN_RELEASE) {
            DeactivateBlackScreen();
        }
        return 0;
    case WM_ERASEBKGND: {
        if (s_videoMode) return 1; // Let MFPlay handle rendering
        HDC hdc = (HDC)wParam; RECT rc; GetClientRect(hWnd, &rc);
        FillRect(hdc, &rc, (HBRUSH)GetStockObject(BLACK_BRUSH));
        return 1;
    }
    case WM_TIMER:
        if (wParam == IDT_VIDEO_TICK) VideoTick();
        return 0;

    case WM_PAINT: {
        PAINTSTRUCT ps; HDC hdc = BeginPaint(hWnd, &ps);
        RECT rc; GetClientRect(hWnd, &rc);
        FillRect(hdc, &rc, (HBRUSH)GetStockObject(BLACK_BRUSH));

        if (s_videoMode) VideoOnPaint(hWnd);   // 자식 창이 알아서 그린다

        // 각 모니터 한가운데에 따로 그린다. 창 한가운데에 한 번 그리면
        // 모니터가 둘일 때 경계에 반씩 걸린다.
        for (const auto& m : MonitorAreas()) {
            // 영상이 도는 모니터는 자식 창이 덮고 있으므로 건너뛴다
            if (s_videoMode && m.primary) continue;

            int mw = m.rc.right - m.rc.left, mh = m.rc.bottom - m.rc.top;
            // 작은 화면에서 1024x768 을 그대로 쓰면 넘친다. 화면의 80% 로 제한하되
            // 원본 비율은 지킨다.
            int imgW = 1024, imgH = 768;
            double fit = (std::min)(1.0, (std::min)(mw * 0.8 / imgW, mh * 0.8 / imgH));
            imgW = (int)(imgW * fit); imgH = (int)(imgH * fit);
            int x = m.rc.left + (mw - imgW) / 2;
            int y = m.rc.top + (mh - imgH) / 2;

            if (s_imgCenter) {
                Gdiplus::Graphics gfx(hdc);
                gfx.DrawImage(s_imgCenter, x, y, imgW, imgH);
            } else if (s_videoMode) {
                // 영상을 트는 중인데 쓸 이미지가 없다. 아래 자리표시자는 설정이
                // 비었을 때 보여주는 개발용 상자라, 이럴 때 내보내면 안 된다.
                // 보조 모니터는 검은 채로 둔다.
            } else {
                RECT imgRc = { x, y, x + imgW, y + imgH };
                HBRUSH br = CreateSolidBrush(RGB(20, 20, 30));
                FillRect(hdc, &imgRc, br); DeleteObject(br);
                HPEN pen = CreatePen(PS_DOT, 1, RGB(60, 60, 80));
                HPEN op = (HPEN)SelectObject(hdc, pen);
                MoveToEx(hdc, x, y, nullptr); LineTo(hdc, x + imgW, y);
                LineTo(hdc, x + imgW, y + imgH); LineTo(hdc, x, y + imgH); LineTo(hdc, x, y);
                SelectObject(hdc, op); DeleteObject(pen);
                SetBkMode(hdc, TRANSPARENT); SetTextColor(hdc, RGB(80, 80, 100));
                DrawTextW(hdc, L"center.png (1024x768)\nimages\\", -1, &imgRc,
                          DT_CENTER | DT_VCENTER | DT_WORDBREAK);
            }
        }
        EndPaint(hWnd, &ps); return 0;
    }
    case WM_CLOSE: return 0;
    case WM_DESTROY:
        KillTimer(hWnd, IDT_VIDEO_TICK);
        // 영상을 먼저 세운다. 호스트 창은 이 창의 자식이라 뒤따라 사라지는데,
        // 플레이어가 아직 그 창을 들고 있으면 안 된다.
        if (s_videoMode) { VideoStop(); s_videoMode = false; }
        s_hVideoHost = nullptr;
        for (HWND h : s_banners) if (h) DestroyWindow(h);
        s_banners.clear();
        return 0;
    }
    return DefWindowProc(hWnd, uMsg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// Register classes
// ---------------------------------------------------------------------------
void RegisterBlackScreenClasses(HINSTANCE hInst) {
    WNDCLASSW wc = {};
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.lpfnWndProc = BlackScreenProc;
    wc.lpszClassName = BLACKSCREEN_CLASS;
    RegisterClassW(&wc);

    wc.lpfnWndProc = BannerProc;
    wc.lpszClassName = BANNER_CLASS;
    RegisterClassW(&wc);
}

// ---------------------------------------------------------------------------
// Activate / Deactivate
// ---------------------------------------------------------------------------
// 이 세션이 원격으로 표시되고 있는지 (원격 데스크톱/터미널 서비스).
// 세션이 원격으로 연결/재연결되면 값이 바뀌므로 그때그때 물어본다.
//
// 이 판정은 RDP 계열만 안다. TeamViewer, AnyDesk, Chrome 원격 데스크톱 같은
// 도구는 콘솔 세션을 그대로 쓰기 때문에 여기 걸리지 않는다. 그런 도구를
// 쓴다면 별도 판정이 필요하다 - 지금 코드는 모르는 척하지 않고 모른다.
bool IsRemoteSession() {
    return GetSystemMetrics(SM_REMOTESESSION) != 0;
}

void ActivateBlackScreen() {
    if (g_bBlackActive) return;
    // 방금 마우스/키보드를 썼다 = 사람이 앞에 있다 → RSSI와 무관하게 잠그지 않음
    if (g_lastInputTick != 0 && (GetTickCount64() - g_lastInputTick) < 5000) return;
    // 원격으로 쓰는 중이면 폰이 책상에 없는 게 정상이다. 여기서 잠그면
    // 원격 사용자 화면만 가린다 - 가려야 할 책상 앞에는 아무도 없다.
    // 사용자가 직접 누른 잠금은 이 경로로 오지 않으므로 그대로 걸린다.
    if (IsRemoteSession()) {
        if (!s_remoteNoted) {
            DbgEvent(L"원격 세션이라 자동 잠금을 건너뛴다");
            s_remoteNoted = true;
        }
        return;
    }
    s_remoteNoted = false;
    if (g_proxState == ProxState::Near) {
        g_nCountdown = g_idleCountdownSec;
        return;
    }
    g_bBlackActive = true;
    g_bManualLock = false;
    g_lockStartTick = GetTickCount64();
    DbgEvent(L"BLACK ON  (idleCountdown=%d)", g_nCountdown);

    int x =GetSystemMetrics(SM_XVIRTUALSCREEN);
    int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);

    g_hBlackScreen = CreateWindowExW(WS_EX_TOPMOST, BLACKSCREEN_CLASS, L"",
        WS_POPUP, x, y, w, h, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
    ShowWindow(g_hBlackScreen, SW_SHOW);
    SetForegroundWindow(g_hBlackScreen);
}

void DeactivateBlackScreen() {
    if (!g_bBlackActive) return;

    SYSTEMTIME stNow; GetLocalTime(&stNow);
    DWORD durationSec = (g_lockStartTick > 0) ? (DWORD)((GetTickCount64() - g_lockStartTick) / 1000) : 0;
    DWORD durMin = durationSec / 60, durSec = durationSec % 60;
    FILETIME ftNow; SystemTimeToFileTime(&stNow, &ftNow);
    ULARGE_INTEGER u; u.LowPart = ftNow.dwLowDateTime; u.HighPart = ftNow.dwHighDateTime;
    u.QuadPart -= (ULONGLONG)durationSec * 10000000ULL;
    ftNow.dwLowDateTime = u.LowPart; ftNow.dwHighDateTime = u.HighPart;
    SYSTEMTIME stLock; FileTimeToSystemTime(&ftNow, &stLock);
    SystemTimeToTzSpecificLocalTime(nullptr, &stLock, &stLock);
    swprintf_s(g_ovlInfo, L"Lock %02d:%02d -> Unlock %02d:%02d (%dm%02ds)",
        stLock.wHour, stLock.wMinute, stNow.wHour, stNow.wMinute, durMin, durSec);

    DbgEvent(L"BLACK OFF (locked %lus, unlockTimer=%d)", durationSec, g_unlockTimer);
    g_bBlackActive = false;
    g_bManualLock = false;
    g_lockStartTick = 0;
    g_nCountdown = g_idleCountdownSec;
    for (HWND h : s_banners) if (h) DestroyWindow(h);
    s_banners.clear();
    if (g_hBlackScreen) { DestroyWindow(g_hBlackScreen); g_hBlackScreen = nullptr; }
}
