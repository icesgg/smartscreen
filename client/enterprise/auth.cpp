// auth.cpp - 구글 로그인용 PKCE, 루프백 리스너, 리프레시 토큰 보관
// 설계 근거는 auth.h 머리말 참고.
#include "auth.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <vector>
#include <string>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "crypt32.lib")

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
