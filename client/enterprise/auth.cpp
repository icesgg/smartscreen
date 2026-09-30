// auth.cpp - 구글 로그인용 PKCE, 루프백 리스너, 리프레시 토큰 보관
// 설계 근거는 auth.h 머리말 참고.
#include "auth.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <vector>
#include <string>
#include <ctime>
#include <cstdlib>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "shell32.lib")

// ---------------------------------------------------------------------------
// base64
// ---------------------------------------------------------------------------
static const char kStd[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string Base64Encode(const unsigned char* data, size_t len) {
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    for (size_t i = 0; i < len; i += 3) {
        unsigned v = data[i] << 16;
        if (i + 1 < len) v |= data[i + 1] << 8;
        if (i + 2 < len) v |= data[i + 2];
        out += kStd[(v >> 18) & 0x3F];
        out += kStd[(v >> 12) & 0x3F];
        out += (i + 1 < len) ? kStd[(v >> 6) & 0x3F] : '=';
        out += (i + 2 < len) ? kStd[v & 0x3F] : '=';
    }
    return out;
}

bool Base64Decode(const std::string& in, std::string& out) {
    int rev[256];
    for (int i = 0; i < 256; ++i) rev[i] = -1;
    for (int i = 0; i < 64; ++i) rev[(unsigned char)kStd[i]] = i;

    out.clear();
    unsigned acc = 0;
    int bits = 0;
    for (char c : in) {
        if (c == '=' || c == '\r' || c == '\n') continue;
        int d = rev[(unsigned char)c];
        if (d < 0) return false;
        acc = (acc << 6) | d;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out += (char)((acc >> bits) & 0xFF);
        }
    }
    return true;
}

// base64url: + -> -, / -> _, 패딩 없음 (RFC 4648 §5)
static std::string Base64Url(const unsigned char* data, size_t len) {
    std::string s = Base64Encode(data, len);
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        if (c == '=') continue;
        if (c == '+') out += '-';
        else if (c == '/') out += '_';
        else out += c;
    }
    return out;
}

// ---------------------------------------------------------------------------
// PKCE
// ---------------------------------------------------------------------------
std::string MakeCodeVerifier() {
    unsigned char buf[32];
    if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, buf, sizeof(buf),
                                        BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
        return std::string();
    }
    // 32바이트 -> base64url 43자. 43은 RFC 7636 이 요구하는 최소 길이와 같다.
    return Base64Url(buf, sizeof(buf));
}

bool MakeCodeChallengeS256(const std::string& verifier, std::string& outChallenge) {
    outChallenge.clear();
    if (verifier.empty()) return false;

    BCRYPT_ALG_HANDLE alg = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM,
                                                    nullptr, 0))) {
        return false;
    }
    unsigned char hash[32];
    NTSTATUS st = BCryptHash(alg, nullptr, 0,
                             (PUCHAR)verifier.data(), (ULONG)verifier.size(),
                             hash, sizeof(hash));
    BCryptCloseAlgorithmProvider(alg, 0);
    if (!BCRYPT_SUCCESS(st)) return false;

    outChallenge = Base64Url(hash, sizeof(hash));
    return true;
}

static std::string HexLower(const unsigned char* d, size_t n) {
    static const char* hx = "0123456789abcdef";
    std::string s; s.reserve(n * 2);
    for (size_t i = 0; i < n; ++i) { s += hx[d[i] >> 4]; s += hx[d[i] & 15]; }
    return s;
}

bool Sha256Bytes(const void* data, size_t len, std::string& outHex) {
    outHex.clear();
    BCRYPT_ALG_HANDLE alg = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0)))
        return false;
    unsigned char hash[32];
    NTSTATUS st = BCryptHash(alg, nullptr, 0, (PUCHAR)data, (ULONG)len, hash, sizeof(hash));
    BCryptCloseAlgorithmProvider(alg, 0);
    if (!BCRYPT_SUCCESS(st)) return false;
    outHex = HexLower(hash, sizeof(hash));
    return true;
}

bool Sha256File(const std::wstring& path, std::string& outHex, unsigned long long& outSize) {
    outHex.clear(); outSize = 0;
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return false;

    BCRYPT_ALG_HANDLE alg = nullptr; BCRYPT_HASH_HANDLE h = nullptr;
    bool ok = BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0)) &&
              BCRYPT_SUCCESS(BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0));
    if (ok) {
        std::vector<unsigned char> buf(64 * 1024);
        size_t n;
        while ((n = fread(buf.data(), 1, buf.size(), f)) > 0) {
            if (!BCRYPT_SUCCESS(BCryptHashData(h, buf.data(), (ULONG)n, 0))) { ok = false; break; }
            outSize += n;
        }
        if (ok && ferror(f)) ok = false;
        unsigned char hash[32];
        if (ok) ok = BCRYPT_SUCCESS(BCryptFinishHash(h, hash, sizeof(hash), 0));
        if (ok) outHex = HexLower(hash, sizeof(hash));
    }
    if (h) BCryptDestroyHash(h);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    fclose(f);
    return ok;
}

// ---------------------------------------------------------------------------
// 루프백 리스너
// ---------------------------------------------------------------------------
struct LoopbackListener::Impl {
    SOCKET sock = INVALID_SOCKET;
    bool   wsaUp = false;
};

LoopbackListener::LoopbackListener() : m_impl(new Impl) {}
LoopbackListener::~LoopbackListener() { Stop(); delete m_impl; }

unsigned short LoopbackListener::Start() {
    WSADATA wsa;
    // 참조 카운트라 다른 곳에서 이미 불렀어도 안전하다.
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 0;
    m_impl->wsaUp = true;

    m_impl->sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (m_impl->sock == INVALID_SOCKET) return 0;

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = 0;                            // OS 가 빈 포트를 고른다
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 127.0.0.1 만. 외부 노출 금지
    if (bind(m_impl->sock, (sockaddr*)&addr, sizeof(addr)) != 0) return 0;
    // 대기열이 1 이면 WaitForCode 가 남의 연결 하나를 정리하는 동안 브라우저의
    // 진짜 요청이 거절당한다. 이제 남의 연결을 넘기고 계속 받으므로 자리가 필요하다.
    if (listen(m_impl->sock, 8) != 0) return 0;

    sockaddr_in bound{};
    int len = sizeof(bound);
    if (getsockname(m_impl->sock, (sockaddr*)&bound, &len) != 0) return 0;
    return ntohs(bound.sin_port);
}

// %XX 를 푼다. 인가 코드 자체는 URL 안전하지만 error_description 은 아니다.
static std::string UrlDecode(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '+') { out += ' '; continue; }
        if (s[i] == '%' && i + 2 < s.size()) {
            auto hex = [](char c) -> int {
                if (c >= '0' && c <= '9') return c - '0';
                if (c >= 'a' && c <= 'f') return c - 'a' + 10;
                if (c >= 'A' && c <= 'F') return c - 'A' + 10;
                return -1;
            };
            int h = hex(s[i + 1]), l = hex(s[i + 2]);
            if (h >= 0 && l >= 0) { out += (char)(h * 16 + l); i += 2; continue; }
        }
        out += s[i];
    }
    return out;
}

// "GET /?code=abc&x=y HTTP/1.1" 의 질의 문자열에서 key 를 꺼낸다
static bool QueryParam(const std::string& req, const char* key, std::string& out) {
    size_t sp = req.find(' ');
    if (sp == std::string::npos) return false;
    size_t sp2 = req.find(' ', sp + 1);
    if (sp2 == std::string::npos) return false;
    std::string target = req.substr(sp + 1, sp2 - sp - 1);

    size_t q = target.find('?');
    if (q == std::string::npos) return false;
    std::string qs = target.substr(q + 1);

    std::string want = std::string(key) + "=";
    size_t pos = 0;
    while (pos < qs.size()) {
        size_t amp = qs.find('&', pos);
        std::string pair = qs.substr(pos, amp == std::string::npos ? std::string::npos : amp - pos);
        if (pair.compare(0, want.size(), want) == 0) {
            out = UrlDecode(pair.substr(want.size()));
            return true;
        }
        if (amp == std::string::npos) break;
        pos = amp + 1;
    }
    return false;
}

// s 에 읽을 것이 생길 때까지 길어야 ms 만큼 기다린다. 리스너에서는 "들어온
// 연결이 있다", 받은 소켓에서는 "바이트가 왔거나 상대가 끊었다" 는 뜻이다.
static bool WaitReadable(SOCKET s, ULONGLONG ms) {
    fd_set rd;
    FD_ZERO(&rd);
    FD_SET(s, &rd);
    timeval tv{};
    tv.tv_sec = (long)(ms / 1000);
    tv.tv_usec = (long)((ms % 1000) * 1000);
    return select(0, &rd, nullptr, nullptr, &tv) > 0;
}

// 코드는 토큰 교환 요청의 JSON 에 그대로 끼워 넣는다 (SignInWithGoogle).
// Supabase 가 주는 코드는 URL 안전 문자뿐이므로, 따옴표·역슬래시·제어문자가 든
// 값은 코드가 아니다 - 받아 주면 이 포트에 닿은 아무나 그 JSON 의 모양을 바꾼다.
static bool PlausibleCode(const std::string& s) {
    if (s.empty()) return false;
    for (unsigned char ch : s)
        if (ch < 0x20 || ch == '"' || ch == '\\') return false;
    return true;
}

bool LoopbackListener::WaitForCode(unsigned timeoutMs, std::string& outCode,
                                   std::string& outErr) {
    outCode.clear();
    outErr.clear();
    if (m_impl->sock == INVALID_SOCKET) return false;

    // 예전에는 select 한 번, accept 한 번이었다. 그래서 이 포트에 먼저 닿은 연결이
    // 무엇이든(포트를 훑는 다른 프로세스, 파비콘 요청) 그것이 로그인의 결과가
    // 됐고, 붙기만 하고 아무것도 안 보내는 연결은 시간 제한 없는 recv 에서
    // LoginThread 를 붙잡았다 - 그 동안 로그인 단추가 죽고 받아 둔 업데이트도
    // 적용되지 않는다 (2026-09-30 검토). 이제 마감까지 계속 받으면서, code= 나
    // error= 를 실은 요청이 올 때만 돌아간다.
    //
    // 리스너는 논블로킹으로 둔다. select 가 "연결이 왔다" 고 한 뒤 accept 하기
    // 전에 상대가 끊고 가면 대기열이 비는데, 블로킹 accept 는 거기서 마감 없이
    // 다음 연결을 기다린다.
    u_long nonBlocking = 1;
    ioctlsocket(m_impl->sock, FIONBIO, &nonBlocking);

    // 연결 하나에 쓰는 시간. 브라우저는 붙자마자 요청 줄을 보내므로 넉넉하다.
    const DWORD kConnMs = 5000;
    const ULONGLONG deadline = GetTickCount64() + timeoutMs;

    SOCKET c = INVALID_SOCKET;
    bool gotCode = false;
    for (;;) {
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) return false;
        if (!WaitReadable(m_impl->sock, deadline - now)) return false;

        c = accept(m_impl->sock, nullptr, nullptr);
        if (c == INVALID_SOCKET) {
            int e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK || e == WSAECONNRESET) continue;   // 붙었다가 가 버린 연결
            return false;
        }

        // 받은 소켓은 리스너의 논블로킹을 물려받는다. 블로킹으로 되돌리고 (응답을
        // 보내는 send 가 예전과 같게) 읽기와 쓰기에 시간 제한을 건다.
        u_long blocking = 0;
        ioctlsocket(c, FIONBIO, &blocking);
        DWORD ioMs = kConnMs;
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, (const char*)&ioMs, sizeof(ioMs));
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, (const char*)&ioMs, sizeof(ioMs));

        // 요청 줄만 있으면 된다. 헤더를 다 읽을 필요가 없다.
        // 마감은 recv 마다가 아니라 연결 전체에 둔다 - 한 바이트씩 흘려 보내며
        // 붙잡는 상대에게 recv 횟수만큼 시간을 내주지 않는다.
        std::string req;
        char buf[2048];
        ULONGLONG connEnd = GetTickCount64() + kConnMs;
        if (connEnd > deadline) connEnd = deadline;
        for (int i = 0; i < 8; ++i) {
            ULONGLONG t = GetTickCount64();
            if (t >= connEnd || !WaitReadable(c, connEnd - t)) break;
            int n = recv(c, buf, sizeof(buf), 0);
            if (n <= 0) break;
            req.append(buf, n);
            if (req.find("\r\n") != std::string::npos) break;
        }

        // 우리가 내준 주소는 http://127.0.0.1:<포트> 이고 (SignInWithGoogle)
        // 브라우저는 거기에 "GET /?code=..." 로 온다. 그 모양이 아니거나 code 도
        // error 도 없는 요청은 로그인의 결과가 아니다.
        //
        // 주소에 난수 경로를 붙여 남이 error= 조차 못 넣게 하는 방법은 쓰지 않았다.
        // Supabase 는 허용 목록에 없는 redirect_to 를 말없이 Site URL 로 바꾸는데
        // (docs/IDENTIFICATION.md "붙이면서 틀렸던 것"), 경로가 붙은 주소가 지금의
        // 허용 목록에 맞는지 여기서는 확인할 길이 없다.
        //
        // 그래서 남은 것이 둘이다 (2026-09-30 검토, 닫지 못함). 이 포트에 닿은 쪽이
        // "GET /?error_description=..." 을 보내면 로그인이 그 글과 함께 바로 끝나고,
        // 그럴듯한 가짜 "GET /?code=..." 를 보내면 교환이 실패하면서 뒤에 오는 진짜
        // 요청을 놓친다. 둘 다 로그인을 망칠 뿐 성사시키지는 못한다 - 교환에는 이
        // 프로세스만 아는 verifier 가 든다.
        std::string code, errText;
        bool onPath = req.compare(0, 6, "GET /?") == 0;
        gotCode = onPath && QueryParam(req, "code", code) && PlausibleCode(code);
        bool gotErr = false;
        if (onPath && !gotCode) {
            gotErr = QueryParam(req, "error_description", errText) && !errText.empty();
            if (!gotErr) gotErr = QueryParam(req, "error", errText) && !errText.empty();
        }
        if (gotCode) { outCode = code; break; }
        if (gotErr)  { outErr = errText; break; }

        // 남의 연결이다. 요청을 보낸 쪽에는 빈 404 를 주어 매달려 있지 않게 하고
        // (브라우저의 /favicon.ico), 다음 연결을 기다린다.
        if (!req.empty()) {
            static const char kNotFound[] =
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            send(c, kNotFound, (int)(sizeof(kNotFound) - 1), 0);
        }
        shutdown(c, SD_BOTH);
        closesocket(c);
        c = INVALID_SOCKET;
    }

    // 브라우저에 남길 화면. 여기서 창을 닫으라고 말해 주지 않으면
    // 사용자는 로그인이 끝났는지 알 수 없다.
    const char* msg = gotCode
        ? "<!doctype html><meta charset=utf-8><title>SmartScreen</title>"
          "<body style=\"font-family:sans-serif;text-align:center;padding-top:80px\">"
          "<h2>로그인되었습니다</h2><p>이 창을 닫고 SmartScreen 으로 돌아가세요.</p>"
        : "<!doctype html><meta charset=utf-8><title>SmartScreen</title>"
          "<body style=\"font-family:sans-serif;text-align:center;padding-top:80px\">"
          "<h2>로그인하지 못했습니다</h2><p>SmartScreen 에서 다시 시도하세요.</p>";
    std::string body(msg);
    std::string resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                       "Content-Length: " + std::to_string(body.size()) +
                       "\r\nConnection: close\r\n\r\n" + body;
    send(c, resp.c_str(), (int)resp.size(), 0);
    shutdown(c, SD_BOTH);
    closesocket(c);
    return gotCode;
}

void LoopbackListener::Stop() {
    if (m_impl->sock != INVALID_SOCKET) {
        closesocket(m_impl->sock);
        m_impl->sock = INVALID_SOCKET;
    }
    if (m_impl->wsaUp) {
        WSACleanup();
        m_impl->wsaUp = false;
    }
}

// ---------------------------------------------------------------------------
// DPAPI
// ---------------------------------------------------------------------------
bool ProtectSecret(const std::wstring& plain, std::wstring& outB64) {
    outB64.clear();
    if (plain.empty()) return false;

    DATA_BLOB in{}, out{};
    in.pbData = (BYTE*)plain.data();
    in.cbData = (DWORD)(plain.size() * sizeof(wchar_t));

    if (!CryptProtectData(&in, L"SmartScreen refresh token", nullptr, nullptr,
                          nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        return false;
    }
    std::string b64 = Base64Encode(out.pbData, out.cbData);
    LocalFree(out.pbData);

    outB64.assign(b64.begin(), b64.end());   // ASCII 라 이 변환으로 충분하다
    return true;
}

bool UnprotectSecret(const std::wstring& b64, std::wstring& outPlain) {
    outPlain.clear();
    if (b64.empty()) return false;

    // base64 는 정의상 ASCII 다. 넓은 문자가 섞여 있으면 우리가 쓴 값이 아니므로
    // 축소 변환으로 뭉개지 말고 거절한다.
    std::string ascii;
    ascii.reserve(b64.size());
    for (wchar_t c : b64) {
        if (c < 0 || c > 127) return false;
        ascii += (char)c;
    }
    std::string raw;
    if (!Base64Decode(ascii, raw) || raw.empty()) return false;

    DATA_BLOB in{}, out{};
    in.pbData = (BYTE*)raw.data();
    in.cbData = (DWORD)raw.size();

    if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        return false;   // 다른 PC 나 다른 사용자 계정으로 복사해 온 값
    }
    outPlain.assign((wchar_t*)out.pbData, out.cbData / sizeof(wchar_t));
    LocalFree(out.pbData);
    return true;
}

// ---------------------------------------------------------------------------
// HTTP (WinHTTP)
// ---------------------------------------------------------------------------
// 앱의 HTTP 는 전부 이것 하나로 간다 (supabase.cpp 에 따로 있던 GET 은 상태 코드를
// 보지 않아서 없앴다). 파일로 흘려 받는 내려받기만 각자 가진다.
//
// clipsync.cpp 도 이걸 쓴다 (선언은 auth.h). 그래서 static 이 아니다.
bool SupabaseHttp(const wchar_t* verb, const std::wstring& url,
                        const std::vector<std::wstring>& headers,
                        const std::string& body,
                        unsigned long& outStatus, std::string& outBody,
                        size_t maxBodyBytes) {
    outStatus = 0;
    outBody.clear();

    URL_COMPONENTS uc{};
    uc.dwStructSize = sizeof(uc);
    wchar_t host[256] = {}, path[2048] = {};
    uc.lpszHostName = host;      uc.dwHostNameLength = _countof(host);
    uc.lpszUrlPath = path;       uc.dwUrlPathLength = _countof(path);
    // 질의 문자열은 lpszUrlPath 뒤에 이어 붙는다 (ExtraInfo 를 따로 안 받으면)
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return false;

    HINTERNET hSession = WinHttpOpen(L"SmartScreen/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                     WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return false;

    // 요청 하나가 무한정 매달리지 않게 한다. 예전에는 부르는 쪽이 로그인 한
    // 번이었으므로 기본값으로 충분했는데, 지금은 클립보드 일꾼이 이걸 계속
    // 부르고 종료할 때 그 스레드를 기다린다 - 한 번의 요청이 종료를 기다릴 수
    // 있는 시간보다 길면 안 된다 (clipsync.cpp 의 ClipSyncStop).
    WinHttpSetTimeouts(hSession, 10000, 10000, 15000, 15000);

    HINTERNET hConnect = WinHttpConnect(hSession, host, uc.nPort, 0);
    if (!hConnect) { WinHttpCloseHandle(hSession); return false; }

    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hReq = WinHttpOpenRequest(hConnect, verb, path, nullptr,
                                        WINHTTP_NO_REFERER,
                                        WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!hReq) { WinHttpCloseHandle(hConnect); WinHttpCloseHandle(hSession); return false; }

    for (const auto& h : headers)
        WinHttpAddRequestHeaders(hReq, h.c_str(), (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD);

    bool ok = false;
    if (WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                           body.empty() ? WINHTTP_NO_REQUEST_DATA : (LPVOID)body.data(),
                           (DWORD)body.size(), (DWORD)body.size(), 0) &&
        WinHttpReceiveResponse(hReq, nullptr)) {

        DWORD code = 0, sz = sizeof(code);
        WinHttpQueryHeaders(hReq, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &code, &sz, WINHTTP_NO_HEADER_INDEX);
        outStatus = code;

        // 본문을 끝까지 받았을 때만 성공이다. 예전 루프는 WinHttpReadData 가
        // 실패해서 끝난 것(수신 시간 제한, 연결 리셋)과 길이 0 을 읽고 끝난 것을
        // 가리지 않고 ok 로 두었고, 그래서 도중에 끊긴 200 응답의 잘린 본문이
        // 온전한 것처럼 쓰일 수 있었다 - 클립보드 텍스트가 잘린 채 붙고, 기준점은
        // 이미 넘어가 있어 다시 받지도 않는다 (2026-09-30 검토).
        // 성공한 길이 0 읽기만이 "본문 끝" 이다.
        char buf[4096];
        bool complete = false;
        for (;;) {
            DWORD n = 0;
            if (!WinHttpReadData(hReq, buf, sizeof(buf), &n)) break;   // 도중에 끊겼다
            if (n == 0) { complete = true; break; }                    // 본문 끝
            // 상한은 부르는 쪽이 정한다 (0 = 없음). 넘는 순간 그만 읽는다 -
            // 서버가 주는 대로 메모리에 다 쌓지 않는다.
            if (maxBodyBytes != 0 && outBody.size() + n > maxBodyBytes) break;
            outBody.append(buf, n);
        }
        // 잘린 본문은 내주지 않는다. 반환값을 안 보고 본문만 쓰는 호출이 있어도
        // 잘린 것을 온전한 것으로 읽지 못하게. outStatus 는 그대로 둔다.
        if (!complete) outBody.clear();
        ok = complete;
    }

    WinHttpCloseHandle(hReq);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return ok;
}

// ---------------------------------------------------------------------------
// 아주 작은 JSON 읽기
// ---------------------------------------------------------------------------
// 응답 모양이 고정이라 파서를 들이지 않는다. 다만 "찾은 첫 문자열"을 쓰면
// 엉뚱한 값을 집으므로 "키":  꼴을 정확히 맞춘다.
// "\uXXXX" 의 네 자리를 읽는다. 넷이 다 16진수가 아니면 실패로 두고 부르는 쪽이
// 원문을 그대로 남기게 한다 - 조용히 0 으로 읽으면 글자가 사라진다.
static bool ReadHex4(const std::string& s, size_t at, unsigned& out) {
    if (at + 4 > s.size()) return false;
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char c = s[at + i];
        int d;
        if      (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else return false;
        v = (v << 4) | (unsigned)d;
    }
    out = v;
    return true;
}

static void AppendUtf8(std::string& out, unsigned cp) {
    if (cp < 0x80) {
        out += (char)cp;
    } else if (cp < 0x800) {
        out += (char)(0xC0 | (cp >> 6));
        out += (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out += (char)(0xE0 | (cp >> 12));
        out += (char)(0x80 | ((cp >> 6) & 0x3F));
        out += (char)(0x80 | (cp & 0x3F));
    } else {
        out += (char)(0xF0 | (cp >> 18));
        out += (char)(0x80 | ((cp >> 12) & 0x3F));
        out += (char)(0x80 | ((cp >> 6) & 0x3F));
        out += (char)(0x80 | (cp & 0x3F));
    }
}

static bool JsonFindString(const std::string& body, const std::string& key,
                           std::string& out) {
    out.clear();
    std::string pat = "\"" + key + "\"";
    size_t p = 0;
    while ((p = body.find(pat, p)) != std::string::npos) {
        size_t c = body.find(':', p + pat.size());
        if (c == std::string::npos) return false;
        size_t q = body.find_first_not_of(" \t\r\n", c + 1);
        if (q == std::string::npos) return false;
        if (body[q] != '"') { p = q; continue; }   // 문자열이 아닌 값
        ++q;
        std::string v;
        while (q < body.size() && body[q] != '"') {
            if (body[q] == '\\' && q + 1 < body.size()) {
                ++q;
                switch (body[q]) {
                    case 'n': v += '\n'; break;
                    case 't': v += '\t'; break;
                    case 'r': v += '\r'; break;
                    // Postgres 는 0x08 과 0x0C 를 \u00XX 가 아니라 짧은 꼴로 적는다.
                    // 이 둘이 없으면 default 가 글자 'b' / 'f' 를 남긴다 - 쪽 나눔이
                    // 든 글을 복사하면 받는 PC 에서 그 자리에 f 가 찍힌다.
                    case 'b': v += '\b'; break;
                    case 'f': v += '\f'; break;
                    // \uXXXX. 이게 없으면 'u' 와 숫자 넷이 그대로 본문에 남는다.
                    // 응답이 토큰과 이메일뿐일 때는 만난 적이 없었지만, 이제
                    // 클립보드 텍스트가 이 파서를 지나간다 - 사람이 복사한
                    // 아무 문자열이므로 제어문자가 섞여 들어올 수 있다.
                    case 'u': {
                        unsigned cp = 0;
                        if (!ReadHex4(body, q + 1, cp)) { v += 'u'; break; }
                        q += 4;
                        // 서러게이트 쌍은 둘을 합쳐야 한 글자가 된다.
                        // 앞짝만 UTF-8 로 적으면 깨진 바이트가 된다.
                        if (cp >= 0xD800 && cp <= 0xDBFF &&
                            q + 6 < body.size() && body[q + 1] == '\\' && body[q + 2] == 'u') {
                            unsigned lo = 0;
                            if (ReadHex4(body, q + 3, lo) && lo >= 0xDC00 && lo <= 0xDFFF) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                q += 6;
                            }
                        }
                        AppendUtf8(v, cp);
                        break;
                    }
                    default:  v += body[q]; break;
                }
            } else {
                v += body[q];
            }
            ++q;
        }
        // 닫는 따옴표를 못 만나고 본문이 끝났다. 잘린 응답이다 - 여기까지 모은
        // 것을 값이라고 내주면 잘린 토큰이나 잘린 글이 온전한 것으로 쓰인다.
        if (q >= body.size()) return false;
        out = v;
        return true;
    }
    return false;
}

static bool JsonFindNumber(const std::string& body, const std::string& key, long long& out) {
    std::string pat = "\"" + key + "\"";
    size_t p = body.find(pat);
    if (p == std::string::npos) return false;
    size_t c = body.find(':', p + pat.size());
    if (c == std::string::npos) return false;
    size_t q = body.find_first_not_of(" \t\r\n", c + 1);
    if (q == std::string::npos) return false;
    out = _atoi64(body.c_str() + q);
    return true;
}

static std::wstring Widen(const std::string& s) {
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

static std::string Narrow(const std::wstring& w) {
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

// 질의 문자열에 실을 값 인코딩
static std::wstring UrlEncode(const std::wstring& in) {
    std::string utf8 = Narrow(in);
    std::wstring out;
    wchar_t hex[4];
    for (unsigned char c : utf8) {
        bool unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                          (c >= '0' && c <= '9') || c == '-' || c == '.' ||
                          c == '_' || c == '~';
        if (unreserved) { out += (wchar_t)c; continue; }
        swprintf_s(hex, L"%%%02X", c);
        out += hex;
    }
    return out;
}

// 밖에서 온 글(서버의 오류 본문, 루프백으로 들어온 error_description)을 오류
// 문장으로 내보낼 때의 상한.
//
// 예전에는 서버가 준 문자열을 통째로 돌려줬다. 그 글은 상태 줄과 로그와
// MessageBox 로 가는데, 받는 쪽 하나가 고정 버퍼에 swprintf_s 로 찍고 있었다
// (main.cpp 의 클립보드 상태 줄, wchar_t[256]) - 갱신 오류 문장이 234자쯤부터
// 프로세스가 끝난다 (NEXT_SESSION.md "swprintf_s 는 잘라 쓰지 않는다").
// 받는 쪽을 고치는 것과 별개로, 여기서 나가는 글은 길이가 정해져 있어야 한다.
//
// UTF-16 단위로 자르되 서러게이트 앞짝에서 끊기면 하나 더 버린다 (반쪽 글자).
// 제어문자는 빈칸으로 - 이 글은 한 줄짜리 상태 줄과 한 줄에 한 건인 events.log
// 에 찍히는데, 줄바꿈이 섞이면 남이 로그에 줄을 지어낼 수 있다.
static std::wstring CapErrorText(std::wstring w) {
    const size_t kMaxChars = 160;
    if (w.size() > kMaxChars) {
        size_t n = kMaxChars;
        if (w[n - 1] >= 0xD800 && w[n - 1] <= 0xDBFF) --n;
        w.resize(n);
    }
    for (wchar_t& ch : w)
        if (ch < 0x20) ch = L' ';
    return w;
}

// 오류 본문에서 사람이 읽을 문장을 고른다. Supabase 는 키 이름이 일정하지 않다.
static std::wstring PickError(const std::string& body, DWORD status) {
    for (const char* k : { "error_description", "msg", "message", "error" }) {
        std::string v;
        if (JsonFindString(body, k, v) && !v.empty()) return CapErrorText(Widen(v));
    }
    wchar_t buf[64];
    swprintf_s(buf, L"HTTP %lu", status);
    return buf;
}

// ---------------------------------------------------------------------------
// 응답 -> 세션
// ---------------------------------------------------------------------------
static bool ParseSession(const std::string& body, AuthSession& s) {
    std::string at, rt;
    if (!JsonFindString(body, "access_token", at) || at.empty()) return false;
    if (!JsonFindString(body, "refresh_token", rt) || rt.empty()) return false;
    s.accessToken = Widen(at);
    s.refreshToken = Widen(rt);

    long long expiresIn = 3600;
    JsonFindNumber(body, "expires_in", expiresIn);
    s.expiresAtUnix = (ULONGLONG)(_time64(nullptr) + expiresIn);

    // user 객체 안의 id/email. 최상위에 같은 이름이 없어 첫 등장으로 충분하다.
    std::string id, em;
    if (JsonFindString(body, "id", id)) s.userId = Widen(id);
    if (JsonFindString(body, "email", em)) s.email = Widen(em);
    return true;
}

// ---------------------------------------------------------------------------
// 구글 로그인
// ---------------------------------------------------------------------------
bool SignInWithGoogle(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                      AuthSession& outSession, std::wstring& outErr,
                      unsigned timeoutSec) {
    outErr.clear();
    if (supabaseUrl.empty() || anonKey.empty()) {
        outErr = L"서버 주소나 키가 비어 있다";
        return false;
    }

    std::string verifier = MakeCodeVerifier();
    std::string challenge;
    if (verifier.empty() || !MakeCodeChallengeS256(verifier, challenge)) {
        outErr = L"PKCE 값을 만들지 못했다";
        return false;
    }

    LoopbackListener listener;
    unsigned short port = listener.Start();
    if (port == 0) {
        outErr = L"127.0.0.1 에 리스너를 못 띄웠다";
        return false;
    }

    wchar_t redirect[64];
    swprintf_s(redirect, L"http://127.0.0.1:%u", port);

    std::wstring url = supabaseUrl + L"/auth/v1/authorize?provider=google"
                     + L"&redirect_to=" + UrlEncode(redirect)
                     + L"&code_challenge=" + UrlEncode(Widen(challenge))
                     + L"&code_challenge_method=s256";

    // 시스템 브라우저로 연다. 임베디드 웹뷰는 구글이 거부한다.
    HINSTANCE r = ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    if ((INT_PTR)r <= 32) {
        outErr = L"브라우저를 열지 못했다";
        return false;
    }

    std::string code, err;
    if (!listener.WaitForCode(timeoutSec * 1000, code, err)) {
        // err 는 이 포트에 닿은 누구든 넣을 수 있는 글이다. 서버 글과 같은 상한을 걸고,
        // 앱이 한 말로 읽히지 않게 어디서 온 글인지 앞에 붙인다 (MessageBox 에 그대로 뜬다).
        outErr = err.empty() ? L"로그인이 시간 안에 끝나지 않았다"
                             : L"브라우저가 돌려준 오류: " + CapErrorText(Widen(err));
        return false;
    }

    // 코드 -> 토큰. verifier 는 여기서 처음 밖으로 나간다.
    // code 를 이스케이프 없이 끼워 넣어도 되는 것은 WaitForCode 가 따옴표·역슬래시·
    // 제어문자가 든 값을 코드로 받지 않기 때문이다 (PlausibleCode).
    std::string body = "{\"auth_code\":\"" + code + "\",\"code_verifier\":\"" + verifier + "\"}";
    std::vector<std::wstring> headers = {
        L"apikey: " + anonKey,
        L"Content-Type: application/json",
    };
    DWORD status = 0;
    std::string resp;
    if (!SupabaseHttp(L"POST", supabaseUrl + L"/auth/v1/token?grant_type=pkce",
                     headers, body, status, resp)) {
        outErr = L"토큰 교환 요청이 실패했다";
        return false;
    }
    if (status < 200 || status >= 300) {
        outErr = PickError(resp, status);
        return false;
    }
    if (!ParseSession(resp, outSession)) {
        outErr = L"토큰 응답을 읽지 못했다";
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 세션 갱신
// ---------------------------------------------------------------------------
bool RefreshSession(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                    const std::wstring& refreshToken,
                    AuthSession& outSession, std::wstring& outErr) {
    outErr.clear();
    if (refreshToken.empty()) { outErr = L"저장된 세션이 없다"; return false; }

    std::string body = "{\"refresh_token\":\"" + Narrow(refreshToken) + "\"}";
    std::vector<std::wstring> headers = {
        L"apikey: " + anonKey,
        L"Content-Type: application/json",
    };
    DWORD status = 0;
    std::string resp;
    if (!SupabaseHttp(L"POST", supabaseUrl + L"/auth/v1/token?grant_type=refresh_token",
                     headers, body, status, resp)) {
        outErr = L"갱신 요청이 실패했다";
        return false;
    }
    if (status < 200 || status >= 300) {
        outErr = PickError(resp, status);
        return false;
    }
    if (!ParseSession(resp, outSession)) {
        outErr = L"갱신 응답을 읽지 못했다";
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 계정에 묶인 폰 토큰 가져오기
// ---------------------------------------------------------------------------
bool FetchDeviceToken(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                      const AuthSession& session,
                      std::wstring& outTokenHex, std::wstring& outErr) {
    outTokenHex.clear();
    outErr.clear();
    if (session.accessToken.empty()) { outErr = L"로그인하지 않았다"; return false; }

    std::vector<std::wstring> headers = {
        L"apikey: " + anonKey,
        L"Authorization: Bearer " + session.accessToken,
    };
    DWORD status = 0;
    std::string resp;
    if (!SupabaseHttp(L"GET", supabaseUrl + L"/rest/v1/device_tokens?select=token",
                     headers, std::string(), status, resp)) {
        outErr = L"조회 요청이 실패했다";
        return false;
    }
    if (status < 200 || status >= 300) {
        outErr = PickError(resp, status);
        return false;
    }
    // 행이 없으면 "[]" 다. 이건 오류가 아니라 "폰에서 아직 로그인 안 함" 이다.
    std::string tok;
    if (JsonFindString(resp, "token", tok) && !tok.empty())
        outTokenHex = Widen(tok);
    return true;
}

// ---------------------------------------------------------------------------
// claim_device_token 직접 호출 (진단용)
// ---------------------------------------------------------------------------
bool ClaimDeviceToken(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                      const AuthSession& session, const std::wstring& tokenHex,
                      std::wstring& outTokenHex, std::wstring& outErr) {
    outTokenHex.clear();
    outErr.clear();
    if (session.accessToken.empty()) { outErr = L"로그인하지 않았다"; return false; }

    std::string body = "{\"p_token\":\"" + Narrow(tokenHex) + "\",\"p_platform\":\"ios\"}";
    std::vector<std::wstring> headers = {
        L"apikey: " + anonKey,
        L"Authorization: Bearer " + session.accessToken,
        L"Content-Type: application/json",
    };
    DWORD status = 0;
    std::string resp;
    if (!SupabaseHttp(L"POST", supabaseUrl + L"/rest/v1/rpc/claim_device_token",
                     headers, body, status, resp)) {
        outErr = L"요청이 실패했다";
        return false;
    }
    if (status < 200 || status >= 300) {
        // 본문은 진단용으로 앞 300바이트만 싣는다 (AuthTest 가 콘솔에 찍는다).
        // 통째로 붙이면 PickError 에 건 상한이 여기서 도로 풀린다.
        outErr = PickError(resp, status) + L"  [본문] " + Widen(resp.substr(0, 300));
        return false;
    }
    // text 를 돌려주므로 응답이 따옴표 붙은 문자열 하나다
    std::string v = resp;
    if (v.size() >= 2 && v.front() == '"' && v.back() == '"') v = v.substr(1, v.size() - 2);
    outTokenHex = Widen(v);
    return true;
}

// ---------------------------------------------------------------------------
// 등록 해제 (진단/복구용)
// ---------------------------------------------------------------------------
bool DeleteDeviceToken(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                       const AuthSession& session, std::wstring& outErr) {
    outErr.clear();
    if (session.accessToken.empty()) { outErr = L"로그인하지 않았다"; return false; }
    if (session.userId.empty())      { outErr = L"user id 를 모른다"; return false; }

    // RLS 가 자기 행만 허용하지만, 필터 없이 DELETE 를 보내면 PostgREST 가
    // 통째 삭제로 보고 거절한다. 그래서 user_id 를 명시한다.
    std::vector<std::wstring> headers = {
        L"apikey: " + anonKey,
        L"Authorization: Bearer " + session.accessToken,
    };
    DWORD status = 0;
    std::string resp;
    if (!SupabaseHttp(L"DELETE",
                     supabaseUrl + L"/rest/v1/device_tokens?user_id=eq." + session.userId,
                     headers, std::string(), status, resp)) {
        outErr = L"요청이 실패했다";
        return false;
    }
    if (status < 200 || status >= 300) {
        // 본문은 앞 300바이트만 (ClaimDeviceToken 과 같은 이유)
        outErr = PickError(resp, status) + L"  [본문] " + Widen(resp.substr(0, 300));
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 다른 번역 단위에 내주는 얇은 껍데기 (선언은 auth.h)
// ---------------------------------------------------------------------------
// 이름만 바꿔 내준다. 안쪽 이름을 그대로 노출하지 않는 이유는 Widen/Narrow 가
// 이 파일 여러 곳에서 불리고 있어서, 파일 밖에서 쓸 이름과 한꺼번에 바꾸면
// 진짜 변경과 이름 바꾸기가 같은 diff 에 섞이기 때문이다.
std::wstring Utf8ToWide(const std::string& s) { return Widen(s); }
std::string  WideToUtf8(const std::wstring& w) { return Narrow(w); }

bool JsonGetString(const std::string& body, const std::string& key, std::string& out) {
    return JsonFindString(body, key, out);
}

bool JsonGetNumber(const std::string& body, const std::string& key, long long& out) {
    return JsonFindNumber(body, key, out);
}
