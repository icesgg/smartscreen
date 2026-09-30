// clipsync.cpp - 설계 근거와 되울림 방지의 이유는 clipsync.h 머리말 참고.
//
// config.h 가 winsock2.h 를 끌어오므로 windows.h 를 끌고 오는 헤더보다 먼저
// 와야 한다 (ble_ident.cpp 가 같은 이유로 그렇게 되어 있다).
#include "config.h"

#include <windows.h>
#include <objidl.h>
#include <gdiplus.h>

#include "clipsync.h"
#include "enterprise/auth.h"
#include "enterprise/session.h"

#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// 상태
// ---------------------------------------------------------------------------
constexpr wchar_t kWndClass[] = L"SmartScreenClipSync";
constexpr UINT    WM_CLIP_APPLY = WM_APP + 71;   // LPARAM = new Payload*

// 입력이 최근에 있었으면 자주, 자리를 비웠으면 드물게 확인한다. 이 앱은 자리
// 비움을 이미 재고 있으므로 그 값을 쓰면 공짜다. 5초 고정으로 두면 하루에
// 2만 번이 넘는 요청이 되고, 아무도 안 쓰는 밤에도 그대로 돈다.
constexpr DWORD kPollBusyMs = 5000;
constexpr DWORD kPollIdleMs = 30000;
constexpr DWORD kIdleAfterMs = 120000;

// 조회가 연달아 실패하면 간격을 벌린다: 첫 실패 뒤에는 평소대로, 둘째부터는
// 30초. 2분까지 가는 것은 **서버가 답하고 거절하는** 동안뿐이다 (토큰 갱신은
// 되는데 조회는 401/5xx) - 그때 5초마다 같은 요청을 보내고 events.log 에 같은
// 줄을 쌓고 있었다 (그 로그는 날짜도 없이 끝없이 이어 붙는 파일이다).
//
// 서버에 닿지 못한 것(네트워크)은 30초에서 멈춘다. 그것까지 2분으로 벌렸더니
// Wi-Fi 가 잠깐 끊겼다 돌아온 PC 가 최대 2분 동안 아무것도 못 받았다 - 기다림은
// 입력으로 깨지 않으므로, 다른 PC 에서 복사하고 와서 앉아도 그대로다 (2차 검토).
constexpr DWORD kBackoffMidMs  = 30000;
constexpr DWORD kBackoffLongMs = 120000;

// 받은 그림을 풀기 전에 보는 화소 수 상한. PNG 는 몇 백 KB 로 2만x2만 짜리를
// 담을 수 있고(1비트 단색), 그걸 그대로 풀면 1.6 GB 짜리 비트맵을 잡게 된다.
// 바이트 상한(clipMaxKB)으로는 이게 걸러지지 않는다. 8K 화면 한 장이 33 MP 다.
constexpr unsigned long long kMaxPixels = 64ULL * 1000 * 1000;

struct Payload {
    bool        isImage = false;
    std::string bytes;      // isImage 면 PNG, 아니면 UTF-8 텍스트
    // 아래 둘은 받는 쪽에서만 쓴다 (WM_CLIP_APPLY 의 주석).
    unsigned long localGen = 0;   // 조회를 시작하기 전의 s_localGen
    DWORD         postSeq = 0;    // 창 스레드로 넘기기 직전의 클립보드 순번
};

std::mutex     s_mx;               // 아래 묶음을 지킨다
ClipSyncStatus s_status;
std::wstring   s_url, s_key;
unsigned long  s_maxBytes = 0;
std::wstring   s_device;           // 사람이 읽는 PC 이름 (행에 들어간다)
std::wstring   s_devSlug;          // Storage 경로에 쓰는 이름
long long      s_seenId = 0;       // 이 id 까지는 처리했다 (시작 시 기준선)
// 기준선을 적었는지. 시작할 때의 조회가 실패하면 s_seenId 는 0 으로 남는데,
// 그 상태로 다음 조회가 성공하면 서버의 가장 새 행(어제 것일 수 있다)이
// "0 보다 새 것" 이라 그대로 클립보드에 붙었다. 처음 성공한 조회는 언제가
// 되든 기준선만 적는다 (DoPoll).
bool           s_haveBaseline = false;
unsigned long long s_lastHash = 0; // 마지막으로 올렸거나 받아 붙인 내용
DWORD          s_ignoreSeq = 0;    // 우리가 클립보드를 바꾼 직후의 순번
// 이 PC 에서 사용자가 무언가를 새로 복사할 때마다 하나씩 오른다. 우리가 붙인
// 것과 그 되울림은 세지 않는다. 받아 온 것을 붙이기 전에 "가지러 간 사이에
// 여기서 새로 복사했나" 를 가리는 데 쓴다 (WM_CLIP_APPLY).
unsigned long  s_localGen = 0;

Payload*       s_outgoing = nullptr;   // 올릴 것이 있으면 여기 (최신 하나만)

// 조회가 연달아 실패한 횟수. 일꾼 스레드만 만진다.
int            s_pollFails = 0;
// 마지막 조회 실패에 HTTP 상태가 있었는지 (서버가 답하고 거절했다). 서버에 닿지
// 못한 것(네트워크)과 가른다 - kBackoffLongMs 의 주석. 일꾼 스레드만 만진다.
bool           s_pollRefused = false;

HANDLE s_winThread = nullptr;
HANDLE s_workThread = nullptr;
HANDLE s_workEvent = nullptr;      // 올릴 것이 생겼다
HANDLE s_stopEvent = nullptr;
// 창 스레드가 쓰고 일꾼 스레드와 Stop 이 읽는다. 그냥 HWND 로 두면
// PROXIMITY.md 의 버그 목록에 있는 lastReceivedTick 과 같은 모양이 된다.
std::atomic<HWND> s_hwnd{ nullptr };
volatile LONG s_running = 0;

void SetStatus(bool ok, const std::wstring& msg) {
    std::lock_guard<std::mutex> lock(s_mx);
    s_status.lastOk = ok;
    // 길이를 자른다. 이 문장은 간단 창이 256자 고정 버퍼에 찍는다 (main.cpp 의
    // SimpleRefresh). 거기가 swprintf_s 였을 때는 넘치면 프로세스가 끝났다 - 지금은
    // 그쪽도 잘라 쓰지만, 여기 들어오는 것 중에는 서버가 준 오류 문구가 그대로 실린
    // 것이 있어서(세션 갱신 실패) 길이를 믿지 않고 여기서도 자른다.
    s_status.lastMsg = msg.substr(0, 200);
}

// ---------------------------------------------------------------------------
// 내용 식별
// ---------------------------------------------------------------------------
// 암호용이 아니다. "이거 방금 본 것과 같나" 만 답하면 된다. FNV-1a 64.
unsigned long long HashBytes(const void* p, size_t n) {
    const unsigned char* b = (const unsigned char*)p;
    unsigned long long h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= b[i];
        h *= 1099511628211ULL;
    }
    return h;
}

// ---------------------------------------------------------------------------
// GDI+ 로 PNG 굽기 / 읽기
// ---------------------------------------------------------------------------
// 인코더 CLSID 를 상수로 박지 않고 찾는다. 박아 두면 틀렸을 때 Save 가 조용히
// 실패하고, 증상은 "이미지만 안 넘어간다" 가 된다 - 로그로 가릴 수 없다.
bool PngEncoderClsid(CLSID& out) {
    UINT n = 0, size = 0;
    if (Gdiplus::GetImageEncodersSize(&n, &size) != Gdiplus::Ok || size == 0) return false;
    std::vector<unsigned char> buf(size);
    auto* codecs = (Gdiplus::ImageCodecInfo*)buf.data();
    if (Gdiplus::GetImageEncoders(n, size, codecs) != Gdiplus::Ok) return false;
    for (UINT i = 0; i < n; i++) {
        if (codecs[i].MimeType && wcscmp(codecs[i].MimeType, L"image/png") == 0) {
            out = codecs[i].Clsid;
            return true;
        }
    }
    return false;
}

bool StreamToString(IStream* st, std::string& out) {
    HGLOBAL hg = nullptr;
    if (GetHGlobalFromStream(st, &hg) != S_OK || !hg) return false;
    SIZE_T n = GlobalSize(hg);
    void* p = GlobalLock(hg);
    if (!p) return false;
    out.assign((const char*)p, n);
    GlobalUnlock(hg);
    return !out.empty();
}

bool BitmapToPng(HBITMAP hbm, std::string& out, std::wstring& why) {
    CLSID png;
    if (!PngEncoderClsid(png)) { why = L"PNG 인코더를 찾지 못했다"; return false; }

    // FromHBITMAP 은 픽셀을 복사한다. 클립보드가 가진 HBITMAP 은 우리 것이
    // 아니므로 지우지 않는다.
    Gdiplus::Bitmap* bmp = Gdiplus::Bitmap::FromHBITMAP(hbm, nullptr);
    if (!bmp || bmp->GetLastStatus() != Gdiplus::Ok) {
        delete bmp;
        why = L"클립보드 비트맵을 읽지 못했다";
        return false;
    }

    IStream* st = nullptr;
    if (CreateStreamOnHGlobal(nullptr, TRUE, &st) != S_OK) {
        delete bmp;
        why = L"스트림을 만들지 못했다";
        return false;
    }
    bool ok = (bmp->Save(st, &png, nullptr) == Gdiplus::Ok) && StreamToString(st, out);
    if (!ok) why = L"PNG 로 굽지 못했다";
    st->Release();
    delete bmp;
    return ok;
}

bool PngToBitmap(const std::string& png, HBITMAP& out, std::wstring& why) {
    out = nullptr;

    // PNG 서명을 먼저 본다. 이 바이트는 서버에서 온 것이고, 서버의 행은 이 계정의
    // 세션을 가진 누구나 쓸 수 있다. 서명을 안 보면 GDI+ 가 아는 모든 형식
    // (TIFF/GIF/JPEG/BMP/ICO)의 디코더에 그대로 들어가고, 풀리기만 하면 PNG 가
    // 아닌 것이 "PNG" 라는 이름으로 클립보드에 올라간다 (WriteClipboard).
    static const unsigned char kPngSig[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (png.size() < sizeof(kPngSig) || memcmp(png.data(), kPngSig, sizeof(kPngSig)) != 0) {
        why = L"받은 것이 PNG 가 아니다";
        return false;
    }

    IStream* st = nullptr;
    if (CreateStreamOnHGlobal(nullptr, TRUE, &st) != S_OK) {
        why = L"스트림을 만들지 못했다";
        return false;
    }
    ULONG wrote = 0;
    LARGE_INTEGER zero{};
    bool ok = false;
    bool tooBig = false;
    if (st->Write(png.data(), (ULONG)png.size(), &wrote) == S_OK && wrote == png.size() &&
        st->Seek(zero, STREAM_SEEK_SET, nullptr) == S_OK) {
        Gdiplus::Bitmap* bmp = Gdiplus::Bitmap::FromStream(st);
        if (bmp && bmp->GetLastStatus() == Gdiplus::Ok) {
            // 크기는 머리말에서 읽히므로 화소를 풀기 전에 알 수 있다. GetHBITMAP 이
            // 화소당 4바이트를 잡으므로 여기서 거른다 (kMaxPixels 의 주석).
            unsigned long long px = (unsigned long long)bmp->GetWidth() * bmp->GetHeight();
            if (px == 0 || px > kMaxPixels) {
                tooBig = true;
            } else {
                // GetHBITMAP 은 새 HBITMAP 을 만들어 주고 그것은 우리 것이 된다.
                // 클립보드에 넘긴 뒤에는 시스템 것이므로 그때부터 지우지 않는다.
                ok = (bmp->GetHBITMAP(Gdiplus::Color(255, 255, 255), &out) == Gdiplus::Ok);
            }
        }
        delete bmp;
    }
    if (tooBig) why = L"그림의 화소 수가 너무 많거나 0 이라 풀지 않았다";
    else if (!ok) why = L"PNG 를 그림으로 풀지 못했다";
    st->Release();
    return ok;
}

// ---------------------------------------------------------------------------
// 클립보드
// ---------------------------------------------------------------------------
// 등록 클립보드 형식 "PNG".
//
// CF_BITMAP 하나만 올려도 윈도가 CF_DIB / CF_DIBV5 를 알파까지 제대로 합성해
// 준다 (실측함). 그런데 캡처 도구가 남기는 클립보드에는 그 셋 말고 "PNG" 가
// 같이 있고, Chromium/Electron 으로 만든 앱은 이미지를 붙여넣을 때 그것을
// 먼저 찾는다. 그게 없으면 "이미지 처리에 실패했습니다" 로 끝난다 - 그림판에는
// 멀쩡히 붙는데 특정 앱에서만 안 되는 모양이 된다.
//
// 우리는 PNG 바이트를 이미 들고 있으므로 그대로 얹으면 된다. 읽을 때도 같다 -
// 클립보드에 PNG 가 있으면 GDI+ 로 다시 구울 이유가 없고, 그 편이 알파도
// 원본 그대로 간다.
UINT PngFormat() {
    static UINT f = RegisterClipboardFormatW(L"PNG");
    return f;
}

// 다른 앱이 쥐고 있으면 OpenClipboard 는 실패한다. 흔한 일이라 몇 번 기다린다.
bool OpenClipboardRetry(HWND owner) {
    for (int i = 0; i < 8; i++) {
        if (OpenClipboard(owner)) return true;
        Sleep(30);
    }
    return false;
}

// 복사한 앱이 "이건 기록하지도, 다른 기기로 보내지도 말라" 고 표시해 두었는지.
// 클립보드를 연 채로 부른다.
//
// 암호 관리자가 암호를 복사할 때 다는 표시이고, 윈도의 클립보드 기록(Win+V)과
// 클라우드 클립보드가 지키는 약속이다. 우리는 이걸 보지 않고 있었다 - 암호가
// 평문으로 서버에 올라가 다른 PC 의 클립보드에 붙었고, 관리자가 30초 뒤에 이
// PC 의 클립보드를 비워도 그쪽에는 그대로 남았다 (비운 클립보드는 넘길 형식이
// 없어서 아무것도 보내지 않는다).
//
//  - ExcludeClipboardContentFromMonitorProcessing : 있기만 하면 제외
//  - Clipboard Viewer Ignore                       : 같은 뜻의 옛 관례. 있기만 하면 제외
//  - CanIncludeInClipboardHistory / CanUploadToCloudClipboard
//                                                  : DWORD 값이 0 일 때만 제외
//
// 브라우저 확장처럼 표시를 달 수 없는 쪽에서 복사한 암호는 여전히 넘어간다.
bool ClipboardOptedOut() {
    static const UINT fExclude = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
    static const UINT fIgnore  = RegisterClipboardFormatW(L"Clipboard Viewer Ignore");
    static const UINT fHistory = RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
    static const UINT fCloud   = RegisterClipboardFormatW(L"CanUploadToCloudClipboard");

    if (fExclude && IsClipboardFormatAvailable(fExclude)) return true;
    if (fIgnore && IsClipboardFormatAvailable(fIgnore)) return true;

    const UINT valued[2] = { fHistory, fCloud };
    for (UINT f : valued) {
        if (!f || !IsClipboardFormatAvailable(f)) continue;
        HANDLE h = GetClipboardData(f);
        if (!h || GlobalSize(h) < sizeof(DWORD)) continue;
        const DWORD* v = (const DWORD*)GlobalLock(h);
        if (!v) continue;
        bool no = (*v == 0);
        GlobalUnlock(h);
        if (no) return true;
    }
    return false;
}

// 클립보드 창 스레드에서만 부른다.
//
// outOptedOut: 읽지 못한 이유가 위의 표시일 때만 true. 부르는 쪽이 이것만은
// 화면에 말해 줘야 한다 - "넘길 형식이 없다" 는 늘 있는 일이지만, 복사했는데
// 일부러 안 보낸 것은 사용자가 알아야 한다.
bool ReadClipboard(HWND owner, Payload& out, std::wstring& why, bool& outOptedOut) {
    outOptedOut = false;
    if (!OpenClipboardRetry(owner)) { why = L"클립보드를 열지 못했다"; return false; }
    // 무엇이든 읽기 전에 본다. 내용을 읽지 않으므로 해시도 남지 않는다.
    if (ClipboardOptedOut()) {
        CloseClipboard();
        outOptedOut = true;
        why = L"복사한 앱이 공유하지 말라고 표시해서 보내지 않았어요";
        return false;
    }
    bool ok = false;

    // 그림을 먼저 본다. 스크린캡처는 CF_BITMAP/CF_DIB 로 오고, 캡처 도구는
    // 텍스트를 같이 얹지 않는다. 반대로 워드 같은 데서 복사하면 그림과 텍스트가
    // 같이 올라오는데, 그때 사람이 원하는 것은 대개 텍스트다.
    if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        HANDLE h = GetClipboardData(CF_UNICODETEXT);
        if (h) {
            const wchar_t* p = (const wchar_t*)GlobalLock(h);
            if (p) {
                std::wstring w(p);
                GlobalUnlock(h);
                if (!w.empty()) {
                    out.isImage = false;
                    out.bytes = WideToUtf8(w);
                    ok = true;
                }
            }
        }
    }
    // 캡처 도구가 PNG 를 같이 올려 두었으면 그것을 그대로 쓴다. 다시 굽지
    // 않으므로 빠르고, 알파도 원본 그대로 간다.
    if (!ok && IsClipboardFormatAvailable(PngFormat())) {
        HANDLE h = GetClipboardData(PngFormat());
        if (h) {
            SIZE_T n = GlobalSize(h);
            const char* p = (const char*)GlobalLock(h);
            if (p && n > 8) {
                out.bytes.assign(p, n);
                GlobalUnlock(h);
                out.isImage = true;
                ok = true;
            } else if (p) {
                GlobalUnlock(h);
            }
        }
    }
    if (!ok && IsClipboardFormatAvailable(CF_BITMAP)) {
        HBITMAP hbm = (HBITMAP)GetClipboardData(CF_BITMAP);
        if (hbm && BitmapToPng(hbm, out.bytes, why)) {
            out.isImage = true;
            ok = true;
        }
    }
    CloseClipboard();
    if (!ok && why.empty()) why = L"넘길 수 있는 형식이 없다";
    return ok;
}

// 클립보드 창 스레드에서만 부른다.
bool WriteClipboard(HWND owner, const Payload& in, std::wstring& why) {
    HBITMAP hbm = nullptr;
    HGLOBAL hText = nullptr;
    HGLOBAL hPng = nullptr;

    // 클립보드를 열기 전에 만든다. 여는 동안 다른 앱이 기다리게 되므로
    // 안에서 PNG 를 푸는 시간을 보내지 않는다.
    if (in.isImage) {
        if (!PngToBitmap(in.bytes, hbm, why)) return false;
        // 받은 PNG 바이트를 그대로 얹을 사본 (PngFormat 주석 참고).
        // 실패해도 CF_BITMAP 은 올라가므로 그림판 같은 곳에는 붙는다.
        hPng = GlobalAlloc(GMEM_MOVEABLE, in.bytes.size());
        if (hPng) {
            if (void* q = GlobalLock(hPng)) {
                memcpy(q, in.bytes.data(), in.bytes.size());
                GlobalUnlock(hPng);
            } else {
                GlobalFree(hPng);
                hPng = nullptr;
            }
        }
    } else {
        std::wstring w = Utf8ToWide(in.bytes);
        size_t cb = (w.size() + 1) * sizeof(wchar_t);
        hText = GlobalAlloc(GMEM_MOVEABLE, cb);
        if (!hText) { why = L"메모리를 잡지 못했다"; return false; }
        void* p = GlobalLock(hText);
        if (!p) { GlobalFree(hText); why = L"메모리를 잠그지 못했다"; return false; }
        memcpy(p, w.c_str(), cb);
        GlobalUnlock(hText);
    }

    if (!OpenClipboardRetry(owner)) {
        if (hbm) DeleteObject(hbm);
        if (hText) GlobalFree(hText);
        if (hPng) GlobalFree(hPng);
        why = L"클립보드를 열지 못했다";
        return false;
    }
    EmptyClipboard();
    // SetClipboardData 가 성공하면 그 핸들은 시스템 것이 된다. 실패했을 때만
    // 우리가 지운다 - 성공한 뒤에 지우면 붙여넣기가 빈 그림이 된다.
    bool ok;
    if (in.isImage) {
        ok = (SetClipboardData(CF_BITMAP, hbm) != nullptr);
        if (!ok) DeleteObject(hbm);
        // PNG 는 덤이다. 이게 없으면 Electron 계열 앱이 못 받고, 이것만 있으면
        // 옛 앱이 못 받는다. 둘 다 올린다.
        if (hPng && !SetClipboardData(PngFormat(), hPng)) GlobalFree(hPng);
    } else {
        ok = (SetClipboardData(CF_UNICODETEXT, hText) != nullptr);
        if (!ok) GlobalFree(hText);
    }
    CloseClipboard();

    if (ok) {
        // 방금 우리가 만든 변경이다. 이 순번의 알림은 무시한다.
        std::lock_guard<std::mutex> lock(s_mx);
        s_ignoreSeq = GetClipboardSequenceNumber();
        s_lastHash = HashBytes(in.bytes.data(), in.bytes.size());
    } else {
        why = L"클립보드에 올리지 못했다";
    }
    return ok;
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------
std::string JsonEscape(const std::string& s) {
    std::string o;
    o.reserve(s.size() + 16);
    for (unsigned char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\r': o += "\\r";  break;
            case '\t': o += "\\t";  break;
            default:
                if (c < 0x20) {
                    // 클립보드 텍스트는 사람이 복사한 아무 문자열이다. 제어문자를
                    // 그대로 실으면 본문이 깨진 JSON 이 되고, 서버는 그걸
                    // "잘못된 요청" 으로만 말해 준다.
                    char b[8];
                    sprintf_s(b, "\\u%04X", c);
                    o += b;
                } else {
                    o += (char)c;   // UTF-8 바이트는 그대로 (PostgREST 가 받는다)
                }
        }
    }
    return o;
}

// ---------------------------------------------------------------------------
// 서버
// ---------------------------------------------------------------------------
std::vector<std::wstring> AuthHeaders(const std::wstring& access, bool json) {
    std::vector<std::wstring> h = {
        L"apikey: " + s_key,
        L"Authorization: Bearer " + access,
    };
    if (json) h.push_back(L"Content-Type: application/json");
    return h;
}

std::wstring StoragePath() {
    return SessionUserId() + L"/" + s_devSlug + L".png";
}

bool UploadImage(const std::wstring& access, const std::string& png, std::wstring& why) {
    std::vector<std::wstring> h = {
        L"apikey: " + s_key,
        L"Authorization: Bearer " + access,
        L"Content-Type: image/png",
        // 경로가 기기마다 하나로 고정이므로 두 번째 캡처부터는 덮어쓰기다.
        // 이게 없으면 첫 장만 올라가고 그 뒤는 전부 409 가 된다.
        L"x-upsert: true",
    };
    unsigned long st = 0;
    std::string resp;
    if (!SupabaseHttp(L"POST", s_url + L"/storage/v1/object/clip/" + StoragePath(),
                      h, png, st, resp)) {
        why = L"업로드 요청이 실패했다";
        return false;
    }
    if (st < 200 || st >= 300) {
        wchar_t b[32]; swprintf_s(b, L"[%lu] ", st);
        why = std::wstring(L"업로드 거절 ") + b + Utf8ToWide(resp.substr(0, 160));
        return false;
    }
    return true;
}

// 올린 행의 id 를 돌려준다. 그 id 보다 오래된 자기 행은 정리한다.
bool InsertRow(const std::wstring& access, const Payload& p, long long& outId,
               std::wstring& why) {
    std::string body = "{\"device\":\"" + JsonEscape(WideToUtf8(s_device)) + "\",";
    if (p.isImage) {
        body += "\"kind\":\"image\",\"storage_path\":\"" +
                JsonEscape(WideToUtf8(StoragePath())) + "\"";
    } else {
        body += "\"kind\":\"text\",\"body\":\"" + JsonEscape(p.bytes) + "\"";
    }
    char n[32]; sprintf_s(n, "%llu", (unsigned long long)p.bytes.size());
    body += ",\"bytes\":" + std::string(n) + "}";

    std::vector<std::wstring> h = AuthHeaders(access, true);
    // 돌려받지 않으면 방금 만든 id 를 모르고, 그러면 무엇보다 오래된 것을
    // 지워야 하는지도 모른다.
    h.push_back(L"Prefer: return=representation");

    unsigned long st = 0;
    std::string resp;
    // select=id: 돌려받을 것은 id 하나다. 이게 없으면 방금 올린 본문이 통째로
    // 되돌아와서, 큰 텍스트는 올리는 만큼을 한 번 더 내려받는다.
    if (!SupabaseHttp(L"POST", s_url + L"/rest/v1/clip_items?select=id", h, body, st, resp)) {
        why = L"행 삽입 요청이 실패했다";
        return false;
    }
    if (st < 200 || st >= 300) {
        wchar_t b[32]; swprintf_s(b, L"[%lu] ", st);
        why = std::wstring(L"행 삽입 거절 ") + b + Utf8ToWide(resp.substr(0, 160));
        return false;
    }
    if (!JsonGetNumber(resp, "id", outId) || outId <= 0) {
        why = L"삽입은 됐는데 id 를 읽지 못했다";
        return false;
    }
    return true;
}

void PruneOlder(const std::wstring& access, long long keepId) {
    char n[32]; sprintf_s(n, "%lld", keepId);
    std::string body = std::string("{\"p_keep_id\":") + n + "}";
    unsigned long st = 0;
    std::string resp;
    // 실패해도 지금 넘기는 것에는 영향이 없다. 다음에 다시 지우면 된다.
    SupabaseHttp(L"POST", s_url + L"/rest/v1/rpc/prune_clip_items",
                 AuthHeaders(access, true), body, st, resp);
}

struct RemoteItem {
    long long    id = 0;
    std::wstring device;
    bool         isImage = false;
    std::wstring path;      // kind=image
    long long    bytes = 0; // 올린 쪽이 적은 크기. 믿지는 않는다 - 받기 전에 거르는 데만 쓴다
};

// 내 것 중 가장 새 행 하나. 행이 없으면 true + id==0 이다 (오류가 아니다).
//
// PostgREST 에 단일 객체를 달라고(Accept: vnd.pgrst.object+json) 하지 않는다.
// 행이 0개일 때 그게 406 으로 돌아오는데, "아직 아무도 아무것도 복사하지
// 않았다" 는 오류가 아니다. 그걸 오류로 만들면 상태창이 늘 빨갛다.
//
// body 는 여기서 받지 않는다. 받던 동안에는 누군가 1 MB 짜리 텍스트를 복사해
// 두면 그것이 가장 새 행으로 남아 있는 내내, 보낸 PC 를 포함한 모든 PC 가
// 5초마다 그 1 MB 를 다시 내려받고 다시 풀었다 - id 를 보고 "이미 본 것" 이라고
// 돌아서는 것은 다 받은 뒤였다. 본문은 새 행이고, 남의 것이고, 상한 안일 때만
// FetchBody 로 한 번 받는다.
//
// 그래서 예전의 "body 를 select 맨 뒤에 둔다" 는 주의도 여기서는 필요 없어졌다.
// 남은 키의 값(기기 이름, 경로)에 따옴표가 들어 있어도 JSON 에서는 \" 로 실려
// 오므로 파서가 찾는 "키" 꼴과 겹치지 않는다.
//
// outSt: HTTP 상태코드를 받고 싶을 때. 401 을 가려내는 데 쓴다 (DoPoll).
bool FetchNewest(const std::wstring& access, RemoteItem& out, std::wstring& why,
                 unsigned long* outSt = nullptr) {
    unsigned long st = 0;
    std::string resp;
    bool sent = SupabaseHttp(L"GET",
            s_url + L"/rest/v1/clip_items"
                    L"?select=id,device,kind,storage_path,bytes"
                    L"&order=id.desc&limit=1",
            AuthHeaders(access, false), std::string(), st, resp);
    if (outSt) *outSt = st;
    if (!sent) {
        why = L"조회 요청이 실패했다";
        return false;
    }
    if (st < 200 || st >= 300) {
        wchar_t b[32]; swprintf_s(b, L"[%lu] ", st);
        why = std::wstring(L"조회 거절 ") + b + Utf8ToWide(resp.substr(0, 160));
        return false;
    }
    if (!JsonGetNumber(resp, "id", out.id) || out.id <= 0) {
        out.id = 0;      // "[]" = 아직 아무것도 없다
        return true;
    }
    std::string dev, kind, path;
    JsonGetString(resp, "device", dev);
    JsonGetString(resp, "kind", kind);
    out.device = Utf8ToWide(dev);
    out.isImage = (kind == "image");
    if (out.isImage) {
        JsonGetString(resp, "storage_path", path);
        out.path = Utf8ToWide(path);
    }
    JsonGetNumber(resp, "bytes", out.bytes);
    return true;
}

// 텍스트 행 하나의 본문. FetchNewest 가 받지 않는 것을 필요할 때만 받는다.
//
// 그 사이에 행이 없어졌으면 true + 빈 값이다. 보낸 쪽이 더 새 것을 올리고 지난
// 행을 정리한 것이고(prune_clip_items), 오류가 아니다 - 다음 조회가 새 행을 본다.
//
// maxBody: 응답 본문의 상한 (0 = 없음). 넘으면 SupabaseHttp 가 읽다가 멈춘다.
// 행의 bytes 칸은 올린 쪽이 적은 값이라 실제 크기와 같다는 보장이 없고, 서버의
// 길이 제한(supabase/hardening.sql)은 이 PC 의 상한보다 크며 적용돼 있는지도
// 여기서는 알 수 없다.
bool FetchBody(const std::wstring& access, long long id, std::string& out,
               std::wstring& why, size_t maxBody) {
    out.clear();
    wchar_t q[64];
    _snwprintf_s(q, _countof(q), _TRUNCATE, L"?select=body&id=eq.%lld", id);
    unsigned long st = 0;
    std::string resp;
    if (!SupabaseHttp(L"GET", s_url + L"/rest/v1/clip_items" + q,
                      AuthHeaders(access, false), std::string(), st, resp, maxBody)) {
        // 상한에 걸려 멈춘 것도 false 로 온다. 그때는 상태코드가 2xx 다.
        why = (st >= 200 && st < 300) ? L"본문이 상한을 넘거나 받다가 끊겼다"
                                      : L"본문 요청이 실패했다";
        return false;
    }
    if (st < 200 || st >= 300) {
        wchar_t b[32];
        _snwprintf_s(b, _countof(b), _TRUNCATE, L"[%lu] ", st);
        why = std::wstring(L"본문 거절 ") + b + Utf8ToWide(resp.substr(0, 160));
        return false;
    }
    // 응답에는 "body" 키 하나뿐이고 그것이 본문보다 앞에 있다. 본문 안에
    // "body": 꼴의 글자가 있어도 파서는 첫 등장을 집는다.
    JsonGetString(resp, "body", out);   // 행이 없거나 null 이면 빈 값으로 남는다
    return true;
}

// maxBytes: 받을 크기의 상한 (0 = 없음). 이걸 주지 않으면 경로가 가리키는 것이
// 무엇이든 끝까지 메모리에 받는다 - 버킷의 크기 제한은 이 PC 의 상한보다 크고,
// 적용돼 있는지도 여기서는 알 수 없다.
bool DownloadImage(const std::wstring& access, const std::wstring& path,
                   std::string& out, std::wstring& why, size_t maxBytes) {
    unsigned long st = 0;
    if (!SupabaseHttp(L"GET",
            s_url + L"/storage/v1/object/authenticated/clip/" + path,
            AuthHeaders(access, false), std::string(), st, out, maxBytes)) {
        // 상한에 걸려 멈춘 것도 false 로 온다. 그때는 상태코드가 2xx 다.
        why = (st >= 200 && st < 300) ? L"그림이 상한을 넘거나 받다가 끊겼다"
                                      : L"다운로드 요청이 실패했다";
        out.clear();
        return false;
    }
    if (st < 200 || st >= 300) {
        wchar_t b[32]; swprintf_s(b, L"[%lu] ", st);
        why = std::wstring(L"다운로드 거절 ") + b + Utf8ToWide(out.substr(0, 160));
        out.clear();
        return false;
    }
    return !out.empty();
}

// ---------------------------------------------------------------------------
// 창 스레드 - 클립보드는 전부 이 스레드에서만 만진다
// ---------------------------------------------------------------------------
LRESULT CALLBACK ClipWndProc(HWND hw, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CLIPBOARDUPDATE: {
        DWORD seq = GetClipboardSequenceNumber();
        {
            std::lock_guard<std::mutex> lock(s_mx);
            if (seq == s_ignoreSeq) return 0;   // 우리가 방금 올린 것
        }
        Payload p;
        std::wstring why;
        bool optedOut = false;
        if (!ReadClipboard(hw, p, why, optedOut)) {
            // 넘길 형식이 없는 것은 늘 있는 일이라 상태를 흔들지 않는다
            // (파일을 복사하면 CF_HDROP 만 올라온다).
            //
            // 그래도 사용자가 여기서 방금 무언가를 복사했다는 것은 적어 둔다.
            // 넘기지 못하는 것이어도, 가지러 간 사이에 복사한 것 위에 남의 것을
            // 덮으면 안 되기는 마찬가지다 (WM_CLIP_APPLY).
            {
                std::lock_guard<std::mutex> lock(s_mx);
                s_localGen++;
            }
            if (optedOut) {
                // 이것만은 말해 준다. 복사했는데 저쪽에 안 붙는 이유가 어디에도
                // 안 뜨면 고장으로 보인다. 내용은 읽지 않았으므로 로그에도 없다.
                SetStatus(true, why);
                DbgEvent(L"clip: not sent - the source app marked it as not to be shared");
            }
            return 0;
        }
        unsigned long long h = HashBytes(p.bytes.data(), p.bytes.size());
        unsigned long cap;
        {
            // 이 비교에는 일부러 기한을 두지 않았다.
            //
            // 기한을 두자는 검토 의견이 있었다. A 가 보낸 X 를 B 가 받지 못했을 때
            // (내려받기 실패, B 가 X 보다 늦게 켜져서 기준선으로만 적었다) 사람은
            // A 에서 X 를 다시 복사하는데, 그것이 여기서 아무 말 없이 버려진다 -
            // 다른 것을 먼저 복사해야 넘어간다. 그 불편은 그대로 남아 있다.
            //
            // 두지 않은 이유: 같은 내용의 알림이 "사용자가 다시 복사했다" 인지
            // "순번만 한 번 더 올랐다" 인지 여기서는 가릴 수 없다. 뒤의 것은 형식
            // 합성이나 늦은 렌더링(엑셀처럼 형식을 붙여넣을 때 만들어 주는 앱)으로
            // 생기고, 붙여넣는 순간에 일어나므로 복사한 지 몇 분 뒤일 수 있다 -
            // 몇 초짜리 기한으로는 걸러지지 않는다. 그것을 새 복사로 치면
            //  - 받은 쪽에서는 받은 것을 도로 올린다. 되울림이다.
            //  - 보낸 쪽에서만 기한을 풀면(받은 것의 해시는 그대로 두면) 고리는
            //    생기지 않는다: 받아 붙인 PC 는 그 내용을 올리지 않으므로 돌아올
            //    행이 없다. 하지만 오래전에 복사한 것이 가장 새 행으로 다시
            //    올라간다. 그 사이에 저쪽에서 복사했고 이쪽이 아직 조회하지 않은
            //    것이 있으면(자리를 비웠던 PC 는 30초에 한 번 조회한다) 그것이 두 PC
            //    모두에서 옛것으로 덮인다. "A 에서 복사하고 B 로 와서 바로 붙여넣는다"
            //    가 바로 그 순간이다.
            // 붙여넣을 때 이 알림이 실제로 오는지를 두 대에서 재 보기 전에는 풀지 말 것.
            std::lock_guard<std::mutex> lock(s_mx);
            if (h == s_lastHash) return 0;      // 방금 올렸거나 받아 붙인 그것
            cap = s_maxBytes;
        }
        if (cap && p.bytes.size() > cap) {
            {
                std::lock_guard<std::mutex> lock(s_mx);
                s_localGen++;                   // 못 보내도 새로 복사한 것은 맞다
            }
            wchar_t b[96];
            swprintf_s(b, L"%zu KB 라 건너뜀 (상한 %lu KB)",
                       p.bytes.size() / 1024, cap / 1024);
            SetStatus(false, b);
            return 0;
        }
        {
            std::lock_guard<std::mutex> lock(s_mx);
            delete s_outgoing;                  // 올리기 전에 또 복사했으면 새 것만
            s_outgoing = new Payload(std::move(p));
            s_lastHash = h;
            // 넣는 것과 같은 잠금 안에서 올린다. 일꾼이 이 값을 읽었을 때 "이미
            // 센 복사는 s_outgoing 에 들어 있다" 가 성립해야 한다 (WorkerThread).
            s_localGen++;
        }
        SetEvent(s_workEvent);
        return 0;
    }
    case WM_CLIP_APPLY: {
        Payload* p = (Payload*)lp;
        std::wstring why;

        // 가지러 간 사이에 사용자가 여기서 새로 복사했으면 붙이지 않는다.
        //
        // 일꾼이 행을 보고 그림을 내려받는 데는 몇 초가 걸릴 수 있고, 그 사이에도
        // 이 스레드는 알림을 받는다. 예전에는 내려받기가 끝나면 무조건 붙였다 -
        // 방금 여기서 복사한 Y 가 그보다 먼저 저쪽에서 복사된 X 로 덮였고, Y 는
        // 그 뒤에 올라가 저쪽에 붙었다. 두 PC 가 서로의 것을 들고 끝났고, 방금
        // 복사한 자리에서 Ctrl+V 를 누르면 남의 옛것이 나왔다.
        //
        // 두 가지를 본다.
        //  - localGen: 일꾼이 이번 바퀴를 시작할 때(올리기 전)의 s_localGen. 그 뒤에
        //    알림이 하나라도 "새 복사" 로 세어졌으면 다르다.
        //  - postSeq: 일꾼이 이 메시지를 부치기 직전의 클립보드 순번. 부친 뒤에
        //    복사한 것은 그 알림이 아직 큐에서 이 메시지 뒤에 있어 localGen 으로는
        //    안 보인다. 여기서 덮으면 s_ignoreSeq 가 그 순번이 되어 뒤따라 오는
        //    알림까지 "우리가 한 것" 으로 버려지고, Y 는 두 PC 어디에도 남지 않는다.
        //    순번이 s_ignoreSeq 와 같은 경우는 뺀다 - 앞서 부친 것을 우리가 붙여서
        //    오른 것이다.
        // 순번만으로 처음부터 끝까지 보지 않는 이유: 순번은 붙여넣기(형식 합성,
        // 늦은 렌더링)로도 오르고, 내려받는 몇 초 사이에 그게 끼면 멀쩡한 것을
        // 버리게 된다. 부치고 처리하기까지의 ms 사이라면 그럴 일이 거의 없다.
        //
        // s_outgoing 이 비었는지는 보지 않는다. 일꾼이 이미 가져갔을 수 있다.
        //
        // 버린 것은 다시 받지 않는다 (s_seenId 는 이미 올랐다). 여기서 복사한 것이
        // 더 새것이고, 그것이 올라가면 저쪽도 그것으로 맞춰진다.
        DWORD curSeq = GetClipboardSequenceNumber();
        bool stale = false;
        {
            std::lock_guard<std::mutex> lock(s_mx);
            stale = (p->localGen != s_localGen) ||
                    (curSeq != p->postSeq && curSeq != s_ignoreSeq);
        }
        if (stale) {
            SetStatus(true, L"여기서 방금 복사한 것이 더 새것이라 받은 것은 붙이지 않았어요");
            DbgEvent(L"clip: incoming %s dropped - a newer local copy exists",
                     p->isImage ? L"image" : L"text");
            delete p;
            return 0;
        }

        if (WriteClipboard(hw, *p, why)) {
            {
                std::lock_guard<std::mutex> lock(s_mx);
                s_status.received++;
            }
            SetStatus(true, p->isImage ? L"그림을 받았습니다" : L"텍스트를 받았습니다");
            DbgEvent(L"clip: applied %s (%zu bytes)",
                     p->isImage ? L"image" : L"text", p->bytes.size());
        } else {
            SetStatus(false, why);
            DbgEvent(L"clip: apply failed - %s", why.c_str());
        }
        delete p;
        return 0;
    }
    case WM_DESTROY:
        RemoveClipboardFormatListener(hw);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hw, msg, wp, lp);
}

DWORD WINAPI WindowThread(LPVOID) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = ClipWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kWndClass;
    RegisterClassExW(&wc);   // 이미 등록돼 있으면 실패하고, 그건 문제가 없다

    // HWND_MESSAGE 창을 쓰지 않는다. 클립보드 알림은 등록한 창에 직접
    // 보내지므로 동작할 것 같지만, 확인할 방법이 여기서는 없다. 숨긴 보통
    // 창이면 의심할 거리가 하나 줄어든다.
    HWND hw = CreateWindowExW(0, kWndClass, L"", WS_OVERLAPPED,
                             0, 0, 0, 0, nullptr, nullptr,
                             GetModuleHandleW(nullptr), nullptr);
    if (!hw) {
        SetStatus(false, L"클립보드 감시 창을 만들지 못했다");
        return 0;
    }
    if (!AddClipboardFormatListener(hw)) {
        SetStatus(false, L"클립보드 알림을 받을 수 없다");
        DestroyWindow(hw);
        return 0;
    }
    s_hwnd = hw;
    DbgEvent(L"clip: listening as '%s'", s_device.c_str());

    MSG m;
    while (GetMessageW(&m, nullptr, 0, 0)) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    s_hwnd = nullptr;
    return 0;
}

// ---------------------------------------------------------------------------
// 일꾼 스레드 - 네트워크는 전부 이 스레드에서만
// ---------------------------------------------------------------------------
DWORD IdleMs() {
    LASTINPUTINFO li{ sizeof(li) };
    if (!GetLastInputInfo(&li)) return 0;
    return GetTickCount() - li.dwTime;
}

void DoUpload(const std::wstring& access) {
    Payload* p = nullptr;
    {
        std::lock_guard<std::mutex> lock(s_mx);
        p = s_outgoing;
        s_outgoing = nullptr;
    }
    if (!p) return;

    std::wstring why;
    bool ok = true;
    if (p->isImage) ok = UploadImage(access, p->bytes, why);

    long long id = 0;
    if (ok) ok = InsertRow(access, *p, id, why);

    if (ok) {
        {
            std::lock_guard<std::mutex> lock(s_mx);
            s_status.sent++;
            // 내가 올린 것을 되받지 않도록 기준선을 올린다.
            if (id > s_seenId) s_seenId = id;
        }
        SetStatus(true, p->isImage ? L"그림을 보냈습니다" : L"텍스트를 보냈습니다");
        DbgEvent(L"clip: sent %s id=%lld (%zu bytes)",
                 p->isImage ? L"image" : L"text", id, p->bytes.size());
        PruneOlder(access, id);
    } else {
        SetStatus(false, why);
        DbgEvent(L"clip: send failed - %s", why.c_str());
        // 해시를 놓아 준다. 안 그러면 같은 것을 다시 복사해도 "방금 올린 것"
        // 으로 걸러져서, 한 번 실패한 내용은 영영 못 보낸다. 자동 재시도는
        // 하지 않는다 - 계속 실패하는 항목이 5초마다 도는 편이 더 나쁘다.
        //
        // 놓는 것은 그 해시가 아직 이 항목의 것일 때만이다. 올리는 몇 초 사이에 창
        // 스레드가 남의 것을 받아 붙였으면 해시는 이미 그것의 것이고, 그걸 0 으로
        // 만들면 받은 것의 늦은 알림이 되울림 방지를 빠져나간다.
        unsigned long long mineHash = HashBytes(p->bytes.data(), p->bytes.size());
        std::lock_guard<std::mutex> lock(s_mx);
        if (s_lastHash == mineHash) s_lastHash = 0;
    }
    delete p;
}

// localGen: 이번 바퀴를 시작할 때의 s_localGen (WM_CLIP_APPLY 의 주석).
void DoPoll(const std::wstring& access, unsigned long localGen) {
    RemoteItem it;
    std::wstring why;
    unsigned long st = 0;
    if (!FetchNewest(access, it, why, &st)) {
        // 401 은 서버가 이 토큰을 거절했다는 뜻이다. 세션 쪽은 이 PC 에서 잰
        // 시간으로만 만료를 판단하므로, 그 판단이 서버와 어긋나면 여기서 알려
        // 주지 않는 한 같은 토큰을 계속 받는다 (session.h 의 SessionInvalidate).
        // Storage 는 만료된 토큰을 400/403 으로 말하기도 하지만, 올리기와 조회가
        // 같은 바퀴에서 같은 토큰으로 나가므로 조회에서 잡으면 된다.
        if (st == 401) SessionInvalidate();
        SetStatus(false, why);
        // 연달아 실패하는 동안에는 첫 번만 적는다 (kBackoffMidMs 의 주석).
        if (s_pollFails == 0) {
            DbgEvent(L"clip: poll failed - %s (repeats are not logged until it recovers)",
                     why.c_str());
        }
        s_pollRefused = (st != 0);
        if (s_pollFails < 1000000) s_pollFails++;
        return;
    }
    if (s_pollFails) {
        DbgEvent(L"clip: poll recovered after %d failed attempt(s)", s_pollFails);
        s_pollFails = 0;
        // 실패 문구가 상태 줄에 남아 있으면 다 나은 뒤에도 "안 됨" 으로 보인다.
        SetStatus(true, L"다시 연결됐어요");
    }

    long long seen;
    std::wstring mine;
    unsigned long cap;
    bool baseline;
    {
        std::lock_guard<std::mutex> lock(s_mx);
        // 처음 성공한 조회는 기준선만 적는다 (s_haveBaseline 의 주석). 행이 하나도
        // 없을 때(id==0)에도 적은 것으로 친다 - 그러지 않으면 빈 테이블에서 시작한
        // PC 가 나중에 오는 첫 항목을 기준선으로 삼켜 버린다. 그래서 아래의
        // id==0 검사보다 앞에 있다.
        baseline = !s_haveBaseline;
        if (baseline) {
            s_haveBaseline = true;
            // 그 전에 내가 올린 것이 있으면 s_seenId 가 이미 올라 있다. 내리지 않는다.
            if (it.id > s_seenId) s_seenId = it.id;
        }
        seen = s_seenId;
        mine = s_device;
        cap = s_maxBytes;
    }
    if (baseline) {
        DbgEvent(L"clip: baseline id=%lld", it.id);
        return;
    }
    if (it.id == 0) return;
    if (it.id <= seen) return;

    // 여기서 기준선을 먼저 올린다. 아래에서 실패해도 같은 항목을 5초마다
    // 영원히 다시 시도하지 않게 한다 - 실패하는 항목 하나가 그 뒤에 오는
    // 모든 것을 막으면 기능이 통째로 멎는다.
    {
        std::lock_guard<std::mutex> lock(s_mx);
        s_seenId = it.id;
    }
    if (it.device == mine) return;    // 내가 올린 것

    // 상한은 받을 때도 지킨다. 예전에는 보낼 때만 봤다 - 상한을 더 크게 잡았거나
    // 0 으로 둔 다른 PC 가 올린 것, 그리고 이 계정의 세션을 가진 누군가가 행에
    // 적어 넣은 것은 크기가 얼마든 끝까지 내려받아 메모리에 올렸다.
    //
    // 세 번 본다. 받기 전에 행의 bytes 로(올린 쪽이 적은 값이라 거짓일 수 있지만
    // 정직한 큰 항목은 여기서 요청 없이 걸러진다), 받는 동안 SupabaseHttp 의
    // 상한으로, 받은 뒤 실제 크기로.
    //
    // 받은 크기가 행의 bytes 와 "같은지" 는 보지 않는다. 그림 파일은 기기마다
    // 하나를 덮어쓰므로, 보낸 쪽이 연달아 올리면 파일이 행보다 새것일 수 있다
    // (docs/CLIPBOARD.md "그림 경로는 기기마다 하나이고 덮어쓴다").
    if (cap && it.bytes > (long long)cap) {
        wchar_t b[96];
        _snwprintf_s(b, _countof(b), _TRUNCATE, L"%lld KB 라 받지 않음 (상한 %lu KB)",
                     it.bytes / 1024, cap / 1024);
        SetStatus(false, b);
        DbgEvent(L"clip: incoming id=%lld not fetched - %lld bytes is over the cap",
                 it.id, it.bytes);
        return;
    }

    Payload* p = new Payload();
    p->isImage = it.isImage;
    p->localGen = localGen;
    bool got;
    if (it.isImage) {
        got = DownloadImage(access, it.path, p->bytes, why, cap);
    } else {
        // JSON 에 실려 오는 동안에는 본문이 원래보다 길다. 제어문자 하나가
        // \u0001 여섯 글자가 되는 것이 가장 크게 불어나는 경우다.
        got = FetchBody(access, it.id, p->bytes, why,
                        cap ? (size_t)cap * 6 + 4096 : 0);
    }
    if (!got) {
        SetStatus(false, why);
        DbgEvent(L"clip: download failed - %s", why.c_str());
        delete p;
        // 글의 본문을 따로 받게 된 뒤로는 그 요청 하나가 실패하면 그 글을 영영 못
        // 받는다 (기준선은 위에서 이미 올렸다). 본문이 조회에 같이 실려 오던 때는
        // 없던 일이다. 같은 id 는 다음 조회에서 한 번만 다시 받아 본다 - 상한을
        // 넘어서 실패한 것도 한 번 더 받게 되지만 거기서 멈춘다. s_seenId 는 시작한
        // 뒤로 일꾼 스레드만 쓰고, 그 사이에 내가 올린 것이 있어 값이 달라졌으면
        // 손대지 않는다.
        static long long retriedId = 0;
        if (!it.isImage && retriedId != it.id) {
            retriedId = it.id;
            std::lock_guard<std::mutex> lock(s_mx);
            if (s_seenId == it.id) s_seenId = seen;
        }
        return;
    }
    if (p->bytes.empty()) { delete p; return; }
    if (cap && p->bytes.size() > cap) {
        wchar_t b[96];
        _snwprintf_s(b, _countof(b), _TRUNCATE, L"%zu KB 라 받지 않음 (상한 %lu KB)",
                     p->bytes.size() / 1024, cap / 1024);
        SetStatus(false, b);
        DbgEvent(L"clip: incoming id=%lld dropped - %zu bytes is over the cap",
                 it.id, p->bytes.size());
        delete p;
        return;
    }

    // 붙이기는 창 스레드가 한다. 클립보드를 두 스레드에서 만지면 우리가 바꾼
    // 것인지 판단하는 순번이 어긋난다. (순번을 읽기만 하는 것은 어느
    // 스레드에서든 된다.)
    p->postSeq = GetClipboardSequenceNumber();
    HWND hw = s_hwnd.load();
    if (!hw || !PostMessageW(hw, WM_CLIP_APPLY, 0, (LPARAM)p)) delete p;
}

DWORD WINAPI WorkerThread(LPVOID) {
    s_pollFails = 0;
    // 세션을 못 얻는 중이었는지. 조회 실패는 DoPoll 이 상태 줄을 걷어 내지만
    // (s_pollFails) 세션 실패는 그 셈에 들지 않는다. 네트워크 없이 켠 PC 는 연결이
    // 돌아와 기준선까지 적은 뒤에도, 무언가를 주고받기 전까지 타일이 "안 됨" 으로
    // 남았다 - main.cpp 가 이제 세션을 되살리지 못해도 계정만 있으면 켜므로
    // 부팅 때 Wi-Fi 가 늦게 붙는 노트북은 매번 그랬다.
    bool sessionDown = false;

    // 켜자마자 한 번 조회한다. 처음 성공한 조회는 기준선만 적고 아무것도 붙이지
    // 않는다 (clipsync.h 머리말, DoPoll). 여기서 실패해도 되는 이유가 그것이다 -
    // 예전에는 기준선을 여기서만 적었고, 이 한 번이 실패하면 다시 적지 않았다.
    {
        std::wstring access, why;
        if (SessionToken(access, why)) DoPoll(access, 0);
        else { SetStatus(false, why); sessionDown = true; }
    }

    HANDLE waits[2] = { s_stopEvent, s_workEvent };
    for (;;) {
        DWORD every = (IdleMs() > kIdleAfterMs) ? kPollIdleMs : kPollBusyMs;
        // 조회가 연달아 실패하는 중이면 간격을 벌린다 (kBackoffMidMs 의 주석).
        // 그 사이에 사용자가 무언가를 복사하면 s_workEvent 가 깨우므로 올리기는
        // 늦어지지 않는다.
        if (s_pollFails >= 3 && s_pollRefused) every = kBackoffLongMs;
        else if (s_pollFails >= 2 && every < kBackoffMidMs) every = kBackoffMidMs;
        DWORD r = WaitForMultipleObjects(2, waits, FALSE, every);
        // WAIT_FAILED 에서도 나간다. Stop 이 기다리다 지쳐 핸들을 닫았으면
        // 여기가 실패로 돌아오는데, 그걸 무시하면 닫힌 핸들로 영원히 돈다.
        if (r == WAIT_OBJECT_0 || r == WAIT_FAILED) break;

        std::wstring access, why;
        if (!SessionToken(access, why)) {
            SetStatus(false, why);
            sessionDown = true;
            // 세션이 없으면 할 수 있는 일이 없다. 5초마다 다시 물어보면
            // 로그가 그것만으로 가득 차므로 한 박자 쉰다.
            if (WaitForSingleObject(s_stopEvent, 30000) == WAIT_OBJECT_0) break;
            continue;
        }
        if (sessionDown) {
            // 세션이 돌아왔다. 아래의 올리기/조회보다 먼저 걷어 낸다 - 그쪽이
            // 실패하면 그 사유가 이 문구를 다시 덮어야 하기 때문이다.
            sessionDown = false;
            SetStatus(true, L"다시 연결됐어요");
        }
        // 올리기 전에 읽어 둔다. 이 값을 읽은 뒤에 여기서 복사한 것이 있으면,
        // 이번 바퀴에서 받아 온 것은 붙이지 않는다 (WM_CLIP_APPLY). 조회 직전이
        // 아니라 올리기 전인 이유: 올리는 몇 초 사이에 복사한 것은 아직
        // s_outgoing 에 남아 있고, 그것도 "받아 온 것보다 새것" 이다.
        unsigned long gen;
        {
            std::lock_guard<std::mutex> lock(s_mx);
            gen = s_localGen;
        }
        // 올릴 것이 있으면 먼저 올린다. 내가 방금 복사한 것을 넘기는 쪽이
        // 남이 올린 것을 받는 것보다 급하다.
        DoUpload(access);
        DoPoll(access, gen);
    }
    return 0;
}

// Storage 경로에 쓸 이름. 호스트 이름에 무엇이 들어 있을지 모르므로 좁게 받는다.
std::wstring Slug(const std::wstring& in) {
    std::wstring o;
    for (wchar_t c : in) {
        if ((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
            (c >= L'0' && c <= L'9') || c == L'-' || c == L'_') o += c;
        else o += L'_';
    }
    if (o.empty()) o = L"pc";
    if (o.size() > 48) o.resize(48);
    return o;
}

} // namespace

// ---------------------------------------------------------------------------
bool ClipSyncStart(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                   unsigned long maxBytes) {
    if (InterlockedCompareExchange(&s_running, 1, 0) != 0) return true;  // 이미 돈다

    if (!SessionHasAccount()) {
        s_running = 0;
        SetStatus(false, L"먼저 구글 계정으로 로그인하세요");
        return false;
    }

    wchar_t name[MAX_COMPUTERNAME_LENGTH + 1] = {};
    DWORD n = _countof(name);
    if (!GetComputerNameW(name, &n)) wcscpy_s(name, L"PC");

    {
        std::lock_guard<std::mutex> lock(s_mx);
        s_url = supabaseUrl;
        s_key = anonKey;
        s_maxBytes = maxBytes;
        s_device = name;
        s_devSlug = Slug(name);
        s_seenId = 0;
        s_haveBaseline = false;
        s_lastHash = 0;
        s_ignoreSeq = 0;
        s_localGen = 0;
        s_status = ClipSyncStatus{};
        s_status.running = true;
    }

    s_workEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    s_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    s_winThread = CreateThread(nullptr, 0, WindowThread, nullptr, 0, nullptr);
    s_workThread = CreateThread(nullptr, 0, WorkerThread, nullptr, 0, nullptr);
    if (!s_workEvent || !s_stopEvent || !s_winThread || !s_workThread) {
        ClipSyncStop();
        SetStatus(false, L"스레드를 만들지 못했다");
        return false;
    }
    DbgEvent(L"clip: started (cap %lu KB)", maxBytes / 1024);
    return true;
}

void ClipSyncStop() {
    if (s_stopEvent) SetEvent(s_stopEvent);
    if (HWND hw = s_hwnd.load()) PostMessageW(hw, WM_CLOSE, 0, 0);

    // 일꾼은 요청 하나를 기다리고 있을 수 있다. SupabaseHttp 가 타임아웃을
    // 걸어 두므로 최악이 수십 초가 아니라 십여 초다.
    //
    // 기다리다 지쳤으면 핸들을 닫지 않는다. 아직 도는 스레드가 쓰는 이벤트를
    // 닫으면 그쪽이 닫힌 핸들을 기다리게 되고, 핸들 값이 재사용되면 무슨 일이
    // 일어날지 알 수 없다. 스레드 핸들 하나를 흘리는 편이 훨씬 싸다 -
    // 끄고 켜기를 반복해도 몇 개에 그친다.
    bool workDone = true, winDone = true;
    if (s_workThread) workDone = (WaitForSingleObject(s_workThread, 20000) == WAIT_OBJECT_0);
    if (s_winThread)  winDone  = (WaitForSingleObject(s_winThread, 5000)  == WAIT_OBJECT_0);
    if (workDone && s_workThread) { CloseHandle(s_workThread); s_workThread = nullptr; }
    if (winDone && s_winThread)   { CloseHandle(s_winThread);  s_winThread = nullptr; }

    {
        std::lock_guard<std::mutex> lock(s_mx);
        delete s_outgoing;
        s_outgoing = nullptr;
        s_status.running = false;
    }

    if (workDone && winDone) {
        if (s_workEvent) { CloseHandle(s_workEvent); s_workEvent = nullptr; }
        if (s_stopEvent) { CloseHandle(s_stopEvent); s_stopEvent = nullptr; }
        s_running = 0;
        DbgEvent(L"clip: stopped");
    } else {
        // s_running 을 1 로 남겨 다시 시작하지 못하게 한다. 풀어 주면 다음
        // [켜기] 가 두 번째 일꾼을 띄우고 핸들을 덮어써서, 두 벌이 같은 상태를
        // 만지게 된다 - 꺼졌다고 표시된 채로 계속 도는 것보다 훨씬 나쁘다.
        SetStatus(false, L"멈추는 중이에요. 앱을 다시 켜면 확실히 정리됩니다");
        DbgEvent(L"clip: stop timed out, threads still live (work=%d win=%d)",
                 workDone ? 1 : 0, winDone ? 1 : 0);
    }
}

bool ClipSyncRunning() {
    std::lock_guard<std::mutex> lock(s_mx);
    return s_status.running;
}

ClipSyncStatus ClipSyncGetStatus() {
    std::lock_guard<std::mutex> lock(s_mx);
    return s_status;
}

// ---------------------------------------------------------------------------
// 진단 왕복. 근거는 clipsync.h 의 해당 선언 위 주석.
// ---------------------------------------------------------------------------
namespace {

// 시험용 PNG. 클립보드에서 가져오지 않는다 - 왕복을 보는 것이 목적이고,
// 사람이 마침 무엇을 복사해 뒀는지에 결과가 달라지면 안 된다.
bool MakeTestPng(std::string& out, std::wstring& why) {
    CLSID png;
    if (!PngEncoderClsid(png)) { why = L"PNG 인코더를 찾지 못했다"; return false; }
    Gdiplus::Bitmap bmp(64, 64, PixelFormat32bppARGB);
    if (bmp.GetLastStatus() != Gdiplus::Ok) { why = L"비트맵을 만들지 못했다"; return false; }
    for (int yy = 0; yy < 64; yy++)
        for (int xx = 0; xx < 64; xx++)
            bmp.SetPixel(xx, yy, Gdiplus::Color(255, (BYTE)(xx * 4), (BYTE)(yy * 4), 0x40));

    IStream* st = nullptr;
    if (CreateStreamOnHGlobal(nullptr, TRUE, &st) != S_OK) {
        why = L"스트림을 만들지 못했다"; return false;
    }
    bool ok = (bmp.Save(st, &png, nullptr) == Gdiplus::Ok) && StreamToString(st, out);
    if (!ok) why = L"PNG 로 굽지 못했다";
    st->Release();
    return ok;
}

void Line(std::wstring& r, const wchar_t* mark, const std::wstring& text) {
    r += mark; r += L" "; r += text; r += L"\n";
}

} // namespace

bool ClipSyncRoundTrip(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                       std::wstring& outReport) {
    outReport.clear();
    std::wstring why;

    if (!SessionHasAccount()) {
        outReport = L"[X] 로그인한 계정이 없다. 먼저 [폰 등록] 에서 계정으로 로그인할 것.\n";
        return false;
    }
    std::wstring access;
    if (!SessionToken(access, why)) {
        Line(outReport, L"[X]", L"세션: " + why);
        return false;
    }
    Line(outReport, L"[OK]", L"세션 (" + SessionEmail() + L")");

    wchar_t name[MAX_COMPUTERNAME_LENGTH + 1] = {};
    DWORD n = _countof(name);
    if (!GetComputerNameW(name, &n)) wcscpy_s(name, L"PC");
    {
        std::lock_guard<std::mutex> lock(s_mx);
        s_url = supabaseUrl;
        s_key = anonKey;
        s_device = name;
        s_devSlug = Slug(name);
    }
    Line(outReport, L"[..]", std::wstring(L"이 PC: ") + name + L"  경로: " + StoragePath());

    bool allOk = true;

    // ---- 텍스트 ----
    {
        Payload p;
        p.isImage = false;
        // 서버를 거치며 깨지기 쉬운 것들을 일부러 넣는다: 따옴표, 역슬래시,
        // 줄바꿈, 탭, 한글, 그리고 \u 로 실려 오는 제어문자.
        p.bytes = "SmartScreen \"clip\" test\\1\n\t\xEA\xB0\x80\xEB\x82\x98\xEB\x8B\xA4 \x01";
        long long id = 0;
        if (!InsertRow(access, p, id, why)) {
            Line(outReport, L"[X]", L"텍스트 올리기: " + why);
            allOk = false;
        } else {
            // 받는 쪽(DoPoll)과 같은 두 걸음으로 읽는다: 조회는 본문 없이, 본문은
            // 그 행 하나만 따로.
            RemoteItem it;
            std::string body;
            if (!FetchNewest(access, it, why)) {
                Line(outReport, L"[X]", L"텍스트 조회: " + why);
                allOk = false;
            } else if (it.id != id) {
                Line(outReport, L"[X]", L"방금 올린 행이 가장 새 행이 아니다");
                allOk = false;
            } else if (it.isImage) {
                Line(outReport, L"[X]", L"kind 가 text 로 돌아오지 않았다");
                allOk = false;
            } else if (it.bytes != (long long)p.bytes.size()) {
                // 받는 쪽이 내려받기 전에 상한을 보는 데 이 칸을 쓴다.
                Line(outReport, L"[X]", L"행의 bytes 가 올린 크기와 다르게 돌아왔다");
                allOk = false;
            } else if (!FetchBody(access, it.id, body, why, 0)) {
                Line(outReport, L"[X]", L"텍스트 본문 조회: " + why);
                allOk = false;
            } else if (body != p.bytes) {
                // 여기서 걸리면 JSON 이스케이프나 \u 풀기가 틀린 것이다.
                wchar_t b[128];
                swprintf_s(b, L"텍스트가 달라졌다 (보냄 %zu 바이트, 받음 %zu 바이트)",
                           p.bytes.size(), body.size());
                Line(outReport, L"[X]", b);
                allOk = false;
            } else {
                Line(outReport, L"[OK]", L"텍스트 왕복 (제어문자·한글·따옴표 포함)");
            }
        }
    }

    // ---- 그림 ----
    {
        Payload p;
        p.isImage = true;
        if (!MakeTestPng(p.bytes, why)) {
            Line(outReport, L"[X]", L"시험 PNG: " + why);
            allOk = false;
        } else if (!UploadImage(access, p.bytes, why)) {
            Line(outReport, L"[X]", L"그림 올리기: " + why);
            allOk = false;
        } else {
            long long id = 0;
            if (!InsertRow(access, p, id, why)) {
                Line(outReport, L"[X]", L"그림 행 삽입: " + why);
                allOk = false;
            } else {
                std::string got;
                if (!DownloadImage(access, StoragePath(), got, why, 0)) {
                    Line(outReport, L"[X]", L"그림 내려받기: " + why);
                    allOk = false;
                } else if (got != p.bytes) {
                    wchar_t b[128];
                    swprintf_s(b, L"그림 바이트가 다르다 (보냄 %zu, 받음 %zu)",
                               p.bytes.size(), got.size());
                    Line(outReport, L"[X]", b);
                    allOk = false;
                } else {
                    wchar_t b[96];
                    swprintf_s(b, L"그림 왕복 (%zu 바이트)", p.bytes.size());
                    Line(outReport, L"[OK]", b);

                    // 받은 PNG 가 실제로 그림으로 풀리는지. 바이트가 같아도
                    // 여기서 막히면 붙여넣기가 빈 그림이 된다.
                    HBITMAP hbm = nullptr;
                    if (PngToBitmap(got, hbm, why)) {
                        BITMAP bi{};
                        GetObject(hbm, sizeof(bi), &bi);
                        swprintf_s(b, L"PNG 풀기 (%ldx%ld)", bi.bmWidth, bi.bmHeight);
                        Line(outReport, L"[OK]", b);
                        DeleteObject(hbm);
                    } else {
                        Line(outReport, L"[X]", L"PNG 풀기: " + why);
                        allOk = false;
                    }

                    // 상한을 주면 받다가 멈추는지. 받는 쪽의 크기 상한은 SupabaseHttp
                    // 가 이 약속을 지키는 것에 기댄다 - 상한을 무시하고 끝까지 받아
                    // 오면 평소에는 아무 증상이 없고, 여기서만 드러난다.
                    std::string cut;
                    std::wstring cutWhy;
                    if (DownloadImage(access, StoragePath(), cut, cutWhy, 16)) {
                        Line(outReport, L"[X]", L"상한(16 바이트)을 줬는데도 그림을 끝까지 받았다");
                        allOk = false;
                    } else {
                        Line(outReport, L"[OK]", L"상한을 넘는 것은 받다가 멈춘다");
                    }
                }
                // 두 번 올려 덮어쓰기(x-upsert)가 되는지. 정책에 update 가
                // 빠져 있으면 여기서만 걸린다 - 실기에서는 "두 번째 캡처부터
                // 안 된다" 로 나타나고, 그건 원인을 짐작하기 어렵다.
                if (UploadImage(access, p.bytes, why))
                    Line(outReport, L"[OK]", L"같은 경로에 덮어쓰기");
                else {
                    Line(outReport, L"[X]", L"덮어쓰기: " + why);
                    allOk = false;
                }
                PruneOlder(access, id);
                Line(outReport, L"[..]", L"지난 행 정리함");
            }
        }
    }

    outReport += allOk ? L"\n전부 통과. 남은 변수는 상대 PC 뿐이다.\n"
                       : L"\n실패한 줄이 있다. supabase/clipboard.sql 을 돌렸는지 먼저 볼 것.\n";
    return allOk;
}
