import Foundation
import Darwin
import SmartScreenCore

/// 앱이 살아 있는 동안 계정 세션 한 벌을 들고 있는 곳 (Windows client/enterprise/session.cpp).
///
/// 클립보드 동기화는 상시로 서버에 말을 걸어야 하고, access 토큰의 수명은 한 시간이다. 그래서
/// 세션을 한 군데서 들고, 만료가 가까워지면 알아서 갱신하고, 그 결과를 여러 스레드가 안전하게
/// 읽을 수 있어야 한다.
///
/// **갱신하면 refresh 토큰이 바뀐다.** Supabase 는 갱신할 때마다 새 refresh 토큰을 주고 예전
/// 것을 무효로 만든다. 새 값을 저장하지 않으면 지금 실행은 잘 돌아가다가 다음 실행에서 로그인이
/// 풀린다 - 증상이 하루 뒤에 나타나므로 원인을 찾기 어렵다. 그래서 회전은 콜백으로 밖에 알리고,
/// 저장은 설정을 쓰는 메인 스레드가 한다.
///
/// **갱신은 한 번에 하나 (single-flight).** 잠금을 네트워크 호출 내내 쥐고 있어서, 동시에 부른
/// 쪽들은 진행 중인 갱신 하나가 끝나기를 기다렸다가 그 결과를 쓴다. 이미 회전한 refresh 토큰을
/// 짧은 재사용 창 밖에서 다시 쓰면 Supabase 는 그 토큰 가족 전체를 폐기한다 - 두 갱신이 나란히
/// 돌면 사용자가 로그아웃된다. (NSLock 은 막히는 I/O 동안 쥐어도 된다. os_unfair_lock 은 안 된다.)
final class AccountSession {
    static let shared = AccountSession()

    // 아래 전부를 lock 이 지킨다.
    private let lock = NSLock()
    private var url = ""
    private var key = ""
    private var session = AuthTokens()
    private var account = false                   // 로그인한 적이 있는지
    private var rotatedFn: ((String) -> Void)?

    // 회전한 refresh 토큰(봉한 값)을 잠금 밖으로 내보내기 위한 칸.
    // 콜백을 잠금 안에서 부르지 않는다. 받는 쪽은 설정을 저장하러 갈 것이고, 거기서 무엇을
    // 부를지 여기서는 알 수 없다 - 다시 token() 을 부르면 그대로 잠긴다. 그래서 칸에 놓고,
    // 잠금을 놓은 뒤에 꺼내 부른다. 가장 새 값만 의미가 있다 (덮어쓰는 것이 맞다).
    private var pendingSealed = ""

    // access 토큰의 만료를 단조 시계(Mono, 잠자기도 센다)로도 적어 둔다.
    //
    // expiresAtUnix 는 받은 순간의 벽시계 + expires_in 이다. 그 뒤에 시계가 뒤로 맞춰지면
    // (빨리 가던 시계를 시간 동기화가 고친다, 사람이 손으로 바꾼다) 벽시계로는 만료가 그만큼
    // 멀어 보인다. 토큰은 실제로 한 시간 뒤에 죽는데 갱신은 미뤄지고, 그 사이의 요청은 전부
    // 401 이 된다. 단조 시계는 시계를 바꿔도 그대로 흐른다.
    //
    // 벽시계 쪽 판단도 남겨 둔다. 둘 중 하나라도 "곧 만료" 라고 하면 갱신한다 - 일찍 갱신하는
    // 것은 요청 한 번이고, 늦게 갱신하는 것은 401 이다.
    private var expiresTick: UInt64 = 0

    // hasAccount / userId / email 의 사본 (infoLock 이 지킨다). account 나 session 이 바뀔 때마다
    // lock 안에서 맞춰 둔다 (publishLocked). 간단 화면은 1 초마다 hasAccount 를 읽는데, lock 은 갱신 요청
    // 내내 쥐어져 있어 서버가 느리면 그동안 메인 스레드가 멎는다 (Windows 는 그대로 멎었다).
    // 사본은 갱신 중에도 바로 읽히고, 값은 갱신 전의 것이다 - 계정 유무는 갱신으로 바뀌지 않는다.
    // 잠금 순서는 언제나 lock -> infoLock 이다.
    private let infoLock = NSLock()
    private var infoAccount = false
    private var infoUserId = ""
    private var infoEmail = ""

    // 만료 5분 전부터 갱신한다. 시계가 조금 틀어져 있어도 견디게 여유를 둔다 - 만료된 토큰으로
    // 보낸 요청은 401 로 돌아오고, 그 401 은 "권한이 없다" 와 구분되지 않는다.
    private static let renewAheadSec: Int64 = 300
    // 서버가 터무니없는 expires_in 을 줘도 곱셈이 넘치지 않게. 그보다 긴 토큰은 30일에 한 번
    // 일찍 갱신될 뿐이다.
    private static let maxLeftSec: Int64 = 30 * 24 * 3600

    private init() {}

    /// sealed refresh token; never called under the lock.
    /// 아무 스레드에서나 불릴 수 있다. 받는 쪽은 메인 스레드로 넘겨서 저장할 것
    /// (config.ini 의 읽고-고치고-쓰기는 메인에서만).
    func onRotated(_ fn: @escaping (String) -> Void) {
        lock.lock()
        rotatedFn = fn
        lock.unlock()
        // 콜백을 늦게 달았어도 그 사이에 회전한 값을 잃지 않는다.
        fireRotatedIfPending()
    }

    /// Blocking. ok=true alive; ok=false err="" never logged in; ok=false err!="" had account, could not revive.
    ///
    /// 앱을 켤 때 한 번, 저장된 계정이 없어도 부른다 - url/key 를 정하는 곳이 여기뿐이고,
    /// 나중의 adopt (로그인 직후) 는 갱신할 때 그 값에 기댄다.
    func start(url: String, key: String, sealed: String) -> (ok: Bool, err: String) {
        let result: (ok: Bool, err: String)
        lock.lock()
        self.url = url
        self.key = key
        session = AuthTokens()
        expiresTick = 0
        account = false
        publishLocked()

        if sealed.isEmpty {
            // 로그인한 적이 없다. 오류가 아니므로 err 를 비워 둔다.
            lock.unlock()
            return (false, "")
        }

        guard let plain = SecretSeal.unprotect(sealed), !plain.isEmpty else {
            // 봉한 값은 이 사용자 + 이 Mac 에 묶여 있다. 다른 PC 에서 config 를 복사해 왔으면
            // (Windows 의 DPAPI 값 포함) 여기서 풀리지 않는다. 다시 로그인하면 되는 일이라
            // 사용자에게 그렇게 말해 줘야 한다.
            lock.unlock()
            return (false, "저장된 로그인을 풀지 못했다 (다른 PC 의 설정을 복사해 왔을 수 있다)")
        }
        account = true
        session.refresh = plain
        publishLocked()
        let renewed = renewLocked()
        result = (renewed.ok, renewed.ok ? "" : renewed.err)
        lock.unlock()

        fireRotatedIfPending()
        // 갱신이 실패해도 account 는 true 로 남는다 - 오프라인으로 켜진 PC 도 클립보드 일꾼을
        // 띄우고, 일꾼이 30 초마다 다시 해 본다.
        return result
    }

    /// 로그인 직후 새 세션을 심는다. 이걸 부르지 않으면 방금 로그인해도 세션이 없는 상태로
    /// 남아, 클립보드 동기화가 앱을 다시 켤 때까지 "로그인하지 않았다" 를 말한다.
    /// url/key 는 건드리지 않는다.
    func adopt(_ t: AuthTokens) {
        lock.lock()
        session = t
        account = !t.refresh.isEmpty
        stampDeadlineLocked()
        publishLocked()
        lock.unlock()
    }

    /// 요청에 실을 access 토큰. 만료가 가까우면 여기서 갱신한다 (그동안 막힌다 - 메인에서
    /// 부르지 말 것). 실패하면 (nil, 이유).
    func token() -> (String?, String) {
        var access: String? = nil
        var err = ""
        lock.lock()
        if !account {
            lock.unlock()
            return (nil, "로그인하지 않았다")
        }
        var alive = true
        if expiringSoonLocked() {
            let renewed = renewLocked()
            if !renewed.ok {
                alive = false
                err = renewed.err
            }
        }
        if alive {
            if session.access.isEmpty {
                err = "세션이 없다"
            } else {
                access = session.access
            }
        }
        lock.unlock()

        fireRotatedIfPending()
        return (access, err)
    }

    /// 서버가 방금 이 access 토큰을 401 로 돌려보냈을 때 부른다. 들고 있던 access 토큰을 버려서,
    /// 다음 token() 이 남은 수명을 따지지 않고 갱신하게 한다.
    ///
    /// 이게 없던 동안에는 만료를 이 PC 의 시계로만 판단했다. 그 판단이 서버와 어긋나면 (토큰을
    /// 받은 뒤 시계가 뒤로 맞춰졌다, 서버의 JWT 비밀이 바뀌었다) 요청마다 401 이 돌아오는데도
    /// 같은 토큰을 계속 내주었다. 마감만 0 으로 하지 않고 토큰을 지우는 것은, 마감을 보지 않고
    /// 토큰을 꺼내는 코드가 생겨도 서버가 거절한 값을 또 내주지 않게 하려는 것이다.
    ///
    /// refresh 토큰과 account 는 그대로 둔다 (로그인한 사람에게 "로그인하지 않았다" 가 뜨면 안 된다).
    /// 부를 때마다 갱신이 한 번, 회전도 한 번 일어나므로 부르는 쪽이 재시도 간격을 벌려야 한다.
    func invalidate() {
        lock.lock()
        session.access = ""
        session.expiresAtUnix = 0
        expiresTick = 0
        lock.unlock()
    }

    /// 로그인한 계정이 있는지 (세션이 지금 유효한지와는 다르다 - 서버가 죽어도 계정은 있다).
    /// UI 가 "로그인하세요" 를 띄울지 판단하는 데 쓴다. 갱신 중에도 막히지 않는다 (infoLock).
    var hasAccount: Bool {
        infoLock.lock()
        defer { infoLock.unlock() }
        return infoAccount
    }

    /// 클립보드 그림 경로 "<user_id>/<기기>.png" 에 쓴다. token() 이 돌아온 뒤에 읽으면 그 토큰과
    /// 같은 세션의 값이다 (갱신은 lock 안에서 사본까지 맞춘 뒤 끝난다).
    var userId: String {
        infoLock.lock()
        defer { infoLock.unlock() }
        return infoUserId
    }

    var email: String {
        infoLock.lock()
        defer { infoLock.unlock() }
        return infoEmail
    }

    // ---- private (lock 을 쥔 채로 부르는 것은 이름이 ...Locked) ----

    private static func nowUnix() -> Int64 {
        return Int64(time(nil))
    }

    /// a - b, 넘치면 끝값 (서버가 준 터무니없는 만료 값에도 죽지 않게).
    private static func diff(_ a: Int64, _ b: Int64) -> Int64 {
        let (d, overflow) = a.subtractingReportingOverflow(b)
        if overflow { return a < 0 ? Int64.min : Int64.max }
        return d
    }

    private func expiringSoonLocked() -> Bool {
        if session.access.isEmpty { return true }
        if AccountSession.diff(session.expiresAtUnix, AccountSession.nowUnix()) < AccountSession.renewAheadSec {
            return true
        }
        return Mono.now() &+ UInt64(AccountSession.renewAheadSec) * 1000 >= expiresTick
    }

    /// session 을 새 세션으로 바꾼 바로 다음에 부른다. 남은 수명은 방금 계산된 expiresAtUnix
    /// 에서 도로 꺼낸다 - 받은 직후라 그 사이에 시계가 움직였을 틈이 없다.
    private func stampDeadlineLocked() {
        var left = AccountSession.diff(session.expiresAtUnix, AccountSession.nowUnix())
        if left < 0 { left = 0 }
        if left > AccountSession.maxLeftSec { left = AccountSession.maxLeftSec }
        expiresTick = Mono.now() &+ UInt64(left) * 1000
    }

    /// lock 을 쥔 채로 부른다. 네트워크를 타므로 수백 ms 가 걸린다. 잠금을 놓지 않는다 -
    /// 회전은 pendingSealed 에 놓고 나간다.
    private func renewLocked() -> (ok: Bool, err: String) {
        if session.refresh.isEmpty {
            return (false, "저장된 refresh 토큰이 없다")
        }
        let got = Auth.refresh(url: url, key: key, refreshToken: session.refresh)
        guard var fresh = got.0 else {
            return (false, got.1)
        }

        // 이메일/계정 id 는 갱신 응답에 없을 수 있다. 있던 값을 지우지 않는다 - 화면에
        // "로그인: (빈칸)" 이 뜨는 것은 로그인이 풀린 것처럼 보인다.
        if fresh.userId.isEmpty { fresh.userId = session.userId }
        if fresh.email.isEmpty { fresh.email = session.email }

        let rotated = fresh.refresh != session.refresh
        session = fresh
        stampDeadlineLocked()
        publishLocked()

        if rotated, let sealed = SecretSeal.protect(fresh.refresh) {
            pendingSealed = sealed
        }
        // 봉인이 실패하면 저장할 값이 없다. 지금 실행은 계속 되지만 다음 실행에서 로그인이
        // 풀린다. 그건 다시 로그인하면 되는 일이고, 여기서 할 수 있는 일은 없다.
        return (true, "")
    }

    /// lock 을 쥔 채로, account 나 session 을 바꾼 바로 다음에 부른다.
    private func publishLocked() {
        infoLock.lock()
        infoAccount = account
        infoUserId = session.userId
        infoEmail = session.email
        infoLock.unlock()
    }

    /// 잠금을 놓은 뒤에 부른다.
    private func fireRotatedIfPending() {
        lock.lock()
        guard !pendingSealed.isEmpty, let fn = rotatedFn else {
            lock.unlock()
            return
        }
        let sealed = pendingSealed
        pendingSealed = ""
        lock.unlock()
        fn(sealed)
    }
}
