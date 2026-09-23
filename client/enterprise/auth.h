// auth.h - 구글 로그인 (Supabase Auth, OAuth PKCE + 루프백 리다이렉트)
//
// 데스크톱 앱이 구글 로그인을 하는 방법은 사실상 하나뿐이다 (RFC 8252):
// 시스템 브라우저를 열고, 127.0.0.1 로 결과를 돌려받는다. 구글은 임베디드
// 웹뷰에서의 OAuth 를 거부하므로 앱 안에 로그인 화면을 그릴 수 없고,
// 시스템 브라우저는 앱에 값을 직접 건네지 못하므로 앱이 잠깐 로컬 서버가 된다.
//
// 암시적(implicit) 흐름이 아니라 PKCE 를 쓴다. 암시적 흐름은 토큰을 URL
// 프래그먼트(#access_token=...)로 주는데, 프래그먼트는 HTTP 요청에 실려
// 가지 않아서 루프백 리스너가 영영 볼 수 없다. PKCE 는 ?code= 로 오므로
// 읽을 수 있다. 이건 취향이 아니라 이 구조에서 유일하게 동작하는 선택이다.
#pragma once
#include <string>

// ---------------------------------------------------------------------------
// PKCE (RFC 7636)
// ---------------------------------------------------------------------------
// code_verifier: [A-Za-z0-9-._~] 로만 이루어진 43~128자 난수.
// 32바이트 난수를 base64url 로 적어 43자를 만든다.
std::string MakeCodeVerifier();

// code_challenge = BASE64URL(SHA256(ASCII(verifier)))
bool MakeCodeChallengeS256(const std::string& verifier, std::string& outChallenge);

// ---------------------------------------------------------------------------
// 루프백 리다이렉트 수신
// ---------------------------------------------------------------------------
class LoopbackListener {
public:
    LoopbackListener();
    ~LoopbackListener();

    // 127.0.0.1 의 빈 포트에 붙고 그 포트 번호를 돌려준다. 실패하면 0.
    // 포트를 OS 가 고르게 두는 이유: 고정 포트는 이미 쓰이고 있을 수 있고,
    // 그러면 로그인이 "왜인지 안 되는" 상태가 된다.
    unsigned short Start();

    // 브라우저가 돌아올 때까지 기다렸다가 ?code= 를 꺼낸다.
    // 사용자가 취소하면 구글/Supabase 가 ?error= 로 돌아오므로 그것도 받는다.
    // 시간 안에 아무것도 안 오면 false.
    bool WaitForCode(unsigned timeoutMs, std::string& outCode, std::string& outErr);

    void Stop();

private:
    struct Impl;
    Impl* m_impl;
    LoopbackListener(const LoopbackListener&) = delete;
    LoopbackListener& operator=(const LoopbackListener&) = delete;
};

// ---------------------------------------------------------------------------
// 리프레시 토큰 보관
// ---------------------------------------------------------------------------
// config.ini 는 %APPDATA% 의 평문 파일이다. 폰 토큰이 거기 있는 것과 리프레시
// 토큰이 거기 있는 것은 위험이 다르다: 폰 토큰은 화면을 열어둘 수 있을 뿐이고,
// 리프레시 토큰은 계정 자체를 연다. 그래서 DPAPI 로 이 사용자+이 PC 에 묶는다.
// 파일을 복사해 가도 다른 PC 에서는 풀리지 않는다.
bool ProtectSecret(const std::wstring& plain, std::wstring& outB64);
bool UnprotectSecret(const std::wstring& b64, std::wstring& outPlain);

// 표준 base64 (DPAPI 산출물 보관용). base64url 과 다르다.
std::string Base64Encode(const unsigned char* data, size_t len);
bool        Base64Decode(const std::string& in, std::string& out);
