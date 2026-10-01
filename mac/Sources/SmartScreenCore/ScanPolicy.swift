import Foundation

/// 거르지 않는 스캔(R)을 돌릴지 (AdvScanner). R 은 주변의 모든 광고를 받는다 - 필터 스캔(F)이 잠긴 폰을
/// 주는지 몰라서 같이 돌렸는데, 1.1.9 실기에서 F 가 잠긴 폰을 주는 것이 확인됐다 (`locked adverts via
/// filter`). 그래서 이 Mac 에 폰 앱이 GATT 로 붙어 있는 동안은 끈다: 그때 RSSI 는 1초마다 연결로 오고,
/// 광고는 묶인 폰을 지키는 데만 쓴다.
///
/// 규칙 (감시 중이고 토큰이 있을 때): GattServer 가 10초 넘게 줄곧 건강하면(구독 중이고 보고가 제때 온다)
/// 끄고, 건강하지 않으면 바로 켠다. 재보기 중에는 늘 켠다 - 광고 기준은 평소 광고 경로가 도는 조건(R 이
/// 켜진 채)에서 재야 한다. 10초를 기다리는 이유: 막 붙은 연결은 몇 초 안에 끊겼다 다시 붙기도 한다
/// (실기에서 끊겼다 다시 붙기 1초) - 그때마다 R 을 껐다 켜면 R 에서만 본 후보와 탐색을 버린다.
public struct RawScanPolicy {

    /// 지금 R 이 그 상태인 까닭. 줄 글자가 이것으로 정해진다.
    public enum Reason: Equatable {
        case measuring      // 켬: 재보기 중
        case gattNotLinked  // 켬: GATT 가 (10초 넘게) 건강하지 않다
        case gattLinked     // 끔: GATT 가 10초 넘게 건강하다
    }

    public static let linkedForMs: UInt64 = 10_000

    /// GATT 가 건강해진 뒤 처음 본 시각 (0 = 지금 건강하지 않다, 또는 아직 못 봤다)
    public private(set) var healthySince: UInt64 = 0
    public private(set) var measuring = false
    /// 마지막으로 남긴(또는 START 줄이 말한) 까닭. nil = 아직 아무것도
    public private(set) var logged: Reason?

    public init() {}

    /// 감시를 (다시) 시작할 때, 토큰이 바뀔 때. 그동안 GATT 를 보지 않았으므로 건강한 시간은 처음부터 센다.
    /// 재보기 중인지는 감시와 상관없이 창이 정하므로 그대로 둔다.
    public mutating func restart() {
        healthySince = 0
        logged = nil
    }

    public mutating func setMeasuring(_ on: Bool) {
        measuring = on
    }

    /// GattServer 의 건강 상태를 본다 (프로버 틱마다, 2초).
    public mutating func observeGatt(healthy: Bool, now: UInt64) {
        if healthy {
            if healthySince == 0 { healthySince = now }
        } else {
            healthySince = 0
        }
    }

    public func reason(now: UInt64) -> Reason {
        if measuring { return .measuring }
        if healthySince != 0 && now > healthySince && now - healthySince >= RawScanPolicy.linkedForMs {
            return .gattLinked
        }
        return .gattNotLinked
    }

    public func wantsRaw(now: UInt64) -> Bool {
        return reason(now: now) != .gattLinked
    }

    /// START 줄이나 토큰 줄이 지금 상태를 이미 말했다 (그 줄의 raw=on|off).
    public mutating func markLogged(now: UInt64) {
        logged = reason(now: now)
    }

    /// 까닭이 바뀌었으면 남길 줄, 아니면 nil. 켜짐/꺼짐이 그대로여도 까닭이 바뀌면 남긴다 - 로그의 마지막
    /// "scan: raw=..." 줄이 언제나 지금 상태와 그 까닭을 말하게.
    public mutating func changedLine(now: UInt64) -> String? {
        let r = reason(now: now)
        if logged == r { return nil }
        logged = r
        return RawScanPolicy.line(r)
    }

    public static func line(_ r: Reason) -> String {
        switch r {
        case .measuring: return "scan: raw=on (measuring)"
        case .gattNotLinked: return "scan: raw=on (GATT not linked)"
        case .gattLinked: return "scan: raw=off (GATT linked)"
        }
    }
}

/// 필터 스캔(F)이 멎었는지 보고 다시 걸지 정한다 (AdvScanner).
///
/// 폰이 가까이 있는 것이 분명한데 (GATT 가 건강하다, 또는 R 이 10초 안에 묶인 폰을 줬다) F 가 30초 넘게
/// 묶인 폰을 (묶이지 않았으면 신원 후보 아무것도) 주지 않으면, F 의 스캔을 멈췄다 같은 옵션으로 다시 건다.
/// 잠긴 폰의 광고 간격은 20초까지 벌어지므로 30초 동안 하나도 없으면 F 쪽이 이상한 것이다. 다시 걸어도
/// 안 되는 경우가 있을 수 있으므로 120초에 한 번까지만 - 그동안 판정은 GATT 나 R 로 돈다.
public struct FilterScanWatch {
    public static let quietMs: UInt64 = 30_000
    public static let minGapMs: UInt64 = 120_000
    public static let rawNearMs: UInt64 = 10_000

    /// F 를 (다시) 건 시각. 그 전의 공백은 세지 않는다
    public private(set) var startTick: UInt64 = 0
    /// F 가 신원 후보(필터가 맞춘 기기)를 마지막으로 준 시각
    public private(set) var anyTick: UInt64 = 0
    /// F 가 묶인 폰을 마지막으로 준 시각. 새로 묶으면 그 순간부터 센다
    public private(set) var boundTick: UInt64 = 0
    /// R 이 묶인 폰을 마지막으로 준 시각 (묶음이 바뀌면 0)
    public private(set) var rawBoundTick: UInt64 = 0
    /// 마지막으로 다시 건 시각 (0 = 이번 감시에 없음)
    public private(set) var lastRestart: UInt64 = 0

    public init() {}

    /// 감시 시작
    public mutating func reset() {
        self = FilterScanWatch()
    }

    /// F 에 스캔을 걸었다 (감시 시작, 블루투스가 켜짐, 등록 스캔이 끝남...).
    public mutating func scanStarted(now: UInt64) {
        startTick = now
    }

    /// F 가 광고 하나를 줬다. boundPhone = 그것이 묶인 폰이다.
    public mutating func filterDelivered(now: UInt64, boundPhone: Bool) {
        anyTick = now
        if boundPhone { boundTick = now }
    }

    /// R 이 묶인 폰의 광고를 줬다.
    public mutating func rawDeliveredBound(now: UInt64) {
        rawBoundTick = now
    }

    /// 묶음이 바뀌었다 (새로 묶음, 풀림). 새 폰에 대해 F 를 기다리는 시간은 지금부터 센다.
    public mutating func bindingChanged(now: UInt64) {
        boundTick = now
        rawBoundTick = 0
    }

    /// F 가 (묶인 폰을 / 아무 후보도) 주지 않은 시간.
    public func filterQuietMs(now: UInt64, bound: Bool) -> UInt64 {
        let ref = max(startTick, bound ? boundTick : anyTick)
        return now > ref ? now - ref : 0
    }

    /// 폰이 가까이 있는 것이 분명한지: GATT 가 건강하거나, 묶여 있고 R 이 10초 안에 그 폰을 줬다.
    public func phoneEvidentlyNear(now: UInt64, bound: Bool, gattHealthy: Bool) -> Bool {
        if gattHealthy { return true }
        guard bound, rawBoundTick != 0 else { return false }
        let age = now > rawBoundTick ? now - rawBoundTick : 0
        return age <= FilterScanWatch.rawNearMs
    }

    /// 지금 F 를 다시 걸지. true 면 다시 건 것으로 기억한다 (부르는 쪽이 실제로 다시 건다).
    public mutating func shouldRestart(now: UInt64, bound: Bool, gattHealthy: Bool) -> Bool {
        guard phoneEvidentlyNear(now: now, bound: bound, gattHealthy: gattHealthy) else { return false }
        guard filterQuietMs(now: now, bound: bound) >= FilterScanWatch.quietMs else { return false }
        if lastRestart != 0 && !(now > lastRestart && now - lastRestart >= FilterScanWatch.minGapMs) {
            return false
        }
        lastRestart = now
        startTick = now
        return true
    }
}
