import AppKit
import Darwin
import SmartScreenCore

// 구글 로그인 (Supabase Auth, OAuth PKCE + 루프백 리다이렉트). Windows client/enterprise/auth.cpp.
//
// 데스크톱 앱이 구글 로그인을 하는 방법은 사실상 하나뿐이다 (RFC 8252): 시스템 브라우저를
// 열고, 127.0.0.1 로 결과를 돌려받는다. 구글은 임베디드 웹뷰에서의 OAuth 를 거부하므로 앱
// 안에 로그인 화면을 그릴 수 없고, 시스템 브라우저는 앱에 값을 직접 건네지 못하므로 앱이
// 잠깐 로컬 서버가 된다.
//
// 암시적(implicit) 흐름이 아니라 PKCE 를 쓴다. 암시적 흐름은 토큰을 URL 프래그먼트
// (#access_token=...)로 주는데, 프래그먼트는 HTTP 요청에 실려 가지 않아서 루프백 리스너가
// 영영 볼 수 없다. PKCE 는 ?code= 로 오므로 읽을 수 있다.
//
// ASWebAuthenticationSession 은 쓰지 않는다: 사용자의 기본 브라우저가 아니라 앱 안의 Safari
// 시트를 띄우고, Windows 와 같은 루프백 결과 화면도 나오지 않는다 (spec §13).

enum Auth {
    /// Blocking: browser + loopback listener + PKCE exchange (spec enterprise-auth §4). Returns tokens or error text.
    /// 사용자가 브라우저에서 시간을 쓰므로 timeoutSec 은 넉넉해야 한다 (기본 3분).
    /// 부르는 쪽이 메인 스레드를 막지 않도록 일꾼 스레드에서 부를 것.
    static func signInWithGoogle(url: String, key: String, timeoutSec: Int = 180) -> (AuthTokens?, String) {
        if url.isEmpty || key.isEmpty {
            return (nil, "서버 주소나 키가 비어 있다")
        }

        guard let verifier = PKCE.makeVerifier(), !verifier.isEmpty else {
            return (nil, "PKCE 값을 만들지 못했다")
        }
        let challenge = PKCE.challenge(for: verifier)
        if challenge.isEmpty {
            return (nil, "PKCE 값을 만들지 못했다")
        }

        // 리스너는 이 함수가 돌아갈 때(성공, 실패, 시간 초과) 닫힌다.
        let listener = LoopbackListener()
        defer { listener.stop() }
        let port = listener.start()
        if port == 0 {
            return (nil, "127.0.0.1 에 리스너를 못 띄웠다")
        }

        // redirect_to 는 정확히 http://127.0.0.1:<포트> 여야 한다 (localhost 아님, 경로 없음,
        // 끝의 / 없음). Supabase 는 허용 목록에 없는 redirect_to 를 말없이 Site URL 로 바꾸는데,
        // 지금 허용 목록에 있는 루프백 꼴은 이것 하나다 (Windows 가 아무 포트나 쓰므로 포트는
        // 와일드카드). 다른 꼴이면 브라우저는 엉뚱한 쪽으로 가고 앱은 180 초 뒤에야 시간 초과를 말한다.
        let redirect = "http://127.0.0.1:\(port)"
        let authorize = url + "/auth/v1/authorize?provider=google"
            + "&redirect_to=" + URLEnc.encode(redirect)
            + "&code_challenge=" + URLEnc.encode(challenge)
            + "&code_challenge_method=s256"

        // 시스템 브라우저로 연다. 임베디드 웹뷰는 구글이 거부한다.
        if !openInBrowser(authorize) {
            return (nil, "브라우저를 열지 못했다")
        }

        let waitMs = UInt64(max(0, timeoutSec)) * 1000
        let got = listener.waitForCode(timeoutMs: waitMs)
        guard let code = got.code else {
            // err 는 이 포트에 닿은 누구든 넣을 수 있는 글이다. 서버 글과 같은 상한을 걸고,
            // 앱이 한 말로 읽히지 않게 어디서 온 글인지 앞에 붙인다 (알림 창에 그대로 뜬다).
            if got.err.isEmpty {
                return (nil, "로그인이 시간 안에 끝나지 않았다")
            }
            return (nil, "브라우저가 돌려준 오류: " + TextSanitize.capErrorText(got.err))
        }

        // 코드 -> 토큰. verifier 는 여기서 처음 밖으로 나간다.
        // code 를 이스케이프 없이 끼워 넣어도 되는 것은 리스너가 따옴표·역슬래시·제어문자가
        // 든 값을 코드로 받지 않기 때문이다 (LoopbackRequest.isPlausibleCode). verifier 는 base64url.
        let body = "{\"auth_code\":\"" + code + "\",\"code_verifier\":\"" + verifier + "\"}"
        let headers = [
            "apikey": key,
            "Content-Type": "application/json",
        ]
        let r = Http.request("POST", url + "/auth/v1/token?grant_type=pkce", headers: headers,
                             body: Data(body.utf8))
        if !r.ok {
            return (nil, "토큰 교환 요청이 실패했다")
        }
        if r.status < 200 || r.status >= 300 {
            return (nil, AuthParse.pickError(r.body, status: r.status))
        }
        guard let tokens = AuthParse.parseSession(r.body, nowUnix: nowUnix()) else {
            return (nil, "토큰 응답을 읽지 못했다")
        }
        return (tokens, "")
    }

    /// 저장해 둔 refresh 토큰으로 세션을 되살린다 (Windows RefreshSession).
    /// Supabase 는 갱신할 때마다 refresh 토큰을 새로 주고 예전 것을 무효로 만든다 -
    /// 새 값을 저장하는 것은 AccountSession 과 그 회전 콜백의 몫이다.
    static func refresh(url: String, key: String, refreshToken: String) -> (AuthTokens?, String) {
        if refreshToken.isEmpty {
            return (nil, "저장된 세션이 없다")
        }
        let body = "{\"refresh_token\":" + jsonQuoted(refreshToken) + "}"
        let headers = [
            "apikey": key,
            "Content-Type": "application/json",
        ]
        let r = Http.request("POST", url + "/auth/v1/token?grant_type=refresh_token", headers: headers,
                             body: Data(body.utf8))
        if !r.ok {
            return (nil, "갱신 요청이 실패했다")
        }
        if r.status < 200 || r.status >= 300 {
            return (nil, AuthParse.pickError(r.body, status: r.status))
        }
        guard let tokens = AuthParse.parseSession(r.body, nowUnix: nowUnix()) else {
            return (nil, "갱신 응답을 읽지 못했다")
        }
        return (tokens, "")
    }

    /// ("", "") = no phone yet; (token, "") ok; (nil, err) failure. Returns (String?, String).
    ///
    /// 로그인한 계정에 묶인 폰 토큰 (Windows FetchDeviceToken). 필터를 걸지 않는다 - RLS 가
    /// 자기 행만 돌려준다. PC 는 select 만 쓴다. 쓰기는 폰만 한다.
    /// 아직 폰에서 로그인한 적이 없으면 행이 없다 ("[]"). 그건 오류가 아니라 흔한 첫 순서
    /// (PC 먼저, 폰 나중)이고, 없는 것과 못 가져온 것은 사용자에게 다른 말을 해 줘야 한다.
    static func fetchDeviceToken(url: String, key: String, access: String) -> (String?, String) {
        if access.isEmpty {
            return (nil, "로그인하지 않았다")
        }
        let headers = [
            "apikey": key,
            "Authorization": "Bearer " + access,
        ]
        let r = Http.request("GET", url + "/rest/v1/device_tokens?select=token", headers: headers)
        if !r.ok {
            return (nil, "조회 요청이 실패했다")
        }
        if r.status < 200 || r.status >= 300 {
            return (nil, AuthParse.pickError(r.body, status: r.status))
        }
        // 2xx 의 PostgREST 답은 언제나 배열이다. 배열이 아니면 받을 토큰이 없는 것으로 본다.
        return (AuthParse.firstToken(r.body) ?? "", "")
    }

    // ---- private ----

    private static func nowUnix() -> Int64 {
        return Int64(time(nil))
    }

    /// 시스템 브라우저로 연다. NSWorkspace 는 메인 스레드에서 부른다 (로그인은 일꾼 스레드에서
    /// 돈다). 메인은 이때 모달 알림 안에 있어도 큐를 비운다 (.common 모드).
    private static func openInBrowser(_ s: String) -> Bool {
        guard let u = URL(string: s) else { return false }
        if Thread.isMainThread {
            return NSWorkspace.shared.open(u)
        }
        var opened = false
        DispatchQueue.main.sync {
            opened = NSWorkspace.shared.open(u)
        }
        return opened
    }

    /// JSON 문자열 리터럴. Windows 는 refresh 토큰을 그대로 끼워 넣는다 - 토큰은 따옴표도
    /// 역슬래시도 없는 글자라 결과 바이트는 같고, 혹시 섞여 있어도 JSON 이 깨지지 않는다.
    private static func jsonQuoted(_ s: String) -> String {
        let hex: [Character] = Array("0123456789abcdef")
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if u.value < 0x20 {
                    out += "\\u00"
                    out.append(hex[Int(u.value >> 4)])
                    out.append(hex[Int(u.value & 0x0F)])
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
        return out
    }
}

extension Auth {
    /// 루프백 리다이렉트 수신 (Windows LoopbackListener). BSD 소켓을 그대로 옮겼다.
    ///
    /// 이 포트는 같은 PC 의 누구나 닿을 수 있다. 그래서 첫 연결을 결과로 치지 않고, 마감까지
    /// 계속 받으면서 "GET /?" 에 code= 나 error= 를 실은 요청이 올 때만 돌아간다.
    private final class LoopbackListener {
        private var sock: Int32 = -1

        /// 연결 하나에 쓰는 시간. 브라우저는 붙자마자 요청 줄을 보내므로 넉넉하다.
        private static let connMs: UInt64 = 5000

        deinit {
            stop()
        }

        /// 127.0.0.1 의 빈 포트에 붙고 그 포트 번호를 돌려준다. 실패하면 0.
        /// 포트를 OS 가 고르게 두는 이유: 고정 포트는 이미 쓰이고 있을 수 있고, 그러면 로그인이
        /// "왜인지 안 되는" 상태가 된다.
        func start() -> UInt16 {
            stop()
            let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            if s < 0 { return 0 }
            sock = s
            // 업데이트 적용기 같은 자식 프로세스가 이 소켓을 물려받지 않게.
            _ = fcntl(s, F_SETFD, FD_CLOEXEC)

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0                                             // OS 가 빈 포트를 고른다
            addr.sin_addr = in_addr(s_addr: in_addr_t(0x7F00_0001).bigEndian)   // 127.0.0.1 만. 외부 노출 금지
            let bound = withUnsafePointer(to: &addr) { (p: UnsafePointer<sockaddr_in>) -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { (sp: UnsafePointer<sockaddr>) -> Int32 in
                    bind(s, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound != 0 { stop(); return 0 }

            // 대기열이 1 이면 남의 연결 하나를 정리하는 동안 브라우저의 진짜 요청이 거절당한다.
            // 남의 연결을 넘기고 계속 받으므로 자리가 필요하다.
            if listen(s, 8) != 0 { stop(); return 0 }

            var got = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let rc = withUnsafeMutablePointer(to: &got) { (p: UnsafeMutablePointer<sockaddr_in>) -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { (sp: UnsafeMutablePointer<sockaddr>) -> Int32 in
                    getsockname(s, sp, &len)
                }
            }
            if rc != 0 { stop(); return 0 }
            let port = UInt16(bigEndian: got.sin_port)
            if port == 0 { stop(); return 0 }
            return port
        }

        /// 브라우저가 돌아올 때까지 기다렸다가 ?code= 를 꺼낸다. 사용자가 취소하면 구글/Supabase 가
        /// ?error= 로 돌아오므로 그것도 받는다. 시간 안에 아무것도 안 오면 (nil, "").
        /// err 쪽 글은 남이 넣을 수 있는 값이다. 그대로 믿지 말 것. code 도 같다 - 남이 그럴듯한
        /// 가짜 코드를 먼저 보내면 그것이 돌아가고, 교환이 실패하면서 진짜 요청은 놓친다.
        func waitForCode(timeoutMs: UInt64) -> (code: String?, err: String) {
            if sock < 0 { return (nil, "") }

            // 예전 Windows 는 select 한 번, accept 한 번이었다. 그래서 이 포트에 먼저 닿은 연결이
            // 무엇이든(포트를 훑는 다른 프로세스, 파비콘 요청) 그것이 로그인의 결과가 됐고, 붙기만
            // 하고 아무것도 안 보내는 연결은 시간 제한 없는 recv 에서 로그인 스레드를 붙잡았다 -
            // 그 동안 로그인 단추가 죽고 받아 둔 업데이트도 적용되지 않는다 (2026-09-30 검토).
            //
            // 리스너는 논블로킹으로 둔다. poll 이 "연결이 왔다" 고 한 뒤 accept 하기 전에 상대가
            // 끊고 가면 대기열이 비는데, 블로킹 accept 는 거기서 마감 없이 다음 연결을 기다린다.
            let fl = fcntl(sock, F_GETFL)
            if fl >= 0 { _ = fcntl(sock, F_SETFL, fl | O_NONBLOCK) }

            let deadline = Mono.now() &+ timeoutMs
            while true {
                if Mono.now() >= deadline { return (nil, "") }
                if !LoopbackListener.waitReadable(sock, until: deadline) { return (nil, "") }

                let c = accept(sock, nil, nil)
                if c < 0 {
                    let e = errno
                    // 붙었다가 가 버린 연결 (Windows WSAEWOULDBLOCK / WSAECONNRESET)
                    if e == EAGAIN || e == EWOULDBLOCK || e == ECONNABORTED || e == EINTR { continue }
                    return (nil, "")
                }
                LoopbackListener.prepareAccepted(c)

                let req = LoopbackListener.readRequestLine(c, deadline: deadline)

                // 우리가 내준 주소는 http://127.0.0.1:<포트> 이고 브라우저는 거기에 "GET /?code=..."
                // 로 온다. 그 모양이 아니거나 code 도 error 도 없는 요청은 로그인의 결과가 아니다.
                //
                // 주소에 난수 경로를 붙여 남이 error= 조차 못 넣게 하는 방법은 쓰지 않았다.
                // Supabase 는 허용 목록에 없는 redirect_to 를 말없이 Site URL 로 바꾸는데, 경로가
                // 붙은 주소가 지금의 허용 목록에 맞는지 여기서는 확인할 길이 없다.
                //
                // 그래서 남은 것이 둘이다 (2026-09-30 검토, 닫지 못함). 이 포트에 닿은 쪽이
                // "GET /?error_description=..." 을 보내면 로그인이 그 글과 함께 바로 끝나고, 그럴듯한
                // 가짜 "GET /?code=..." 를 보내면 교환이 실패하면서 뒤에 오는 진짜 요청을 놓친다.
                // 둘 다 로그인을 망칠 뿐 성사시키지는 못한다 - 교환에는 이 프로세스만 아는 verifier 가 든다.
                let onPath = LoopbackRequest.isOnPath(req)
                var code: String? = nil
                if onPath, let c0 = LoopbackRequest.queryParam(req, "code"), LoopbackRequest.isPlausibleCode(c0) {
                    code = c0
                }
                var errText = ""
                if onPath && code == nil {
                    if let d = LoopbackRequest.queryParam(req, "error_description"), !d.isEmpty {
                        errText = d
                    } else if let e = LoopbackRequest.queryParam(req, "error"), !e.isEmpty {
                        errText = e
                    }
                }

                if code != nil || !errText.isEmpty {
                    // 브라우저에 남길 화면 (교환 전에 보낸다 - Windows 와 같다). 여기서 창을 닫으라고
                    // 말해 주지 않으면 사용자는 로그인이 끝났는지 알 수 없다.
                    let page = code != nil ? LoopbackRequest.successBody : LoopbackRequest.failureBody
                    LoopbackListener.sendAll(c, LoopbackRequest.response200(body: page))
                    LoopbackListener.finishConnection(c, sentSomething: true)
                    return (code, errText)
                }

                // 남의 연결이다. 요청을 보낸 쪽에는 빈 404 를 주어 매달려 있지 않게 하고
                // (브라우저의 /favicon.ico), 다음 연결을 기다린다.
                if !req.isEmpty {
                    LoopbackListener.sendAll(c, LoopbackRequest.response404)
                }
                LoopbackListener.finishConnection(c, sentSomething: !req.isEmpty)
            }
        }

        func stop() {
            if sock >= 0 {
                _ = close(sock)
                sock = -1
            }
        }

        // ---- private ----

        /// 받은 소켓은 macOS 에서 리스너의 O_NONBLOCK 을 물려받는다. 블로킹으로 되돌리고 (응답을
        /// 보내는 send 가 Windows 와 같게) 읽기와 쓰기에 시간 제한을 건다. SO_NOSIGPIPE 가 없으면
        /// 이미 닫힌 상대에게 send 하는 순간 SIGPIPE 로 프로세스가 끝난다.
        private static func prepareAccepted(_ c: Int32) {
            let fl = fcntl(c, F_GETFL)
            if fl >= 0 { _ = fcntl(c, F_SETFL, fl & ~O_NONBLOCK) }
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            _ = setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        /// 요청 줄만 있으면 된다. 헤더를 다 읽을 필요가 없다 (2048 바이트씩 길어야 8 번,
        /// 첫 "\r\n" 에서 멈춘다). 마감은 recv 마다가 아니라 연결 전체에 둔다 - 한 바이트씩 흘려
        /// 보내며 붙잡는 상대에게 recv 횟수만큼 시간을 내주지 않는다.
        private static func readRequestLine(_ c: Int32, deadline: UInt64) -> String {
            var req: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 2048)
            var connEnd = Mono.now() &+ connMs
            if connEnd > deadline { connEnd = deadline }
            for _ in 0..<8 {
                if Mono.now() >= connEnd || !waitReadable(c, until: connEnd) { break }
                let n: Int = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                    return recv(c, raw.baseAddress, raw.count, 0)
                }
                if n <= 0 { break }
                req.append(contentsOf: buf[0..<n])
                if containsCRLF(req) { break }
            }
            return String(decoding: req, as: UTF8.self)
        }

        private static func containsCRLF(_ b: [UInt8]) -> Bool {
            if b.count < 2 { return false }
            for i in 0..<(b.count - 1) where b[i] == 0x0D && b[i + 1] == 0x0A {
                return true
            }
            return false
        }

        /// 읽을 것이 생길 때까지 (Mono 기준) deadline 까지 기다린다. 리스너에서는 "들어온 연결이
        /// 있다", 받은 소켓에서는 "바이트가 왔거나 상대가 끊었다" 는 뜻이다.
        private static func waitReadable(_ fd: Int32, until deadline: UInt64) -> Bool {
            while true {
                let now = Mono.now()
                if now >= deadline { return false }
                let left = deadline - now
                let ms = Int32(min(left, UInt64(Int32.max)))
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let r = poll(&p, 1, ms)
                if r > 0 { return true }
                if r == 0 { return false }
                if errno == EINTR { continue }
                return false
            }
        }

        private static func sendAll(_ c: Int32, _ data: Data) {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < raw.count {
                    let n = send(c, base + off, raw.count - off, 0)
                    if n > 0 {
                        off += n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }

        /// 보낸 뒤 닫는다. 읽지 않은 요청 헤더가 남은 채 close 하면 BSD 는 RST 를 보내고, 브라우저가
        /// 아직 읽지 않은 응답까지 버릴 수 있다 ("연결이 재설정됨" 화면). 그래서 쓰기 쪽만 먼저 닫고
        /// (FIN), 남은 바이트를 잠깐(길어야 0.5 초) 읽어 버린 뒤 닫는다.
        private static func finishConnection(_ c: Int32, sentSomething: Bool) {
            if sentSomething {
                _ = shutdown(c, SHUT_WR)
                var buf = [UInt8](repeating: 0, count: 2048)
                let end = Mono.now() &+ 500
                for _ in 0..<16 {
                    if !waitReadable(c, until: end) { break }
                    let n: Int = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                        return recv(c, raw.baseAddress, raw.count, 0)
                    }
                    if n <= 0 { break }
                }
            }
            _ = shutdown(c, SHUT_RDWR)
            _ = close(c)
        }
    }
}
