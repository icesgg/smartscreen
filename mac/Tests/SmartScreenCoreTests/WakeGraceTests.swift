import XCTest
@testable import SmartScreenCore

// 깨어난 뒤의 유예 (ProximityJudge.noteResume), 잠자기 재기 (SleepWatch), 재보기 중의 TICK 간격
// (GattPollPolicy). 시각은 Mono 밀리초처럼 쓰는 임의의 수다 (0 은 "없음" 표식이라 크게 잡는다).
//
// 유예의 규칙: 깨어난 뒤 새 샘플(광고 패킷이나 GATT 보고의 시각 > 깨어난 판정 시각)이 오기 전까지,
// 최대 12 s 동안은 어느 갈래(-100 부재, "absent", 2 샘플 규칙, keepAlive)로도 FAR 로 가지 않는다.

private enum WakeFix {
    static let t0: UInt64 = 1_000_000
    /// 9 시간 잔 뒤
    static let wake: UInt64 = t0 + 9 * 3600 * 1000

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

    /// 잠든 동안 수신 타임아웃이 지난 스캐너: 받은 적은 있지만 -100, 수신 중 아님.
    static func stale() -> ScannerSnapshot {
        return adv(-100, tick: t0, receiving: false)
    }

    /// GATT 경로: 구독 중이고 건강하다.
    static func gatt(_ rssi: Int, poll: UInt32, reportTick: UInt64) -> GattSnapshot {
        var g = GattSnapshot()
        g.running = true
        g.subscribed = true
        g.everSubscribed = true
        g.healthy = true
        g.pollIntervalMs = poll
        g.reportAgeMs = 500
        g.lastReportTick = reportTick
        g.smoothedRssi = rssi
        g.rawRssi = rssi
        return g
    }

    /// 이번 세션에 구독했다가 끊긴 GATT (자는 동안 연결이 떨어졌다): "absent" 규칙이 기대한다.
    static func lostLink(lastReportTick: UInt64) -> GattSnapshot {
        var g = GattSnapshot()
        g.running = true
        g.everSubscribed = true
        g.lastReportTick = lastReportTick
        return g
    }

    static func settings(thr: Int = -65) -> JudgeSettings {
        var s = JudgeSettings()
        s.nearRssiThreshold = thr
        s.gattRssiThreshold = thr
        s.gattSeen = true
        s.monStartTick = 1
        return s
    }
}

final class WakeGraceTests: XCTestCase {
    private func step(_ j: ProximityJudge, _ now: UInt64, _ s: ScannerSnapshot,
                      gatt: GattSnapshot = GattSnapshot(), settings: JudgeSettings = WakeFix.settings())
        -> (result: ProbeResult, becameGattSeen: Bool, wakeGraceExpired: Bool) {
        return j.step(now: now, scanner: s, gatt: gatt, settings: settings, timeStr: "09:00:00")
    }

    /// 자기 전에 NEAR 였던 판정기. 마지막 패킷은 t0.
    private func nearJudge() -> ProximityJudge {
        let j = ProximityJudge()
        _ = step(j, WakeFix.t0, WakeFix.adv(-50, tick: WakeFix.t0))
        XCTAssertEqual(j.state, .near)
        return j
    }

    func testConstantsAndLines() {
        XCTAssertEqual(ProximityJudge.wakeGraceMs, 12000)
        XCTAssertEqual(ProximityJudge.sleptLine(sleptMs: 32_400_999),
                       "judge: slept 32400s - absence waits up to 12s for a fresh sample")
        XCTAssertEqual(ProximityJudge.sleptLine(sleptMs: 5_000),
                       "judge: slept 5s - absence waits up to 12s for a fresh sample")
        XCTAssertEqual(ProximityJudge.wakeGraceExpiredLine,
                       "judge: no sample within 12s of waking - absence applies")
    }

    /// 9 시간 자고 깼다: 스캐너는 낡았고(-100) GATT 는 없다. 12 s 동안은 NEAR 그대로, 그 뒤에 FAR
    /// 이고 "no sample within 12s" 는 한 번만 알린다.
    func testNearHeldAfterLongSleepThenAbsenceAfter12s() {
        let j = nearJudge()
        j.noteResume(now: WakeFix.wake)
        XCTAssertEqual(j.resumeTick, WakeFix.wake)

        var out = step(j, WakeFix.wake, WakeFix.stale())
        XCTAssertEqual(out.result.state, .near)
        XCTAssertEqual(out.result.prevState, .near)
        XCTAssertEqual(out.result.rssiDbm, -100)      // 판정한 값은 그대로 보인다 - 상태만 버틴다
        XCTAssertFalse(out.wakeGraceExpired)

        out = step(j, WakeFix.wake + 6_000, WakeFix.stale())
        XCTAssertEqual(out.result.state, .near)
        out = step(j, WakeFix.wake + 11_999, WakeFix.stale())
        XCTAssertEqual(out.result.state, .near)
        XCTAssertFalse(out.wakeGraceExpired)

        out = step(j, WakeFix.wake + 12_000, WakeFix.stale())
        XCTAssertEqual(out.result.state, .far)
        XCTAssertEqual(out.result.prevState, .near)
        XCTAssertTrue(out.wakeGraceExpired)
        XCTAssertEqual(j.resumeTick, 0)

        out = step(j, WakeFix.wake + 14_000, WakeFix.stale())
        XCTAssertEqual(out.result.state, .far)
        XCTAssertFalse(out.wakeGraceExpired)           // 한 번만
    }

    /// 자는 동안 GATT 연결이 끊겼고 광고도 안 들린다 ("absent" 갈래): 역시 12 s 버틴다.
    func testAbsentBranchHeld() {
        let j = nearJudge()
        j.noteResume(now: WakeFix.wake)
        let lost = WakeFix.lostLink(lastReportTick: WakeFix.t0 - 500)
        var out = step(j, WakeFix.wake + 2_000, WakeFix.stale(), gatt: lost)
        XCTAssertTrue(out.result.gatt)
        XCTAssertEqual(out.result.rssiDbm, -100)
        XCTAssertEqual(out.result.state, .near)
        out = step(j, WakeFix.wake + 12_000, WakeFix.stale(), gatt: lost)
        XCTAssertTrue(out.result.gatt)
        XCTAssertEqual(out.result.state, .far)
        XCTAssertTrue(out.wakeGraceExpired)
    }

    /// bleLostMeansFar=0 이라 BLE 로 판단하지 않는 갈래(keepAlive 유예): 역시 12 s 버틴다.
    func testKeepAliveBranchHeld() {
        var s = WakeFix.settings()
        s.bleLostMeansFar = false
        let j = ProximityJudge()
        _ = step(j, WakeFix.t0, WakeFix.adv(-50, tick: WakeFix.t0), settings: s)
        XCTAssertEqual(j.state, .near)
        j.noteResume(now: WakeFix.wake)
        var out = step(j, WakeFix.wake + 1_000, WakeFix.stale(), settings: s)
        XCTAssertFalse(out.result.bleAvailable)
        XCTAssertEqual(out.result.state, .near)
        out = step(j, WakeFix.wake + 11_000, WakeFix.stale(), settings: s)
        XCTAssertEqual(out.result.state, .near)
        out = step(j, WakeFix.wake + 13_000, WakeFix.stale(), settings: s)
        XCTAssertEqual(out.result.state, .far)
        XCTAssertTrue(out.wakeGraceExpired)
    }

    /// 깨어난 뒤 첫 새 샘플부터는 평소 규칙: 미만 샘플은 2 샘플 규칙이 바로 센다 (12 s 를 기다리지 않는다).
    func testFreshBelowSamplesFollowTwoSampleRuleAtOnce() {
        let j = nearJudge()
        j.noteResume(now: WakeFix.wake)
        XCTAssertEqual(step(j, WakeFix.wake, WakeFix.stale()).result.state, .near)

        var out = step(j, WakeFix.wake + 1_000, WakeFix.adv(-70, tick: WakeFix.wake + 1_000))   // 첫 미만
        XCTAssertEqual(out.result.state, .near)
        XCTAssertEqual(j.resumeTick, 0)                // 새 샘플이 유예를 끝냈다
        XCTAssertFalse(out.wakeGraceExpired)

        out = step(j, WakeFix.wake + 2_500, WakeFix.adv(-72, tick: WakeFix.wake + 2_500))       // 두 번째
        XCTAssertEqual(out.result.state, .far)
        XCTAssertFalse(out.wakeGraceExpired)

        // 유예는 이미 끝났다 - 12 s 가 지나도 다시 알리지 않는다
        out = step(j, WakeFix.wake + 13_000, WakeFix.adv(-72, tick: WakeFix.wake + 2_500))
        XCTAssertFalse(out.wakeGraceExpired)
    }

    /// 새 샘플이 한 번 왔으면 유예는 끝났다: 그 뒤의 "신호 없음"(-100) 은 12 s 안이라도 평소대로 바로 부재다.
    func testAfterFreshSampleAbsenceIsImmediate() {
        let j = nearJudge()
        j.noteResume(now: WakeFix.wake)
        _ = step(j, WakeFix.wake + 1_000, WakeFix.adv(-50, tick: WakeFix.wake + 1_000))
        XCTAssertEqual(j.resumeTick, 0)
        let gone = WakeFix.adv(-100, tick: WakeFix.wake + 1_000, receiving: false)
        XCTAssertEqual(step(j, WakeFix.wake + 3_000, gone).result.state, .far)
    }

    /// 새 좋은 샘플은 NEAR 를 지킨다 (lastNearTick 도 새로).
    func testFreshGoodSampleKeepsNear() {
        let j = nearJudge()
        j.noteResume(now: WakeFix.wake)
        var out = step(j, WakeFix.wake + 500, WakeFix.adv(-50, tick: WakeFix.wake + 500))
        XCTAssertEqual(out.result.state, .near)
        XCTAssertEqual(j.lastNearTick, WakeFix.wake + 500)
        XCTAssertEqual(out.result.timerRemainMs, 5_000)
        out = step(j, WakeFix.wake + 20_000, WakeFix.adv(-50, tick: WakeFix.wake + 19_000))
        XCTAssertEqual(out.result.state, .near)
        XCTAssertFalse(out.wakeGraceExpired)
    }

    /// GATT 보고도 새 샘플이다 (광고가 낡아 있어도). 그 뒤는 평소 규칙.
    func testFreshGattReportEndsGrace() {
        let j = nearJudge()
        j.noteResume(now: WakeFix.wake)
        let g1 = WakeFix.gatt(-70, poll: 1000, reportTick: WakeFix.wake + 1_000)
        var out = step(j, WakeFix.wake + 1_000, WakeFix.stale(), gatt: g1)
        XCTAssertTrue(out.result.gatt)
        XCTAssertEqual(out.result.state, .near)        // 미만 1
        XCTAssertEqual(j.resumeTick, 0)
        let g2 = WakeFix.gatt(-70, poll: 1000, reportTick: WakeFix.wake + 2_000)
        out = step(j, WakeFix.wake + 2_000, WakeFix.stale(), gatt: g2)
        XCTAssertEqual(out.result.state, .far)         // 미만 2
    }

    /// 깨어난 판정 시각과 같은 시각의 패킷은 새 샘플이 아니다 (경계: <= 는 낡은 것).
    func testSampleAtResumeTickIsNotFresh() {
        let j = nearJudge()
        j.noteResume(now: WakeFix.wake)
        let atResume = WakeFix.adv(-100, tick: WakeFix.wake, receiving: false)
        let out = step(j, WakeFix.wake + 3_000, atResume)
        XCTAssertEqual(out.result.state, .near)
        XCTAssertEqual(j.resumeTick, WakeFix.wake)
    }

    /// 자기 전에 미만 샘플 하나가 세어져 있었다: 유예 중에는 6 s 상한도 FAR 로 보내지 않는다.
    func testBelowCapDoesNotFireDuringGrace() {
        let j = nearJudge()
        _ = step(j, WakeFix.t0 + 1_000, WakeFix.adv(-70, tick: WakeFix.t0 + 1_000))   // 미만 1 (자기 전)
        XCTAssertEqual(j.state, .near)
        let resume = WakeFix.t0 + 30_000                                                   // 짧게 잤다
        j.noteResume(now: resume)
        // 수신 타임아웃 전이라 스캐너는 아직 낡은 -70 을 들고 있다
        var out = step(j, resume + 1_000, WakeFix.adv(-70, tick: WakeFix.t0 + 1_000))
        XCTAssertEqual(out.result.state, .near)
        out = step(j, resume + 2_000, WakeFix.adv(-50, tick: resume + 2_000))
        XCTAssertEqual(out.result.state, .near)
        XCTAssertEqual(j.resumeTick, 0)
    }

    /// 잠들기 전에 미만 샘플 하나가 세어져 있었다: 깬 뒤 첫 새 미만 샘플은 새 구간의 첫 샘플이다 (NEAR 그대로).
    /// 두 번째 새 미만 샘플에 FAR. 잠들기 전의 하나와 합쳐 2 샘플이 차거나, 그때의 첫 시각으로 6 s 상한이
    /// 이미 지난 것으로 보면 안 된다.
    func testPreSleepBelowSampleIsForgottenWhenAFreshSampleEndsTheGrace() {
        let j = nearJudge()
        _ = step(j, WakeFix.t0 + 1_000, WakeFix.adv(-70, tick: WakeFix.t0 + 1_000))   // 미만 1 (자기 전)
        XCTAssertEqual(j.state, .near)
        j.noteResume(now: WakeFix.wake)
        // 유예 중, 아직 새 샘플이 없다
        XCTAssertEqual(step(j, WakeFix.wake, WakeFix.stale()).result.state, .near)

        var out = step(j, WakeFix.wake + 1_000, WakeFix.adv(-70, tick: WakeFix.wake + 1_000))   // 새 미만 1
        XCTAssertEqual(out.result.state, .near)
        XCTAssertEqual(j.resumeTick, 0)
        XCTAssertFalse(out.wakeGraceExpired)

        out = step(j, WakeFix.wake + 2_500, WakeFix.adv(-72, tick: WakeFix.wake + 2_500))       // 새 미만 2
        XCTAssertEqual(out.result.state, .far)
        XCTAssertEqual(out.result.prevState, .near)
    }

    /// 짧게 잤다 (스캐너가 아직 잠들기 전의 미만 값을 들고 있다): 깬 뒤 첫 새 미만 샘플만으로는 FAR 가 아니다.
    /// 그 뒤 6 s 상한은 새 샘플의 시각부터 잰다.
    func testFreshSampleRestartsTheBelowCap() {
        let j = nearJudge()
        _ = step(j, WakeFix.t0 + 1_000, WakeFix.adv(-70, tick: WakeFix.t0 + 1_000))   // 미만 1 (자기 전)
        let resume = WakeFix.t0 + 30_000
        j.noteResume(now: resume)
        var out = step(j, resume + 1_000, WakeFix.adv(-70, tick: resume + 1_000))          // 새 미만 1
        XCTAssertEqual(out.result.state, .near)
        // 같은 샘플을 다시 봐도 세지 않는다. 6 s 가 되기 전에는 그대로
        out = step(j, resume + 6_999, WakeFix.adv(-70, tick: resume + 1_000))
        XCTAssertEqual(out.result.state, .near)
        out = step(j, resume + 7_000, WakeFix.adv(-70, tick: resume + 1_000))
        XCTAssertEqual(out.result.state, .far)
    }

    /// 잠들기 전 미만 1 이 있고 유예가 새 샘플 없이 끝났다: 예전처럼 평소 규칙이다 (카운터를 지우지 않는다) -
    /// 낡은 값을 들고 있는 스캐너로는 6 s 상한이 이미 지나 FAR, 수신 타임아웃이 지났으면 -100 으로 FAR.
    func testGraceExpiringWithoutASampleStillGoesFar() {
        // 짧게 잤다: 스캐너는 아직 잠들기 전의 미만 값(-70)을 들고 있다
        let j = nearJudge()
        _ = step(j, WakeFix.t0 + 1_000, WakeFix.adv(-70, tick: WakeFix.t0 + 1_000))
        let resume = WakeFix.t0 + 30_000
        j.noteResume(now: resume)
        var out = step(j, resume + 11_999, WakeFix.adv(-70, tick: WakeFix.t0 + 1_000))
        XCTAssertEqual(out.result.state, .near)
        out = step(j, resume + 12_000, WakeFix.adv(-70, tick: WakeFix.t0 + 1_000))
        XCTAssertTrue(out.wakeGraceExpired)
        XCTAssertEqual(out.result.state, .far)

        // 오래 잤다: 수신 타임아웃이 지나 -100
        let k = nearJudge()
        _ = step(k, WakeFix.t0 + 1_000, WakeFix.adv(-70, tick: WakeFix.t0 + 1_000))
        k.noteResume(now: WakeFix.wake)
        XCTAssertEqual(step(k, WakeFix.wake + 6_000, WakeFix.stale()).result.state, .near)
        out = step(k, WakeFix.wake + 12_000, WakeFix.stale())
        XCTAssertTrue(out.wakeGraceExpired)
        XCTAssertEqual(out.result.state, .far)
    }

    /// 유예는 FAR 로 가는 것만 막는다: 입력 중(GATT 폴링 쉼)이면 FAR 에서 NEAR 로 간다.
    func testGraceDoesNotBlockNear() {
        let j = ProximityJudge()
        j.noteResume(now: WakeFix.wake)
        let typing = WakeFix.gatt(-90, poll: 0, reportTick: WakeFix.t0)
        let out = step(j, WakeFix.wake + 1_000, WakeFix.stale(), gatt: typing)
        XCTAssertEqual(out.result.state, .near)
        XCTAssertEqual(out.result.prevState, .far)
    }

    /// FAR 로 잠들었으면 FAR 그대로다 (지킬 NEAR 가 없다). 12 s 뒤 알림은 똑같이 한 번.
    func testFarStaysFar() {
        let j = ProximityJudge()
        _ = step(j, WakeFix.t0, WakeFix.adv(-90, tick: WakeFix.t0))
        XCTAssertEqual(j.state, .far)
        j.noteResume(now: WakeFix.wake)
        XCTAssertEqual(step(j, WakeFix.wake + 1_000, WakeFix.stale()).result.state, .far)
        let out = step(j, WakeFix.wake + 12_500, WakeFix.stale())
        XCTAssertEqual(out.result.state, .far)
        XCTAssertTrue(out.wakeGraceExpired)
    }

    /// 유예 중에 다시 잤다 깼으면 그때부터 다시 12 s.
    func testSecondResumeRestartsGrace() {
        let j = nearJudge()
        j.noteResume(now: WakeFix.wake)
        XCTAssertEqual(step(j, WakeFix.wake + 10_000, WakeFix.stale()).result.state, .near)
        let again = WakeFix.wake + 11_000             // 첫 유예가 끝나기 전
        j.noteResume(now: again)
        XCTAssertEqual(step(j, again + 11_000, WakeFix.stale()).result.state, .near)
        let out = step(j, again + 12_000, WakeFix.stale())
        XCTAssertEqual(out.result.state, .far)
        XCTAssertTrue(out.wakeGraceExpired)
    }

    /// 깨어난 적이 없으면 아무것도 바뀌지 않는다 (-100 은 바로 FAR).
    func testNoResumeNoGrace() {
        let j = nearJudge()
        let out = step(j, WakeFix.t0 + 95_000, WakeFix.stale())
        XCTAssertEqual(out.result.state, .far)
        XCTAssertFalse(out.wakeGraceExpired)
        XCTAssertEqual(j.resumeTick, 0)
    }
}

final class SleepWatchTests: XCTestCase {
    func testFirstObservationOnlySetsBaseline() {
        var w = SleepWatch()
        XCTAssertNil(w.observe(asleepMs: 1_000_000))
    }

    func testGrowthOfFiveSecondsIsSleep() {
        var w = SleepWatch()
        _ = w.observe(asleepMs: 100)
        XCTAssertNil(w.observe(asleepMs: 100))
        XCTAssertNil(w.observe(asleepMs: 5_099))           // 4999 ms: 아니다
        XCTAssertEqual(w.observe(asleepMs: 10_099), 5_000)  // 직전 반복과 비교한다
        XCTAssertNil(w.observe(asleepMs: 10_099))
        XCTAssertEqual(w.observe(asleepMs: 10_099 + 32_400_000), 32_400_000)
    }

    /// 두 시계의 흔들림으로 줄면 새 값을 기준으로 삼을 뿐이다.
    func testDecreaseRebaselines() {
        var w = SleepWatch()
        _ = w.observe(asleepMs: 20_000)
        XCTAssertNil(w.observe(asleepMs: 19_999))
        XCTAssertEqual(w.observe(asleepMs: 24_999), 5_000)
    }

    /// 느린 밀림은 쌓이지 않는다: 반복마다 1 ms 씩 늘어도 잠자기가 아니다.
    func testSlowDriftNeverAccumulates() {
        var w = SleepWatch()
        var v: UInt64 = 0
        _ = w.observe(asleepMs: v)
        for _ in 0..<10_000 {
            v += 1
            XCTAssertNil(w.observe(asleepMs: v))
        }
    }
}

final class GattPollPolicyTests: XCTestCase {
    func testBlankedScreenWinsOverMeasuring() {
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: true, measuring: true, idleMs: 0), 2000)
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: true, measuring: false, idleMs: 0), 2000)
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: true, measuring: false, idleMs: 500_000), 2000)
    }

    /// 재보기 중에는 입력과 무관하게 1000 ms (입력 5 초 규칙이 TICK 을 멈추지 않는다).
    func testMeasuringIgnoresInput() {
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: false, measuring: true, idleMs: 0), 1000)
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: false, measuring: true, idleMs: 4_999), 1000)
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: false, measuring: true, idleMs: 500_000), 1000)
    }

    func testIdleRules() {
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: false, measuring: false, idleMs: 0), 0)
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: false, measuring: false, idleMs: 4_999), 0)
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: false, measuring: false, idleMs: 5_000), 1000)
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: false, measuring: false, idleMs: 119_999), 1000)
        XCTAssertEqual(GattPollPolicy.intervalMs(blackActive: false, measuring: false, idleMs: 120_000), 3000)
    }
}
