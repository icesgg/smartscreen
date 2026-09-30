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
#include <vector>

// ---------------------------------------------------------------------------
// HTTP 한 번 왕복 (WinHTTP)
// ---------------------------------------------------------------------------
// auth.cpp 안에만 static 으로 있던 것을 꺼냈다. 클립보드 동기화가 똑같은 것을
// 필요로 하는데(clipsync.cpp), 한 벌 더 만들면 두 벌이 된다. 기업 콘텐츠
// (supabase.cpp)도 이제 이것을 쓴다.
//
// body 와 outBody 는 바이너리도 담는다 - std::string 은 여기서 문자열이 아니라
// 바이트 통이다. PNG 를 그대로 싣고 그대로 받는다.
//
// 이 헤더는 <string>/<vector> 말고는 아무것도 요구하지 않는다. windows.h 를
// 끌어오면 이걸 포함하는 쪽의 헤더 순서 문제가 된다(config.h 가 winsock2 로
// 겪은 일). 그래서 상태 코드가 DWORD 가 아니라 unsigned long 이다 - 윈도에서
// 같은 타입이므로 DWORD 변수를 그대로 넘겨도 된다.
//
// true 는 응답을 본문 끝까지 받았다는 뜻이다 (상태 코드가 4xx/5xx 여도 true 다 -
// 그건 outStatus 로 본다). 헤더는 왔는데 본문을 읽다가 끊기면(수신 시간 제한,
// 연결 리셋) false 를 주고 outBody 를 비운다. 예전에는 그때도 true 여서 잘린
// 본문이 온전한 응답처럼 쓰일 수 있었다. outStatus 는 헤더에서 읽은 값이 남으므로
// "false 인데 outStatus 가 0 이 아니다" 는 닿기는 했는데 본문을 못 받은 것이다.
//
// maxBodyBytes 가 0 이 아니면 본문이 그 크기를 넘는 순간 읽기를 그만두고 false 를
// 준다 (outBody 는 비고 outStatus 는 남는다). 서버가 주는 대로 메모리에 쌓지
// 않으려는 호출이 쓴다. 0 은 상한 없음 - 몇 MB 짜리 exe 를 되받아 대조하는
// tools/publish.cpp 가 그렇게 부른다.
bool SupabaseHttp(const wchar_t* verb, const std::wstring& url,
                  const std::vector<std::wstring>& headers,
                  const std::string& body,
                  unsigned long& outStatus, std::string& outBody,
                  size_t maxBodyBytes = 0);

// UTF-8 <-> UTF-16. 같은 이유로 여기 있다.
std::wstring Utf8ToWide(const std::string& s);
std::string  WideToUtf8(const std::wstring& w);

// 응답 본문에서 "key": "value" 를 꺼낸다. 응답 모양이 고정이라 파서를 들이지
// 않는다. 첫 번째로 나오는 것을 준다 - 배열을 읽을 때는 PostgREST 에
// 단일 객체를 달라고 해서(Accept: application/vnd.pgrst.object+json) 배열을
// 아예 만들지 않는 편이 맞다.
// JsonGetString 은 닫는 따옴표가 없는 문자열(잘린 본문)을 값으로 치지 않는다 - false.
bool JsonGetString(const std::string& body, const std::string& key, std::string& out);
bool JsonGetNumber(const std::string& body, const std::string& key, long long& out);

// ---------------------------------------------------------------------------
// PKCE (RFC 7636)
// ---------------------------------------------------------------------------
// code_verifier: [A-Za-z0-9-._~] 로만 이루어진 43~128자 난수.
// 32바이트 난수를 base64url 로 적어 43자를 만든다.
std::string MakeCodeVerifier();

// code_challenge = BASE64URL(SHA256(ASCII(verifier)))
bool MakeCodeChallengeS256(const std::string& verifier, std::string& outChallenge);

// SHA-256 을 소문자 hex 64자로. 업데이트 파일의 해시 대조에 쓴다 (client/update.cpp,
// tools/publish.cpp). 같은 bcrypt 배관이라 여기 둔다.
bool Sha256Bytes(const void* data, size_t len, std::string& outHex);
bool Sha256File(const std::wstring& path, std::string& outHex, unsigned long long& outSize);

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
    //
    // "GET /?..." 에 code 나 error 를 실은 요청만 결과로 친다. 그 밖의 연결
    // (아무 말 없는 연결, 다른 경로, 다른 메서드)은 닫고 timeoutMs 가 다할 때까지
    // 계속 기다린다 - 이 포트는 같은 PC 의 누구나 닿을 수 있어서, 첫 연결을
    // 결과로 치면 남이 로그인을 끝내거나 붙잡아 둘 수 있다.
    // error 쪽 글(outErr)은 여전히 남이 넣을 수 있는 값이다. 그대로 믿지 말 것.
    // outCode 도 같다 - 남이 그럴듯한 가짜 코드를 먼저 보내면 그것이 돌아가고,
    // 교환이 실패하면서 진짜 요청은 놓친다 (auth.cpp 의 WaitForCode 에 까닭).
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

// ---------------------------------------------------------------------------
// Supabase Auth
// ---------------------------------------------------------------------------
struct AuthSession {
    std::wstring accessToken;    // 수명 1시간짜리. 요청에 싣는 값
    std::wstring refreshToken;   // 보관용. config 에는 DPAPI 로 봉해서 넣는다
    std::wstring userId;
    std::wstring email;
    // 이 헤더는 <string> 말고는 아무것도 요구하지 않는다. windows.h 를 끌어오면
    // 이걸 포함하는 쪽의 헤더 순서 문제가 된다 (config.h 가 winsock2 로 겪은 일).
    unsigned long long expiresAtUnix = 0;
};

// 브라우저를 열어 구글 로그인을 받고, 돌아온 코드를 세션으로 바꾼다.
// 사용자가 브라우저에서 시간을 쓰므로 timeoutSec 은 넉넉해야 한다(기본 3분).
// 호출하는 쪽이 UI 스레드를 막지 않도록 별도 스레드에서 부를 것.
bool SignInWithGoogle(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                      AuthSession& outSession, std::wstring& outErr,
                      unsigned timeoutSec = 180);

// 저장해 둔 refresh token 으로 세션을 되살린다. 앱을 켤 때마다 부른다.
bool RefreshSession(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                    const std::wstring& refreshToken,
                    AuthSession& outSession, std::wstring& outErr);

// 로그인한 계정에 묶인 폰 토큰을 가져온다.
// 아직 폰에서 로그인한 적이 없으면 행이 없다 - 그때는 true 를 주고 토큰은 빈 값이다.
// (없는 것과 못 가져온 것은 사용자에게 다른 말을 해 줘야 한다)
bool FetchDeviceToken(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                      const AuthSession& session,
                      std::wstring& outTokenHex, std::wstring& outErr);

// 폰이 하는 것과 같은 RPC. 서버에 이미 값이 있으면 그 값이 돌아온다.
// PC 에서 등록하는 용도는 아니고, 폰 쪽이 실패할 때 원인을 가르는 데 쓴다
// (서버가 거절하는지, 폰이 안 보내는지).
bool ClaimDeviceToken(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                      const AuthSession& session, const std::wstring& tokenHex,
                      std::wstring& outTokenHex, std::wstring& outErr);

// 이 계정의 행을 지운다. 등록을 해제하는 것이고, 폰 자체의 토큰은 그대로다.
// 지운 뒤 폰에서 다시 로그인하면 폰이 INSERT 경로를 타므로, 폰 쪽 등록이
// 실제로 되는지를 이것 없이는 확인할 수 없다 (PC 가 넣어 둔 행과 구분이 안 된다).
bool DeleteDeviceToken(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                       const AuthSession& session, std::wstring& outErr);
