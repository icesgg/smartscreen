import Foundation
import Darwin

/// 진단용 이벤트 로그 events.log (Windows DbgEvent).
///
/// 줄 모양은 "HH:MM:SS <message>" 하나뿐이다. 날짜는 없다 - 날짜 없이 계속 이어 붙고,
/// 읽는 사람과 도구는 시각이 아니라 세션 경계(`start: SmartScreen x.y.z`, `START thr=`)
/// 로 자른다. 회전(rotate)도 하지 않는다. 언제나 켜져 있다 (Windows g_debugEvents = true).
///
/// 광고 콜백, GATT 큐, 판정 스레드, UI 가 동시에 부른다. 한 프로세스 안에서는 잠금으로
/// 줄을 하나씩 쓰고, 부를 때마다 열고-붙이고-닫는다 (Windows 는 공유 모드로 열지 않으면
/// 동시 호출 시 한쪽의 _wfsopen 이 실패해 메시지가 조용히 사라졌다). O_APPEND 의 write
/// 한 번으로 한 줄을 쓰므로 다른 프로세스(--clip-test 등)와 겹쳐도 줄이 섞이지 않는다.
public enum EventLog {
    private static let lock = NSLock()

    /// Appends "HH:MM:SS <message>\n" to Paths.eventsLog. UTF-8 (BOM only when the file is created).
    /// Thread-safe (serial), opens/appends/closes per line, never throws, never crashes.
    /// Newlines/CR inside `message` are replaced by spaces (one event = one line).
    public static func write(_ message: String) {
        // 한 건 = 한 줄. 서버나 브라우저에서 온 글자에 줄바꿈이 섞이면 남이 로그에
        // 줄을 지어낼 수 있다 (부르는 쪽도 OneLine / CapErrorText 를 거치지만 여기서 한 번 더).
        var clean = String.UnicodeScalarView()
        let space: Unicode.Scalar = " "
        for u in message.unicodeScalars {
            clean.append((u == "\n" || u == "\r") ? space : u)
        }
        lock.lock()
        defer { lock.unlock() }
        // 시각은 잠금 안에서 잰다 - 줄 순서와 시각 순서가 어긋나지 않게.
        let line = LocalClock.hhmmss(Date()) + " " + String(clean) + "\n"
        appendLogLine(Paths.eventsLog.path, Array(line.utf8))
    }
}

/// 열고, 붙이고, 닫는다. 실패하면 그 줄은 조용히 사라진다 (Windows 와 같다 - 로그 때문에
/// 앱이 멎거나 죽으면 안 된다).
private func appendLogLine(_ path: String, _ bytes: [UInt8]) {
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    if fd < 0 { return }
    defer { _ = close(fd) }
    var out = bytes
    // 새 파일(빈 파일)이면 BOM 을 먼저 쓴다. Windows CRT 의 "a,ccs=UTF-8" 이 그렇게 해서
    // 지금 쓰이는 파일들이 EF BB BF 로 시작한다 - 같은 도구로 읽히게 맞춘다.
    if lseek(fd, 0, SEEK_END) == 0 {
        out = [0xEF, 0xBB, 0xBF] + bytes
    }
    var off = 0
    while off < out.count {
        let n: Int = out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base + off, raw.count - off)
        }
        if n > 0 {
            off += n
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            return
        }
    }
}
