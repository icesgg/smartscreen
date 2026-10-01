import Foundation
import CryptoKit

// 구글 로그인용 PKCE 와 루프백 리스너가 쓰는 순수 로직 (client/enterprise/auth.cpp).
// 소켓과 브라우저는 앱 쪽(Net/Auth.swift)이 맡고, 여기에는 바이트를 어떻게 읽고
// 무엇을 돌려주는지만 둔다 - Windows 판과 같은 입력에 같은 답을 내야 하고, 그걸
// `swift test` 로 확인할 수 있어야 한다.

/// PKCE (RFC 7636). Windows 의 MakeCodeVerifier / MakeCodeChallengeS256 과 같은 값을 만든다.
///
/// PKCE 를 쓰는 이유: implicit 흐름은 토큰을 URL 조각(#...)에 싣는데 브라우저는 그 조각을
/// HTTP 요청에 보내지 않으므로 루프백 리스너가 볼 수 없다. 시스템 브라우저를 쓰는 이유:
/// 구글은 임베디드 웹뷰의 OAuth 를 거부한다 (RFC 8252).
public enum PKCE {
    /// 32 CSPRNG bytes -> base64url, no padding (43 chars of [A-Za-z0-9-_]).
    /// 32바이트 -> base64url 43자. 43은 RFC 7636 이 요구하는 최소 길이와 같다.
    /// CryptoKit 의 키 생성은 시스템 CSPRNG 를 쓴다 (Windows 는 BCryptGenRandom).
    public static func makeVerifier() -> String? {
        let key = SymmetricKey(size: .bits256)
        let bytes: [UInt8] = key.withUnsafeBytes { Array($0) }
        if bytes.count != 32 { return nil }
        return base64url(Data(bytes))
    }

    /// base64url(SHA-256(ASCII(verifier))), no padding -> 43 chars.
    /// 빈 verifier 는 Windows 에서 실패(false)다. 여기서는 "" 를 돌려주고, 부르는 쪽은
    /// makeVerifier() 가 nil 이 아닌 값만 넘기므로 만날 일이 없다.
    public static func challenge(for verifier: String) -> String {
        if verifier.isEmpty { return "" }
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(digest))
    }

    /// base64url: + -> -, / -> _, 패딩 없음 (RFC 4648 §5)
    public static func base64url(_ d: Data) -> String {
        var out = ""
        out.reserveCapacity((d.count + 2) / 3 * 4)
        for c in d.base64EncodedString().unicodeScalars {
            switch c {
            case "=": continue
            case "+": out.unicodeScalars.append("-")
            case "/": out.unicodeScalars.append("_")
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }
}

/// 질의 문자열에 실을 값 인코딩 (Windows UrlEncode): UTF-8 바이트마다, unreserved
/// (A-Z a-z 0-9 - . _ ~) 는 그대로, 나머지는 대문자 %XX.
/// "http://127.0.0.1:54321" -> "http%3A%2F%2F127.0.0.1%3A54321"
public enum URLEnc {
    public static func encode(_ s: String) -> String {
        let hex: [Unicode.Scalar] = Array("0123456789ABCDEF".unicodeScalars)
        var out = ""
        for b in s.utf8 {
            let unreserved = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) ||
                             (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E ||
                             b == 0x5F || b == 0x7E
            if unreserved {
                out.unicodeScalars.append(Unicode.Scalar(b))
            } else {
                out.unicodeScalars.append("%")
                out.unicodeScalars.append(hex[Int(b >> 4)])
                out.unicodeScalars.append(hex[Int(b & 0x0F)])
            }
        }
        return out
    }
}

/// 루프백 리스너(127.0.0.1:<포트>)가 받은 요청을 읽고, 브라우저에 돌려줄 바이트를 만든다.
/// 리스너의 흐름(마감, 연결당 5초, 남의 연결에 404)은 Net/Auth.swift 에 있다.
public enum LoopbackRequest {
    /// "GET /?code=abc&x=y HTTP/1.1" 의 질의 문자열에서 key 를 꺼낸다. 없으면 nil.
    ///
    /// Windows QueryParam 과 같은 규칙: 요청 대상은 첫 공백과 두 번째 공백 사이, 그 안의
    /// 첫 '?' 뒤가 질의 문자열, '&' 로 나눈 쌍 중 "key=" 로 **시작하는** 첫 쌍이 이긴다
    /// (그래서 "error_code=" 는 "error" 에 걸리지 않는다). 값은 URL 디코딩(+ -> 공백,
    /// %XX -> 바이트, 잘못된 % 는 그대로) 뒤 UTF-8 로 읽는다 (잘못된 바이트는 U+FFFD).
    /// "code=" 처럼 값이 비어 있으면 nil 이 아니라 "" 다.
    public static func queryParam(_ request: String, _ key: String) -> String? {
        let req = Array(request.utf8)
        guard let sp = req.firstIndex(of: 0x20) else { return nil }
        guard let sp2 = req[(sp + 1)...].firstIndex(of: 0x20) else { return nil }
        let target = Array(req[(sp + 1)..<sp2])
        guard let q = target.firstIndex(of: 0x3F) else { return nil }   // '?'
        let qs = Array(target[(q + 1)...])

        let want: [UInt8] = Array(key.utf8) + [0x3D]   // "key="
        var pos = 0
        while pos < qs.count {
            let amp = qs[pos...].firstIndex(of: 0x26) ?? qs.count   // '&'
            let pair = qs[pos..<amp]
            if pair.starts(with: want) {
                let raw = Array(pair.dropFirst(want.count))
                return String(decoding: urlDecode(raw), as: UTF8.self)
            }
            if amp >= qs.count { break }
            pos = amp + 1
        }
        return nil
    }

    /// 우리가 내준 주소는 http://127.0.0.1:<포트> 이고 브라우저는 거기에 "GET /?code=..."
    /// 로 온다. 그 모양이 아닌 요청(파비콘, 포트를 훑는 다른 프로세스)은 로그인의 결과가 아니다.
    public static func isOnPath(_ request: String) -> Bool {
        return request.utf8.starts(with: "GET /?".utf8)
    }

    /// 코드는 토큰 교환 요청의 JSON 에 그대로 끼워 넣는다. Supabase 가 주는 코드는 URL 안전
    /// 문자뿐이므로, 따옴표·역슬래시·제어문자가 든 값은 코드가 아니다 - 받아 주면 이 포트에
    /// 닿은 아무나 그 JSON 의 모양을 바꾼다.
    public static func isPlausibleCode(_ code: String) -> Bool {
        if code.isEmpty { return false }
        for b in code.utf8 where b < 0x20 || b == 0x22 || b == 0x5C {
            return false
        }
        return true
    }

    private static let pageHead =
        "<!doctype html><meta charset=utf-8><title>SmartScreen</title>" +
        "<body style=\"font-family:sans-serif;text-align:center;padding-top:80px\">"

    // 브라우저에 남길 화면. 여기서 창을 닫으라고 말해 주지 않으면 사용자는 로그인이
    // 끝났는지 알 수 없다. (교환 전에 보낸다 - Windows 와 같다.)
    // 돌아가는 길은 Mac 만 적는다 (Windows 는 "SmartScreen 으로 돌아가세요"). Windows 는 작업 표시줄이
    // 있지만, 이 앱은 Dock 에도 Cmd-Tab 에도 없고, macOS 14+ 는 브라우저를 쓰는 중인 사용자에게서
    // 우리 앱으로 초점을 넘기지 않는다 - 결과 상자가 브라우저 뒤에 있으면 돌아갈 곳이 안 보인다.
    // 결과 상자는 떠 있는 층으로 올리지만(Alerts), 그것도 안 보일 때 남는 길이 오버레이의 [설정] 이다.
    public static let successBody: String =
        pageHead + "<h2>로그인되었습니다</h2><p>이 탭을 닫으세요. "
        + "결과 창이 안 보이면 화면 오른쪽 위 작은 상자의 [설정] 을 누르세요.</p>"

    public static let failureBody: String =
        pageHead + "<h2>로그인하지 못했습니다</h2><p>SmartScreen 에서 다시 시도하세요.</p>"

    /// 결과 화면은 성공이든 실패든 늘 200 OK 다. Content-Length 는 본문의 UTF-8 바이트 수.
    public static func response200(body: String) -> Data {
        let b = Data(body.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
                   "Content-Length: \(b.count)\r\nConnection: close\r\n\r\n"
        var d = Data(head.utf8)
        d.append(b)
        return d
    }

    /// 남의 연결에는 빈 404 를 주어 매달려 있지 않게 한다 (브라우저의 /favicon.ico).
    public static let response404: Data =
        Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)

    // %XX 를 푼다. 인가 코드 자체는 URL 안전하지만 error_description 은 아니다.
    private static func urlDecode(_ s: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == 0x2B {   // '+'
                out.append(0x20)
                i += 1
                continue
            }
            if c == 0x25 && i + 2 < s.count,   // '%'
               let h = hexValue(s[i + 1]), let l = hexValue(s[i + 2]) {
                out.append((h << 4) | l)
                i += 3
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        if c >= 0x30 && c <= 0x39 { return c - 0x30 }
        if c >= 0x61 && c <= 0x66 { return c - 0x61 + 10 }
        if c >= 0x41 && c <= 0x46 { return c - 0x41 + 10 }
        return nil
    }
}
