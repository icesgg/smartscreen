import Foundation

// 잠금/해제 상태 기계 (UI 스레드 전용). Windows 의 다음 부분을 창과 떼어 옮겼다:
//   - OnResult 의 잠금/해제 부분 (client/main.cpp)
//   - IDT_COUNTDOWN 1 초 틱의 잠금 부분 (client/main.cpp)
//   - ResetCountdown: 마우스/키보드 입력 (client/main.cpp)
//   - ActivateBlackScreen / DeactivateBlackScreen (client/blackscreen.cpp)
//   - 수동 잠금 버튼 3 개 (오버레이 [잠금], 고급 [지금 잠금], 간단 [지금 가리기])
//   - StopMon 의 잠금 부분
// 창 만들기/없애기와 원격 세션 판정은 host 가 한다. 라벨, 오버레이, 목록, config 저장,
// STATE 로그는 호출자(AppController) 몫이다.
//
// 이 화면은 보안 잠금이 아니라 가림막이다: 어떤 입력이든 곧바로 걷힌다 (수동 잠금도).
// 자동 잠금이 걸리지 않는 경우는 넷: 5 초 안에 입력이 있었다, 재보기 중이다, 원격 세션이다,
// 폰이 NEAR 다.
//
// Windows 와 일부러 다르게 한 것 (모두 lockscreen 스펙의 권고):
//   Q1  오버레이 셋째 줄의 잠근 시각: Windows 는 시간대만큼 틀린다. 여기는 지역 시각
//       (지금 - 잠긴 시간) 으로 바르게 쓴다.
//   Q2  unlockTimer 를 잠글 때마다(자동, 수동) 0 으로 지운다. Windows 는 해제 때도 잠글 때도
//       안 지워서, 지연 해제를 기다리던 중 입력으로 풀린 뒤 남은 값이 나중의 "수동" 잠금을
//       풀어 버렸다 (틱은 수동 여부를 안 본다).
//   Q6  activate() 는 모니터링 중에만 잠근다. Windows 는 [중지] 직후 큐에 남은 결과가 입력 훅도
//       없는 상태에서 화면을 잠글 수 있었다. 낡은 결과는 호출자가 세션 번호로도 버린다.

/// 차트용 FAR 사건 (Windows FarEvent: GetTickCount64 + GetLocalTime)
public struct FarEvent {
    public let tick: UInt64
    public let date: Date
    public init(tick: UInt64, date: Date) {
        self.tick = tick
        self.date = date
    }
}

/// 잠금 창을 실제로 띄우고 내리는 쪽 (앱의 AppController)
public protocol GuardEngineHost: AnyObject {
    /// 잠금 창을 만들고 띄운다 (그 순간의 그림 경로를 읽는다)
    func guardShowLock()
    /// 잠금 창을 없애고 그림을 놓는다 (다음 잠금이 바뀐 경로를 다시 읽게)
    func guardHideLock()
    /// 이 세션이 콘솔에 있지 않은가 (Windows SM_REMOTESESSION). 매번 새로 묻는다.
    func guardIsRemoteSession() -> Bool
}

public final class GuardEngine {
    /// 입력 보호 시간. 방금 마우스/키보드를 썼다 = 사람이 앞에 있다 → RSSI 와 무관하게 잠그지 않는다.
    private static let inputGuardMs: UInt64 = 5000
    /// 차트가 보여 주는 폭이자 FAR 사건을 들고 있는 시간 (30 분)
    private static let chartWindowMs: UInt64 = 30 * 60 * 1000
    /// 잠금 시작과 입력 시각을 비교할 때의 여유. Mac 은 입력을 100 ms 마다 HID 유휴 시간으로
    /// 읽어 시각을 거꾸로 계산하므로 몇 ms 흔들린다. 수동 잠금을 건 클릭(잠금보다 먼저
    /// 일어났다)이 그 흔들림 때문에 "잠금 뒤 입력" 으로 보여 잠금을 바로 풀면 안 된다.
    /// Windows 는 훅이 사건마다 오므로 이런 문제가 없다.
    private static let inputAfterLockSlackMs: UInt64 = 50

    public weak var host: GuardEngineHost?
    public var monitoring = false
    public var idleCountdownSec = 20
    public var unlockDelaySec = 0
    public var keepAliveSec = 5
    /// 재보기 마법사가 열려 있는 동안 참. 자리를 비우는 것이 절차의 일부라
    /// 그냥 두면 재는 도중에 화면이 꺼진다.
    public var measuring = false
    /// 판정 스레드가 쓰는 지금 상태 (Windows g_proxState / g_lastNearTick).
    /// 결과(r.state)보다 한 샘플 새로울 수 있다 - Windows 도 같고 문제없다.
    public var liveState: () -> (state: ProxState, lastNearTick: UInt64) = { (state: .far, lastNearTick: 0) }

    public private(set) var blackActive = false
    public private(set) var manualLock = false
    public private(set) var nCountdown = 20
    public private(set) var unlockTimer = 0
    public private(set) var lockStartTick: UInt64 = 0
    public private(set) var lastInputTick: UInt64 = 0
    public private(set) var ovlInfo = ""
    public private(set) var farEvents: [FarEvent] = []

    /// "원격이라 건너뛴다" 는 연속 구간마다 한 번만 남긴다. 안 그러면 자리를 비운 내내
    /// 2 초마다 같은 줄이 쌓인다. (Windows 의 파일 static 처럼 [중지]/[시작] 에도 지우지 않는다.)
    private var remoteNoted = false

    /// events.log 로 가는 통로. 테스트가 바꿔 끼운다.
    var logSink: (String) -> Void = { EventLog.write($0) }

    public init() {}

    // MARK: - 시작 / 중지

    /// StartMon 의 이 부분: [시작] 도 입력으로 친다 (시작 직후 5 초는 잠그지 않는다).
    public func start(now: UInt64) {
        monitoring = true
        lastInputTick = now
        nCountdown = idleCountdownSec
    }

    /// StopMon: 모니터링을 끄고, 가려져 있으면 걷는다.
    public func stop(now: UInt64, wall: Date = Date()) {
        monitoring = false
        if blackActive { deactivate(now: now, wall: wall) }
    }

    /// 간단 창 유휴 단추 / StartMon: 유휴 시간을 바꾸고 카운트다운도 그 값에서 다시 센다.
    public func setIdle(_ sec: Int) {
        idleCountdownSec = sec
        nCountdown = sec
    }

    public func clearFarEvents() {
        farEvents.removeAll()
    }

    // MARK: - 판정 결과 (OnResult 의 잠금/해제 부분)

    /// 순서가 중요하다: (1) FAR 전환 잠금 (2) NEAR 자동 해제 (3) FAR 이면 지연 해제 취소.
    /// STATE 로그, 라벨, 목록, 오버레이는 호출자가 한다.
    public func onResult(_ r: ProbeResult, now: UInt64, wall: Date = Date()) {
        // [중지] 뒤에 도착한 결과는 아무것도 바꾸지 않는다 (Q6). 호출자도 세션 번호로 거른다.
        guard monitoring else { return }
        let transition = r.state != r.prevState
        if transition && r.state == .far {
            farEvents.append(FarEvent(tick: now, date: wall))
            let cut = now > GuardEngine.chartWindowMs ? now - GuardEngine.chartWindowMs : 0
            while let first = farEvents.first, first.tick < cut {
                farEvents.removeFirst()
            }
            // FAR 전환 → 바로 잠근다 (관문은 activate 가 본다). 유휴 시간은 여기서 아무 역할도 없다.
            if !blackActive { activate(now: now) }
        }

        // 폰이 돌아오면 자동으로 풀어 준다. 단 사용자가 직접 잠근 것은 예외다 -
        // 그건 "자리에 있어도 가려 두겠다"는 명시적 의사라, 폰이 곁에 있다는
        // 이유로 되돌리면 그 의사를 뒤집는 것이 된다. 풀려면 [해제] 를 누른다.
        // (manualLock 은 두 잠금 버튼이 세팅해 왔지만 한동안 아무도 읽지 않아서
        //  수동 잠금도 자동으로 풀렸다.)
        if r.state == .near && blackActive && !manualLock && unlockTimer <= 0 {
            unlockTimer = unlockDelaySec
            if unlockTimer <= 0 { deactivate(now: now, wall: wall) }   // 지연 0 = 즉시
        }
        if r.state == .far { unlockTimer = 0 }   // 기다리던 지연 해제를 취소한다
        // NEAR 는 유휴 카운트다운을 되돌리지 않는다 - 입력만 되돌린다 (NEAR 중에는 관문이 되돌린다)
    }

    // MARK: - 1 초 틱 (IDT_COUNTDOWN 의 잠금 부분)

    /// 순서: 유휴 카운트다운 → 오래된 FAR 강제 잠금 → 원격 세션 해제 → 지연 해제 카운트다운.
    /// (overflow 비트 저장, 라벨, 오버레이는 호출자가 이 앞뒤에서 한다.)
    public func tick(now: UInt64, wall: Date = Date()) {
        guard monitoring else { return }
        if !blackActive {
            // NEAR 와 FAR 모두에서 센다. 0 이 되면 잠금을 시도한다 - NEAR 면 관문이 다시 채운다.
            // "바로"(0) 면 매 틱 시도하므로, FAR 이고 입력이 5 초 넘게 없으면 곧 잠긴다.
            if nCountdown > 0 { nCountdown -= 1 }
            if nCountdown == 0 { activate(now: now) }
        }
        // FAR 가 timeout + 유휴 시간보다 오래 이어지면 카운트다운을 0 으로 당겨 잠근다.
        // 이번 세션에 NEAR 를 한 번이라도 봤어야 한다 (lastNearTick > 0).
        if !blackActive && monitoring {
            let live = liveState()
            if live.state == .far && live.lastNearTick > 0 {
                let need = UInt64(max(0, keepAliveSec + idleCountdownSec)) * 1000
                if now >= live.lastNearTick && now - live.lastNearTick >= need {
                    nCountdown = 0
                    activate(now: now)
                }
            }
        }
        // 잠긴 뒤에 원격으로 붙었다면 풀어 준다. 자리를 비웠다가 원격으로
        // 들어오는 것이 흔한 순서인데, 안 풀면 원격 화면이 검은 채로 시작한다.
        // 직접 잠근 것은 건드리지 않는다 - 원격이든 아니든 그 의사가 우선이다.
        if blackActive && !manualLock && (host?.guardIsRemoteSession() ?? false) {
            logSink("원격 세션이 감지되어 잠금을 푼다")
            deactivate(now: now, wall: wall)
        }
        if blackActive && unlockTimer > 0 {
            unlockTimer -= 1
            if unlockTimer <= 0 { deactivate(now: now, wall: wall) }
        }
    }

    // MARK: - 입력 (ResetCountdown)

    /// 새 마우스/키보드 입력마다. eventTick = 그 입력이 일어난 Mono 시각.
    /// 입력은 언제나 곧바로 화면을 걷는다 - 수동 잠금도. 다만 잠금이 걸리기 전에 일어난
    /// 입력(수동 잠금을 건 그 클릭)으로는 풀지 않는다. Windows 는 훅이 사건 순간에 와서
    /// 이 구분이 저절로 됐지만, Mac 은 100 ms 마다 묻기 때문에 잠금 뒤에 알게 된다.
    public func onInput(eventTick: UInt64, now: UInt64, wall: Date = Date()) {
        // Windows 의 입력 훅은 [시작]~[중지] 사이에만 있다
        guard monitoring else { return }
        // 시각이 거꾸로 가지 않게 한다: [시작] 이 찍은 시각보다 이른 입력이
        // 늦게 보고되어도 시작 직후 5 초 보호가 줄지 않는다.
        if eventTick > lastInputTick { lastInputTick = eventTick }
        nCountdown = idleCountdownSec
        if blackActive && eventTick > lockStartTick + GuardEngine.inputAfterLockSlackMs {
            deactivate(now: now, wall: wall)
        }
        // 셋째 줄("Lock .. -> Unlock ..")은 다음 입력까지만 보인다. 입력으로 풀렸으면
        // 같은 호출에서 썼다가 지우므로 보이지 않는다 - 근접/[해제]/원격 해제 뒤에만 보인다.
        if !ovlInfo.isEmpty { ovlInfo = "" }
    }

    /// 마지막 입력이 5000 ms 안에 있었나 (자동 잠금 관문의 첫 조건)
    public func inputGuardActive(now: UInt64) -> Bool {
        if lastInputTick == 0 { return false }
        // 입력 시각이 now 보다 뒤면 (다른 스레드가 잰 시각) 방금 입력이 있었던 것이다
        if now < lastInputTick { return true }
        return now - lastInputTick < GuardEngine.inputGuardMs
    }

    // MARK: - 잠금 / 해제

    /// ActivateBlackScreen: 모든 자동 잠금이 여기를 지난다. 관문 순서를 Windows 그대로 지킨다.
    @discardableResult
    public func activate(now: UInt64) -> Bool {
        // Q6: Windows 는 여기서 모니터링을 안 봤다 ([중지] 직후의 결과가 잠글 수 있었다)
        guard monitoring else { return false }
        if blackActive { return false }
        // 방금 마우스/키보드를 썼다 = 사람이 앞에 있다 → RSSI와 무관하게 잠그지 않음
        if inputGuardActive(now: now) { return false }
        // 재보기 중에는 자리를 비우는 것이 절차의 일부다. 여기서 잠그면 측정이
        // 끊기고, 사용자는 자기가 뭘 잘못한 줄 안다.
        if measuring { return false }
        // 원격으로 쓰는 중이면 폰이 책상에 없는 게 정상이다. 여기서 잠그면
        // 원격 사용자 화면만 가린다 - 가려야 할 책상 앞에는 아무도 없다.
        // 사용자가 직접 누른 잠금은 이 경로로 오지 않으므로 그대로 걸린다.
        // (카운트다운은 되돌리지 않으므로 매 틱 다시 시도한다.)
        let remote = host?.guardIsRemoteSession() ?? false
        if remote {
            if !remoteNoted {
                logSink("원격 세션이라 자동 잠금을 건너뛴다")
                remoteNoted = true
            }
            return false
        }
        remoteNoted = false
        // NEAR 인 동안은 절대 잠그지 않는다. 유휴 카운트다운만 처음부터 다시 센다.
        if liveState().state == .near {
            nCountdown = idleCountdownSec
            return false
        }
        blackActive = true
        manualLock = false
        lockStartTick = now
        unlockTimer = 0   // Q2: 지난 잠금에서 남은 지연 해제 값을 버린다
        // idleCountdown 0 = 카운트다운/강제 경로, >0 = FAR 전환으로 잠겼다. "ON" 뒤는 두 칸.
        logSink("BLACK ON  (idleCountdown=\(nCountdown))")
        host?.guardShowLock()
        return true
    }

    /// 수동 잠금 (오버레이 [잠금], 고급 [지금 잠금], 간단 [지금 가리기]).
    /// 관문을 하나도 보지 않는다 (입력, 재보기, 원격, NEAR). BLACK ON 줄도 남기지 않는다.
    /// 모니터링 중이 아니거나 이미 가려져 있으면 조용히 아무것도 안 한다.
    public func manualLockNow(now: UInt64) {
        guard monitoring && !blackActive else { return }
        blackActive = true
        manualLock = true
        lockStartTick = now
        unlockTimer = 0   // Q2: 남은 지연 해제 값이 이 수동 잠금을 풀지 못하게
        host?.guardShowLock()
    }

    /// DeactivateBlackScreen. 정보 줄과 로그를 먼저 만들고 상태를 지운 다음 창을 내린다.
    /// unlockTimer 는 여기서 지우지 않는다 (로그에 그 값이 찍히고, Q2 는 잠글 때 지운다).
    public func deactivate(now: UInt64, wall: Date = Date()) {
        guard blackActive else { return }
        let durationSec: UInt64 = (lockStartTick > 0 && now >= lockStartTick) ? (now - lockStartTick) / 1000 : 0
        // Q1: 잠근 시각 = 지금(지역 시각) - 잠긴 시간
        let lockDate = wall.addingTimeInterval(-Double(durationSec))
        ovlInfo = Texts.ovlInfo(lock: lockDate, unlock: wall, durationSec: durationSec)
        logSink("BLACK OFF (locked \(durationSec)s, unlockTimer=\(unlockTimer))")
        blackActive = false
        manualLock = false
        lockStartTick = 0
        nCountdown = idleCountdownSec
        // 잠금 중에 그림 경로가 바뀌었을 수 있다 (기업 콘텐츠 동기화의 결과는 작업
        // 스레드에서 오므로 잠금 중에도 도착한다). 떠 있는 동안에는 보여 주던 것을 그대로
        // 두고, 여기서 버려서 다음 잠금이 새 경로로 다시 읽게 한다 (host 가 한다).
        host?.guardHideLock()
    }
}
