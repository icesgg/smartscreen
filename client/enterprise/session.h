// session.h - 앱이 살아 있는 동안 계정 세션을 유지한다
//
// 여기까지 이런 것이 없었던 이유: 로그인은 폰을 등록할 때 한 번만 필요했고,
// 등록이 끝나면 세션은 버려도 됐다. config 의 authRefresh 는 저장만 되고
// `RefreshSession` 은 앱에서 한 번도 불린 적이 없다 (tools/authtest.cpp 만
// 불렀다). 이 저장소가 반복해서 보는 그 모양이다 - 쓰인 적 없는 코드.
//
// 클립보드 동기화는 사정이 다르다. 상시로 서버에 말을 걸어야 하고, access
// 토큰의 수명은 한 시간이다. 그래서 세션을 한 군데서 들고, 만료가 가까워지면
// 알아서 갱신하고, 그 결과를 여러 스레드가 안전하게 읽을 수 있어야 한다.
//
// **갱신하면 refresh 토큰이 바뀐다.** Supabase 는 갱신할 때마다 새 refresh
// 토큰을 주고 예전 것을 무효로 만든다. 새 값을 저장하지 않으면 지금 실행은
// 잘 돌아가다가 다음 실행에서 로그인이 풀린다 - 증상이 하루 뒤에 나타나므로
// 원인을 찾기 어렵다. 그래서 회전은 콜백으로 밖에 알리고, 저장은 설정을
// 쓰는 스레드가 하도록 맡긴다.
#pragma once
#include "auth.h"
#include <string>

// refresh 토큰이 회전했을 때 불린다. 인자는 DPAPI 로 봉한 값이라 그대로
// config 의 authRefresh 에 넣으면 된다.
//
// 아무 스레드에서나 불릴 수 있다. config 파일을 여기서 직접 쓰면 UI 스레드의
// SaveAppConfig 와 겹쳐 서로의 변경을 덮어쓸 수 있으므로, 받는 쪽은 UI
// 스레드로 넘겨서 저장할 것.
typedef void (*SessionRotatedFn)(const std::wstring& sealedRefresh);
void SessionOnRotated(SessionRotatedFn fn);

// 앱을 켤 때 한 번. 봉해진 refresh 토큰으로 세션을 되살린다.
//
// 돌려주는 값 세 가지를 구분해야 한다.
//  - true                : 세션이 살아 있다
//  - false, outErr 빈 값  : 로그인한 적이 없다. 오류가 아니다
//  - false, outErr 있음   : 로그인은 했었는데 되살리지 못했다 (토큰 폐기,
//                          다른 PC 에서 복사해 온 config, 서버가 죽음 등)
bool SessionStart(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                  const std::wstring& sealedRefresh, std::wstring& outErr);

// 로그인 직후 새 세션을 심는다. 이걸 부르지 않으면 방금 로그인해도 세션이
// 없는 상태로 남아, 클립보드 동기화가 앱을 다시 켤 때까지 안 돈다.
void SessionAdopt(const AuthSession& s);

// 요청에 실을 access 토큰. 만료가 가까우면 여기서 갱신한다.
// 갱신에 걸리는 시간(수백 ms) 동안 부르는 스레드가 막히므로 UI 스레드에서
// 부르지 말 것.
bool SessionToken(std::wstring& outAccess, std::wstring& outErr);

// 서버가 방금 이 access 토큰을 401 로 돌려보냈을 때 부른다. 들고 있던 access
// 토큰을 버려서, 다음 SessionToken 이 남은 수명을 따지지 않고 갱신하게 한다.
//
// 이게 없던 동안에는 만료를 이 PC 의 시계로만 판단했다. 그 판단이 서버와
// 어긋나면(토큰을 받은 뒤 시계가 뒤로 맞춰졌다, 서버의 JWT 비밀이 바뀌었다)
// 요청마다 401 이 돌아오는데도 같은 토큰을 계속 내주었고, 어긋난 만큼의
// 시간이 지나거나 앱을 다시 켜기 전에는 풀리지 않았다.
//
// 여기서 갱신하지는 않는다. 갱신은 다음 SessionToken 이 한다. 다만 다른
// 스레드가 마침 갱신 중이면 그것이 끝날 때까지 기다리므로, SessionToken 과
// 마찬가지로 UI 스레드에서 부르지 말 것.
//
// 로그인은 그대로다 - refresh 토큰은 건드리지 않는다. 갱신이 실패하면 그 뒤의
// SessionToken 은 거절된 토큰을 다시 내주지 않고 false 를 준다.
//
// 401 을 볼 때마다 부르면 그때마다 갱신이 한 번씩 돌고 refresh 토큰도 그만큼
// 회전한다. 부르는 쪽이 재시도 간격을 벌려야 한다 (clipsync.cpp 의 일꾼이 그렇게 한다).
void SessionInvalidate();

// 로그인한 계정이 있는지 (세션이 지금 유효한지와는 다르다 - 서버가 죽어도
// 계정은 있다). UI 가 "로그인하세요" 를 띄울지 판단하는 데 쓴다.
bool SessionHasAccount();
std::wstring SessionUserId();
std::wstring SessionEmail();

// 세션을 버린다. 로그아웃이 아니다 - 서버의 refresh 토큰은 그대로다.
void SessionClear();
