import Foundation
import SmartScreenCore

/// 스레드 사이에서 함께 읽는 값들. Windows globals.cpp 의 g_* 가운데 UI 스레드 말고도
/// 스캔(판정) 스레드나 GATT 틱 스레드가 읽는 것만 여기에 모았다.
///
/// Windows 는 "정렬된 int 는 찢어지지 않는다" 에 기대어 락 없이 읽고 썼다. Swift 는 그렇지
/// 않다 - 두 스레드가 같은 클래스 프로퍼티를 동기화 없이 만지면 정의되지 않은 동작이다.
/// Windows 에서도 `lastReceivedTick` 을 원자적이지 않게 읽다가 버그가 난 적이 있다
/// ("스레드를 건너는 틱은 전부 원자적이어야 한다"). 그래서 값 하나하나를 NSLock 뒤에 둔다.
///
/// 쓰는 쪽:
///  - 메인 스레드: 임계값(StartMon, 간단 화면 슬라이더), gattSeen/gattGraceSec/monStartTick/
///    bleLostMeansFar/keepAliveSec (StartMon), blackActive/lastInputTick (GuardEngine 의 거울),
///    measuring (재보기 창)
///  - 판정 스레드(JudgeThread): proxState, lastNearTick, 그리고 첫 구독 때의 gattSeen = true
/// 읽는 쪽: 판정 스레드(judgeSettings), GATT 틱 타이머(blackActive, lastInputTick),
///          메인(proxState, lastNearTick, measuring).
final class Shared {
    static let shared = Shared()

    private let lock = NSLock()

    // 초기값은 Windows globals.cpp 와 같다.
    private var _nearRssiThreshold = -65     // BLE RSSI 임계값 (dBm). 이 값 이상이면 NEAR
    // v2(GATT) 임계값. Windows 초기값이 -55 다. 1.1.6 부터 StartMon 이 광고 임계값과 같은 값으로
    // 덮으므로 -55 는 첫 [시작] 전에만 존재하고, 판정 스레드는 [시작] 뒤에만 돌아서 실제로는 안 쓰인다.
    private var _gattRssiThreshold = -55
    private var _gattSeen = false
    private var _gattGraceSec: UInt32 = 90
    private var _monStartTick: UInt64 = 0
    // 컴패니언 앱이 계속 광고하므로 끊김 = 이탈. 앱을 안 쓰면 0으로
    private var _bleLostMeansFar = true
    private var _keepAliveSec: UInt32 = 5
    private var _proxState: ProxState = .far
    private var _lastNearTick: UInt64 = 0
    private var _blackActive = false
    private var _lastInputTick: UInt64 = 0
    private var _measuring = false

    private init() {}

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// g_nearRssiThreshold: 광고 경로 임계값. StartMon(입력 칸)과 간단 화면 슬라이더가 바꾼다.
    var nearRssiThreshold: Int {
        get { return locked { _nearRssiThreshold } }
        set { locked { _nearRssiThreshold = newValue } }
    }

    /// g_gattRssiThreshold: GATT 경로 임계값. StartMon 과 슬라이더가 광고 값과 같게 맞춘다
    /// (두 값을 따로 두었더니 -67/-61 처럼 갈라져 앉아 있는 사람이 잠겼다).
    var gattRssiThreshold: Int {
        get { return locked { _gattRssiThreshold } }
        set { locked { _gattRssiThreshold = newValue } }
    }

    /// g_gattSeen: 컴패니언 앱이 이 PC 에 한 번이라도 붙은 적이 있다.
    /// StartMon 이 config 에서 읽고, 판정 스레드가 첫 구독 때 true 로 만든다
    /// (저장은 메인이 한다 - JudgeThread 의 onGattSeen).
    var gattSeen: Bool {
        get { return locked { _gattSeen } }
        set { locked { _gattSeen = newValue } }
    }

    /// g_gattGraceSec: [시작] 뒤 앱 연결을 기다려 주는 시간. 지나면 "연결 없음" 이 부재의 단서가 된다.
    var gattGraceSec: UInt32 {
        get { return locked { _gattGraceSec } }
        set { locked { _gattGraceSec = newValue } }
    }

    /// g_monStartTick: 감시를 시작한 Mono 시각 (ms).
    var monStartTick: UInt64 {
        get { return locked { _monStartTick } }
        set { locked { _monStartTick = newValue } }
    }

    /// g_bleLostMeansFar: 광고가 끊긴 것을 부재로 본다.
    var bleLostMeansFar: Bool {
        get { return locked { _bleLostMeansFar } }
        set { locked { _bleLostMeansFar = newValue } }
    }

    /// g_keepAliveSec: StartMon 이 늘 5 로 둔다. latency 경로 유예이자 강제 잠금 식과
    /// "Timer" 열의 일부다.
    var keepAliveSec: UInt32 {
        get { return locked { _keepAliveSec } }
        set { locked { _keepAliveSec = newValue } }
    }

    /// g_proxState: 판정 스레드가 쓴다 (스레드 시작 때 FAR 로 되돌린다). 결과를 메인에 보내기
    /// **전에** 쓴다 - 메인의 잠금 관문은 결과의 state 가 아니라 이 값을 읽는다.
    var proxState: ProxState {
        get { return locked { _proxState } }
        set { locked { _proxState = newValue } }
    }

    /// g_lastNearTick: 판정 스레드가 NEAR 판정 때마다 now 로 쓴다 (스레드 시작 때 0).
    /// 메인의 1초 틱이 "FAR 가 너무 오래" 강제 잠금에 쓴다.
    var lastNearTick: UInt64 {
        get { return locked { _lastNearTick } }
        set { locked { _lastNearTick = newValue } }
    }

    /// g_bBlackActive 의 거울 (메인이 GuardEngine.blackActive 를 바꿀 때마다 쓴다).
    /// GATT 틱 타이머가 폴링 간격(잠금 중 2000 ms)을 정하는 데 읽는다.
    var blackActive: Bool {
        get { return locked { _blackActive } }
        set { locked { _blackActive = newValue } }
    }

    /// g_lastInputTick 의 거울 (Windows 에서도 std::atomic 이었다). GATT 틱 타이머가 읽는다:
    /// 입력 5초 이내면 폴링을 쉰다(간격 0 = 자리에 있음).
    var lastInputTick: UInt64 {
        get { return locked { _lastInputTick } }
        set { locked { _lastInputTick = newValue } }
    }

    /// g_measuring: 재보기 창이 열려 있다. 자리 비우기가 재는 절차의 한 단계라서
    /// 이동안은 자동 잠금을 하지 않는다 (업데이트 적용도 기다린다).
    var measuring: Bool {
        get { return locked { _measuring } }
        set { locked { _measuring = newValue } }
    }

    /// 판정 한 번에 쓸 설정을 한 락 안에서 한꺼번에 복사한다. 값마다 따로 읽으면 슬라이더가
    /// 움직이는 사이에 두 임계값이 서로 다른 시점의 값으로 섞일 수 있다.
    func judgeSettings() -> JudgeSettings {
        return locked {
            var s = JudgeSettings()
            s.nearRssiThreshold = _nearRssiThreshold
            s.gattRssiThreshold = _gattRssiThreshold
            s.gattSeen = _gattSeen
            s.gattGraceSec = _gattGraceSec
            s.monStartTick = _monStartTick
            s.bleLostMeansFar = _bleLostMeansFar
            s.keepAliveSec = _keepAliveSec
            // g_nearLatencyMs 는 StartMon 이 늘 200 으로 둔다. Mac 에는 latency(RFCOMM) 경로가
            // 없어서 판정에 쓰이지도 않으므로 따로 들고 있지 않는다.
            s.nearLatencyMs = 200
            return s
        }
    }
}
