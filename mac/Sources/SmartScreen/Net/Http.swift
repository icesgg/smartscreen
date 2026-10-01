import Foundation
import Darwin

// 앱의 HTTP 는 전부 이것 하나로 간다 (Windows auth.cpp 의 SupabaseHttp, supabase.cpp 의
// DownloadToFile). 로그인, 세션 갱신, 폰 토큰, 기업 콘텐츠, 클립보드가 같은 규칙을 쓴다.
//
// 동기 호출이다 - 일꾼 스레드에서 부를 것 (메인에서 부르면 그동안 화면이 멎는다).
// Windows 처럼 부를 때마다 세션을 새로 열고 닫는다: 호출 사이에 나눠 갖는 상태(쿠키,
// 캐시, 연결)가 없으므로 한 호출의 결과가 다른 호출에 섞일 길이 없다.
//
// 캐시는 반드시 끈다. 켜 두면 Storage 가 준 Cache-Control 을 따라 contents 목록이나
// 기기마다 같은 경로에 덮어쓰는 클립보드 그림이 예전 것으로 돌아온다 - 같은 기기의
// 다음 캡처가 계속 첫 그림으로 붙는다 (spec clipsync §Mac mapping).

/// ok == true 는 응답 본문을 끝까지 받았다는 뜻이다 (4xx/5xx 여도 true - 그건 status 로 본다).
/// 헤더는 왔는데 본문을 읽다가 끊기면 ok = false, body 는 비고 status 는 남는다
/// ("false 인데 status 가 0 이 아니다" = 닿기는 했는데 본문을 못 받았다).
struct HttpResponse {
    let ok: Bool
    let status: Int
    let body: Data
}

enum Http {
    /// Windows WinHttpOpen 의 에이전트 이름과 같다 (서버는 보지 않지만 로그에서 같게 보이게).
    private static let userAgent = "SmartScreen/1.0"

    /// Synchronous (call off main). ok = body received completely (4xx/5xx still ok=true).
    /// maxBodyBytes 0 = unlimited; exceeding -> ok=false, body empty. User-Agent "SmartScreen/1.0",
    /// no caches/cookies. timeout = request timeout seconds.
    ///
    /// timeout 은 Windows 의 수신 제한(15 s)처럼 "바이트가 오지 않고 지나도 되는 시간" 이다
    /// (URLSession 의 timeoutIntervalForRequest). 전체 상한은 따로 둔다 - Windows 는 덩이마다의
    /// 제한뿐이지만, 한 바이트씩 흘려 보내는 상대가 클립보드 일꾼을 붙잡지 못하게 한다.
    /// 예전에는 부르는 쪽이 로그인 한 번이라 제한이 필요 없었는데, 지금은 클립보드 일꾼이
    /// 이걸 계속 부르고 종료할 때 그 스레드를 기다린다.
    static func request(_ method: String, _ url: String, headers: [String: String], body: Data? = nil,
                        maxBodyBytes: Int = 0, timeout: TimeInterval = 15) -> HttpResponse {
        let idle = timeout > 0 ? timeout : 15
        let total = max(120, idle * 8)
        guard let req = makeRequest(method, url, headers: headers, body: body, timeout: idle) else {
            // Windows: WinHttpCrackUrl 이 실패하면 상태 0 으로 false.
            return HttpResponse(ok: false, status: 0, body: Data())
        }

        let sink = MemorySink(maxBytes: maxBodyBytes)
        let session = makeSession(idle: idle, total: total, delegate: sink)
        let task = session.dataTask(with: req)
        task.resume()
        // 남은 작업이 끝나면 세션이 스스로 무효가 되고 delegate 를 놓는다.
        session.finishTasksAndInvalidate()
        waitDone(sink.done, task: task, limit: total + 30)

        // 본문을 끝까지 받았을 때만 성공이다. 예전 Windows 루프는 읽기가 실패해서 끝난 것
        // (수신 시간 제한, 연결 리셋)과 본문 끝을 가리지 않았고, 그래서 도중에 끊긴 200
        // 응답의 잘린 본문이 온전한 것처럼 쓰일 수 있었다 - 클립보드 텍스트가 잘린 채 붙고,
        // 기준점은 이미 넘어가 있어 다시 받지도 않는다 (2026-09-30 검토).
        // 잘린 본문은 내주지 않는다. status 는 그대로 둔다.
        let complete = sink.error == nil && !sink.overflow
        return HttpResponse(ok: complete, status: sink.status, body: complete ? sink.body : Data())
    }

    /// Streamed download to `to` (overwritten). result 1 ok, 0 permanent failure, -1 transient.
    ///
    ///   1  = 2xx 이고 본문을 끝까지 받아 `to` 에 썼다
    ///   0  = 서버가 줄 수 없다고 답했거나 (4xx, 408/429 제외) 본문이 maxBytes 를 넘었거나
    ///        디스크에 못 썼다 - 다시 물어도 같을 실패
    ///  -1  = 서버에 닿지 못했거나 도중에 끊겼다 (5xx, 408, 429, 그 밖의 2xx 아닌 답 포함)
    ///        - 나중에는 될 실패
    ///
    /// 1 이 아니면 `to` 에 아무것도 남기지 않는다. 예전 Windows 는 상태 코드를 보지 않아서
    /// 404 의 JSON 오류 본문이 콘텐츠 파일이 됐고, 읽기가 도중에 끊겨도 잘린 파일을 제자리로
    /// 옮겼다. maxBytes <= 0 은 상한 없음.
    ///
    /// 영상은 수십 MB 라 메모리에 모으지 않고 받는 대로 파일에 쓴다. timeout 은 덩이 사이의
    /// 제한이라 큰 영상도 30 초면 넉넉하다 (Windows 와 같은 값). 전체 상한은 200 MB 가 느린
    /// 회선에서도 끝날 만큼 길게 둔다.
    static func download(_ url: String, headers: [String: String], to: URL, maxBytes: Int64,
                         timeout: TimeInterval = 30) -> (result: Int, status: Int) {
        let idle = timeout > 0 ? timeout : 30
        let total: TimeInterval = 3600
        guard let req = makeRequest("GET", url, headers: headers, body: nil, timeout: idle) else {
            return (-1, 0)
        }

        let sink = FileSink(dest: to, maxBytes: maxBytes)
        let session = makeSession(idle: idle, total: total, delegate: sink)
        let task = session.dataTask(with: req)
        task.resume()
        session.finishTasksAndInvalidate()
        waitDone(sink.done, task: task, limit: total + 30)

        let result = sink.finish()
        if result != 1 {
            _ = unlink(to.path)
        }
        return (result, sink.status)
    }

    // ---- private ----

    private static func makeRequest(_ method: String, _ url: String, headers: [String: String],
                                    body: Data?, timeout: TimeInterval) -> URLRequest? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", u.host != nil else { return nil }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        // 기본 에이전트를 먼저 두고 부르는 쪽의 머리글을 얹는다 (업데이트 내려받기는
        // "SmartScreen/<버전>" 을 싣는다 - spec update §2).
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let b = body, !b.isEmpty {
            req.httpBody = b
        }
        return req
    }

    private static func makeSession(idle: TimeInterval, total: TimeInterval,
                                    delegate: URLSessionDelegate) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCredentialStorage = nil
        cfg.timeoutIntervalForRequest = idle
        cfg.timeoutIntervalForResource = total
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    /// URLSession 은 전체 상한(timeoutIntervalForResource)이 지나면 반드시 끝을 알린다.
    /// 그래도 영영 매달리지 않게 한 겹 더: 그보다 오래 걸리면 취소하고, 취소의 끝을 기다린다.
    private static func waitDone(_ done: DispatchSemaphore, task: URLSessionTask, limit: TimeInterval) {
        let seconds: Double = max(1, limit)
        if done.wait(timeout: DispatchTime.now() + seconds) == .timedOut {
            task.cancel()
            done.wait()
        }
    }
}

extension Http {
    /// 본문을 메모리에 모은다 (SupabaseHttp). delegate 콜백은 세션의 직렬 큐에서 오고,
    /// 부르는 스레드는 done 을 기다린 뒤에만 값을 읽는다.
    private final class MemorySink: NSObject, URLSessionDataDelegate {
        let maxBytes: Int
        let done = DispatchSemaphore(value: 0)
        var status = 0
        var body = Data()
        var overflow = false
        var error: Error?

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
            super.init()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if overflow { return }
            if status == 0, let h = dataTask.response as? HTTPURLResponse {
                status = h.statusCode
            }
            // 상한은 부르는 쪽이 정한다 (0 = 없음). 넘는 순간 그만 읽는다 - 서버가 주는 대로
            // 메모리에 다 쌓지 않는다.
            if maxBytes > 0 && body.count + data.count > maxBytes {
                overflow = true
                body = Data()
                dataTask.cancel()
                return
            }
            body.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let h = task.response as? HTTPURLResponse {
                status = h.statusCode
            }
            self.error = error
            done.signal()
        }
    }

    /// 본문을 파일로 흘려 쓴다 (Windows DownloadToFile). 2xx 가 아니면 본문을 읽지 않고 끊는다.
    private final class FileSink: NSObject, URLSessionDataDelegate {
        let dest: URL
        let maxBytes: Int64
        let done = DispatchSemaphore(value: 0)
        var status = 0
        var error: Error?
        private var decided = false      // 첫 덩이에서 상태 코드를 보고 받을지 정했다
        private var handle: FileHandle?
        private var openFailed = false   // 임시 파일을 못 만든다. 네트워크 탓이 아니다
        private var giveUp = false       // 너무 길다 / 디스크에 못 썼다
        private var total: Int64 = 0

        init(dest: URL, maxBytes: Int64) {
            self.dest = dest
            self.maxBytes = maxBytes
            super.init()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if openFailed || giveUp { return }
            if !decided {
                decided = true
                if let h = dataTask.response as? HTTPURLResponse { status = h.statusCode }
                if status < 200 || status >= 300 {
                    // 오류 본문은 받을 필요가 없다. 상태 코드만으로 나눈다.
                    dataTask.cancel()
                    return
                }
                guard let h = openDest() else {
                    openFailed = true
                    dataTask.cancel()
                    return
                }
                handle = h
            }
            guard let h = handle else { return }
            total += Int64(data.count)
            // 행이 말한 크기보다 길면 어차피 다른 파일이다. 끝까지 받지 않는다.
            if maxBytes > 0 && total > maxBytes {
                giveUp = true
                dataTask.cancel()
                return
            }
            do {
                try h.write(contentsOf: data)
            } catch {
                giveUp = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let h = task.response as? HTTPURLResponse {
                status = h.statusCode
            }
            self.error = error
            done.signal()
        }

        /// done 이 신호된 뒤 부르는 스레드에서 한 번 부른다. 파일을 닫고 결과를 나눈다.
        func finish() -> Int {
            if status >= 200 && status < 300 {
                if openFailed { return 0 }
                let complete = error == nil && !giveUp
                if handle == nil && complete {
                    // 2xx 인데 본문이 비었다 - 덩이가 한 번도 오지 않았다. Windows 처럼 빈 파일을
                    // 만들어 둔다 (크기 검증이 걸러 낸다).
                    guard let h = openDest() else { return 0 }
                    handle = h
                }
                var closeFailed = false
                if let h = handle {
                    do { try h.close() } catch { closeFailed = true }
                    handle = nil
                }
                if giveUp || closeFailed { return 0 }
                return complete ? 1 : -1      // 도중에 끊겼다
            }
            // "그런 파일 없다 / 못 준다" 는 답을 받았다. 408, 429 는 나중에 될 수 있다.
            if status >= 400 && status < 500 && status != 408 && status != 429 { return 0 }
            return -1
        }

        private func openDest() -> FileHandle? {
            let fd = open(dest.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            if fd < 0 { return nil }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }
}
