// choicebox.cpp - 단추를 정해 쓰는 MessageBox (choicebox.h)
#include "choicebox.h"
#include <string>
#include <vector>

namespace {

// 치수는 96 DPI 픽셀이고 창의 DPI 만큼 늘린다. 이 PC 에서 같은 exe 조건(매니페스트 없음,
// DPI 비인식)으로 MessageBoxW 를 띄워 자식 창 자리를 재어 옮겼다:
//   아이콘 (21,23) 32x32, 글 (62,23), 글 오른쪽 여백 28,
//   글 아래 21 에서 회색 띠 시작, 띠 높이 42 (단추 위 9, 아래 10), 단추 75x23, 띠 오른쪽 끝에서 15.
// 단추 사이는 MessageBox 가 7~9 로 들쭉날쭉해서 8 로 고르게 둔다. 글자 양옆 10 이면
// "아니요(N)" 까지는 75 안에 들어가 예/아니요/취소가 MessageBox 처럼 같은 폭이 된다.
constexpr int kIconX = 21, kTop = 23, kIconSize = 32, kIconGap = 9;
constexpr int kTextRight = 28, kTextToFooter = 21;
constexpr int kBtnMinW = 75, kBtnH = 23, kBtnPadX = 10, kBtnGap = 8;
constexpr int kFooterPadTop = 9, kFooterPadBottom = 10, kFooterSide = 15;
// 왼쪽에 떼어 둔 단추와 오른쪽 묶음 사이의 최소 간격. 붙어 보이면 떼어 둔 뜻이 없다.
constexpr int kApartGap = 32;

constexpr int kTextId = 0xFFFF;   // MessageBox 의 글 칸과 같은 id (IDC_STATIC)

// 템플릿은 비어 있고 크기도 0 이다. 글꼴, 크기, 자식 창은 WM_INITDIALOG 에서 실제 글꼴로 재서 만든다.
// MessageBox 와 같은 스타일 (모달 테두리, 제목 줄 아이콘 없음, 시스템 메뉴는 이동/닫기).
constexpr DWORD kStyle   = WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_MODALFRAME | DS_3DLOOK | DS_NOIDLEMSG;
constexpr DWORD kExStyle = WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE | WS_EX_CONTROLPARENT;

struct State {
    const wchar_t*      text;
    ChoiceIcon          icon;
    const ChoiceButton* buttons;
    int                 count;
    int                 defaultId;
    int                 cancelId;
    HFONT               font = nullptr;
    HICON               hIcon = nullptr;
    bool                ownIcon = false;   // LoadImage 로 따로 만든 것이면 닫을 때 지운다
    RECT                iconRc{};
    int                 footerTop = 0;
};

bool HasButton(const State* s, int id) {
    for (int i = 0; i < s->count; i++) if (s->buttons[i].id == id) return true;
    return false;
}

// 아래 셋은 윈도우 10 1607 부터 있다. 직접 가져다 쓰면 그보다 오래된 윈도우에서 exe 가
// 아예 뜨지 않으므로 찾아서 쓰고, 없으면 예전 함수로 간다 (이 exe 는 DPI 비인식이라 어느 쪽이든 96).
UINT WindowDpi(HWND h) {
    using Fn = UINT(WINAPI*)(HWND);
    static Fn fn = reinterpret_cast<Fn>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
    if (fn) { UINT d = fn(h); if (d) return d; }
    HDC dc = GetDC(h);
    int d = dc ? GetDeviceCaps(dc, LOGPIXELSY) : 96;
    if (dc) ReleaseDC(h, dc);
    return d > 0 ? (UINT)d : 96;
}

bool MetricsForDpi(UINT dpi, NONCLIENTMETRICSW& ncm) {
    ncm = {};
    ncm.cbSize = sizeof(ncm);
    using Fn = BOOL(WINAPI*)(UINT, UINT, PVOID, UINT, UINT);
    static Fn fn = reinterpret_cast<Fn>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "SystemParametersInfoForDpi"));
    if (fn && fn(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0, dpi)) return true;
    return SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0) != FALSE;
}

void FrameForDpi(RECT& rc, UINT dpi) {
    using Fn = BOOL(WINAPI*)(LPRECT, DWORD, BOOL, DWORD, UINT);
    static Fn fn = reinterpret_cast<Fn>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "AdjustWindowRectExForDpi"));
    if (fn && fn(&rc, kStyle, FALSE, kExStyle, dpi)) return;
    AdjustWindowRectEx(&rc, kStyle, FALSE, kExStyle);
}

LPCWSTR IconResource(ChoiceIcon i) {
    switch (i) {
    case ChoiceIcon::Question:    return IDI_QUESTION;
    case ChoiceIcon::Warning:     return IDI_WARNING;
    case ChoiceIcon::Information: return IDI_INFORMATION;
    case ChoiceIcon::Error:       return IDI_ERROR;
    default:                      return nullptr;
    }
}

UINT IconSound(ChoiceIcon i) {
    switch (i) {
    case ChoiceIcon::Question:    return MB_ICONQUESTION;
    case ChoiceIcon::Warning:     return MB_ICONWARNING;
    case ChoiceIcon::Information: return MB_ICONINFORMATION;
    case ChoiceIcon::Error:       return MB_ICONERROR;
    default:                      return MB_OK;
    }
}

BOOL Init(HWND h, State* s) {
    SetWindowLongPtrW(h, DWLP_USER, (LONG_PTR)s);
    HINSTANCE hi = (HINSTANCE)GetWindowLongPtrW(h, GWLP_HINSTANCE);
    const UINT dpi = WindowDpi(h);
    auto px = [dpi](int v) { return MulDiv(v, (int)dpi, 96); };

    // 글꼴은 시스템 메시지 글꼴 (한국어 윈도우라면 맑은 고딕 9pt). 글도 단추도 이 글꼴로 잰다.
    // 이 PC 의 MessageBox 는 같은 글꼴을 한 단계 작게(높이 -11) 그리는데, 그 크기를 주는 공개
    // API 가 없다. 메시지 글꼴 그대로 둔다 - 글자가 1px 크고 창이 그만큼 넓을 뿐 모양은 같다.
    NONCLIENTMETRICSW ncm;
    if (MetricsForDpi(dpi, ncm)) s->font = CreateFontIndirectW(&ncm.lfMessageFont);
    HFONT font = s->font ? s->font : (HFONT)GetStockObject(DEFAULT_GUI_FONT);

    // MessageBox 는 owner 창이 아니라 owner 가 있는 모니터의 가운데에 뜬다 (재 보니 owner 를 어디에
    // 두든, 숨겨 두든 같은 자리였다). 글이 너무 길면 접는 폭도 그 모니터 기준이다.
    HWND owner = GetWindow(h, GW_OWNER);
    MONITORINFO mi = { sizeof(mi) };
    GetMonitorInfoW(MonitorFromWindow(owner ? owner : h, MONITOR_DEFAULTTONEAREST), &mi);
    const RECT wa = mi.rcWork;

    HDC dc = GetDC(h);
    HGDIOBJ oldFont = SelectObject(dc, font);

    // 아이콘
    int iconSz = 0;
    if (LPCWSTR res = IconResource(s->icon)) {
        iconSz = px(kIconSize);
        if (iconSz != GetSystemMetrics(SM_CXICON)) {
            s->hIcon = (HICON)LoadImageW(nullptr, res, IMAGE_ICON, iconSz, iconSz, 0);
            s->ownIcon = (s->hIcon != nullptr);
        }
        if (!s->hIcon) s->hIcon = LoadIconW(nullptr, res);   // 공유 아이콘 - 지우지 않는다
    }
    const int textX = iconSz ? px(kIconX) + iconSz + px(kIconGap) : px(kIconX);

    // 글. 재는 플래그는 글 칸(STATIC: SS_LEFT | SS_NOPREFIX | SS_EDITCONTROL)이 그릴 때와 같아야
    // 잘리지 않는다. 줄 앞의 공백(들여쓰기)도 그대로 남는다.
    const UINT textFlags = DT_WORDBREAK | DT_EXPANDTABS | DT_NOPREFIX | DT_EDITCONTROL;
    int maxTextW = (wa.right - wa.left) * 5 / 8 - textX - px(kTextRight);
    if (maxTextW < px(240)) maxTextW = px(240);
    RECT tr = { 0, 0, maxTextW, 0 };
    DrawTextW(dc, s->text, -1, &tr, DT_CALCRECT | textFlags);
    const int textW = tr.right - tr.left, textH = tr.bottom - tr.top;

    // 단추는 글자에 맞추되 MessageBox 단추보다 작아지지 않게. & 는 재지 않는다 (밑줄이 된다).
    TEXTMETRICW tm = {};
    GetTextMetricsW(dc, &tm);
    int bh = px(kBtnH);
    if (bh < tm.tmHeight + px(6)) bh = tm.tmHeight + px(6);
    std::vector<int> bw(s->count);
    int leftW = 0, rightW = 0, nLeft = 0, nRight = 0;
    for (int i = 0; i < s->count; i++) {
        RECT r = { 0, 0, 0, 0 };
        DrawTextW(dc, s->buttons[i].label, -1, &r, DT_CALCRECT | DT_SINGLELINE);
        bw[i] = r.right - r.left + 2 * px(kBtnPadX);
        if (bw[i] < px(kBtnMinW)) bw[i] = px(kBtnMinW);
        if (s->buttons[i].apart) { leftW += bw[i]; nLeft++; }
        else                     { rightW += bw[i]; nRight++; }
    }
    if (nLeft > 1)  leftW  += (nLeft - 1) * px(kBtnGap);
    if (nRight > 1) rightW += (nRight - 1) * px(kBtnGap);
    int rowW = 2 * px(kFooterSide) + leftW + rightW + ((nLeft && nRight) ? px(kApartGap) : 0);

    // 제목이 잘리지 않을 만큼은 넓게 (글이 아주 짧을 때만 걸린다)
    int titleW = 0;
    {
        wchar_t title[256] = L"";
        GetWindowTextW(h, title, 256);
        HFONT cf = CreateFontIndirectW(&ncm.lfCaptionFont);
        HGDIOBJ of = SelectObject(dc, cf ? (HGDIOBJ)cf : (HGDIOBJ)font);
        RECT r = { 0, 0, 0, 0 };
        DrawTextW(dc, title, -1, &r, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        SelectObject(dc, of);
        if (cf) DeleteObject(cf);
        titleW = r.right + px(80);   // 닫기 단추와 여백
    }

    SelectObject(dc, oldFont);
    ReleaseDC(h, dc);

    // 배치. 글이 아이콘보다 낮으면 아이콘 가운데에 맞춘다 (MessageBox 와 같다).
    const int contentH = (textH > iconSz) ? textH : iconSz;
    const int textY = px(kTop) + (textH < iconSz ? (iconSz - textH) / 2 : 0);
    s->iconRc = { px(kIconX), px(kTop), px(kIconX) + iconSz, px(kTop) + iconSz };
    s->footerTop = px(kTop) + contentH + px(kTextToFooter);
    int clientW = textX + textW + px(kTextRight);
    if (clientW < rowW) clientW = rowW;
    if (clientW < titleW) clientW = titleW;
    const int clientH = s->footerTop + px(kFooterPadTop) + bh + px(kFooterPadBottom);

    // 창 크기와 자리
    RECT wr = { 0, 0, clientW, clientH };
    FrameForDpi(wr, dpi);
    const int ww = wr.right - wr.left, wh = wr.bottom - wr.top;
    int x = wa.left + ((wa.right - wa.left) - ww) / 2;
    int y = wa.top + ((wa.bottom - wa.top) - wh) / 2;
    if (x < wa.left) x = wa.left;
    if (y < wa.top) y = wa.top;
    SetWindowPos(h, nullptr, x, y, ww, wh, SWP_NOZORDER | SWP_NOACTIVATE);

    // 글 칸. MessageBox 처럼 STATIC 으로 둔다 - 화면 읽기 프로그램이 이 글을 읽는다.
    HWND ht = CreateWindowExW(0, L"STATIC", s->text,
        WS_CHILD | WS_VISIBLE | WS_GROUP | SS_LEFT | SS_NOPREFIX | SS_EDITCONTROL,
        textX, textY, textW, textH, h, (HMENU)(INT_PTR)kTextId, hi, nullptr);
    if (ht) SendMessageW(ht, WM_SETFONT, (WPARAM)font, FALSE);

    // 단추. 만드는 순서가 Tab 순서라 화면 순서(왼쪽 묶음 -> 오른쪽 묶음)대로 만든다.
    int defId = HasButton(s, s->defaultId) ? s->defaultId : 0;
    if (!defId) for (int i = 0; i < s->count && !defId; i++) if (!s->buttons[i].apart) defId = s->buttons[i].id;
    if (!defId && s->count) defId = s->buttons[0].id;
    const int by = s->footerTop + px(kFooterPadTop);
    int xl = px(kFooterSide), xr = clientW - px(kFooterSide) - rightW;
    bool first = true;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < s->count; i++) {
            const ChoiceButton& b = s->buttons[i];
            if (b.apart != (pass == 0)) continue;
            int& bx = b.apart ? xl : xr;
            DWORD st = WS_CHILD | WS_VISIBLE | WS_TABSTOP | (first ? WS_GROUP : 0) |
                       (b.id == defId ? BS_DEFPUSHBUTTON : BS_PUSHBUTTON);
            HWND hb = CreateWindowExW(0, L"BUTTON", b.label, st, bx, by, bw[i], bh,
                                      h, (HMENU)(INT_PTR)b.id, hi, nullptr);
            if (hb) SendMessageW(hb, WM_SETFONT, (WPARAM)font, FALSE);
            bx += bw[i] + px(kBtnGap);
            first = false;
        }
    }

    // 취소할 길이 없으면 X 도 막는다 (MB_YESNO 의 MessageBox 와 같다)
    if (!s->cancelId && !HasButton(s, IDCANCEL))
        EnableMenuItem(GetSystemMenu(h, FALSE), SC_CLOSE, MF_BYCOMMAND | MF_GRAYED);

    // 초점은 WM_NEXTDLGCTL 로 옮긴다. SetFocus 로 옮겼더니 초점은 [예] 에 있는데 기본 단추
    // 테두리(BS_DEFPUSHBUTTON)가 사라졌다 - 대화상자 관리자가 기본 단추를 다시 맞추는 길은 이쪽이다.
    SendMessageW(h, DM_SETDEFID, defId, 0);
    if (HWND hd = GetDlgItem(h, defId)) SendMessageW(h, WM_NEXTDLGCTL, (WPARAM)hd, TRUE);
    MessageBeep(IconSound(s->icon));
    return FALSE;   // 초점은 위에서 정했다
}

INT_PTR CALLBACK Proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    State* s = (State*)GetWindowLongPtrW(h, DWLP_USER);
    switch (msg) {
    case WM_INITDIALOG:
        return Init(h, (State*)lp);

    case WM_ERASEBKGND: {
        if (!s) break;
        // 위는 흰 글 칸, 아래는 단추가 놓이는 회색 띠 (MessageBox 와 같은 색)
        HDC dc = (HDC)wp;
        RECT rc; GetClientRect(h, &rc);
        RECT top = rc, bottom = rc;
        top.bottom = s->footerTop;
        bottom.top = s->footerTop;
        FillRect(dc, &top, GetSysColorBrush(COLOR_WINDOW));
        FillRect(dc, &bottom, GetSysColorBrush(COLOR_BTNFACE));
        SetWindowLongPtrW(h, DWLP_MSGRESULT, TRUE);
        return TRUE;
    }

    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        if (s && s->hIcon)
            DrawIconEx(dc, s->iconRc.left, s->iconRc.top, s->hIcon,
                       s->iconRc.right - s->iconRc.left, s->iconRc.bottom - s->iconRc.top,
                       0, nullptr, DI_NORMAL);
        EndPaint(h, &ps);
        return TRUE;
    }

    case WM_CTLCOLORSTATIC: {
        // 글 칸은 흰 바탕 위에 있다. 기본(회색)으로 두면 글자 뒤만 회색 띠가 된다.
        HDC dc = (HDC)wp;
        SetTextColor(dc, GetSysColor(COLOR_WINDOWTEXT));
        SetBkColor(dc, GetSysColor(COLOR_WINDOW));
        return (INT_PTR)GetSysColorBrush(COLOR_WINDOW);
    }

    case WM_COMMAND: {
        if (!s) break;
        const int id = LOWORD(wp);
        if (id == IDCANCEL) {
            // Esc 와 X 도 여기로 온다. 취소할 길이 없으면 무시한다.
            int r = s->cancelId ? s->cancelId : (HasButton(s, IDCANCEL) ? IDCANCEL : 0);
            if (r) EndDialog(h, r);
            return TRUE;
        }
        if (HIWORD(wp) == BN_CLICKED && HasButton(s, id)) {
            EndDialog(h, id);
            return TRUE;
        }
        break;
    }

    case WM_DESTROY:
        if (s) {
            if (s->font) { DeleteObject(s->font); s->font = nullptr; }
            if (s->ownIcon && s->hIcon) DestroyIcon(s->hIcon);
            s->hIcon = nullptr;
        }
        break;
    }
    return FALSE;
}

} // namespace

int ChoiceBox(HWND owner, const wchar_t* text, const wchar_t* title, ChoiceIcon icon,
              const ChoiceButton* buttons, int count, int defaultId, int cancelId) {
    if (!buttons || count <= 0) return 0;

    // DLGTEMPLATE + 메뉴 없음 + 기본 대화상자 클래스 + 제목. 컨트롤은 0 개 (WM_INITDIALOG 에서 만든다).
    // vector<WORD> 의 버퍼는 DWORD 경계에서 시작하므로 템플릿 정렬 조건을 채운다.
    std::vector<WORD> t;
    t.reserve(32);
    t.push_back(LOWORD(kStyle));   t.push_back(HIWORD(kStyle));
    t.push_back(LOWORD(kExStyle)); t.push_back(HIWORD(kExStyle));
    t.push_back(0);                                            // cdit
    t.push_back(0); t.push_back(0); t.push_back(0); t.push_back(0);   // x, y, cx, cy
    t.push_back(0);                                            // 메뉴 없음
    t.push_back(0);                                            // 기본 대화상자 클래스
    for (const wchar_t* p = title ? title : L""; *p; ++p) t.push_back((WORD)*p);
    t.push_back(0);

    State s{ text ? text : L"", icon, buttons, count, defaultId, cancelId };
    INT_PTR r = DialogBoxIndirectParamW(GetModuleHandleW(nullptr), (LPCDLGTEMPLATEW)t.data(),
                                        owner, Proc, (LPARAM)&s);
    return (r == -1) ? 0 : (int)r;
}
