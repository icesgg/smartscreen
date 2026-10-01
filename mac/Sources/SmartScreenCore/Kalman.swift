import Foundation

/// 1차원 칼만 필터. client/ble_rssi.cpp 의 KalmanFilter 를 그대로 옮겼다.
/// Q 는 "초당" 프로세스 노이즈다: 패킷 간격이 길수록 불확실성이 커져 새 측정값을 더
/// 크게 반영한다. 기본값(Q=1.0, R=10.0)도 Windows 판과 같다 - 두 판이 같은 폰 신호를
/// 같은 값으로 매끄럽게 해야 같은 임계값이 같은 뜻이 된다.
public struct KalmanFilter {
    public private(set) var estimate: Double = 0
    private var p: Double = 1.0
    private let q: Double
    private let r: Double
    public private(set) var initialized = false

    public init(processNoise: Double = 1.0, measureNoise: Double = 10.0) {
        q = processNoise
        r = measureNoise
    }

    @discardableResult
    public mutating func update(_ measurement: Double, dtSec: Double = 1.0) -> Double {
        if !initialized {
            // 첫 측정값으로 초기화
            estimate = measurement
            p = 1.0
            initialized = true
            return estimate
        }
        let dt = min(max(dtSec, 0.05), 60.0)
        let pPred = p + q * dt
        let k = pPred / (pPred + r)             // 칼만 이득
        estimate = estimate + k * (measurement - estimate)
        p = (1.0 - k) * pPred
        return estimate
    }

    public mutating func reset() {
        initialized = false
        estimate = 0
        p = 1.0
    }
}
