import Foundation

/// 신원을 확인하러 붙어 볼 후보 하나 (AdvScanner 의 후보 표에서 고를 때 쓰는 값만).
public struct IdentCandidate<ID: Hashable> {
    public var id: ID
    /// 마지막 원시 RSSI (매끄럽게 하지 않은 것). 측정 불가는 -127.
    public var rssi: Int
    /// 신원 서비스 UUID 를 직접 봤다: 필터 스캔이 준 기기, 또는 필터 없는 스캔의 광고에서
    /// 서비스 UUID 목록(일반/overflow)에 그 UUID 가 있던 기기.
    public var sure: Bool
    /// 필터 없는 스캔이 제조사 데이터에서 읽은 overflow 비트 (-1 = 모름/하나가 아님)
    public var bit: Int

    public init(id: ID, rssi: Int, sure: Bool, bit: Int) {
        self.id = id
        self.rssi = rssi
        self.sure = sure
        self.bit = bit
    }
}

/// 후보 고르기 (client/ble_rssi.cpp ProberLoop 의 두 번 훑기).
///
/// 1차(pass 0) 는 맞을 가능성이 높은 것만 본다: 신원 UUID 를 직접 본 후보(sure), 그리고 배운 비트가
/// 있으면(learnedBit >= 0) 그 비트와 같은 후보. 1차에서 못 찾으면 2차(pass 1)에서 전체를 신호 순으로 -
/// 비트는 광고 UUID 가 바뀌면 같이 옮겨 가므로 배운 값만 믿으면 영영 못 찾을 수 있다.
/// (Windows 의 1차는 비트만 본다. Windows 에는 필터 경로가 없어 sure 가 없다.)
///
/// 두 번 모두: probeFloor 보다 약한 것(자리 판정에 쓸 수 없는 거리)과 재시도 금지 시각
/// (probedUntil > now)이 남은 것은 건너뛰고, 가장 센 것을 고른다. 같은 세기면 배열에서 앞의 것.
/// -127(측정 불가)은 고르지 않는다 (Windows 의 pickRssi 시작값 -127 과 엄격한 >).
public enum IdentCandidatePick {
    public struct Pick<ID: Hashable> {
        public let id: ID
        public let pass: Int
    }

    public static func pick<ID: Hashable>(_ cands: [IdentCandidate<ID>], learnedBit: Int, probeFloor: Int,
                                          probedUntil: [ID: UInt64], now: UInt64) -> Pick<ID>? {
        for pass in 0..<2 {
            var best: ID?
            var bestRssi = -127
            for c in cands {
                if pass == 0 && !(c.sure || (learnedBit >= 0 && c.bit == learnedBit)) { continue }
                if c.rssi < probeFloor { continue }
                if let until = probedUntil[c.id], until > now { continue }
                if c.rssi > bestRssi {
                    best = c.id
                    bestRssi = c.rssi
                }
            }
            if let b = best { return Pick(id: b, pass: pass) }
        }
        return nil
    }
}

/// 두 스캔 관리자가 같은 광고 패킷을 각각 알려 줄 때 한 번만 세게 한다.
///
/// Mac 은 광고 스캔을 둘 돌린다: 신원 서비스 UUID 로 거르는 것(F)과 거르지 않는 것(R). 등록된 폰의
/// 패킷 하나가 둘 다에 걸리면 같은 RSSI 가 두 번 들어온다. 판정의 "연속 2샘플" 규칙은 샘플 수를
/// 세므로, 그대로 두면 페이딩 한 번이 두 샘플이 되어 앉아 있는 사람 앞에서 화면이 꺼진다 -
/// 그 규칙이 막으려던 바로 그 일이다. 칼만 필터도 같은 값을 두 번 먹는다.
///
/// 규칙: 마지막으로 받은 샘플과 같은 쪽이면 받는다. 다른 쪽이면 마지막으로 받은 때부터 400 ms 가
/// 지났을 때만 받는다 (그 안이면 같은 패킷의 다른 쪽 사본으로 보고 버린다).
/// 400 ms 인 이유: 잠긴 아이폰의 광고 간격은 1초 남짓 이상이다 (Windows 실측 중앙값 1.7초,
/// p90 5.8초). 두 관리자가 같은 패킷을 알리는 시차는 그보다 훨씬 짧으므로, 400 ms 안의 다른 쪽
/// 샘플은 사본이고 400 ms 뒤의 것은 새 패킷이다. 앱이 화면에 떠 있어 광고가 빠를 때는 한 쪽 흐름이
/// 그대로 이어지고 (같은 쪽은 언제나 받는다), 그쪽이 400 ms 넘게 조용할 때만 다른 쪽으로 넘어간다.
/// 한쪽만 폰을 볼 때는 (필터가 잠긴 폰을 못 볼 때 등) 아무것도 버리지 않는다.
public struct DualSourceDedupe {
    public static let windowMs: UInt64 = 400

    private var hasLast = false
    private var lastSource = 0
    private var lastTick: UInt64 = 0

    public init() {}

    /// 이 샘플을 셀지. true 면 받은 것으로 기억한다.
    public mutating func accept(source: Int, now: UInt64) -> Bool {
        if hasLast && source != lastSource {
            // 다른 스레드가 잰 시각이 거꾸로 올 수 있다 - 그때는 0 ms 로 본다 (UInt64 뺄셈이 죽지 않게)
            let age = now > lastTick ? now - lastTick : 0
            if age < DualSourceDedupe.windowMs { return false }
        }
        hasLast = true
        lastSource = source
        lastTick = now
        return true
    }

    /// 스캔을 다시 시작할 때 (지난 세션의 마지막 샘플이 새 세션의 첫 샘플을 버리지 않게).
    public mutating func reset() {
        hasLast = false
        lastSource = 0
        lastTick = 0
    }
}
