// blackscreen.cpp - Black screen window, image/video rendering, activation
#include "blackscreen.h"
#include "config.h"
#include "video/player.h"

static constexpr int IDC_BTN_RELEASE = 301;
static constexpr int IDT_VIDEO_TICK  = 20;
static bool s_videoMode = false;

static Gdiplus::Image* s_imgCenter = nullptr;
static Gdiplus::Image* s_imgBanner = nullptr;
static HWND s_hBannerPopup = nullptr;
extern HWND g_hBlackScreen;

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
        if (s_imgBanner) {
            Gdiplus::Graphics gfx(hdc);
            gfx.DrawImage(s_imgBanner, 0, 0, rc.right, rc.bottom);
        } else {
            HBRUSH br = CreateSolidBrush(RGB(40, 40, 60));
            FillRect(hdc, &rc, br); DeleteObject(br);
            SetBkMode(hdc, TRANSPARENT); SetTextColor(hdc, RGB(120, 120, 150));
            DrawTextW(hdc, L"banner.png\n(300x400)\nimages\\", -1, &rc, DT_CENTER | DT_VCENTER | DT_WORDBREAK);
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
        RECT rc; GetClientRect(hWnd, &rc);
        int sw = rc.right, sh = rc.bottom;

        HWND hBtn = CreateWindowW(L"BUTTON", L"\xD574\xC81C", // 해제
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            sw - 125, 15, 110, 42,
            hWnd, (HMENU)(UINT_PTR)IDC_BTN_RELEASE, GetModuleHandle(nullptr), nullptr);
        if (g_hFont) SendMessage(hBtn, WM_SETFONT, (WPARAM)g_hFont, TRUE);

        // Check if center content is video
        s_videoMode = false;
        if (!g_centerImagePath.empty() && IsVideoFile(g_centerImagePath)) {
            if (VideoInit() && VideoPlay(hWnd, g_centerImagePath)) {
                s_videoMode = true;
                SetTimer(hWnd, IDT_VIDEO_TICK, 500, nullptr); // loop check
            }
        }

        // Banner popup
        int bannerW = 300, bannerH = 400;
        int bannerX = sw - bannerW - 40, bannerY = 80;
        POINT pt = { bannerX, bannerY };
        ClientToScreen(hWnd, &pt);
        s_hBannerPopup = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW, BANNER_CLASS, L"",
            WS_POPUP | WS_VISIBLE | WS_BORDER,
            pt.x, pt.y, bannerW, bannerH,
            hWnd, nullptr, GetModuleHandle(nullptr), nullptr);
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wParam) == IDC_BTN_RELEASE) {
            DeactivateBlackScreen();
        }
        return 0;
    case WM_ERASEBKGND: {
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
        int cw = rc.right, ch = rc.bottom;
        FillRect(hdc, &rc, (HBRUSH)GetStockObject(BLACK_BRUSH));

        if (s_videoMode) {
            VideoOnPaint(hWnd);
            EndPaint(hWnd, &ps); return 0;
        }

        int imgW = 1024, imgH = 768;
        if (s_imgCenter) {
            Gdiplus::Graphics gfx(hdc);
            gfx.DrawImage(s_imgCenter, (cw - imgW) / 2, (ch - imgH) / 2, imgW, imgH);
        } else {
            int x = (cw - imgW) / 2, y = (ch - imgH) / 2;
            RECT imgRc = { x, y, x + imgW, y + imgH };
            HBRUSH br = CreateSolidBrush(RGB(20, 20, 30));
            FillRect(hdc, &imgRc, br); DeleteObject(br);
            HPEN pen = CreatePen(PS_DOT, 1, RGB(60, 60, 80));
            HPEN op = (HPEN)SelectObject(hdc, pen);
            MoveToEx(hdc, x, y, nullptr); LineTo(hdc, x + imgW, y);
            LineTo(hdc, x + imgW, y + imgH); LineTo(hdc, x, y + imgH); LineTo(hdc, x, y);
            SelectObject(hdc, op); DeleteObject(pen);
            SetBkMode(hdc, TRANSPARENT); SetTextColor(hdc, RGB(80, 80, 100));
            DrawTextW(hdc, L"center.png (1024x768)\nimages\\", -1, &imgRc, DT_CENTER | DT_VCENTER | DT_WORDBREAK);
        }
        EndPaint(hWnd, &ps); return 0;
    }
    case WM_CLOSE: return 0;
    case WM_DESTROY:
        KillTimer(hWnd, IDT_VIDEO_TICK);
        if (s_videoMode) { VideoStop(); s_videoMode = false; }
        if (s_hBannerPopup) { DestroyWindow(s_hBannerPopup); s_hBannerPopup = nullptr; }
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
void ActivateBlackScreen() {
    if (g_bBlackActive) return;
    if (g_proxState == ProxState::Near) {
        g_nCountdown = g_idleCountdownSec;
        return;
    }
    g_bBlackActive = true;
    g_bManualLock = false;
    g_lockStartTick = GetTickCount64();

    int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
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

    g_bBlackActive = false;
    g_bManualLock = false;
    g_lockStartTick = 0;
    g_nCountdown = g_idleCountdownSec;
    if (s_hBannerPopup) { DestroyWindow(s_hBannerPopup); s_hBannerPopup = nullptr; }
    if (g_hBlackScreen) { DestroyWindow(g_hBlackScreen); g_hBlackScreen = nullptr; }
}
