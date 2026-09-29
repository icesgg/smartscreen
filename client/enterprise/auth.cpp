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
    if (listen(m_impl->sock, 1) != 0) return 0;

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

bool LoopbackListener::WaitForCode(unsigned timeoutMs, std::string& outCode,
                                   std::string& outErr) {
    outCode.clear();
    outErr.clear();
    if (m_impl->sock == INVALID_SOCKET) return false;

    fd_set rd;
    FD_ZERO(&rd);
    FD_SET(m_impl->sock, &rd);
    timeval tv{};
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    if (select(0, &rd, nullptr, nullptr, &tv) <= 0) return false;

    SOCKET c = accept(m_impl->sock, nullptr, nullptr);
    if (c == INVALID_SOCKET) return false;

    // 요청 줄만 있으면 된다. 헤더를 다 읽을 필요가 없다.
    std::string req;
    char buf[2048];
    for (int i = 0; i < 8; ++i) {
        int n = recv(c, buf, sizeof(buf), 0);
        if (n <= 0) break;
        req.append(buf, n);
        if (req.find("\r\n") != std::string::npos) break;
    }

    bool gotCode = QueryParam(req, "code", outCode);
    if (!gotCode) {
        std::string d;
        if (!QueryParam(req, "error_description", d)) QueryParam(req, "error", d);
        outErr = d;
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
// supabase.cpp 에도 GET 이 있지만 static 이고 본문을 보내지 못한다.
// 토큰 교환은 POST + JSON 본문이라 여기에 따로 둔다.
static bool HttpRequest(const wchar_t* verb, const std::wstring& url,
                        const std::vector<std::wstring>& headers,
                        const std::string& body,
                        DWORD& outStatus, std::string& outBody) {
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

        char buf[4096];
        DWORD n = 0;
        while (WinHttpReadData(hReq, buf, sizeof(buf), &n) && n > 0)
            outBody.append(buf, n);
        ok = true;
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
                    default:  v += body[q]; break;
                }
            } else {
                v += body[q];
            }
            ++q;
        }
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

// 오류 본문에서 사람이 읽을 문장을 고른다. Supabase 는 키 이름이 일정하지 않다.
static std::wstring PickError(const std::string& body, DWORD status) {
    for (const char* k : { "error_description", "msg", "message", "error" }) {
        std::string v;
        if (JsonFindString(body, k, v) && !v.empty()) return Widen(v);
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
        outErr = err.empty() ? L"로그인이 시간 안에 끝나지 않았다" : Widen(err);
        return false;
    }

    // 코드 -> 토큰. verifier 는 여기서 처음 밖으로 나간다.
    std::string body = "{\"auth_code\":\"" + code + "\",\"code_verifier\":\"" + verifier + "\"}";
    std::vector<std::wstring> headers = {
        L"apikey: " + anonKey,
        L"Content-Type: application/json",
    };
    DWORD status = 0;
    std::string resp;
    if (!HttpRequest(L"POST", supabaseUrl + L"/auth/v1/token?grant_type=pkce",
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
    if (!HttpRequest(L"POST", supabaseUrl + L"/auth/v1/token?grant_type=refresh_token",
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
    if (!HttpRequest(L"GET", supabaseUrl + L"/rest/v1/device_tokens?select=token",
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
    if (!HttpRequest(L"POST", supabaseUrl + L"/rest/v1/rpc/claim_device_token",
                     headers, body, status, resp)) {
        outErr = L"요청이 실패했다";
        return false;
    }
    if (status < 200 || status >= 300) {
        outErr = PickError(resp, status) + L"  [본문] " + Widen(resp);
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
    if (!HttpRequest(L"DELETE",
                     supabaseUrl + L"/rest/v1/device_tokens?user_id=eq." + session.userId,
                     headers, std::string(), status, resp)) {
        outErr = L"요청이 실패했다";
        return false;
    }
    if (status < 200 || status >= 300) {
        outErr = PickError(resp, status) + L"  [본문] " + Widen(resp);
        return false;
    }
    return true;
}
