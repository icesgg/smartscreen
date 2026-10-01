import Foundation

// 고급 창 콤보와 간단 창 단추가 고르는 값들 (Windows client/main.cpp 의 kIdleValues,
// kDelayValues, kSimpleIdle, kDistOffset, kDistFallbackBase).
//
// 한 값이 두 화면에 보이면, 바꾸는 쪽 화면이 다른 화면의 칸도 같이 바꿔야 하고 두 화면이
// 같은 선택지를 가져야 한다. 간단 창의 네 단추(simpleIdle)가 고르는 값은 전부 idleValues 에
// 있어야 한다. "바로"(0) 가 없던 동안, 간단 창에서 [바로] 를 골라도 다음 [시작] 이 콤보에서
// 가장 가까운 15초를 다시 읽어 갔다 ("다시 켜면 바뀌어 있다").
public enum Choices {
    /// 고급 창 "유휴 시간:" (기본 선택 2 = 30초)
    public static let idleValues = [0, 15, 30, 60, 120]
    public static let idleLabels = ["바로", "15초", "30초", "1분", "2분"]
    public static let idleDefaultIndex = 2

    /// 고급 창 "잠금 해제 지연:" (기본 선택 0 = 즉시)
    public static let delayValues = [0, 10, 30, 60]
    public static let delayLabels = ["즉시", "10초", "30초", "1분"]

    /// 간단 창 "자리를 뜨고 몇 초 뒤에 가릴까요?" 단추들
    public static let simpleIdle = [0, 15, 30, 60]
    public static let simpleIdleLabels = ["바로", "15초", "30초", "1분"]

    /// 간단 창 거리 슬라이더 0..2 = 가까이 / 보통 / 멀리. 기준값에 더하는 dB.
    /// 같은 "보통" 도 책상과 어댑터에 따라 10~20 dB 달라져서, 절대값이 아니라 잰 기준에서의
    /// 차이로 둔다.
    public static let distOffsets = [6, 0, -6]
    /// 아직 재지 않았을 때(measuredBaseRssi == 0) 쓰는 기준
    public static let distFallbackBase = -64

    /// SimpleBaseRssi: 잰 값이 있으면 그것, 없으면 -64
    public static func distBase(measured: Int) -> Int {
        return measured != 0 ? measured : distFallbackBase
    }

    /// SimpleDistStep: 지금 임계값에 가장 가까운 단계. 고급 창에서 dBm 을 직접 고쳤을 때도
    /// 슬라이더가 엉뚱한 곳을 가리키지 않게 하려는 것이다. 엄격한 < 로 보므로 같으면 앞 단계
    /// (가까이 쪽)가 이긴다.
    public static func distStep(base: Int, threshold: Int) -> Int {
        var best = 1
        var bestD = 9999
        for i in 0..<distOffsets.count {
            let d = abs((base + distOffsets[i]) - threshold)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// SimpleApplyDist 가 쓰는 값: base + offset[step] (자르지 않는다).
    /// Windows 는 범위 밖 step 을 무시한다. 여기서는 죽지 않도록 0...2 로 붙인다 -
    /// 호출자는 범위 밖 step 을 적용하지 말아야 한다.
    public static func distValue(base: Int, step: Int) -> Int {
        let s = min(max(step, 0), distOffsets.count - 1)
        return base + distOffsets[s]
    }

    /// 장치 목록에서 등록된 폰을 고르고 시작했을 때의 g_targetName. 표시 전용이라
    /// 광고 이름과 맞춰 보는 일은 없다.
    public static let registeredPhoneName = "등록된 폰"
}
