import Foundation
import CoreGraphics
import SmartScreenCore

/// Windows 의 저수준 입력 훅(WH_MOUSE_LL / WH_KEYBOARD_LL -> ResetCountdown)을 대신한다.
///
/// macOS 에는 권한 없이 쓸 수 있는 이벤트별 훅이 없다. CGEventTap 은 "입력 모니터링",
/// NSEvent.addGlobalMonitorForEvents 는 키 입력에 "손쉬운 사용" 권한이 필요하고(게다가 우리 창,
/// 즉 검은 화면을 향한 이벤트는 놓친다), 사용자가 거절하면 "입력하면 바로 풀린다" 가 통째로 깨진다.
/// 그래서 권한이 필요 없는 CGEventSource 의 "마지막 입력 뒤 지난 시간" 을 100 ms 마다 읽고,
/// 그 값으로 계산한 "마지막 입력 시각" 이 앞으로 움직였으면 새 입력으로 본다.
/// 해제가 최대 100 ms 늦을 수 있지만 사람이 느끼는 차이는 없다.
///
/// combinedSessionState 는 다른 앱이 넣은(합성) 이벤트도 센다 - Windows 훅도 LLMHF_INJECTED 를
/// 거르지 않았으니 같다. Windows 처럼 [시작] 과 [중지] 사이에만 돈다 (앱이 start/stop 을 부른다).
/// start/stop 과 콜백은 메인 스레드다.
final class InputWatcher {
    private static let pollInterval: TimeInterval = 0.1
    /// 같은 이벤트를 두 번 세지 않게 두는 여유 (ms 로 자르며 생기는 오차를 흡수한다).
    private static let newEventSlackMs: UInt64 = 10
    /// kCGAnyInputEventType 은 C 에서 ((CGEventType)(~0)) 로 정의된 매크로라 Swift 에 들어오지 않는다.
    /// 0xFFFFFFFF 는 CGEventType 에 선언된 값(kCGEventTapDisabledByUserInput)이기도 해서 nil 이 될 수 없다.
    private static let anyInputEventType: CGEventType = CGEventType(rawValue: ~0)!

    private let onInput: (UInt64) -> Void
    private var timer: Timer?
    /// 마지막으로 알린 입력이 일어났을 수 있는 가장 늦은 시각 (업타임 ms, 아래 설명 참고).
    private var lastReportedLatestUp: UInt64 = 0

    /// onInput(eventTick) on main for every NEW input event (polling CGEventSource every 100 ms).
    init(onInput: @escaping (UInt64) -> Void) {
        self.onInput = onInput
    }

    func start() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        if timer != nil { return }
        // 기준점은 "지금까지의 마지막 입력" 이다. [시작] 을 누른 클릭처럼 감시 전에 있었던 입력은
        // 새 입력이 아니다 (Windows 훅도 설치된 뒤의 이벤트만 본다).
        lastReportedLatestUp = InputWatcher.readLastInput().latestUp
        timer = MainTimer.every(InputWatcher.pollInterval) { [weak self] in
            self?.poll()
        }
    }

    func stop() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        timer?.invalidate()
        timer = nil
    }

    /// 마지막 입력(키보드, 마우스, 그 밖의 모든 입력) 뒤로 지난 초. kCGAnyInputEventType,
    /// combinedSessionState. 어느 스레드에서 불러도 된다 (클립보드 동기화의 GetLastInputInfo 대용).
    static func secondsSinceLastInput() -> Double {
        let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
        if s.isNaN || s < 0 { return 0 }
        return s
    }

    // MARK: - private

    /// 마지막 입력이 일어난 시각. 경과 시간을 묻는 호출 자체에 시간이 걸리므로 한 점이 아니라
    /// 구간 [earliestUp, latestUp] 으로 잡는다 (호출 앞뒤로 시계를 읽는다).
    private struct LastInput {
        /// 업타임(잠자기 동안 멈추는 mach 시계) 기준, 가장 이른 / 가장 늦은 가능 시각 (ms).
        var earliestUp: UInt64
        var latestUp: UInt64
        /// Mono(잠자기도 센다 - GetTickCount64 와 같은 뜻) 기준, 가장 이른 가능 시각. 0 은 넘기지 않는다.
        var earliestMono: UInt64
    }

    private static func uptimeMs() -> UInt64 {
        return DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private static func readLastInput() -> LastInput {
        let upBefore = uptimeMs()
        let monoBefore = Mono.now()
        let idle = secondsSinceLastInput()
        let upAfter = uptimeMs()
        let idleMsUp = toMs(idle, roundUp: true)
        let idleMsDown = toMs(idle, roundUp: false)
        let earliestUp = upBefore > idleMsUp ? upBefore - idleMsUp : 0
        let latestUp = upAfter > idleMsDown ? upAfter - idleMsDown : 0
        let earliestMono = monoBefore > idleMsUp ? max(monoBefore - idleMsUp, 1) : 1
        return LastInput(earliestUp: earliestUp, latestUp: latestUp, earliestMono: earliestMono)
    }

    /// 초(Double)를 ms(UInt64)로 바꾼다. NaN, 음수, 터무니없이 큰 값에서도 트랩하지 않는다.
    private static func toMs(_ seconds: Double, roundUp: Bool) -> UInt64 {
        if !(seconds > 0) { return 0 }
        if seconds >= 1.0e9 { return 1_000_000_000_000 }
        let ms = seconds * 1000.0
        return UInt64(roundUp ? ms.rounded(.up) : ms.rounded(.down))
    }

    /// 100 ms 마다: 마지막 입력이 지난번에 알린 입력보다 확실히(10 ms 넘게) 뒤면 새 입력이다.
    ///
    /// - 비교는 "이번 입력의 가장 이른 시각" 과 "지난번 입력의 가장 늦은 시각" 으로 한다. 같은 입력을
    ///   다시 읽은 것이면 이 둘이 실제 시각을 사이에 두므로, WindowServer 응답이 들쑥날쑥해도 같은
    ///   입력이 새 입력으로 보이지 않는다. 가짜 입력은 유휴 카운트다운을 되감아 잠금을 미룬다.
    /// - 새 입력인지는 잠자기 동안 멈추는 업타임 시계로 가린다. 입력 경과 시간(HID idle)은 이벤트
    ///   시각(mach 시계)에서 나오는데, Mono 처럼 잠자기도 세는 시계에서 빼면 맥이 잠들었다 깨어날 때
    ///   잠든 시간만큼 "마지막 입력 시각" 이 앞으로 튀어 손대지 않았는데도 입력으로 보이고 검은 화면이
    ///   저절로 풀린다. 업타임에서 빼면 그런 튐이 없다 (시계가 반대로 어긋나도 뒤로 갈 뿐이다).
    /// - 앱에 넘기는 시각(eventTick)은 Mono 기준의 가장 이른 시각이다. lastInputTick, 잠금 시작 시각과
    ///   같은 시계라야 "잠금 시작보다 나중 입력만 잠금을 푼다" 를 비교할 수 있고, 이르게 잡아야
    ///   [잠금] 을 누른 그 클릭이 잠금 뒤의 입력처럼 보여 직접 잠금을 스스로 푸는 일이 없다.
    ///   (Windows 훅은 잠금 뒤에 생긴 이벤트만 받으므로 저절로 그렇게 된다.)
    private func poll() {
        guard timer != nil else { return }
        let ev = InputWatcher.readLastInput()
        guard ev.earliestUp > lastReportedLatestUp + InputWatcher.newEventSlackMs else { return }
        lastReportedLatestUp = ev.latestUp
        onInput(ev.earliestMono)
    }
}
