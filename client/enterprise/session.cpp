// session.cpp - 계정 세션 한 벌을 들고 있는 곳. 설계 근거는 session.h 머리말.
#include "session.h"

#include <windows.h>
#include <mutex>
#include <ctime>

namespace {

std::mutex        s_mx;          // 아래 전부를 지킨다
std::wstring      s_url, s_key;
AuthSession       s_session;
bool              s_hasAccount = false;   // 로그인한 적이 있는지
SessionRotatedFn  s_rotatedFn = nullptr;

// 회전한 refresh 토큰을 잠금 밖으로 내보내기 위한 칸.
//
// 콜백을 잠금 안에서 부르지 않는다. 받는 쪽은 설정을 저장하러 갈 것이고,
// 거기서 무엇을 부를지 여기서는 알 수 없다 - 다시 SessionToken 을 부르면
// 그대로 잠긴다. 그래서 칸에 놓고, 잠금을 놓은 뒤에 꺼내 부른다.
std::wstring      s_pendingSealed;

// 만료 5분 전부터 갱신한다. 요청 한 번이 그 사이에 끝나지 않을 이유가 없지만,
// 시계가 조금 틀어져 있어도 견디게 여유를 둔다 - 만료된 토큰으로 보낸 요청은
// 401 로 돌아오고, 그 401 은 "권한이 없다" 와 구분되지 않는다.
constexpr long long kRenewAheadSec = 300;

bool ExpiringSoon(const AuthSession& s) {
    if (s.accessToken.empty()) return true;
    return (long long)s.expiresAtUnix - (long long)_time64(nullptr) < kRenewAheadSec;
}

// s_mx 를 잡은 채로 부른다. 네트워크를 타므로 수백 ms 가 걸린다.
// 잠금을 놓지 않는다 - 회전은 s_pendingSealed 에 놓고 나간다.
bool RenewLocked(std::wstring& outErr) {
    if (s_session.refreshToken.empty()) {
        outErr = L"저장된 refresh 토큰이 없다";
        return false;
    }
    AuthSession fresh;
    if (!RefreshSession(s_url, s_key, s_session.refreshToken, fresh, outErr))
        return false;

    // 이메일/계정 id 는 갱신 응답에 없을 수 있다. 있던 값을 지우지 않는다 -
    // 화면에 "로그인: (빈칸)" 이 뜨는 것은 로그인이 풀린 것처럼 보인다.
    if (fresh.userId.empty()) fresh.userId = s_session.userId;
    if (fresh.email.empty())  fresh.email  = s_session.email;

    bool rotated = (fresh.refreshToken != s_session.refreshToken);
    s_session = fresh;

    if (rotated) {
        std::wstring sealed;
        if (ProtectSecret(s_session.refreshToken, sealed)) s_pendingSealed = sealed;
        // 봉인이 실패하면 저장할 값이 없다. 지금 실행은 계속 되지만 다음
        // 실행에서 로그인이 풀린다. 그건 다시 로그인하면 되는 일이고,
        // 여기서 할 수 있는 일은 없다.
    }
    return true;
}

// 잠금을 놓은 뒤에 부른다.
void FireRotatedIfPending() {
    std::wstring sealed;
    SessionRotatedFn fn = nullptr;
    {
        std::lock_guard<std::mutex> lock(s_mx);
        if (s_pendingSealed.empty() || !s_rotatedFn) return;
        sealed.swap(s_pendingSealed);
        fn = s_rotatedFn;
    }
    fn(sealed);
}

} // namespace

void SessionOnRotated(SessionRotatedFn fn) {
    {
        std::lock_guard<std::mutex> lock(s_mx);
        s_rotatedFn = fn;
    }
    // 콜백을 늦게 달았어도 그 사이에 회전한 값을 잃지 않는다.
    FireRotatedIfPending();
}

bool SessionStart(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                  const std::wstring& sealedRefresh, std::wstring& outErr) {
    outErr.clear();
    bool ok = false;
    {
        std::lock_guard<std::mutex> lock(s_mx);
        s_url = supabaseUrl;
        s_key = anonKey;
        s_session = AuthSession{};
        s_hasAccount = false;

        if (sealedRefresh.empty()) {
            // 로그인한 적이 없다. 오류가 아니므로 outErr 를 비워 둔다.
            return false;
        }

        std::wstring plain;
        if (!UnprotectSecret(sealedRefresh, plain) || plain.empty()) {
            // DPAPI 는 이 사용자+이 PC 에 묶여 있다. 다른 PC 에서 config 를
            // 복사해 왔으면 여기서 풀리지 않는다. 다시 로그인하면 되는 일이라
            // 사용자에게 그렇게 말해 줘야 한다.
            outErr = L"저장된 로그인을 풀지 못했다 (다른 PC 의 설정을 복사해 왔을 수 있다)";
            return false;
        }
        s_hasAccount = true;
        s_session.refreshToken = plain;
        ok = RenewLocked(outErr);
    }
    FireRotatedIfPending();
    return ok;
}

void SessionAdopt(const AuthSession& s) {
    std::lock_guard<std::mutex> lock(s_mx);
    s_session = s;
    s_hasAccount = !s.refreshToken.empty();
}

bool SessionToken(std::wstring& outAccess, std::wstring& outErr) {
    outAccess.clear();
    outErr.clear();
    bool ok = false;
    {
        std::lock_guard<std::mutex> lock(s_mx);
        if (!s_hasAccount) { outErr = L"로그인하지 않았다"; return false; }

        if (!ExpiringSoon(s_session) || RenewLocked(outErr)) {
            if (s_session.accessToken.empty()) outErr = L"세션이 없다";
            else { outAccess = s_session.accessToken; ok = true; }
        }
    }
    FireRotatedIfPending();
    return ok;
}

bool SessionHasAccount() {
    std::lock_guard<std::mutex> lock(s_mx);
    return s_hasAccount;
}

std::wstring SessionUserId() {
    std::lock_guard<std::mutex> lock(s_mx);
    return s_session.userId;
}

std::wstring SessionEmail() {
    std::lock_guard<std::mutex> lock(s_mx);
    return s_session.email;
}

void SessionClear() {
    std::lock_guard<std::mutex> lock(s_mx);
    s_session = AuthSession{};
    s_hasAccount = false;
}
