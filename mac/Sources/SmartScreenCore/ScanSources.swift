import Foundation

/// 한 기기를 어느 스캔이 마지막으로 언제 줬는지 (AdvScanner). events.log 의 "via ..." 글자를 만든다.
///
/// 첫 판은 후보가 생긴 뒤 한 번이라도 그 기기를 준 스캔을 전부 적었다 (깃발을 세우기만 하고 내리지
/// 않았다). 그러면 앱이 화면에 떠 있을 때 필터가 준 기기를 잠근 뒤에 묶어도 "via filter" 가 되어,
/// 필터가 잠긴 폰을 한 번도 주지 않았는데 필터 경로가 된다고 읽힌다. 그래서 시각을 적고, 글자는
/// 최근에 준 스캔만으로 만든다.
public struct ScanSourceTimes: Equatable {

    /// 기기를 준 길 하나. 글자 순서도 이 순서다.
    public enum Source: Int, Comparable, CaseIterable {
        case filter    // 필터 스캔(F)
        case rawBit    // 거르지 않은 스캔(R)의 비트 하나짜리 overflow 광고
        case rawList   // R 광고의 서비스 UUID 목록(일반/overflow)에 신원 UUID

        public static func < (a: Source, b: Source) -> Bool { return a.rawValue < b.rawValue }
    }

    /// "via" 글자가 볼 최근의 폭 (ms). 묶기 직전 10초 안에 준 스캔만 적는다.
    public static let recentMs: UInt64 = 10_000

    // 마지막으로 준 시각 (Mono ms, 0 = 한 번도 없음)
    public var filter: UInt64 = 0
    public var rawBit: UInt64 = 0
    public var rawList: UInt64 = 0
    /// 일반 서비스 목록에 신원 UUID 가 실린 광고(= 앱이 화면에 떠 있음)를 마지막으로 본 시각, 어느 쪽이든
    public var plain: UInt64 = 0
    /// 마지막으로 읽은 비트 (-1 = 없음)
    public var bit = -1

    public init() {}

    /// 광고 하나를 적는다. listed 는 R 광고의 UUID 목록에 신원 UUID 가 있었는지 (F 에서는 보지 않는다 -
    /// F 가 준 것 자체가 필터 길이다). plain 은 일반 목록에 있었는지.
    public mutating func note(fromRaw: Bool, bit: Int, listed: Bool, plain: Bool, now: UInt64) {
        if fromRaw {
            if bit >= 0 {
                rawBit = now
                self.bit = bit
            }
            if listed { rawList = now }
        } else {
            filter = now
        }
        if plain { self.plain = now }
    }

    public func time(_ s: Source) -> UInt64 {
        switch s {
        case .filter: return filter
        case .rawBit: return rawBit
        case .rawList: return rawList
        }
    }

    /// now 에서 windowMs 안에 준 길. 시각이 now 보다 뒤면 (다른 스레드가 잰 시각) 0 ms 로 본다.
    public func recent(now: UInt64, windowMs: UInt64) -> Set<Source> {
        var out = Set<Source>()
        for s in Source.allCases where ScanSourceTimes.within(time(s), now: now, windowMs) {
            out.insert(s)
        }
        return out
    }

    /// "filter + raw bit 31" 모양 (Source 순서). 비트를 모르면 "raw bit ?".
    public static func text(_ s: Set<Source>, bit: Int) -> String {
        return s.sorted().map { src -> String in
            switch src {
            case .filter: return "filter"
            case .rawBit: return "raw bit " + (bit >= 0 ? String(bit) : "?")
            case .rawList: return "raw list"
            }
        }.joined(separator: " + ")
    }

    /// bound 줄의 "via ..." 글자: now 직전 recentMs 안에 이 기기를 준 스캔, 그동안 앱이 화면에 떠 있던
    /// 광고도 봤으면 ", app on screen". 아무 스캔도 그 안에 주지 않았으면 (잠긴 폰의 광고 간격은 20초까지
    /// 벌어진다) 가장 최근에 준 스캔을 그때 기준으로 적고 몇 초 전인지 붙인다. 한 번도 없으면 "".
    public func viaText(now: UInt64, windowMs: UInt64 = ScanSourceTimes.recentMs) -> String {
        var ref = now
        var srcs = recent(now: now, windowMs: windowMs)
        var stale = ""
        if srcs.isEmpty {
            let newest = max(filter, rawBit, rawList)
            if newest == 0 { return "" }
            ref = newest
            srcs = recent(now: newest, windowMs: windowMs)
            stale = ", last seen \(ScanSourceTimes.age(newest, now: now) / 1000)s ago"
        }
        var t = ScanSourceTimes.text(srcs, bit: bit)
        if ScanSourceTimes.within(plain, now: ref, windowMs) { t += ", app on screen" }
        return t + stale
    }

    static func age(_ t: UInt64, now: UInt64) -> UInt64 {
        return now > t ? now - t : 0
    }

    static func within(_ t: UInt64, now: UInt64, _ windowMs: UInt64) -> Bool {
        return t != 0 && age(t, now: now) <= windowMs
    }
}

/// 묶인 폰의 잠긴 광고(일반 서비스 목록에 신원 UUID 가 없는 것)를 어느 스캔이 주는지 - 처음 보일 때와
/// 그 묶음이 바뀔 때만 한 줄 (`ident: XXXX locked adverts via ...`).
///
/// bound 줄은 묶는 순간을 말할 뿐이다 (앱이 화면에 떠 있을 때 묶었을 수도 있다). 잠긴 폰을 실제로 어느
/// 길이 주는지는 이 줄이 말한다. 길은 최근 10초 안에 주면 들어오고, 60초 동안 주지 않아야 빠진다 -
/// 광고 간격이 들쭉날쭉해서 10초 창으로 넣고 빼면 2초 틱마다 줄이 바뀔 수 있다.
public struct LockedPathLog {
    public static let addWithinMs: UInt64 = 10_000
    public static let dropAfterMs: UInt64 = 60_000

    public private(set) var logged = Set<ScanSourceTimes.Source>()

    public init() {}

    /// 새로 묶었거나 결합이 풀렸을 때.
    public mutating func reset() {
        logged.removeAll()
    }

    /// 남길 "via" 글자, 남길 것이 없으면 nil. times 에는 잠긴 광고만 적혀 있어야 한다.
    /// 아무 길도 최근에 주지 않으면 (폰이 조용하거나 앱이 화면에 떠 있다) 줄을 남기지 않고 기억도 그대로다.
    public mutating func update(_ times: ScanSourceTimes, now: UInt64) -> String? {
        let add = times.recent(now: now, windowMs: LockedPathLog.addWithinMs)
        let keep = logged.intersection(times.recent(now: now, windowMs: LockedPathLog.dropAfterMs))
        let next = keep.union(add)
        if next.isEmpty || next == logged { return nil }
        logged = next
        return ScanSourceTimes.text(next, bit: times.bit)
    }
}
