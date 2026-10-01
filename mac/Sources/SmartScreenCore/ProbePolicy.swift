import Foundation

/// 확인 연결(신원 토큰 탐색)의 재시도 간격과 실패 줄 (AdvScanner). Windows client/ble_rssi.cpp 의
/// ProberLoop 와 같은 수, 같은 글자를 쓴다 - 두 판의 events.log 가 같은 줄을 남겨야 grep 하나로 본다.
public enum ProbePolicy {
    /// 못 붙은 것(Unreachable)의 첫 재시도. 실측에서 맞는 주소인데도 Unreachable 이 다섯 번 연달아
    /// 났고, 60초 간격일 때는 4분에 다섯 번밖에 시도하지 못했다 - 첫 몇 번은 빨리 다시 해 본다.
    public static let unreachableFirstMs: UInt64 = 15_000
    /// 연달아 못 붙으면 간격을 두 배씩 늘리되 여기서 멈춘다. Windows 노트북 로그에서 같은 후보가 18초마다
    /// Unreachable 을 27분 동안 냈다 - 그동안 연결 시도가 라디오를 차지하고 events.log 를 같은 줄로 덮었다.
    /// 2분이면 15분마다 바뀌는 주소 하나에 일곱 번은 더 해 볼 수 있다.
    public static let unreachableMaxMs: UInt64 = 120_000
    /// 붙었는데 남의 기기로 확인된 것 (서비스가 없다, 토큰이 다르다). 주소가 바뀌면 어차피 새 후보다.
    public static let notOursMs: UInt64 = 600_000
    /// 같은 주소의 연속 실패는 첫 줄 뒤로 이 수마다 한 번 요약한다.
    public static let summaryEvery = 10
    /// 이만큼 다시 탐색하지 않은 주소의 연속은 끝난 것으로 본다 (주소가 바뀌어 후보에서 빠졌다).
    public static let streakIdleMs: UInt64 = 300_000

    /// n 번째 연속 실패 뒤 다시 해 볼 때까지: min(15 * 2^(n-1), 120) 초. 15, 30, 60, 120, 120, ...
    public static func unreachableDelayMs(failures n: Int) -> UInt64 {
        if n <= 1 { return unreachableFirstMs }
        // 15 << 3 = 120 에서 이미 상한이다. 그 위로 밀지 않는다 (큰 n 에서 넘치지 않게).
        let shift = UInt64(min(n - 1, 4))
        return min(unreachableFirstMs << shift, unreachableMaxMs)
    }
}

/// 한 주소에 연달아 못 붙은 기록. Unreachable("probe failed") 만 센다 - 남의 폰 판정이나 묶임이 끝낸다.
public struct ProbeFailStreak: Equatable {
    public var count: Int
    /// 줄로 남긴 마지막 count (첫 실패 줄 = 1, 10번째마다의 요약 = 그 수)
    public var logged: Int
    /// 첫 실패의 지역 시각 "HH:MM:SS" (요약 줄의 since)
    public var since: String
    public var firstTick: UInt64
    /// 마지막 실패 = 그 주소를 마지막으로 탐색한 시각 (Mono ms)
    public var lastTick: UInt64
    public var lastWhy: String
    public var lastMs: UInt64

    public init(count: Int, logged: Int, since: String, firstTick: UInt64, lastTick: UInt64,
                lastWhy: String, lastMs: UInt64) {
        self.count = count
        self.logged = logged
        self.since = since
        self.firstTick = firstTick
        self.lastTick = lastTick
        self.lastWhy = lastWhy
        self.lastMs = lastMs
    }

    /// 끝날 때 요약할 것이 있는지: 줄로 남기지 않은 실패가 있고, 모두 둘 이상이다.
    /// (한 번뿐이면 첫 줄이 이미 다 말했다.)
    public var needsSummary: Bool {
        return count > 1 && count > logged
    }

    /// "probe failed x7 since 09:05:03 (last: Unreachable, 10012ms)". 앞에 "ident: <id> " 를 붙여 쓴다.
    public var summaryText: String {
        return "probe failed x\(count) since \(since) (last: \(lastWhy), \(lastMs)ms)"
    }
}

/// 주소마다의 연속 실패. 같은 주소의 실패를 하나하나 적지 않는다 - 노트북 로그에서 한 후보의
/// "probe failed" 가 27분 동안 줄줄이 이어져 다른 줄을 묻었다. 첫 실패는 지금과 같은 줄로, 그 뒤는
/// 10번째마다와 연속이 끝날 때 "probe failed xN since HH:MM:SS (last: ...)" 한 줄로 남긴다.
/// 재시도 간격(ProbePolicy.unreachableDelayMs)도 이 횟수로 정한다.
public struct ProbeFailStreaks<ID: Hashable> {

    /// fail 이 남기라고 하는 줄.
    public enum Line: Equatable {
        case first      // 지금과 같은 "probe failed (<why>, <ms>ms)"
        case summary    // summaryText (10번째마다)
        case silent     // 남기지 않는다 (2..9, 11..19 번째 ...)
    }

    /// 끝난 연속 중 요약할 것.
    public struct Ended {
        public let id: ID
        public let streak: ProbeFailStreak
    }

    public private(set) var streaks: [ID: ProbeFailStreak] = [:]

    public init() {}

    public var isEmpty: Bool {
        return streaks.isEmpty
    }

    /// 지금 연속의 실패 횟수 (없으면 0).
    public func failures(_ id: ID) -> Int {
        return streaks[id]?.count ?? 0
    }

    /// 실패 하나. 몇 번째 연속 실패인지(재시도 간격용)와 남길 줄을 돌려준다.
    /// why 는 줄에 쓰는 글자 그대로 (빈 사유는 부르는 쪽이 "token mismatch" 로 바꿔서 준다).
    /// wallClock 은 지금의 "HH:MM:SS" - 연속의 첫 실패일 때만 쓴다.
    public mutating func fail(_ id: ID, why: String, ms: UInt64, now: UInt64,
                              wallClock: String) -> (n: Int, line: Line) {
        var s = streaks[id] ?? ProbeFailStreak(count: 0, logged: 0, since: wallClock, firstTick: now,
                                               lastTick: now, lastWhy: why, lastMs: ms)
        s.count += 1
        s.lastTick = now
        s.lastWhy = why
        s.lastMs = ms
        var line = Line.silent
        if s.count == 1 {
            line = .first
            s.logged = 1
        } else if s.count % ProbePolicy.summaryEvery == 0 {
            line = .summary
            s.logged = s.count
        }
        streaks[id] = s
        return (s.count, line)
    }

    /// 그 주소의 연속이 끝났다 (묶었다, 남의 폰으로 확인됐다). 요약할 것이 있으면 그 연속.
    public mutating func end(_ id: ID) -> ProbeFailStreak? {
        guard let s = streaks.removeValue(forKey: id) else { return nil }
        return s.needsSummary ? s : nil
    }

    /// 모든 연속을 끝낸다 (감시 멈춤, 재시도 간격 되돌리기). 요약할 것들을 첫 실패 순으로.
    public mutating func endAll() -> [Ended] {
        let out = ProbeFailStreaks.summaries(streaks)
        streaks.removeAll()
        return out
    }

    /// streakIdleMs 동안 다시 탐색하지 않은 주소의 연속을 끝낸다. 요약할 것들을 첫 실패 순으로.
    public mutating func expire(now: UInt64) -> [Ended] {
        let idle = streaks.filter { now > $0.value.lastTick && now - $0.value.lastTick >= ProbePolicy.streakIdleMs }
        if idle.isEmpty { return [] }
        for k in idle.keys { streaks.removeValue(forKey: k) }
        return ProbeFailStreaks.summaries(idle)
    }

    private static func summaries(_ d: [ID: ProbeFailStreak]) -> [Ended] {
        return d.filter { $0.value.needsSummary }
            .map { Ended(id: $0.key, streak: $0.value) }
            .sorted { $0.streak.firstTick < $1.streak.firstTick }
    }
}

/// STATE 줄 꼬리: 상태가 바뀐 순간에 확인 연결이 돌고 있었는지, 막 끝났는지.
/// 연결 하나가 폰의 광고를 몇 초 멈추게 할 수 있어서, 그때 난 FAR 가 그 때문인지 로그에서 가려야 한다.
/// Windows BleRssiScanner::ProbeTagForLog 와 같은 글자 ("%.1f", 소수점은 언제나 '.').
public enum ProbeTag {
    /// 끝난 지 이만큼 안이면 ", probe ended 0.4s ago" (경계 포함)
    public static let endedWithinMs: UInt64 = 3_000

    /// runningSince: 진행 중인 탐색의 시작 (0 = 없음). endedAt: 마지막 탐색이 끝난 시각 (0 = 없음).
    /// 진행 중이면 ", probing for 1.3s", 끝난 지 3.0초 안이면 ", probe ended 0.4s ago", 아니면 "".
    public static func text(now: UInt64, runningSince: UInt64, endedAt: UInt64) -> String {
        if runningSince != 0 {
            return ", probing for \(seconds(age(runningSince, now)))s"
        }
        if endedAt != 0 {
            let a = age(endedAt, now)
            if a <= endedWithinMs { return ", probe ended \(seconds(a))s ago" }
        }
        return ""
    }

    /// ms 를 "%.1f" 초로. String(format:) 은 로캘 없이 쓰면 언제나 '.' 이다 (Windows swprintf 와 같다).
    public static func seconds(_ ms: UInt64) -> String {
        return String(format: "%.1f", Double(ms) / 1000.0)
    }

    // 다른 스레드가 잰 시각이 now 보다 뒤일 수 있다 - 그때는 0 (UInt64 뺄셈이 죽지 않게)
    private static func age(_ t: UInt64, _ now: UInt64) -> UInt64 {
        return now > t ? now - t : 0
    }
}
