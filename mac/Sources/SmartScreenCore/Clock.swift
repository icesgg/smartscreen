import Foundation
import Darwin

/// 단조 시계 (Windows GetTickCount64 자리).
///
/// CLOCK_MONOTONIC 을 쓴다 - macOS 에서는 잠자기 동안에도 센다. 저장해 두는 틱
/// (마지막 NEAR, 마지막 입력, 토큰 만료 기한...) 은 잠자기를 세야 한다: 자리를 비운 채
/// 잠들었다 깬 Mac 이 "방금 전까지 NEAR" 로 보이면 시간 초과, FAR, 강제 잠금이 모두
/// 늦어진다. DispatchTime / mach_absolute_time / ProcessInfo.systemUptime /
/// CLOCK_UPTIME_RAW 는 잠자기 동안 멈추므로 쓰지 않는다 (spec monitor §7).
public enum Mono {
    /// Milliseconds on CLOCK_MONOTONIC (counts system sleep, like GetTickCount64).
    /// Never returns 0 (0 is the "never" sentinel everywhere).
    public static func now() -> UInt64 {
        let ms = clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000
        // 0 은 어디서나 "한 번도 없음" 이다. 부팅 직후라도 그 값을 돌려주면 안 된다.
        return ms == 0 ? 1 : ms
    }
}

/// 지역 시각 문자열 (Windows GetLocalTime + "%02d:%02d:%02d").
/// events.log, 목록 줄, CSV, 차트, 잠금 기록이 같은 모양을 쓴다.
public enum LocalClock {
    /// "09:05:03"
    public static func hhmmss(_ d: Date = Date()) -> String {
        let t = parts(d)
        return "\(pad2(t.h)):\(pad2(t.m)):\(pad2(t.s))"
    }

    /// "09:05:03.042" (밀리초는 GetLocalTime 의 wMilliseconds 처럼 버림)
    public static func hhmmssmmm(_ d: Date = Date()) -> String {
        let t = parts(d)
        return "\(pad2(t.h)):\(pad2(t.m)):\(pad2(t.s)).\(pad3(t.ms))"
    }

    /// "09:05"
    public static func hhmm(_ d: Date) -> String {
        let t = parts(d)
        return "\(pad2(t.h)):\(pad2(t.m))"
    }

    private static func pad3(_ v: Int) -> String {
        if v >= 0 && v < 10 { return "00\(v)" }
        if v >= 0 && v < 100 { return "0\(v)" }
        return "\(v)"
    }

    /// 시, 분, 초, 밀리초. localtime_r 은 스레드에 안전하고 포매터 상태가 없다
    /// (여러 스레드가 로그를 쓴다).
    private static func parts(_ d: Date) -> (h: Int, m: Int, s: Int, ms: Int) {
        // 1 µs 를 더하고 버린다: 042 ms 가 부동소수점으로 0.04199999.. 가 되어 041 로
        // 찍히는 것을 막는다. 초와 밀리초를 같은 정수에서 나눠야 둘이 어긋나지 않는다.
        let totalMs = (d.timeIntervalSince1970 * 1000.0 + 0.001).rounded(.down)
        guard totalMs.isFinite, abs(totalMs) < 9.0e15 else { return (0, 0, 0, 0) }
        let all = Int64(totalMs)
        var secs = all / 1000
        var ms = all % 1000
        if ms < 0 { ms += 1000; secs -= 1 }
        var tt = time_t(secs)
        var tmv = tm()
        if localtime_r(&tt, &tmv) == nil { return (0, 0, 0, Int(ms)) }
        return (Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec), Int(ms))
    }
}

/// "%02d": 7 -> "07", 12 -> "12", -5 -> "-5" (C 와 같다).
/// String(format:) 에 Swift String 을 %s 로 넘기면 죽는다 - 숫자 두 자리는 이것으로 만든다.
public func pad2(_ v: Int) -> String {
    if v >= 0 && v < 10 { return "0\(v)" }
    return "\(v)"
}

/// Windows SetTimer 자리.
///
/// 언제나 RunLoop.main 의 .common 모드에 건다. 기본 모드에만 걸면 NSAlert.runModal(),
/// 메뉴 추적, 슬라이더 끌기 동안 멎는다 - Windows 의 MessageBox 는 메시지를 계속
/// 돌리므로 그동안에도 카운트다운과 잠금이 이어진다 (spec monitor §5 순서 제약 8).
public enum MainTimer {
    /// Repeating timer on RunLoop.main in .common mode. Must be called on the main thread.
    @discardableResult
    public static func every(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: seconds, repeats: true) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    /// One-shot timer on RunLoop.main in .common mode. Must be called on the main thread.
    @discardableResult
    public static func once(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: seconds, repeats: false) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
