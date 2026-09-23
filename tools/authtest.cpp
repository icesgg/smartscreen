// authtest.cpp - 구글 로그인 부품 자체 점검
//
// 이 부품들은 Supabase 프로젝트가 없어도 정답을 대조할 수 있다. PKCE 는 RFC
// 7636 이 시험값을 싣고 있고, 루프백 리스너와 DPAPI 는 이 PC 안에서 왕복이
// 가능하다. 서버가 생기기 전에 여기까지는 실제로 돌려 두는 게 목적이다.
// "쓰인 적 없는 코드는 틀린 줄 모른다" (docs/PROXIMITY.md).
//
//   AuthTest.exe          자체 점검만
//   AuthTest.exe --serve  루프백 리스너를 띄우고 브라우저로 직접 확인
#include "../client/enterprise/auth.h"

#include <winsock2.h>
#include <windows.h>
#include <shellapi.h>
#include <cstdio>
#include <string>

static int g_fail = 0;

static void Check(bool ok, const char* what) {
    printf("  [%s] %s\n", ok ? "OK" : "FAIL", what);
    if (!ok) ++g_fail;
}

int main(int argc, char** argv) {
    SetConsoleOutputCP(CP_UTF8);

    bool serve = (argc > 1 && strcmp(argv[1], "--serve") == 0);

    printf("PKCE (RFC 7636)\n");
    {
        // RFC 7636 Appendix B 시험값. 이게 맞으면 SHA-256 과 base64url 이
        // 둘 다 맞는 것이다 - 틀리면 서버가 invalid_grant 만 돌려주고
        // 어느 쪽이 틀렸는지는 안 알려준다.
        const std::string v = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        const std::string want = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
        std::string got;
        bool ok = MakeCodeChallengeS256(v, got);
        if (!ok || got != want) {
            printf("      want %s\n      got  %s\n", want.c_str(), got.c_str());
        }
        Check(ok && got == want, "Appendix B 시험값과 일치");
    }
    {
        std::string a = MakeCodeVerifier(), b = MakeCodeVerifier();
        Check(a.size() >= 43 && a.size() <= 128, "verifier 길이 43~128");
        Check(a != b, "부를 때마다 다른 값");
        bool charsOk = true;
        for (char c : a) {
            bool unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                              (c >= '0' && c <= '9') || c == '-' || c == '.' ||
                              c == '_' || c == '~';
            if (!unreserved) { charsOk = false; break; }
        }
        Check(charsOk, "unreserved 문자만 (URL 에 그대로 실린다)");

        std::string ch;
        Check(MakeCodeChallengeS256(a, ch) && ch.size() == 43, "challenge 43자");
        Check(ch.find('+') == std::string::npos &&
              ch.find('/') == std::string::npos &&
              ch.find('=') == std::string::npos,
              "challenge 가 base64url (+ / = 없음)");
    }

    printf("base64 왕복\n");
    {
        const char* s = "SmartScreen \xed\x86\xa0\xed\x81\xb0 \x00\x01\x02 binary";
        std::string in(s, 30);
        std::string enc = Base64Encode((const unsigned char*)in.data(), in.size());
        std::string dec;
        Check(Base64Decode(enc, dec) && dec == in, "임의 바이트 왕복");
        Check(!Base64Decode("!!!not base64!!!", dec), "잘못된 입력을 거절");
    }

    printf("DPAPI\n");
    {
        std::wstring secret = L"refresh-token-\xd55c\xae00-0123456789abcdef";
        std::wstring sealed, opened;
        bool p = ProtectSecret(secret, sealed);
        Check(p && !sealed.empty(), "암호화");
        Check(p && sealed.find(secret) == std::wstring::npos,
              "결과에 평문이 남지 않음");
        Check(UnprotectSecret(sealed, opened) && opened == secret, "복호화 왕복");

        std::wstring junk = sealed;
        if (junk.size() > 40) junk[40] = (junk[40] == L'A') ? L'B' : L'A';
        std::wstring dummy;
        Check(!UnprotectSecret(junk, dummy), "변조된 값을 거절");
    }

    printf("루프백 리스너\n");
    {
        LoopbackListener ls;
        unsigned short port = ls.Start();
        Check(port != 0, "127.0.0.1 의 빈 포트에 바인딩");
        if (port) printf("      포트 %u\n", port);

        if (serve) {
            wchar_t url[256];
            swprintf_s(url, L"http://127.0.0.1:%u/?code=TEST_CODE_123&state=x", port);
            printf("      브라우저를 연다: %ls\n", url);
            ShellExecuteW(nullptr, L"open", url, nullptr, nullptr, SW_SHOWNORMAL);

            std::string code, err;
            bool got = ls.WaitForCode(30000, code, err);
            Check(got && code == "TEST_CODE_123", "브라우저가 보낸 code 를 읽음");
            if (!got) printf("      err=%s\n", err.c_str());
        } else {
            // 서버 없이도 왕복을 확인한다: 우리가 직접 붙어서 요청을 보낸다.
            WSADATA wsa; WSAStartup(MAKEWORD(2, 2), &wsa);
            SOCKET c = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            sockaddr_in a{};
            a.sin_family = AF_INET;
            a.sin_port = htons(port);
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            bool connected = (connect(c, (sockaddr*)&a, sizeof(a)) == 0);
            Check(connected, "리스너에 접속");

            const char* req =
                "GET /?code=abc%2Ddef&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
            send(c, req, (int)strlen(req), 0);

            std::string code, err;
            bool got = ls.WaitForCode(5000, code, err);
            if (!got || code != "abc-def") printf("      code=%s err=%s\n", code.c_str(), err.c_str());
            Check(got && code == "abc-def", "code 를 꺼내고 %2D 를 풀었다");

            char rb[512];
            int n = recv(c, rb, sizeof(rb) - 1, 0);
            if (n > 0) rb[n] = 0; else rb[0] = 0;
            Check(n > 0 && strstr(rb, "200 OK") != nullptr, "브라우저에 응답을 돌려줌");
            closesocket(c);
            WSACleanup();
        }
    }

    printf("\n%s\n", g_fail == 0 ? "전부 통과" : "실패 있음");
    return g_fail == 0 ? 0 : 1;
}
