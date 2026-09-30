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

struct Payload {
    bool        isImage = false;
    std::string bytes;      // isImage 면 PNG, 아니면 UTF-8 텍스트
};

std::mutex     s_mx;               // 아래 묶음을 지킨다
ClipSyncStatus s_status;
std::wstring   s_url, s_key;
unsigned long  s_maxBytes = 0;
std::wstring   s_device;           // 사람이 읽는 PC 이름 (행에 들어간다)
std::wstring   s_devSlug;          // Storage 경로에 쓰는 이름
long long      s_seenId = 0;       // 이 id 까지는 처리했다 (시작 시 기준선)
unsigned long long s_lastHash = 0; // 마지막으로 올렸거나 받아 붙인 내용
DWORD          s_ignoreSeq = 0;    // 우리가 클립보드를 바꾼 직후의 순번

Payload*       s_outgoing = nullptr;   // 올릴 것이 있으면 여기 (최신 하나만)

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
    s_status.lastMsg = msg;
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
    IStream* st = nullptr;
    if (CreateStreamOnHGlobal(nullptr, TRUE, &st) != S_OK) {
        why = L"스트림을 만들지 못했다";
        return false;
    }
    ULONG wrote = 0;
    LARGE_INTEGER zero{};
    bool ok = false;
    if (st->Write(png.data(), (ULONG)png.size(), &wrote) == S_OK && wrote == png.size() &&
        st->Seek(zero, STREAM_SEEK_SET, nullptr) == S_OK) {
        Gdiplus::Bitmap* bmp = Gdiplus::Bitmap::FromStream(st);
        if (bmp && bmp->GetLastStatus() == Gdiplus::Ok) {
            // GetHBITMAP 은 새 HBITMAP 을 만들어 주고 그것은 우리 것이 된다.
            // 클립보드에 넘긴 뒤에는 시스템 것이므로 그때부터 지우지 않는다.
            ok = (bmp->GetHBITMAP(Gdiplus::Color(255, 255, 255), &out) == Gdiplus::Ok);
        }
        delete bmp;
    }
    if (!ok) why = L"PNG 를 그림으로 풀지 못했다";
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

// 클립보드 창 스레드에서만 부른다.
bool ReadClipboard(HWND owner, Payload& out, std::wstring& why) {
    if (!OpenClipboardRetry(owner)) { why = L"클립보드를 열지 못했다"; return false; }
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
    if (!SupabaseHttp(L"POST", s_url + L"/rest/v1/clip_items", h, body, st, resp)) {
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
    std::string  body;      // kind=text
    std::wstring path;      // kind=image
    long long    bytes = 0;
};

// 내 것 중 가장 새 행 하나. 행이 없으면 true + id==0 이다 (오류가 아니다).
//
// PostgREST 에 단일 객체를 달라고(Accept: vnd.pgrst.object+json) 하지 않는다.
// 행이 0개일 때 그게 406 으로 돌아오는데, "아직 아무도 아무것도 복사하지
// 않았다" 는 오류가 아니다. 그걸 오류로 만들면 상태창이 늘 빨갛다.
//
// select 에서 body 가 맨 뒤인 것은 일부러다. 파서가 "키":값 의 첫 등장을
// 집으므로, 사람이 복사한 본문에 {"kind":"image"} 같은 것이 들어 있으면 그걸
// 먼저 집을 수 있다. body 를 마지막에 두면 다른 키는 모두 본문보다 앞에서
// 끝난다 - PostgREST 가 select 순서대로 내주는 것에 기대는 부분이다.
bool FetchNewest(const std::wstring& access, RemoteItem& out, std::wstring& why) {
    unsigned long st = 0;
    std::string resp;
    if (!SupabaseHttp(L"GET",
            s_url + L"/rest/v1/clip_items"
                    L"?select=id,device,kind,storage_path,bytes,body"
                    L"&order=id.desc&limit=1",
            AuthHeaders(access, false), std::string(), st, resp)) {
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
    } else {
        JsonGetString(resp, "body", out.body);
    }
    JsonGetNumber(resp, "bytes", out.bytes);
    return true;
}

bool DownloadImage(const std::wstring& access, const std::wstring& path,
                   std::string& out, std::wstring& why) {
    unsigned long st = 0;
    if (!SupabaseHttp(L"GET",
            s_url + L"/storage/v1/object/authenticated/clip/" + path,
            AuthHeaders(access, false), std::string(), st, out)) {
        why = L"다운로드 요청이 실패했다";
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
        if (!ReadClipboard(hw, p, why)) {
            // 넘길 형식이 없는 것은 늘 있는 일이라 상태를 흔들지 않는다
            // (파일을 복사하면 CF_HDROP 만 올라온다).
            return 0;
        }
        unsigned long long h = HashBytes(p.bytes.data(), p.bytes.size());
        unsigned long cap;
        {
            std::lock_guard<std::mutex> lock(s_mx);
            if (h == s_lastHash) return 0;      // 방금 올렸거나 받아 붙인 그것
            cap = s_maxBytes;
        }
        if (cap && p.bytes.size() > cap) {
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
        }
        SetEvent(s_workEvent);
        return 0;
    }
    case WM_CLIP_APPLY: {
        Payload* p = (Payload*)lp;
        std::wstring why;
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
        std::lock_guard<std::mutex> lock(s_mx);
        s_lastHash = 0;
    }
    delete p;
}

void DoPoll(const std::wstring& access) {
    RemoteItem it;
    std::wstring why;
    if (!FetchNewest(access, it, why)) {
        SetStatus(false, why);
        DbgEvent(L"clip: poll failed - %s", why.c_str());
        return;
    }
    if (it.id == 0) return;

    long long seen;
    std::wstring mine;
    {
        std::lock_guard<std::mutex> lock(s_mx);
        seen = s_seenId;
        mine = s_device;
    }
    if (it.id <= seen) return;

    // 여기서 기준선을 먼저 올린다. 아래에서 실패해도 같은 항목을 5초마다
    // 영원히 다시 시도하지 않게 한다 - 실패하는 항목 하나가 그 뒤에 오는
    // 모든 것을 막으면 기능이 통째로 멎는다.
    {
        std::lock_guard<std::mutex> lock(s_mx);
        s_seenId = it.id;
    }
    if (it.device == mine) return;    // 내가 올린 것

    Payload* p = new Payload();
    p->isImage = it.isImage;
    if (it.isImage) {
        if (!DownloadImage(access, it.path, p->bytes, why)) {
            SetStatus(false, why);
            DbgEvent(L"clip: download failed - %s", why.c_str());
            delete p;
            return;
        }
    } else {
        p->bytes = it.body;
    }
    if (p->bytes.empty()) { delete p; return; }

    // 붙이기는 창 스레드가 한다. 클립보드를 두 스레드에서 만지면 우리가 바꾼
    // 것인지 판단하는 순번이 어긋난다.
    HWND hw = s_hwnd.load();
    if (!hw || !PostMessageW(hw, WM_CLIP_APPLY, 0, (LPARAM)p)) delete p;
}

DWORD WINAPI WorkerThread(LPVOID) {
    // 시작할 때의 가장 새 id 를 기준선으로만 적어 둔다 (clipsync.h 머리말).
    {
        std::wstring access, why;
        if (SessionToken(access, why)) {
            RemoteItem it;
            if (FetchNewest(access, it, why)) {
                std::lock_guard<std::mutex> lock(s_mx);
                s_seenId = it.id;
                DbgEvent(L"clip: baseline id=%lld", it.id);
            } else {
                SetStatus(false, why);
            }
        } else {
            SetStatus(false, why);
        }
    }

    HANDLE waits[2] = { s_stopEvent, s_workEvent };
    for (;;) {
        DWORD every = (IdleMs() > kIdleAfterMs) ? kPollIdleMs : kPollBusyMs;
        DWORD r = WaitForMultipleObjects(2, waits, FALSE, every);
        // WAIT_FAILED 에서도 나간다. Stop 이 기다리다 지쳐 핸들을 닫았으면
        // 여기가 실패로 돌아오는데, 그걸 무시하면 닫힌 핸들로 영원히 돈다.
        if (r == WAIT_OBJECT_0 || r == WAIT_FAILED) break;

        std::wstring access, why;
        if (!SessionToken(access, why)) {
            SetStatus(false, why);
            // 세션이 없으면 할 수 있는 일이 없다. 5초마다 다시 물어보면
            // 로그가 그것만으로 가득 차므로 한 박자 쉰다.
            if (WaitForSingleObject(s_stopEvent, 30000) == WAIT_OBJECT_0) break;
            continue;
        }
        // 올릴 것이 있으면 먼저 올린다. 내가 방금 복사한 것을 넘기는 쪽이
        // 남이 올린 것을 받는 것보다 급하다.
        DoUpload(access);
        DoPoll(access);
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
        s_lastHash = 0;
        s_ignoreSeq = 0;
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
            RemoteItem it;
            if (!FetchNewest(access, it, why)) {
                Line(outReport, L"[X]", L"텍스트 조회: " + why);
                allOk = false;
            } else if (it.id != id) {
                Line(outReport, L"[X]", L"방금 올린 행이 가장 새 행이 아니다");
                allOk = false;
            } else if (it.isImage) {
                Line(outReport, L"[X]", L"kind 가 text 로 돌아오지 않았다");
                allOk = false;
            } else if (it.body != p.bytes) {
                // 여기서 걸리면 JSON 이스케이프나 \u 풀기가 틀린 것이다.
                wchar_t b[128];
                swprintf_s(b, L"텍스트가 달라졌다 (보냄 %zu 바이트, 받음 %zu 바이트)",
                           p.bytes.size(), it.body.size());
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
                if (!DownloadImage(access, StoragePath(), got, why)) {
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
