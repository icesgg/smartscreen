import XCTest
@testable import SmartScreenCore

// monitor 스펙 §4.13 의 타임라인을 그대로 테스트로 옮겼다. 시각은 Mono 밀리초처럼 쓰는
// 임의의 수다 (0 은 "없음" 표식이라 T0 를 크게 잡는다).

private enum CoreBFix {
    static let t0: UInt64 = 1_000_000

    /// 광고 경로: 스캔 중이고, tick 에 패킷을 받았고, 그 값이 rssi 다.
    static func adv(_ rssi: Int, tick: UInt64, receiving: Bool = true) -> ScannerSnapshot {
        var s = ScannerSnapshot()
        s.available = true
        s.lastReceivedTick = tick
        s.smoothedRssi = rssi
        s.rawRssi = rssi
        s.receiving = receiving
        s.hasEverReceived = tick != 0
        return s
    }

    /// GATT 경로: 구독 중이고 건강하다.
    static func gatt(_ rssi: Int, poll: UInt32, reportTick: UInt64, age: UInt32 = 500) -> GattSnapshot {
        var g = GattSnapshot()
        g.running = true
        g.subscribed = true
        g.everSubscribed = true
        g.healthy = true
        g.pollIntervalMs = poll
        g.reportAgeMs = age
        g.lastReportTick = reportTick
        g.smoothedRssi = rssi
        g.rawRssi = rssi
        return g
    }

    static func settings(thr: Int = -65) -> JudgeSettings {
        var s = JudgeSettings()
        s.nearRssiThreshold = thr
        s.gattRssiThreshold = thr
        // gattSeen 을 미리 true 로 두어 "companion app seen" 알림이 테스트를 흐리지 않게 한다
        s.gattSeen = true
        s.monStartTick = 1
        return s
    }

    static func result(_ state: ProxState, prev: ProxState) -> ProbeResult {
        var r = ProbeResult()
        r.state = state
        r.prevState = prev
        r.reachable = true
        r.bleAvailable = true
        return r
    }
}

private final class CoreBFakeHost: GuardEngineHost {
    var shows = 0
    var hides = 0
    var remote = false
    func guardShowLock() { shows += 1 }
    func guardHideLock() { hides += 1 }
    func guardIsRemoteSession() -> Bool { return remote }
}

private final class CoreBLive {
    var state: ProxState = .far
    var lastNearTick: UInt64 = 0
    var lines: [String] = []
}

// MARK: - ProximityJudge

final class CoreBProximityTests: XCTestCase {
    private func step(_ j: ProximityJudge, _ now: UInt64, _ s: ScannerSnapshot,
                      gatt: GattSnapshot = GattSnapshot(), settings: JudgeSettings = CoreBFix.settings()) -> ProbeResult {
        return j.step(now: now, scanner: s, gatt: gatt, settings: settings, timeStr: "09:00:00").result
    }

    /// 폰을 들고 떠난다: 첫 미만 샘플은 아무것도 안 하고, 두 번째 "새" 샘플에서 FAR.
    func testLeaveWithPhoneFarOnSecondNewSample() {
        let j = ProximityJudge()
        var r = step(j, 1_000, CoreBFix.adv(-50, tick: 1_000))
        XCTAssertEqual(r.state, .near)
        XCTAssertEqual(r.prevState, .far)
        XCTAssertEqual(r.thresholdDbm, -61)          // FAR 에서는 설정 + 4
        XCTAssertEqual(j.lastNearTick, 1_000)
        XCTAssertEqual(r.timeStr, "09:00:00")

        r = step(j, 3_000, CoreBFix.adv(-70, tick: 3_000))   // 첫 미만 샘플
        XCTAssertEqual(r.state, .near)
        XCTAssertEqual(r.thresholdDbm, -65)          // NEAR 에서는 설정 그대로

        r = step(j, 4_000, CoreBFix.adv(-70, tick: 3_000))   // 같은 샘플 (2 초 타임아웃 회차): 다시 세지 않는다
        XCTAssertEqual(r.state, .near)
        r = step(j, 4_500, CoreBFix.adv(-70, tick: 3_000))
        XCTAssertEqual(r.state, .near)

        r = step(j, 5_000, CoreBFix.adv(-72, tick: 5_000))   // 두 번째 새 샘플
        XCTAssertEqual(r.state, .far)
        XCTAssertEqual(r.prevState, .near)
        XCTAssertEqual(r.rssiDbm, -72)
        XCTAssertEqual(r.timerRemainMs, 0)
        XCTAssertEqual(j.state, .far)
    }

    /// 두 번째 샘플이 영영 안 와도 첫 미만 샘플에서 6 s 뒤에는 FAR.
    func testSixSecondCap() {
        let j = ProximityJudge()
        _ = step(j, 1_000, CoreBFix.adv(-50, tick: 1_000))
        XCTAssertEqual(step(j, 3_000, CoreBFix.adv(-70, tick: 3_000)).state, .near)
        XCTAssertEqual(step(j, 8_999, CoreBFix.adv(-70, tick: 3_000)).state, .near)
        XCTAssertEqual(step(j, 9_000, CoreBFix.adv(-70, tick: 3_000)).state, .far)
    }

    /// 신호가 아예 없다(-100) = 부재. 두 샘플을 기다리지 않는다.
    func testMinus100IsImmediateFar() {
        let j = ProximityJudge()
        _ = step(j, 1_000, CoreBFix.adv(-50, tick: 1_000))
        // 수신 타임아웃: 스캐너가 -100 을 돌려주고 receiving 은 false, 받은 적은 있다
        let r = step(j, 95_000, CoreBFix.adv(-100, tick: 1_000, receiving: false))
        XCTAssertEqual(r.state, .far)
        XCTAssertTrue(r.bleAvailable)        // bleLostMeansFar=1: 받은 적이 있으면 BLE 가 판정한다
        XCTAssertTrue(r.reachable)
        XCTAssertEqual(r.rssiDbm, -100)
        XCTAssertEqual(Texts.stateLabel(r, countdown: 5), "  멀리  (폰 신호 없음 - 앱 확인)")
    }

    func testHysteresis() {
        let j = ProximityJudge()
        var r = step(j, 1_000, CoreBFix.adv(-62, tick: 1_000))
        XCTAssertEqual(r.state, .far)                 // FAR 에서는 -61 이상이어야 NEAR
        XCTAssertEqual(r.thresholdDbm, -61)
        r = step(j, 2_000, CoreBFix.adv(-61, tick: 2_000))
        XCTAssertEqual(r.state, .near)
        r = step(j, 3_000, CoreBFix.adv(-65, tick: 3_000))
        XCTAssertEqual(r.state, .near)                // NEAR 에서는 -65 이상이면 그대로
        XCTAssertEqual(r.thresholdDbm, -65)
    }

    /// 미만 카운터는 NEAR 판정일 때만 지운다.
    func testBelowCounterResetsOnlyOnNear() {
        let j = ProximityJudge()
        _ = step(j, 1_000, CoreBFix.adv(-50, tick: 1_000))
        XCTAssertEqual(step(j, 2_000, CoreBFix.adv(-70, tick: 2_000)).state, .near)  // 1
        XCTAssertEqual(step(j, 3_000, CoreBFix.adv(-60, tick: 3_000)).state, .near)  // NEAR: 0 으로
        XCTAssertEqual(step(j, 4_000, CoreBFix.adv(-70, tick: 4_000)).state, .near)  // 1
        XCTAssertEqual(step(j, 5_000, CoreBFix.adv(-70, tick: 5_000)).state, .far)   // 2
    }

    /// 경로가 바뀌어도 센 수는 이어진다: 광고 미만 1 + GATT 미만 1 = 2.
    func testPathSwitchCountsAsTwoSamples() {
        let j = ProximityJudge()
        _ = step(j, 1_000, CoreBFix.adv(-50, tick: 1_000))
        XCTAssertEqual(step(j, 2_000, CoreBFix.adv(-70, tick: 2_000)).state, .near)
        let r = step(j, 3_000, CoreBFix.adv(-70, tick: 2_000), gatt: CoreBFix.gatt(-70, poll: 1000, reportTick: 3_000))
        XCTAssertTrue(r.gatt)
        XCTAssertEqual(r.state, .far)
    }

    /// GATT: 입력 중이라 폴링을 쉬면(간격 0) RSSI 와 무관하게 NEAR.
    func testGattInputShortcut() {
        let j = ProximityJudge()
        let r = step(j, 1_000, CoreBFix.adv(-90, tick: 1_000), gatt: CoreBFix.gatt(-90, poll: 0, reportTick: 900))
        XCTAssertEqual(r.state, .near)
        XCTAssertTrue(r.gatt)
        XCTAssertTrue(r.bleAvailable)
        XCTAssertTrue(r.reachable)
        XCTAssertEqual(r.rssiDbm, -90)
        XCTAssertEqual(r.thresholdDbm, -65)          // 이 경로의 설정값 (히스테리시스 없음)
    }

    /// GATT: 구독 뒤 첫 보고를 기다리는 동안은 지금 상태를 유지한다.
    func testGattWaitingForFirstReportHolds() {
        let farJ = ProximityJudge()
        let waiting = CoreBFix.gatt(-40, poll: 1000, reportTick: 0, age: 0xFFFF_FFFF)
        XCTAssertEqual(step(farJ, 1_000, ScannerSnapshot(), gatt: waiting).state, .far)

        let nearJ = ProximityJudge()
        _ = step(nearJ, 1_000, ScannerSnapshot(), gatt: CoreBFix.gatt(-90, poll: 0, reportTick: 0))
        XCTAssertEqual(nearJ.state, .near)
        let weakWaiting = CoreBFix.gatt(-99, poll: 2000, reportTick: 0, age: 0xFFFF_FFFF)
        XCTAssertEqual(step(nearJ, 3_000, ScannerSnapshot(), gatt: weakWaiting).state, .near)
    }

    func testGattHysteresisAndThresholdLogged() {
        let j = ProximityJudge()
        var s = CoreBFix.settings(thr: -67)
        s.nearRssiThreshold = -67
        s.gattRssiThreshold = -67
        var r = step(j, 1_000, ScannerSnapshot(), gatt: CoreBFix.gatt(-64, poll: 1000, reportTick: 1_000), settings: s)
        XCTAssertEqual(r.state, .far)
        XCTAssertEqual(r.thresholdDbm, -63)
        r = step(j, 2_000, ScannerSnapshot(), gatt: CoreBFix.gatt(-63, poll: 1000, reportTick: 2_000), settings: s)
        XCTAssertEqual(r.state, .near)
    }

    /// 앱이 있어야 하는데 연결도 광고도 없다 → 부재(-100, 즉시 FAR). 광고가 들리면 광고가 판정한다.
    func testAbsentRule() {
        let j = ProximityJudge()
        var s = CoreBFix.settings()
        s.monStartTick = 10_000
        s.gattGraceSec = 90
        _ = step(j, 11_000, CoreBFix.adv(-50, tick: 11_000), settings: s)
        XCTAssertEqual(j.state, .near)

        var link = GattSnapshot()
        link.running = true            // 서버는 돌지만 이번 세션에 아무도 안 붙었다
        let silent = CoreBFix.adv(-100, tick: 11_000, receiving: false)

        // 유예 90 s 안: 아직 기대하지 않는다 → 광고 경로 (그래도 -100 이라 FAR)
        var r = step(j, 10_000 + 90_000, silent, gatt: link, settings: s)
        XCTAssertFalse(r.gatt)
        XCTAssertEqual(r.state, .far)

        // 유예가 지나면 "absent" 규칙: GATT 로 표시되고 rssi -100, reachable
        _ = step(j, 100_500, CoreBFix.adv(-50, tick: 100_500), settings: s)   // 다시 NEAR
        XCTAssertEqual(j.state, .near)
        r = step(j, 10_000 + 90_001 + 100_000, silent, gatt: link, settings: s)
        XCTAssertTrue(r.gatt)
        XCTAssertTrue(r.bleAvailable)
        XCTAssertTrue(r.reachable)
        XCTAssertEqual(r.rssiDbm, -100)
        XCTAssertEqual(r.thresholdDbm, -65)
        XCTAssertEqual(r.state, .far)

        // 기대하는 중이라도 광고가 들리면 광고가 판정한다 (-46 dBm 폰 앞에서 잠그던 버그)
        let heard = CoreBFix.adv(-46, tick: 300_000)
        r = step(j, 300_000, heard, gatt: link, settings: s)
        XCTAssertFalse(r.gatt)
        XCTAssertEqual(r.state, .near)

        // 이번 세션에 구독한 적이 있으면 유예와 무관하게 기대한다
        var lost = GattSnapshot()
        lost.running = true
        lost.everSubscribed = true
        var fresh = s
        fresh.monStartTick = 299_000
        r = step(j, 301_000, CoreBFix.adv(-100, tick: 300_000, receiving: false), gatt: lost, settings: fresh)
        XCTAssertTrue(r.gatt)
        XCTAssertEqual(r.state, .far)
    }

    /// BLE 를 쓸 수 없으면 Mac 은 unreachable (latency 경로 없음): FAR, "timeout".
    func testNoBleIsUnreachable() {
        let j = ProximityJudge()
        var r = step(j, 1_000, ScannerSnapshot())
        XCTAssertFalse(r.reachable)
        XCTAssertFalse(r.bleAvailable)
        XCTAssertEqual(r.state, .far)
        XCTAssertEqual(r.latencyMs, 0)
        XCTAssertEqual(r.rssiDbm, -100)

        // 스캔은 켜졌지만 등록된 폰의 첫 패킷 전
        var s = ScannerSnapshot()
        s.available = true
        r = step(j, 2_000, s)
        XCTAssertFalse(r.reachable)
        XCTAssertEqual(r.state, .far)
        XCTAssertEqual(Texts.listRow(r, nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 0),
                       ["09:00:00", "timeout", "\u{2591}\u{2591}\u{2591}\u{2591}\u{2591} 0", "-", "FAR", "-", "unreachable (err=0)"])
    }

    /// bleLostMeansFar=0: 수신이 끊기면 BLE 로 판단하지 않고, keepAlive 유예 뒤 FAR.
    func testLostNotFarUsesKeepAliveGrace() {
        let j = ProximityJudge()
        var s = CoreBFix.settings()
        s.bleLostMeansFar = false
        _ = step(j, 1_000, CoreBFix.adv(-50, tick: 1_000), settings: s)
        let quiet = CoreBFix.adv(-100, tick: 1_000, receiving: false)
        var r = step(j, 3_000, quiet, settings: s)
        XCTAssertFalse(r.bleAvailable)
        XCTAssertEqual(r.state, .near)
        XCTAssertEqual(r.timerRemainMs, 3_000)
        r = step(j, 5_999, quiet, settings: s)
        XCTAssertEqual(r.state, .near)
        r = step(j, 6_000, quiet, settings: s)
        XCTAssertEqual(r.state, .far)
    }

    func testTimerRemainFromKeepAlive() {
        let j = ProximityJudge()
        var r = step(j, 1_000, CoreBFix.adv(-50, tick: 1_000))
        XCTAssertEqual(r.timerRemainMs, 5_000)
        r = step(j, 4_000, CoreBFix.adv(-70, tick: 4_000))
        XCTAssertEqual(r.state, .near)
        XCTAssertEqual(r.timerRemainMs, 2_000)
        XCTAssertEqual(Texts.listRow(r, nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 0)[5], "2s")
    }

    /// 처음 구독을 본 판정만 알린다 (호출자가 저장과 로그를 한다).
    func testBecameGattSeenOnce() {
        let j = ProximityJudge()
        var s = CoreBFix.settings()
        s.gattSeen = false
        var g = GattSnapshot()
        g.running = true
        g.subscribed = true
        g.everSubscribed = true
        XCTAssertTrue(j.step(now: 1_000, scanner: ScannerSnapshot(), gatt: g, settings: s, timeStr: "").becameGattSeen)
        XCTAssertFalse(j.step(now: 2_000, scanner: ScannerSnapshot(), gatt: g, settings: s, timeStr: "").becameGattSeen)

        let k = ProximityJudge()
        s.gattSeen = true
        XCTAssertFalse(k.step(now: 1_000, scanner: ScannerSnapshot(), gatt: g, settings: s, timeStr: "").becameGattSeen)
    }

    func testStateNames() {
        XCTAssertEqual(ProxState.near.name, "NEAR")
        XCTAssertEqual(ProxState.far.name, "FAR")
    }
}

// MARK: - GuardEngine

final class CoreBGuardEngineTests: XCTestCase {
    private let t0 = CoreBFix.t0
    private var host = CoreBFakeHost()
    private var live = CoreBLive()

    private func makeEngine(idle: Int = 20, delay: Int = 0) -> GuardEngine {
        host = CoreBFakeHost()
        live = CoreBLive()
        let e = GuardEngine()
        e.host = host
        e.setIdle(idle)
        e.unlockDelaySec = delay
        e.keepAliveSec = 5
        let lv = live
        e.liveState = { (state: lv.state, lastNearTick: lv.lastNearTick) }
        e.logSink = { lv.lines.append($0) }
        return e
    }

    private func farTransition(_ e: GuardEngine, _ now: UInt64) {
        live.state = .far
        e.onResult(CoreBFix.result(.far, prev: .near), now: now)
    }

    private func nearResult(_ e: GuardEngine, _ now: UInt64, transition: Bool = true) {
        live.state = .near
        live.lastNearTick = now
        e.onResult(CoreBFix.result(.near, prev: transition ? .far : .near), now: now)
    }

    func testFarTransitionLocksAtOnce() {
        let e = makeEngine(idle: 20)
        e.start(now: t0)
        farTransition(e, t0 + 6_000)
        XCTAssertTrue(e.blackActive)
        XCTAssertFalse(e.manualLock)
        XCTAssertEqual(e.lockStartTick, t0 + 6_000)
        XCTAssertEqual(host.shows, 1)
        XCTAssertEqual(live.lines, ["BLACK ON  (idleCountdown=20)"])
        XCTAssertEqual(e.farEvents.count, 1)
        XCTAssertEqual(e.farEvents.first?.tick, t0 + 6_000)
    }

    /// 지연 d: NEAR 가 unlockTimer = d 를 걸고 틱마다 1 씩 줄어 0 에서 풀린다.
    func testUnlockDelay() {
        let e = makeEngine(idle: 20, delay: 10)
        e.start(now: t0)
        farTransition(e, t0 + 6_000)
        XCTAssertTrue(e.blackActive)
        nearResult(e, t0 + 8_000)
        XCTAssertTrue(e.blackActive)
        XCTAssertEqual(e.unlockTimer, 10)
        for i in 1...9 { e.tick(now: t0 + 8_000 + UInt64(i) * 1_000) }
        XCTAssertTrue(e.blackActive)
        XCTAssertEqual(e.unlockTimer, 1)
        XCTAssertEqual(Texts.countdownLabel(black: e.blackActive, unlockTimer: e.unlockTimer, manual: e.manualLock,
                                            near: true, countdown: e.nCountdown), "  잠금 - 1초 후 해제")
        e.tick(now: t0 + 18_000)
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(host.hides, 1)
        XCTAssertEqual(live.lines.last, "BLACK OFF (locked 12s, unlockTimer=0)")
        XCTAssertTrue(e.ovlInfo.hasPrefix("Lock "))
        XCTAssertTrue(e.ovlInfo.hasSuffix("(0m12s)"))
        XCTAssertEqual(e.nCountdown, 20)
    }

    /// FAR 결과는 기다리던 지연 해제를 취소하고, 다음 NEAR 가 d 부터 다시 센다.
    func testFarCancelsPendingUnlock() {
        let e = makeEngine(idle: 20, delay: 10)
        e.start(now: t0)
        farTransition(e, t0 + 6_000)
        nearResult(e, t0 + 7_000)
        e.tick(now: t0 + 8_000)
        e.tick(now: t0 + 9_000)
        XCTAssertEqual(e.unlockTimer, 8)
        farTransition(e, t0 + 9_500)
        XCTAssertEqual(e.unlockTimer, 0)
        XCTAssertTrue(e.blackActive)
        nearResult(e, t0 + 10_000)
        XCTAssertEqual(e.unlockTimer, 10)
        nearResult(e, t0 + 10_500, transition: false)     // 매 결과마다 보지만 이미 세는 중이면 그대로
        XCTAssertEqual(e.unlockTimer, 10)
    }

    func testDelayZeroUnlocksOnFirstNear() {
        let e = makeEngine(idle: 20, delay: 0)
        e.start(now: t0)
        farTransition(e, t0 + 6_000)
        nearResult(e, t0 + 8_000)
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(live.lines, ["BLACK ON  (idleCountdown=20)", "BLACK OFF (locked 2s, unlockTimer=0)"])
        XCTAssertFalse(e.ovlInfo.isEmpty)
        // 다음 입력이 셋째 줄을 지운다
        e.onInput(eventTick: t0 + 9_000, now: t0 + 9_000)
        XCTAssertEqual(e.ovlInfo, "")
    }

    /// 수동 잠금은 NEAR 로도 원격으로도 안 풀리고, 입력(잠금 뒤의)으로는 풀린다.
    func testManualLockNotReleasedByNearButByInput() {
        let e = makeEngine(idle: 20, delay: 0)
        e.start(now: t0)
        nearResult(e, t0 + 500)
        e.manualLockNow(now: t0 + 1_000)          // 입력 보호도 NEAR 도 안 본다
        XCTAssertTrue(e.blackActive)
        XCTAssertTrue(e.manualLock)
        XCTAssertEqual(host.shows, 1)
        XCTAssertEqual(live.lines, [])             // BLACK ON 줄을 남기지 않는다
        nearResult(e, t0 + 2_000, transition: false)
        XCTAssertTrue(e.blackActive)
        XCTAssertEqual(e.unlockTimer, 0)
        host.remote = true
        e.tick(now: t0 + 3_000)
        XCTAssertTrue(e.blackActive)
        host.remote = false
        XCTAssertEqual(Texts.countdownLabel(black: true, unlockTimer: 0, manual: true, near: true, countdown: 5),
                       "  직접 잠금 - [해제] 필요")
        XCTAssertEqual(Texts.simpleCard(monitoring: true, black: true, manual: true, near: true).subtitle,
                       "검은 화면의 [해제] 를 누르면 돌아와요")
        // 잠금을 건 그 클릭 (잠금보다 먼저 일어났고 뒤늦게 보고됨): 풀지 않는다
        e.onInput(eventTick: t0 + 995, now: t0 + 3_050)
        XCTAssertTrue(e.blackActive)
        // 잠금 뒤의 입력: 언제나 곧바로 푼다 (수동 잠금도)
        e.onInput(eventTick: t0 + 4_000, now: t0 + 4_000)
        XCTAssertFalse(e.blackActive)
        XCTAssertFalse(e.manualLock)
        XCTAssertEqual(live.lines, ["BLACK OFF (locked 3s, unlockTimer=0)"])
        XCTAssertEqual(e.ovlInfo, "")              // 입력으로 풀면 셋째 줄은 바로 지워진다
        XCTAssertEqual(e.lastInputTick, t0 + 4_000)
    }

    func testManualLockNeedsMonitoring() {
        let e = makeEngine()
        e.manualLockNow(now: t0)
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(host.shows, 0)
    }

    /// 입력 뒤 5 초 안에는 자동으로 잠그지 않는다. [시작] 도 입력이다.
    func testInputGuardFiveSeconds() {
        let e = makeEngine(idle: 20)
        e.start(now: t0)
        XCTAssertTrue(e.inputGuardActive(now: t0 + 4_999))
        XCTAssertFalse(e.inputGuardActive(now: t0 + 5_000))
        farTransition(e, t0 + 4_000)
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(live.lines, [])
        XCTAssertFalse(e.activate(now: t0 + 4_999))
        XCTAssertTrue(e.activate(now: t0 + 5_000))
    }

    /// 타이핑하며 떠난다: FAR 전환의 잠금은 거절되고, 마지막 입력 + max(idle, 5 s) 에 잠긴다.
    func testLeavingWhileTypingLocksFiveSecondsAfterLastInput() {
        let e = makeEngine(idle: 0)
        e.start(now: t0)
        e.onInput(eventTick: t0 + 10_000, now: t0 + 10_000)
        farTransition(e, t0 + 12_000)
        XCTAssertFalse(e.blackActive)
        e.tick(now: t0 + 13_000)
        e.tick(now: t0 + 14_000)
        XCTAssertFalse(e.blackActive)
        e.tick(now: t0 + 15_000)
        XCTAssertTrue(e.blackActive)
        XCTAssertEqual(live.lines, ["BLACK ON  (idleCountdown=0)"])
    }

    /// "바로"(0): FAR 이고 입력이 5 초 없으면 다음 틱에 잠긴다.
    func testIdleZeroLocksAfterFiveSecondsWithoutInput() {
        let e = makeEngine(idle: 0)
        e.start(now: t0)
        for s in 1...4 {
            e.tick(now: t0 + UInt64(s) * 1_000)
            XCTAssertFalse(e.blackActive)
            XCTAssertEqual(e.nCountdown, 0)
        }
        e.tick(now: t0 + 5_000)
        XCTAssertTrue(e.blackActive)
        XCTAssertEqual(live.lines, ["BLACK ON  (idleCountdown=0)"])
    }

    /// 한 번도 NEAR 가 아니었다 (폰 못 찾음, BT 꺼짐): 강제 경로 없이 유휴 시간 뒤에 잠긴다.
    func testNeverNearLocksAfterIdle() {
        let e = makeEngine(idle: 15)
        e.start(now: t0)
        for s in 1...14 { e.tick(now: t0 + UInt64(s) * 1_000) }
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(Texts.countdownLabel(black: false, unlockTimer: 0, manual: false, near: false, countdown: e.nCountdown),
                       "  1초 후 잠금")
        e.tick(now: t0 + 15_000)
        XCTAssertTrue(e.blackActive)
    }

    /// FAR 가 keepAlive + idle 보다 오래 이어지면 매 틱 카운트다운을 0 으로 당긴다.
    func testForceFarAfterKeepAlivePlusIdle() {
        let e = makeEngine(idle: 30)
        live.state = .far
        live.lastNearTick = t0
        e.start(now: t0)
        e.onInput(eventTick: t0 + 20_000, now: t0 + 20_000)
        XCTAssertEqual(e.nCountdown, 30)
        for s in 21...34 { e.tick(now: t0 + UInt64(s) * 1_000) }
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(e.nCountdown, 16)
        e.tick(now: t0 + 35_000)                  // 35 s = 5 + 30 since last NEAR
        XCTAssertTrue(e.blackActive)
        XCTAssertEqual(live.lines, ["BLACK ON  (idleCountdown=0)"])
    }

    /// NEAR 인 동안 관문은 잠그지 않고 카운트다운만 다시 채운다.
    func testNearNeverLocksAndRearmsCountdown() {
        let e = makeEngine(idle: 3)
        live.state = .near
        e.start(now: t0)
        for s in 1...4 { e.tick(now: t0 + UInt64(s) * 1_000) }
        XCTAssertEqual(e.nCountdown, 0)           // 입력 보호에 막혀 0 에 머문다
        e.tick(now: t0 + 5_000)
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(e.nCountdown, 3)
    }

    func testMeasuringBlocksAutoLockButNotManual() {
        let e = makeEngine(idle: 0)
        e.measuring = true
        e.start(now: t0)
        farTransition(e, t0 + 10_000)
        e.tick(now: t0 + 11_000)
        XCTAssertFalse(e.blackActive)
        e.manualLockNow(now: t0 + 12_000)
        XCTAssertTrue(e.blackActive)
    }

    func testRemoteSessionSkipLoggedOnceAndRemoteUnlock() {
        let e = makeEngine(idle: 0)
        e.start(now: t0)
        host.remote = true
        e.tick(now: t0 + 5_000)
        e.tick(now: t0 + 6_000)
        e.tick(now: t0 + 7_000)
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(live.lines, ["원격 세션이라 자동 잠금을 건너뛴다"])
        host.remote = false
        e.tick(now: t0 + 8_000)
        XCTAssertTrue(e.blackActive)
        host.remote = true
        e.tick(now: t0 + 9_000)
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(live.lines, ["원격 세션이라 자동 잠금을 건너뛴다",
                                    "BLACK ON  (idleCountdown=0)",
                                    "원격 세션이 감지되어 잠금을 푼다",
                                    "BLACK OFF (locked 1s, unlockTimer=0)"])
    }

    /// Q2: 입력으로 풀려 남은 unlockTimer 가 나중의 수동 잠금을 풀지 못한다.
    func testStaleUnlockTimerDoesNotReleaseManualLock() {
        let e = makeEngine(idle: 20, delay: 10)
        e.start(now: t0)
        farTransition(e, t0 + 6_000)
        nearResult(e, t0 + 7_000)
        XCTAssertEqual(e.unlockTimer, 10)
        e.onInput(eventTick: t0 + 8_000, now: t0 + 8_000)
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(e.unlockTimer, 10)           // Windows 처럼 해제 때는 안 지운다
        e.manualLockNow(now: t0 + 9_000)
        XCTAssertEqual(e.unlockTimer, 0)
        for s in 10...25 { e.tick(now: t0 + UInt64(s) * 1_000) }
        XCTAssertTrue(e.blackActive)
        XCTAssertTrue(e.manualLock)
    }

    /// Q6: 모니터링 중이 아니면 자동으로 잠그지 않고, 결과도 무시한다.
    func testNoAutoLockWithoutMonitoring() {
        let e = makeEngine(idle: 0)
        XCTAssertFalse(e.activate(now: t0 + 100_000))
        farTransition(e, t0 + 100_000)
        XCTAssertFalse(e.blackActive)
        XCTAssertTrue(e.farEvents.isEmpty)
        e.tick(now: t0 + 200_000)
        XCTAssertFalse(e.blackActive)
    }

    func testStopUnlocksAndStopsTicking() {
        let e = makeEngine(idle: 0)
        e.start(now: t0)
        e.manualLockNow(now: t0 + 1_000)
        e.stop(now: t0 + 4_000)
        XCTAssertFalse(e.monitoring)
        XCTAssertFalse(e.blackActive)
        XCTAssertEqual(live.lines, ["BLACK OFF (locked 3s, unlockTimer=0)"])
        e.tick(now: t0 + 20_000)
        XCTAssertFalse(e.blackActive)
    }

    func testFarEventsPrunedAfterThirtyMinutes() {
        let e = makeEngine()
        e.start(now: t0)
        farTransition(e, t0 + 1_000)
        farTransition(e, t0 + 1_000 + 1_800_001)
        XCTAssertEqual(e.farEvents.count, 1)
        XCTAssertEqual(e.farEvents.first?.tick, t0 + 1_000 + 1_800_001)
        e.clearFarEvents()
        XCTAssertTrue(e.farEvents.isEmpty)
    }

    /// Q1: 잠근 시각은 지역 시각으로 (지금 - 잠긴 시간).
    func testDeactivateWritesCorrectLockTime() throws {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 10; dc.day = 1; dc.hour = 14; dc.minute = 9; dc.second = 0
        let unlock = try XCTUnwrap(Calendar.current.date(from: dc))
        let e = makeEngine()
        e.start(now: t0)
        e.manualLockNow(now: t0 + 1_000)
        e.deactivate(now: t0 + 1_000 + 423_500, wall: unlock)
        XCTAssertEqual(e.ovlInfo, "Lock 14:01 -> Unlock 14:09 (7m03s)")
        XCTAssertEqual(live.lines, ["BLACK OFF (locked 423s, unlockTimer=0)"])
    }
}

// MARK: - Texts

final class CoreBTextsTests: XCTestCase {
    private func bleResult(_ state: ProxState, prev: ProxState, rssi: Int, gatt: Bool = false, remainMs: UInt32 = 0) -> ProbeResult {
        var r = ProbeResult()
        r.state = state
        r.prevState = prev
        r.rssiDbm = rssi
        r.gatt = gatt
        r.bleAvailable = true
        r.reachable = true
        r.timerRemainMs = remainMs
        r.timeStr = "14:02:03"
        return r
    }

    func testStatusBar() {
        let r = bleResult(.near, prev: .near, rssi: -58)
        XCTAssertEqual(Texts.statusBar(r, targetName: "등록된 폰", packetRate: 0.6, nearThr: -67, gattThr: -61,
                                       idSt: "토큰", gattSt: "linked", countdown: 15),
                       "  \"등록된 폰\"  |  NEAR  |  RSSI: -58 dBm  |  0.6/s  |  Near>=-67 dBm  |  ID: 토큰  |  GATT: linked  |  Idle: 15s")
        let g = bleResult(.near, prev: .near, rssi: -58, gatt: true)
        XCTAssertEqual(Texts.statusBar(g, targetName: "등록된 폰", packetRate: 0, nearThr: -67, gattThr: -61,
                                       idSt: "토큰", gattSt: "linked", countdown: 15),
                       "  \"등록된 폰\"  |  NEAR  |  RSSI: -58 dBm (GATT)  |  0.0/s  |  Near>=-61 dBm  |  ID: 토큰  |  GATT: linked  |  Idle: 15s")
        var u = ProbeResult()
        u.state = .far
        XCTAssertEqual(Texts.statusBar(u, targetName: "등록된 폰", packetRate: 2.0, nearThr: -65, gattThr: -65,
                                       idSt: "토큰 대기", gattSt: "off", countdown: 30),
                       "  \"등록된 폰\"  |  FAR  |  Latency: 0 ms  |  BLE: N/A  |  ID: 토큰 대기  |  GATT: off  |  Idle: 30s")
        let long = Texts.statusBar(r, targetName: String(repeating: "a", count: 400), packetRate: 1, nearThr: -65,
                                   gattThr: -65, idSt: "없음!", gattSt: "waiting", countdown: 1)
        XCTAssertEqual(long.utf16.count, 299)
        XCTAssertTrue(long.hasPrefix("  \"aaaa"))
    }

    func testStatusParts() {
        XCTAssertEqual(Texts.idStatus(hasToken: false, bound: false), "없음!")
        XCTAssertEqual(Texts.idStatus(hasToken: false, bound: true), "없음!")
        XCTAssertEqual(Texts.idStatus(hasToken: true, bound: false), "토큰 대기")
        XCTAssertEqual(Texts.idStatus(hasToken: true, bound: true), "토큰")
        XCTAssertEqual(Texts.gattStatus(running: false, subscribed: true), "off")
        XCTAssertEqual(Texts.gattStatus(running: true, subscribed: true), "linked")
        XCTAssertEqual(Texts.gattStatus(running: true, subscribed: false), "waiting")
        XCTAssertEqual(Texts.statusInitial, "  기기를 선택하고 시작을 누르세요")
        XCTAssertEqual(Texts.stateLabelStopped, "  정지됨")
    }

    func testStateLabel() {
        XCTAssertEqual(Texts.stateLabel(bleResult(.near, prev: .far, rssi: -50), countdown: 15), "  근처   (유휴: 15s)")
        XCTAssertEqual(Texts.stateLabel(bleResult(.far, prev: .far, rssi: -100), countdown: 15), "  멀리  (폰 신호 없음 - 앱 확인)")
        XCTAssertEqual(Texts.stateLabel(bleResult(.far, prev: .far, rssi: -80), countdown: 15), "  멀리")
        var u = ProbeResult()
        u.rssiDbm = -100      // BLE 아님: "앱 확인" 이 아니다
        XCTAssertEqual(Texts.stateLabel(u, countdown: 1), "  멀리")
    }

    func testListRows() {
        let bar4 = "\u{2588}\u{2588}\u{2588}\u{2588}\u{2591} 4"
        XCTAssertEqual(Texts.listRow(bleResult(.near, prev: .far, rssi: -58, remainMs: 5_000),
                                     nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 0),
                       ["14:02:03", "-58 dBm", bar4, "~2-5m", "NEAR", "5s", ">>> ENTERED NEAR (-58 dBm) <<<"])
        XCTAssertEqual(Texts.listRow(bleResult(.near, prev: .far, rssi: -44, gatt: true, remainMs: 5_000),
                                     nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 0),
                       ["14:02:03", "-44 dBm G", "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588} 5", "< 1m", "NEAR", "5s",
                        ">>> ENTERED NEAR (-44 dBm GATT) <<<"])
        XCTAssertEqual(Texts.listRow(bleResult(.far, prev: .near, rssi: -72), nearThr: -65, gattThr: -65, nearLatencyMs: 200,
                                     inWarmup: false, fails: 0)[6], "<<< LEFT NEAR ZONE >>>")
        XCTAssertEqual(Texts.listRow(bleResult(.near, prev: .near, rssi: -60, remainMs: 3_500), nearThr: -65, gattThr: -65,
                                     nearLatencyMs: 200, inWarmup: false, fails: 0)[6], "near (-60 dBm, reset 3s)")
        XCTAssertEqual(Texts.listRow(bleResult(.near, prev: .near, rssi: -66, remainMs: 3_500), nearThr: -65, gattThr: -65,
                                     nearLatencyMs: 200, inWarmup: false, fails: 0)[6], "near (weak -66 dBm, 3s)")
        XCTAssertEqual(Texts.listRow(bleResult(.near, prev: .near, rssi: -70), nearThr: -65, gattThr: -65,
                                     nearLatencyMs: 200, inWarmup: true, fails: 0)[6], "near (warmup, -70 dBm)")
        let lost = Texts.listRow(bleResult(.far, prev: .far, rssi: -100), nearThr: -65, gattThr: -65, nearLatencyMs: 200,
                                 inWarmup: false, fails: 0)
        XCTAssertEqual(lost, ["14:02:03", "-100 dBm", "\u{2591}\u{2591}\u{2591}\u{2591}\u{2591} 0", "> 15m", "FAR", "-",
                              "far (BLE lost)"])
        XCTAssertEqual(Texts.listRow(bleResult(.far, prev: .far, rssi: -86), nearThr: -65, gattThr: -65, nearLatencyMs: 200,
                                     inWarmup: false, fails: 0)[6], "far (-86 dBm)")

        var u = ProbeResult()
        u.timeStr = "14:02:03"
        u.wsaError = 10060
        XCTAssertEqual(Texts.listRow(u, nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 5)[6],
                       "unreachable - reconnecting... (fail=5)")
        XCTAssertEqual(Texts.listRow(u, nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 3)[6],
                       "unreachable (fail=3, err=10060)")

        var lat = ProbeResult()
        lat.timeStr = "14:02:03"
        lat.reachable = true
        lat.latencyMs = 120
        lat.state = .near
        lat.prevState = .far
        lat.timerRemainMs = 5_000
        XCTAssertEqual(Texts.listRow(lat, nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 0),
                       ["14:02:03", "120 ms", bar4, "< 1m", "NEAR", "5s", ">>> ENTERED NEAR (120ms) <<<"])
        lat.prevState = .near
        XCTAssertEqual(Texts.listRow(lat, nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 0)[6],
                       "near (reset 5s, 120ms)")
        lat.latencyMs = 450
        XCTAssertEqual(Texts.listRow(lat, nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 0)[6],
                       "near (weak 450ms, 5s)")
        lat.state = .far
        lat.prevState = .far
        XCTAssertEqual(Texts.listRow(lat, nearThr: -65, gattThr: -65, nearLatencyMs: 200, inWarmup: false, fails: 0),
                       ["14:02:03", "450 ms", "\u{2588}\u{2588}\u{2588}\u{2591}\u{2591} 3", "~2-3m", "FAR", "-", "far (450ms)"])
    }

    /// 행은 그 경로의 설정값으로 잰다: 재보기가 차이 -12 를 재서 광고 -47, 연결 -59 일 때
    /// 연결 -55 는 멀쩡한 NEAR 이고 (판정·상태바와 같다), 같은 값의 광고 행은 "weak" 이다.
    func testListRowUsesItsPathThreshold() {
        let gattRow = Texts.listRow(bleResult(.near, prev: .near, rssi: -55, gatt: true, remainMs: 5_000),
                                    nearThr: -47, gattThr: -59, nearLatencyMs: 200, inWarmup: false, fails: 0)
        XCTAssertEqual(gattRow[1], "-55 dBm G")
        XCTAssertEqual(gattRow[6], "near (-55 dBm, reset 5s)")
        XCTAssertEqual(Texts.listRow(bleResult(.near, prev: .near, rssi: -55, remainMs: 5_000),
                                     nearThr: -47, gattThr: -59, nearLatencyMs: 200, inWarmup: false, fails: 0)[6],
                       "near (weak -55 dBm, 5s)")
        XCTAssertEqual(Texts.listRow(bleResult(.near, prev: .near, rssi: -61, gatt: true, remainMs: 5_000),
                                     nearThr: -47, gattThr: -59, nearLatencyMs: 200, inWarmup: false, fails: 0)[6],
                       "near (weak -61 dBm, 5s)")
        // 같은 숫자를 가진 상태바와 한 경로를 본다
        XCTAssertTrue(Texts.statusBar(bleResult(.near, prev: .near, rssi: -55, gatt: true), targetName: "p", packetRate: 1,
                                      nearThr: -47, gattThr: -59, idSt: "토큰", gattSt: "linked", countdown: 1)
                        .contains("Near>=-59 dBm"))
    }

    func testLevelsAndDistances() {
        XCTAssertEqual(Texts.rssiToLevel(-50, receiving: true), 5)
        XCTAssertEqual(Texts.rssiToLevel(-51, receiving: true), 4)
        XCTAssertEqual(Texts.rssiToLevel(-60, receiving: true), 4)
        XCTAssertEqual(Texts.rssiToLevel(-70, receiving: true), 3)
        XCTAssertEqual(Texts.rssiToLevel(-80, receiving: true), 2)
        XCTAssertEqual(Texts.rssiToLevel(-81, receiving: true), 1)
        XCTAssertEqual(Texts.rssiToLevel(-100, receiving: true), 0)
        XCTAssertEqual(Texts.rssiToLevel(-40, receiving: false), 0)
        XCTAssertEqual(Texts.levelBar(2), "\u{2588}\u{2588}\u{2591}\u{2591}\u{2591}")
        XCTAssertEqual(Texts.levelBar(1), "\u{2588}\u{2591}\u{2591}\u{2591}\u{2591}")
        XCTAssertEqual(Texts.levelBar(9), "\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}")
        XCTAssertEqual(Texts.rssiToDist(-45), "< 1m")
        XCTAssertEqual(Texts.rssiToDist(-55), "~1-2m")
        XCTAssertEqual(Texts.rssiToDist(-65), "~2-5m")
        XCTAssertEqual(Texts.rssiToDist(-75), "~5-10m")
        XCTAssertEqual(Texts.rssiToDist(-85), "~10-15m")
        XCTAssertEqual(Texts.rssiToDist(-86), "> 15m")
        XCTAssertEqual(Texts.latencyToDist(149), "< 1m")
        XCTAssertEqual(Texts.latencyToDist(299), "~1-2m")
        XCTAssertEqual(Texts.latencyToDist(499), "~2-3m")
        XCTAssertEqual(Texts.latencyToDist(999), "~3-5m")
        XCTAssertEqual(Texts.latencyToDist(1999), "~5-10m")
        XCTAssertEqual(Texts.latencyToDist(2000), "> 10m")
    }

    func testCountdownLabel() {
        XCTAssertEqual(Texts.countdownLabel(black: true, unlockTimer: 7, manual: true, near: true, countdown: 3), "  잠금 - 7초 후 해제")
        XCTAssertEqual(Texts.countdownLabel(black: true, unlockTimer: 0, manual: true, near: true, countdown: 3), "  직접 잠금 - [해제] 필요")
        XCTAssertEqual(Texts.countdownLabel(black: true, unlockTimer: 0, manual: false, near: true, countdown: 3), "  잠금 중")
        XCTAssertEqual(Texts.countdownLabel(black: false, unlockTimer: 5, manual: false, near: true, countdown: 3), "  보호 중")
        XCTAssertEqual(Texts.countdownLabel(black: false, unlockTimer: 0, manual: false, near: false, countdown: 12), "  12초 후 잠금")
    }

    func testOverlayLines() {
        XCTAssertEqual(Texts.overlayLine1(monitoring: true, targetName: "등록된 폰"), "\u{25A3} 등록된 폰")
        XCTAssertEqual(Texts.overlayLine1(monitoring: false, targetName: "등록된 폰"), "\u{25A3} SmartScreen")
        XCTAssertEqual(Texts.overlayLine1(monitoring: true, targetName: ""), "\u{25A3} SmartScreen")
        XCTAssertEqual(Texts.overlayLine1(monitoring: true, targetName: String(repeating: "b", count: 300)).utf16.count, 63)
        // 서로게이트 쌍은 쪼개지 않는다
        let emoji = Texts.overlayLine1(monitoring: true, targetName: String(repeating: "\u{1F600}", count: 40))
        XCTAssertEqual(emoji.utf16.count, 62)
        XCTAssertFalse(emoji.contains("\u{FFFD}"))

        var l = Texts.overlayLine2(monitoring: false, black: true, unlockTimer: 3, manual: true, near: true, countdown: 9)
        XCTAssertEqual(l.text, "정지됨")
        XCTAssertEqual(l.color, RGB(128, 128, 128))
        l = Texts.overlayLine2(monitoring: true, black: true, unlockTimer: 3, manual: true, near: true, countdown: 9)
        XCTAssertEqual(l.text, "잠금  \u{2022}  3초 후 해제")
        XCTAssertEqual(l.color, RGB(235, 70, 70))
        l = Texts.overlayLine2(monitoring: true, black: true, unlockTimer: 0, manual: true, near: true, countdown: 9)
        XCTAssertEqual(l.text, "잠금  \u{2022}  [해제] 를 눌러야 풀립니다")
        l = Texts.overlayLine2(monitoring: true, black: true, unlockTimer: 0, manual: false, near: true, countdown: 9)
        XCTAssertEqual(l.text, "잠금")
        XCTAssertEqual(l.color, RGB(235, 70, 70))
        l = Texts.overlayLine2(monitoring: true, black: false, unlockTimer: 0, manual: false, near: true, countdown: 9)
        XCTAssertEqual(l.text, "근처  \u{2022}  보호 중")
        XCTAssertEqual(l.color, RGB(60, 210, 90))
        l = Texts.overlayLine2(monitoring: true, black: false, unlockTimer: 0, manual: false, near: false, countdown: 9)
        XCTAssertEqual(l.text, "멀리  \u{2022}  9초")
        XCTAssertEqual(l.color, RGB(240, 170, 50))
    }

    func testSimpleCard() {
        var c = Texts.simpleCard(monitoring: false, black: true, manual: true, near: true)
        XCTAssertEqual(c.title, "꺼져 있어요")
        XCTAssertEqual(c.subtitle, "아래 [보호 꺼짐] 을 누르면 시작해요")
        XCTAssertEqual(c.color, RGB(120, 120, 120))
        c = Texts.simpleCard(monitoring: true, black: true, manual: false, near: true)
        XCTAssertEqual(c.title, "화면을 가리는 중")
        XCTAssertEqual(c.subtitle, "폰이 돌아오면 저절로 풀려요")
        XCTAssertEqual(c.color, RGB(200, 60, 60))
        c = Texts.simpleCard(monitoring: true, black: false, manual: false, near: true)
        XCTAssertEqual(c.title, "지키는 중")
        XCTAssertEqual(c.subtitle, "자리를 비우면 화면을 가려요")
        XCTAssertEqual(c.color, RGB(46, 160, 67))
        c = Texts.simpleCard(monitoring: true, black: false, manual: false, near: false)
        XCTAssertEqual(c.title, "폰이 안 보여요")
        XCTAssertEqual(c.subtitle, "곧 화면을 가릴 거예요")
        XCTAssertEqual(c.color, RGB(230, 145, 40))
    }

    func testOvlInfo() throws {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 10; dc.day = 1; dc.hour = 9; dc.minute = 5; dc.second = 30
        let unlock = try XCTUnwrap(Calendar.current.date(from: dc))
        XCTAssertEqual(Texts.ovlInfo(lock: unlock.addingTimeInterval(-3_725), unlock: unlock, durationSec: 3_725),
                       "Lock 08:03 -> Unlock 09:05 (62m05s)")
        XCTAssertEqual(Texts.ovlInfo(lock: unlock, unlock: unlock, durationSec: 0), "Lock 09:05 -> Unlock 09:05 (0m00s)")
    }

    func testParseThresholdField() {
        XCTAssertEqual(Texts.parseThresholdField(""), -30)
        XCTAssertEqual(Texts.parseThresholdField("abc"), -30)
        XCTAssertEqual(Texts.parseThresholdField("67"), -67)
        XCTAssertEqual(Texts.parseThresholdField("-67"), -67)
        XCTAssertEqual(Texts.parseThresholdField("+80"), -80)
        XCTAssertEqual(Texts.parseThresholdField("  -70dBm"), -70)
        XCTAssertEqual(Texts.parseThresholdField("-20"), -30)
        XCTAssertEqual(Texts.parseThresholdField("-120"), -100)
        XCTAssertEqual(Texts.parseThresholdField("99999999999999999999"), -100)
        XCTAssertEqual(Texts.parseThresholdField("- 5"), -30)
    }

    func testComboFindValueTiesGoToLowerIndex() {
        let idle = Choices.idleValues
        XCTAssertEqual(Texts.comboFindValue(idle, 20), 1)     // config 기본 20 → 15초
        XCTAssertEqual(Texts.comboFindValue(idle, 45), 2)     // 30 과 60 이 같다 → 앞 칸 30
        XCTAssertEqual(Texts.comboFindValue(idle, 90), 3)     // 60 과 120 이 같다 → 60
        XCTAssertEqual(Texts.comboFindValue(idle, 0), 0)
        XCTAssertEqual(Texts.comboFindValue(idle, 500), 4)
        XCTAssertEqual(Texts.comboFindValue(Choices.delayValues, 20), 1)   // 10 과 30 이 같다 → 10초
        XCTAssertEqual(Texts.comboFindValue(Choices.delayValues, -5), 0)
        XCTAssertEqual(Texts.comboFindValue([], 5), 0)
    }

    func testPhoneEntryAndPaths() {
        XCTAssertEqual(Texts.tokenPrefix("0123456789ABCDEF0123456789ABCDEF"), "01234567")
        XCTAssertEqual(Texts.tokenPrefix("ABC"), "ABC")
        XCTAssertEqual(Texts.phoneEntry(token: "A1B2C3D4E5F60718293A4B5C6D7E8F90"), "등록된 폰  [토큰 A1B2C3D4]")
        XCTAssertEqual(Choices.registeredPhoneName, "등록된 폰")
        XCTAssertEqual(Texts.truncPath("/a/b.png"), "/a/b.png")
        let long = "/Users/kim/" + String(repeating: "x", count: 40) + ".png"
        let t = Texts.truncPath(long)
        XCTAssertEqual(t.utf16.count, 35)
        XCTAssertTrue(t.hasPrefix("..."))
        XCTAssertTrue(t.hasSuffix("xx.png"))
        XCTAssertEqual(Texts.truncPath(String(repeating: "y", count: 35)), String(repeating: "y", count: 35))
    }
}

// MARK: - Choices

final class CoreBChoicesTests: XCTestCase {
    func testTables() {
        XCTAssertEqual(Choices.idleValues, [0, 15, 30, 60, 120])
        XCTAssertEqual(Choices.idleLabels, ["바로", "15초", "30초", "1분", "2분"])
        XCTAssertEqual(Choices.idleDefaultIndex, 2)
        XCTAssertEqual(Choices.delayValues, [0, 10, 30, 60])
        XCTAssertEqual(Choices.delayLabels, ["즉시", "10초", "30초", "1분"])
        XCTAssertEqual(Choices.simpleIdle, [0, 15, 30, 60])
        XCTAssertEqual(Choices.simpleIdleLabels, ["바로", "15초", "30초", "1분"])
        // 간단 창이 고르는 값은 전부 고급 창 콤보에 있어야 한다 (없으면 다음 [시작] 이 되돌린다)
        for v in Choices.simpleIdle { XCTAssertTrue(Choices.idleValues.contains(v)) }
    }

    func testDistBaseAndValue() {
        XCTAssertEqual(Choices.distBase(measured: 0), -64)
        XCTAssertEqual(Choices.distBase(measured: -67), -67)
        XCTAssertEqual(Choices.distValue(base: -67, step: 0), -61)
        XCTAssertEqual(Choices.distValue(base: -67, step: 1), -67)
        XCTAssertEqual(Choices.distValue(base: -67, step: 2), -73)
    }

    func testDistStepTiesGoToLowerIndex() {
        XCTAssertEqual(Choices.distStep(base: -64, threshold: -65), 1)   // 기본값: 보통
        XCTAssertEqual(Choices.distStep(base: -64, threshold: -67), 1)   // -64 와 -70 이 3 으로 같다 → 보통
        XCTAssertEqual(Choices.distStep(base: -64, threshold: -61), 0)   // -58 과 -64 가 3 으로 같다 → 가까이
        XCTAssertEqual(Choices.distStep(base: -64, threshold: -100), 2)
        XCTAssertEqual(Choices.distStep(base: -67, threshold: -61), 0)
        XCTAssertEqual(Choices.distStep(base: -67, threshold: -73), 2)
    }

    func testGattThresholdFollowsNearByOffset() {
        XCTAssertEqual(Choices.gattOffsetMin, -40)
        XCTAssertEqual(Choices.gattOffsetMax, 40)
        // 차이 0 (예전 config, 아직 안 잼): 두 경로가 같은 값 - 1.1.6 ~ 1.1.9 와 같다
        XCTAssertEqual(Choices.gattThreshold(near: -64, offset: 0), -64)
        XCTAssertEqual(Choices.gattThreshold(near: -59, offset: 0), -59)
        // M1 맥북: 광고 기준 -47, 연결이 12 dB 낮다 → 연결 -59
        XCTAssertEqual(Choices.gattThreshold(near: -47, offset: -12), -59)
        XCTAssertEqual(Choices.gattThreshold(near: -41, offset: -12), -53)    // 슬라이더 "가까이"
        XCTAssertEqual(Choices.gattThreshold(near: -60, offset: 5), -55)
        // [-100, -30] 으로 자른다 ("신호 강도" 칸과 같은 범위)
        XCTAssertEqual(Choices.gattThreshold(near: -95, offset: -15), -100)
        XCTAssertEqual(Choices.gattThreshold(near: -100, offset: -40), -100)
        XCTAssertEqual(Choices.gattThreshold(near: -85, offset: -15), -100)
        XCTAssertEqual(Choices.gattThreshold(near: -84, offset: -15), -99)
        XCTAssertEqual(Choices.gattThreshold(near: -35, offset: 10), -30)
        XCTAssertEqual(Choices.gattThreshold(near: -30, offset: 40), -30)
        XCTAssertEqual(Choices.gattThreshold(near: -31, offset: 1), -30)
        XCTAssertEqual(Choices.gattThreshold(near: -32, offset: 1), -31)
    }

    func testDistLogLine() {
        XCTAssertEqual(Texts.distLogLine(step: 1, near: -47, gatt: -59), "간단 화면: 거리 2단계 -> -47 dBm (연결 -59 dBm)")
        XCTAssertEqual(Texts.distLogLine(step: 0, near: -58, gatt: -58), "간단 화면: 거리 1단계 -> -58 dBm (연결 -58 dBm)")
        XCTAssertEqual(Texts.distLogLine(step: 2, near: -70, gatt: -65), "간단 화면: 거리 3단계 -> -70 dBm (연결 -65 dBm)")
    }
}

// MARK: - WizardJudge

final class CoreBWizardJudgeTests: XCTestCase {
    // 광고 신호가 되는 한 벌: 착석 -60..-50 (22개), 비움 -80..-63 (9개) → 기준 -62
    private let advSeated = Array(-60 ... -50) + Array(-60 ... -50)
    private let advAway = [-80, -70, -63, -75, -66, -71, -79, -68, -77]
    // 연결 신호가 되는 한 벌: 착석 -75..-66 (20개), 비움 -90..-80 (8개) → 연결 기준 -77
    private let gattSeated = Array(-75 ... -66) + Array(-75 ... -66)
    private let gattAway = [-90, -85, -80, -88, -82, -86, -84, -81]

    /// 연결 신호를 아예 못 받았을 때 (폰 앱이 다른 PC 에 붙어 있었다)
    private func judgeAdvOnly(_ seated: [Int], _ away: [Int], offset: Int = 0) -> WizardVerdict {
        return WizardJudge.judge(seated: seated, away: away, gattSeated: [], gattAway: [], currentGattOffset: offset)
    }

    private let doneTail = "\n\n이 자리에 맞게 \"보통\" 을 맞췄어요. \"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다."

    // MARK: 광고가 실패하면 연결 신호는 보지 않는다 (글과 로그는 예전 그대로)

    func testTooFew() {
        let v = judgeAdvOnly(Array(repeating: -55, count: 14), Array(repeating: -80, count: 8))
        XCTAssertFalse(v.ok)
        XCTAssertEqual(v.title, "신호를 거의 못 받았어요")
        XCTAssertEqual(v.body, "앉아 있을 때 14번, 비웠을 때 8번밖에 못 받았어요.\n\n폰에서 SSBeacon 앱이 켜져 있는지, 그리고 이 컴퓨터의 블루투스가 켜져 있는지 확인해 주세요.")
        XCTAssertEqual(v.logLine, "재보기: 표본 부족 (착석 14, 비움 8)")
        let empty = judgeAdvOnly([], [])
        XCTAssertEqual(empty.logLine, "재보기: 표본 부족 (착석 0, 비움 0)")
        XCTAssertEqual(judgeAdvOnly(Array(-60 ... -50) + Array(-60 ... -50), Array(repeating: -80, count: 7)).logLine,
                       "재보기: 표본 부족 (착석 22, 비움 7)")

        // 연결 신호가 아무리 좋아도 광고가 모자라면 실패다. 차이는 저장하지 않는다.
        let g = WizardJudge.judge(seated: Array(repeating: -55, count: 14), away: Array(repeating: -80, count: 8),
                                  gattSeated: gattSeated, gattAway: gattAway, currentGattOffset: -12)
        XCTAssertFalse(g.ok)
        XCTAssertNil(g.gatt)
        XCTAssertEqual(g.gattOffset, 0)
        XCTAssertEqual(g.base, 0)
        XCTAssertEqual(g.title, v.title)
        XCTAssertEqual(g.body, v.body)
        XCTAssertEqual(g.logLine, v.logLine)
    }

    func testFlatAdapter() {
        var seated: [Int] = []
        for i in 0..<20 { seated.append(i % 2 == 0 ? -60 : -61) }
        let v = judgeAdvOnly(seated, Array(repeating: -90, count: 10))
        XCTAssertFalse(v.ok)
        XCTAssertEqual(v.title, "이 블루투스 장치는 세기를 못 재요")
        XCTAssertEqual(v.body, "1분 동안 20번을 받았는데 값이 -61 dBm 에서 거의 움직이지 않았어요.\n\n진짜로 재는 장치라면 가만히 있어도 값이 몇 칸은 흔들립니다. 이 장치는 신호 세기를 흉내만 내고 있어서 거리로 쓸 수 없어요.\n\n다른 블루투스 동글로 바꾸는 게 좋습니다.")
        XCTAssertEqual(v.logLine, "재보기: 어댑터가 세기를 안 낸다 (착석 20개, -61..-60 dBm)")

        let g = WizardJudge.judge(seated: seated, away: Array(repeating: -90, count: 10),
                                  gattSeated: gattSeated, gattAway: gattAway, currentGattOffset: 5)
        XCTAssertFalse(g.ok)
        XCTAssertNil(g.gatt)
        XCTAssertEqual(g.gattOffset, 0)
        XCTAssertEqual(g.title, v.title)
        XCTAssertEqual(g.body, v.body)
        XCTAssertEqual(g.logLine, v.logLine)
    }

    func testFlatGattIsNotAnAdapterFailure() {
        // 연결 신호에는 어댑터 검사가 없다 - 폰이 잰 값이다. 1 dB 안에서만 흔들려도 쓴다.
        var gs: [Int] = []
        for i in 0..<20 { gs.append(i % 2 == 0 ? -70 : -71) }
        let v = WizardJudge.judge(seated: advSeated, away: advAway, gattSeated: gs, gattAway: gattAway,
                                  currentGattOffset: 0)
        XCTAssertTrue(v.ok)
        XCTAssertEqual(v.gatt, .measured)
        XCTAssertEqual(v.gattOffset, -11)             // (-71 - 2) - (-62)
    }

    func testOverlap() {
        let seated = Array(-60 ... -50)  + Array(-60 ... -50)
        let away = [-80, -70, -62, -75, -66, -71, -79, -68]
        let v = judgeAdvOnly(seated, away)
        XCTAssertFalse(v.ok)
        XCTAssertEqual(v.title, "앉아 있을 때와 비울 때가 구분되지 않아요")
        XCTAssertEqual(v.body, "앉아 있을 때 -60~-50, 비웠을 때 -80~-62 로 겹칩니다.\n\n폰을 둔 곳이 책상과 너무 가까웠어요. 더 멀리 두고 다시 해 보세요.")
        XCTAssertEqual(v.logLine, "재보기: 구간이 겹친다 (착석 -60..-50, 비움 -80..-62)")

        let g = WizardJudge.judge(seated: seated, away: away,
                                  gattSeated: gattSeated, gattAway: gattAway, currentGattOffset: -12)
        XCTAssertFalse(g.ok)
        XCTAssertNil(g.gatt)
        XCTAssertEqual(g.gattOffset, 0)
        XCTAssertEqual(g.title, v.title)
        XCTAssertEqual(g.body, v.body)
        XCTAssertEqual(g.logLine, v.logLine)
    }

    // MARK: 광고가 되면 연결 신호로 차이를 정한다

    func testDoneGattMeasured() {
        let v = WizardJudge.judge(seated: advSeated, away: advAway, gattSeated: gattSeated, gattAway: gattAway,
                                  currentGattOffset: 7)
        XCTAssertTrue(v.ok)
        XCTAssertEqual(v.base, -62)
        XCTAssertEqual(v.gatt, .measured)
        XCTAssertEqual(v.gattOffset, -15)            // (-75 - 2) - (-62). 지금 값 7 은 버린다
        XCTAssertEqual(v.title, "다 됐어요")
        XCTAssertEqual(v.body, "광고 신호\n  앉아 있을 때  -60 ~ -50\n  자리 비웠을 때  -80 ~ -63\n연결 신호\n  앉아 있을 때  -75 ~ -66\n  자리 비웠을 때  -90 ~ -80\n\n이 자리에 맞게 \"보통\" 을 맞췄어요. \"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다.")
        XCTAssertEqual(v.logLine, "재보기: 착석 -60..-50 (22개), 비움 -80..-63 (9개) -> 기준 -62 dBm; 연결 착석 -75..-66 (20개), 비움 -90..-80 (8개) -> 차이 -15 dB")
        XCTAssertTrue(v.body.hasSuffix(doneTail))
    }

    func testDoneGattMeasuredSigns() {
        // 연결이 광고보다 세면 + 로, 같으면 +0 으로 적는다 (C 의 %+d)
        let up = WizardJudge.judge(seated: advSeated, away: advAway,
                                   gattSeated: Array(-55 ... -45) + Array(-55 ... -45), gattAway: gattAway,
                                   currentGattOffset: -12)
        XCTAssertEqual(up.gatt, .measured)
        XCTAssertEqual(up.gattOffset, 5)
        XCTAssertTrue(up.logLine.hasSuffix("; 연결 착석 -55..-45 (22개), 비움 -90..-80 (8개) -> 차이 +5 dB"), up.logLine)

        let same = WizardJudge.judge(seated: advSeated, away: advAway, gattSeated: advSeated, gattAway: advAway,
                                     currentGattOffset: -12)
        XCTAssertEqual(same.gatt, .measured)
        XCTAssertEqual(same.gattOffset, 0)
        XCTAssertEqual(same.logLine, "재보기: 착석 -60..-50 (22개), 비움 -80..-63 (9개) -> 기준 -62 dBm; 연결 착석 -60..-50 (22개), 비움 -80..-63 (9개) -> 차이 +0 dB")
        XCTAssertEqual(same.body, "광고 신호\n  앉아 있을 때  -60 ~ -50\n  자리 비웠을 때  -80 ~ -63\n연결 신호\n  앉아 있을 때  -60 ~ -50\n  자리 비웠을 때  -80 ~ -63\n\n이 자리에 맞게 \"보통\" 을 맞췄어요. \"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다.")
    }

    func testMacBookCase() {
        // M1 맥북에서 같은 순간 광고 -41 / 연결 -58. 연결로 잰 기준이 -59 였다 (2026-10-01).
        let advS = Array(-45 ... -38) + Array(-45 ... -38)          // 16 개
        let advA = [-56, -54, -50, -52, -55, -51, -53, -56]         // 8 개
        let gS = Array(-57 ... -51) + Array(-57 ... -51) + [-55]    // 15 개
        let gA = [-69, -67, -65, -66, -68, -69, -65, -66]           // 8 개
        let v = WizardJudge.judge(seated: advS, away: advA, gattSeated: gS, gattAway: gA, currentGattOffset: 0)
        XCTAssertTrue(v.ok)
        XCTAssertEqual(v.base, -47)
        XCTAssertEqual(v.gattOffset, -12)
        XCTAssertEqual(v.logLine, "재보기: 착석 -45..-38 (16개), 비움 -56..-50 (8개) -> 기준 -47 dBm; 연결 착석 -57..-51 (15개), 비움 -69..-65 (8개) -> 차이 -12 dB")
        // "보통" 을 고르면 광고 -47, 연결 -59 - 연결로 쟀던 기준과 같아진다
        let near = Choices.distValue(base: v.base, step: 1)
        XCTAssertEqual(near, -47)
        XCTAssertEqual(Choices.gattThreshold(near: near, offset: v.gattOffset), -59)
    }

    func testMeasuredOffsetIsClamped() {
        // 잰 차이가 [-40, 40] 밖이면 config.ini 를 읽을 때처럼 잘라서 로그·저장·적용이 한 값이다.
        // 잰 범위는 그대로 적는다.
        let advS = Array(-38 ... -30) + Array(-38 ... -30)           // 18 개, 기준 -40
        let advA = [-60, -55, -58, -52, -57, -59, -54, -56]
        let gS = Array(-82 ... -75) + Array(-82 ... -75)             // 16 개, 연결 기준 -84
        let gA = [-95, -90, -88, -92, -86, -94, -89, -91]
        let low = WizardJudge.judge(seated: advS, away: advA, gattSeated: gS, gattAway: gA, currentGattOffset: 0)
        XCTAssertTrue(low.ok)
        XCTAssertEqual(low.base, -40)
        XCTAssertEqual(low.gatt, .measured)
        XCTAssertEqual(low.gattOffset, -40)                          // (-84) - (-40) = -44 → -40
        XCTAssertEqual(low.logLine, "재보기: 착석 -38..-30 (18개), 비움 -60..-52 (8개) -> 기준 -40 dBm; 연결 착석 -82..-75 (16개), 비움 -95..-86 (8개) -> 차이 -40 dB")
        XCTAssertEqual(low.body, "광고 신호\n  앉아 있을 때  -38 ~ -30\n  자리 비웠을 때  -60 ~ -52\n연결 신호\n  앉아 있을 때  -82 ~ -75\n  자리 비웠을 때  -95 ~ -86\n\n이 자리에 맞게 \"보통\" 을 맞췄어요. \"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다.")
        XCTAssertEqual(Choices.gattThreshold(near: low.base, offset: low.gattOffset), -80)

        // 반대쪽: 연결이 광고보다 42 dB 세다 → +40
        let high = WizardJudge.judge(seated: gS, away: gA, gattSeated: advS, gattAway: advA, currentGattOffset: 0)
        XCTAssertTrue(high.ok)
        XCTAssertEqual(high.base, -84)
        XCTAssertEqual(high.gattOffset, 40)                          // (-40) - (-84) = +44 → +40
        XCTAssertTrue(high.logLine.hasSuffix("; 연결 착석 -38..-30 (18개), 비움 -60..-52 (8개) -> 차이 +40 dB"), high.logLine)

        // 경계값은 그대로 (-40 / +40)
        let edge = WizardJudge.judge(seated: advS, away: advA,
                                     gattSeated: Array(-78 ... -71) + Array(-78 ... -71), gattAway: gA,
                                     currentGattOffset: 0)
        XCTAssertEqual(edge.gattOffset, -40)                         // (-80) - (-40)
        XCTAssertTrue(edge.logLine.hasSuffix("-> 차이 -40 dB"), edge.logLine)
    }

    func testGattNotMeasuredKeepsOffset() {
        // 폰 앱이 다른 PC 에 붙어 있었다: 연결 표본이 없다
        let v = WizardJudge.judge(seated: advSeated, away: advAway, gattSeated: [], gattAway: [], currentGattOffset: -12)
        XCTAssertTrue(v.ok)
        XCTAssertEqual(v.base, -62)
        XCTAssertEqual(v.gatt, .notMeasured)
        XCTAssertEqual(v.gattOffset, -12)
        XCTAssertEqual(v.title, "다 됐어요")
        XCTAssertEqual(v.body, "광고 신호\n  앉아 있을 때  -60 ~ -50\n  자리 비웠을 때  -80 ~ -63\n연결 신호\n  이번에는 못 쟀어요 (폰 앱이 이 컴퓨터에 연결돼 있지 않았어요)\n\n이 자리에 맞게 \"보통\" 을 맞췄어요. \"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다.")
        XCTAssertEqual(v.logLine, "재보기: 착석 -60..-50 (22개), 비움 -80..-63 (9개) -> 기준 -62 dBm; 연결 못 잼 (착석 0개, 비움 0개) - 차이 -12 dB 그대로")

        // 처음 재는 사람 (차이 0)
        let zero = judgeAdvOnly(advSeated, advAway)
        XCTAssertEqual(zero.gatt, .notMeasured)
        XCTAssertEqual(zero.gattOffset, 0)
        XCTAssertTrue(zero.logLine.hasSuffix("; 연결 못 잼 (착석 0개, 비움 0개) - 차이 +0 dB 그대로"), zero.logLine)

        // 도중에 붙거나 끊겨서 한쪽이 모자라도 못 잰 것이다 (15 / 8 개)
        let fewSeated = WizardJudge.judge(seated: advSeated, away: advAway,
                                          gattSeated: Array(gattSeated.prefix(14)), gattAway: gattAway,
                                          currentGattOffset: 3)
        XCTAssertEqual(fewSeated.gatt, .notMeasured)
        XCTAssertEqual(fewSeated.gattOffset, 3)
        XCTAssertTrue(fewSeated.logLine.hasSuffix("; 연결 못 잼 (착석 14개, 비움 8개) - 차이 +3 dB 그대로"), fewSeated.logLine)
        let fewAway = WizardJudge.judge(seated: advSeated, away: advAway,
                                        gattSeated: Array(gattSeated.prefix(15)), gattAway: Array(gattAway.prefix(7)),
                                        currentGattOffset: -40)
        XCTAssertEqual(fewAway.gatt, .notMeasured)
        XCTAssertEqual(fewAway.gattOffset, -40)
        XCTAssertTrue(fewAway.logLine.hasSuffix("; 연결 못 잼 (착석 15개, 비움 7개) - 차이 -40 dB 그대로"), fewAway.logLine)
        // 딱 15 / 8 개면 잰 것이다
        let exact = WizardJudge.judge(seated: advSeated, away: advAway,
                                      gattSeated: Array(gattSeated.prefix(15)), gattAway: gattAway,
                                      currentGattOffset: 3)
        XCTAssertEqual(exact.gatt, .measured)
    }

    func testGattOverlapKeepsOffset() {
        // 연결 착석 최저 -75 - 2 = -77 이 비움 최고 -77 보다 위가 아니다 → 겹침
        let away = [-90, -85, -77, -88, -82, -86, -84, -81]
        let v = WizardJudge.judge(seated: advSeated, away: advAway, gattSeated: gattSeated, gattAway: away,
                                  currentGattOffset: 3)
        XCTAssertTrue(v.ok)
        XCTAssertEqual(v.base, -62)
        XCTAssertEqual(v.gatt, .overlap)
        XCTAssertEqual(v.gattOffset, 3)
        XCTAssertEqual(v.title, "다 됐어요")
        XCTAssertEqual(v.body, "광고 신호\n  앉아 있을 때  -60 ~ -50\n  자리 비웠을 때  -80 ~ -63\n연결 신호\n  앉아 있을 때 -75~-66, 비웠을 때 -90~-77 로 겹쳐서 이번 값은 쓰지 않았어요\n\n이 자리에 맞게 \"보통\" 을 맞췄어요. \"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다.")
        XCTAssertEqual(v.logLine, "재보기: 착석 -60..-50 (22개), 비움 -80..-63 (9개) -> 기준 -62 dBm; 연결 겹침 (착석 -75..-66, 비움 -90..-77) - 차이 +3 dB 그대로")

        // 한 칸만 더 떨어지면 잰다 (-77 > -78)
        let apart = [-90, -85, -78, -88, -82, -86, -84, -81]
        let w = WizardJudge.judge(seated: advSeated, away: advAway, gattSeated: gattSeated, gattAway: apart,
                                  currentGattOffset: 3)
        XCTAssertEqual(w.gatt, .measured)
        XCTAssertEqual(w.gattOffset, -15)
    }

    func testLiveLineAndHelpers() {
        XCTAssertEqual(WizardJudge.liveLine(left: 60, adv: 0, gatt: 0), "60초 남음   ·   광고 0번   ·   연결 0번")
        XCTAssertEqual(WizardJudge.liveLine(left: 12, adv: 31, gatt: 48), "12초 남음   ·   광고 31번   ·   연결 48번")
        XCTAssertEqual(WizardJudge.minSeated, 15)
        XCTAssertEqual(WizardJudge.minAway, 8)
        // 표식 거르기: -100 이하와 0 이상은 측정값이 아니다
        XCTAssertFalse(WizardJudge.isSample(-100))
        XCTAssertFalse(WizardJudge.isSample(-127))
        XCTAssertTrue(WizardJudge.isSample(-99))
        XCTAssertTrue(WizardJudge.isSample(-1))
        XCTAssertFalse(WizardJudge.isSample(0))
        XCTAssertFalse(WizardJudge.isSample(127))
        XCTAssertEqual(WizardJudge.signed(-15), "-15")
        XCTAssertEqual(WizardJudge.signed(0), "+0")
        XCTAssertEqual(WizardJudge.signed(3), "+3")
        XCTAssertEqual(WizardJudge.signed(40), "+40")
    }

    func testPhaseTexts() {
        XCTAssertEqual(WizardJudge.seatedSec, 60)
        XCTAssertEqual(WizardJudge.awaySec, 45)
        XCTAssertEqual(WizardJudge.phaseTitles, ["내 자리에 맞게 재보기", "1/3  자리에 앉아 계세요",
                                                 "2/3  폰을 두고 오세요", "3/3  거의 다 됐어요"])
        XCTAssertEqual(WizardJudge.phaseBodies.count, 4)
        XCTAssertEqual(WizardJudge.phaseBodies[0], "2분쯤 걸려요. 순서는 이렇습니다.\n\n1.  폰을 평소처럼 지닌 채 1분 동안 앉아 있기\n     (주머니에 넣고 다니면 주머니에 넣은 채로)\n2.  폰만 \"화면이 꺼지길 원하는 곳\" 에 두고 오기\n3.  자리에 앉아서 45초 기다리기")
        XCTAssertEqual(WizardJudge.phaseBodies[1], "폰은 평소처럼 지니고 계세요.\n주머니에 넣고 다니면 주머니에 넣은 채로 앉아 계세요.\n컴퓨터는 건드리지 않아도 돼요.")
        XCTAssertEqual(WizardJudge.phaseBodies[3], "그대로 기다려 주세요.\n폰을 가지러 가지 마세요.")
    }
}
