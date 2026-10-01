import Foundation

/// 로그인 세션 하나 (Windows AuthSession). expiresAtUnix 는 벽시계 기준 만료 시각(초).
public struct AuthTokens: Equatable {
    public var access = ""; public var refresh = ""; public var userId = ""; public var email = ""
    public var expiresAtUnix: Int64 = 0
    public init() {}
}

/// Supabase Auth / PostgREST 응답 읽기 (client/enterprise/auth.cpp 의 ParseSession,
/// PickError, FetchDeviceToken 의 본문 처리).
///
/// Windows 는 "키": 꼴을 찾아 첫 문자열 값을 집는 작은 손 파서를 쓴다. 여기서는
/// JSONSerialization 으로 읽되 뜻은 같게 둔다: \b \f 같은 짧은 이스케이프(Postgres 가
/// 그렇게 적는다)와 \uXXXX 서러게이트 쌍을 풀고, 잘린 본문은 값이 아니다 (파싱 실패).
/// 키는 최상위에서 먼저 찾고, 없으면 안쪽 객체/배열을 뒤진다 - Windows 가 본문 어디서든
/// 처음 나온 "키" 를 집는 것에 가깝게.
public enum AuthParse {
    /// ParseSession: access_token 과 refresh_token 이 둘 다 비어 있지 않아야 한다.
    /// expires_in 이 없으면 3600. expiresAt = nowUnix + expires_in (서버의 expires_at 은 보지 않는다).
    /// userId / email 은 user.id / user.email.
    public static func parseSession(_ body: Data, nowUnix: Int64) -> AuthTokens? {
        guard let root = jsonObject(body) as? [String: Any] else { return nil }
        guard let at = firstString(root, "access_token"), !at.isEmpty else { return nil }
        guard let rt = firstString(root, "refresh_token"), !rt.isEmpty else { return nil }

        var t = AuthTokens()
        t.access = at
        t.refresh = rt

        // Windows: 키가 없으면 3600, 있으면 _atoi64(값) - 숫자가 아닌 값(null, "3600")은 0 이 된다.
        var expiresIn: Int64 = 3600
        if let v = root["expires_in"] { expiresIn = atoi64Like(v) }
        let (sum, overflow) = nowUnix.addingReportingOverflow(expiresIn)
        if overflow {
            t.expiresAtUnix = expiresIn > 0 ? Int64.max : Int64.min
        } else {
            t.expiresAtUnix = sum
        }

        // user 객체 안의 id/email. Windows 는 본문에서 처음 나온 "id"/"email" 문자열을 집는데,
        // Supabase 의 토큰 응답에서는 그게 user.id / user.email 이다.
        let user = root["user"] as? [String: Any]
        if let id = (user?["id"] as? String) ?? firstString(root, "id") { t.userId = id }
        if let em = (user?["email"] as? String) ?? firstString(root, "email") { t.email = em }
        return t
    }

    /// PickError: 오류 본문에서 사람이 읽을 문장을 고른다. Supabase 는 키 이름이 일정하지 않다.
    /// error_description, msg, message, error 순서로 처음 만난 비어 있지 않은 문자열을
    /// TextSanitize.capErrorText 로 다듬어 돌려주고, 없으면 "HTTP <status>".
    ///
    /// 상한(160)과 제어문자 지우기: 이 글은 한 줄짜리 상태 줄, 알림 창, events.log 로 간다 -
    /// 줄바꿈이 섞이면 서버가 로그에 줄을 지어낼 수 있고, 길이가 정해져 있지 않던 글이
    /// Windows 판을 한 번 죽였다.
    public static func pickError(_ body: Data, status: Int) -> String {
        if let root = jsonObject(body) {
            for k in ["error_description", "msg", "message", "error"] {
                if let v = firstString(root, k), !v.isEmpty {
                    return TextSanitize.capErrorText(v)
                }
            }
        }
        return "HTTP \(status)"
    }

    /// device_tokens?select=token 의 2xx 본문에서 첫 비어 있지 않은 "token" 문자열.
    /// 행이 없으면 "[]" 이고, 그건 오류가 아니라 "폰에서 아직 로그인 안 함" 이다 -> "".
    /// 본문이 JSON 배열이 아니면 nil.
    public static func firstToken(_ body: Data) -> String? {
        guard let arr = jsonObject(body) as? [Any] else { return nil }
        for el in arr {
            if let d = el as? [String: Any], let t = d["token"] as? String, !t.isEmpty {
                return t
            }
        }
        return ""
    }

    // ---- private ----

    private static func jsonObject(_ body: Data) -> Any? {
        if body.isEmpty { return nil }
        return try? JSONSerialization.jsonObject(with: body, options: [])
    }

    /// key 의 첫 문자열 값. 최상위 객체를 먼저 보고, 없으면 안쪽을 깊이 우선으로 뒤진다.
    /// 값이 문자열이 아니면(null, 숫자) 그 자리는 건너뛴다 - Windows 의 JsonFindString 처럼.
    private static func firstString(_ obj: Any, _ key: String) -> String? {
        if let d = obj as? [String: Any] {
            if let s = d[key] as? String { return s }
            for (_, v) in d {
                if let s = firstString(v, key) { return s }
            }
        } else if let a = obj as? [Any] {
            for v in a {
                if let s = firstString(v, key) { return s }
            }
        }
        return nil
    }

    /// C 의 _atoi64 처럼: 숫자면 0 쪽으로 자른 정수(범위 밖은 끝값), 숫자가 아니면 0.
    private static func atoi64Like(_ v: Any) -> Int64 {
        guard let n = v as? NSNumber else { return 0 }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return 0 }   // _atoi64("true") == 0
        let d = n.doubleValue.rounded(.towardZero)
        if d.isNaN { return 0 }
        if d >= 9.2e18 { return Int64.max }
        if d <= -9.2e18 { return Int64.min }
        return Int64(d)
    }
}
