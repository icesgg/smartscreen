import XCTest
@testable import SmartScreenCore

// 광고 스캔의 available / 멈춤 (AdvScanner 가 블루투스 상태 콜백에서 쓴다) 과, 그것이 판정에 닿는 모양.
// 블루투스를 껐다 켜도 available 은 내려가지 않는다 - Windows IsAvailable 과 같다.
final class ScanAvailabilityTests: XCTestCase {

    func testIssuingTheScanMakesItAvailable() {
        var a = ScanAvailability()
        XCTAssertFalse(a.available)
        XCTAssertFalse(a.stopped)
        XCTAssertNil(a.scanIssued(now: 1_000))      // 처음 건 것은 "다시" 가 아니다
        XCTAssertTrue(a.available)
        XCTAssertFalse(a.stopped)
    }

    /// 블루투스를 끄면 멈춤이지만 available 은 그대로. 다시 켜면 멈춰 있던 시간을 돌려준다.
    func testBluetoothOffKeepsAvailableAndReportsTheStop() {
        var a = ScanAvailability()
        _ = a.scanIssued(now: 1_000)
        a.scanLost(now: 5_000)
        XCTAssertTrue(a.available)
        XCTAssertTrue(a.stopped)
        XCTAssertEqual(a.stoppedSince, 5_000)
        XCTAssertEqual(a.scanIssued(now: 17_000), 12_000)
        XCTAssertTrue(a.available)
        XCTAssertFalse(a.stopped)
        // 한 번만 돌려준다 - 같은 감시에서 다시 걸어도(등록 스캔이 끝남 등) 복구로 치지 않는다
        XCTAssertNil(a.scanIssued(now: 18_000))
    }

    /// 재설정 뒤 꺼짐처럼 여러 번 와도 멈춘 시간은 처음부터 잰다.
    func testRepeatedLossKeepsTheFirstTime() {
        var a = ScanAvailability()
        _ = a.scanIssued(now: 1_000)
        a.scanLost(now: 5_000)
        a.scanLost(now: 6_000)
        XCTAssertEqual(a.scanIssued(now: 10_000), 5_000)
    }

    /// 감시를 시작할 때 블루투스가 이미 꺼져 있었다: 멈춤이고 available 도 아직 false. 켜지면 둘 다 바뀐다.
    func testLossBeforeTheFirstScan() {
        var a = ScanAvailability()
        a.scanLost(now: 2_000)
        XCTAssertFalse(a.available)
        XCTAssertTrue(a.stopped)
        XCTAssertEqual(a.scanIssued(now: 9_500), 7_500)
        XCTAssertTrue(a.available)
    }

    func testResetForgetsTheLastSession() {
        var a = ScanAvailability()
        _ = a.scanIssued(now: 1_000)
        a.scanLost(now: 5_000)
        a.reset()
        XCTAssertFalse(a.available)
        XCTAssertFalse(a.stopped)
        XCTAssertNil(a.stoppedSince)
        XCTAssertNil(a.scanIssued(now: 9_000))
    }

    /// 다른 스레드가 잰 시각이 거꾸로 와도 죽지 않는다.
    func testClockGoingBackwards() {
        var a = ScanAvailability()
        a.scanLost(now: 50_000)
        XCTAssertEqual(a.scanIssued(now: 10_000), 0)
    }

    /// Windows "v1 advertisement scan: restarted after 12s" 와 같은 grep 에 걸린다. 초는 버림.
    func testRestartedLine() {
        XCTAssertEqual(ScanAvailability.restartedLine(stoppedMs: 12_999), "scan: restarted after 12s (bluetooth back on)")
        XCTAssertEqual(ScanAvailability.restartedLine(stoppedMs: 0), "scan: restarted after 0s (bluetooth back on)")
        XCTAssertTrue(ScanAvailability.restartedLine(stoppedMs: 5_000).contains("restarted after 5s"))
    }
}

// 블루투스를 껐다 켜는 동안의 판정. 판정 자체는 바뀌지 않았다 - available 을 내리지 않는 것이 어떤 판정을
// 내는지를 못박아 둔다 (예전에는 내려서 곧바로 FAR 이 됐다).
final class ScanAvailabilityJudgeTests: XCTestCase {
    private static let t0: UInt64 = 1_000_000

    private func settings() -> JudgeSettings {
        var s = JudgeSettings()
        s.nearRssiThreshold = -65
        s.gattRssiThreshold = -65
        s.gattSeen = true
        s.monStartTick = 1
        return s   // bleLostMeansFar = true, keepAliveSec = 5
    }

    /// 스캐너 사본. available 과 멈춤은 ScanAvailability 에서 그대로 옮긴다 (AdvScanner.snapshot 과 같다).
    private func scanner(_ a: ScanAvailability, rssi: Int, tick: UInt64, receiving: Bool) -> ScannerSnapshot {
        var s = ScannerSnapshot()
        s.available = a.available
        s.scanStopped = a.stopped
        s.lastReceivedTick = tick
        s.smoothedRssi = receiving ? rssi : -100
        s.rawRssi = s.smoothedRssi
        s.receiving = receiving
        s.hasEverReceived = tick != 0
        return s
    }

    /// 폰 앱이 이 Mac 에 GATT 로 붙어 있었다 (구독한 적 있음).
    private func gatt(healthy: Bool, reportTick: UInt64) -> GattSnapshot {
        var g = GattSnapshot()
        g.running = true
        g.everSubscribed = true
        g.subscribed = healthy
        g.healthy = healthy
        g.pollIntervalMs = 1000
        g.reportAgeMs = 500
        g.lastReportTick = reportTick
        g.smoothedRssi = -50
        g.rawRssi = -50
        return g
    }

    private func step(_ j: ProximityJudge, _ now: UInt64, _ s: ScannerSnapshot, _ g: GattSnapshot) -> ProbeResult {
        return j.step(now: now, scanner: s, gatt: g, settings: settings(), timeStr: "09:00:00").result
    }

    /// GATT 가 붙어 있던 Mac: 블루투스를 끄면 GATT 구독이 사라지지만, 마지막 광고가 bleTimeoutSec 안이면
    /// 그 값으로 NEAR 를 잇는다. 그 뒤에야 "absent" 로 FAR.
    func testGattMacStaysNearUntilTheAdvertTimesOut() {
        let t0 = ScanAvailabilityJudgeTests.t0
        var a = ScanAvailability()
        _ = a.scanIssued(now: t0)
        let j = ProximityJudge()
        XCTAssertEqual(step(j, t0 + 1_000, scanner(a, rssi: -50, tick: t0 + 900, receiving: true),
                            gatt(healthy: true, reportTick: t0 + 1_000)).state, .near)

        // 블루투스 꺼짐 (t0 + 2_000): 구독이 사라지고 스캔이 멈춘다
        a.scanLost(now: t0 + 2_000)
        let off = gatt(healthy: false, reportTick: t0 + 1_000)
        let offsets: [UInt64] = [2_000, 8_000, 30_000, 90_000]
        for dt in offsets {
            let r = step(j, t0 + dt, scanner(a, rssi: -50, tick: t0 + 900, receiving: true), off)
            XCTAssertEqual(r.state, .near, "at +\(dt)")
            XCTAssertFalse(r.gatt, "at +\(dt)")       // 광고 갈래가 판정한다
        }
        // 마지막 광고가 90초를 넘었다: 이제 부재
        let r = step(j, t0 + 91_000, scanner(a, rssi: -50, tick: t0 + 900, receiving: false), off)
        XCTAssertEqual(r.state, .far)
        XCTAssertTrue(r.gatt)                          // 연결도 광고도 없다 = "absent"
    }

    /// 예전처럼 available 을 내렸다면 같은 순간에 곧바로 FAR 였다 (이 수정이 막는 것).
    func testLoweringAvailableWouldHaveMeantImmediateAbsence() {
        let t0 = ScanAvailabilityJudgeTests.t0
        var a = ScanAvailability()
        _ = a.scanIssued(now: t0)
        let j = ProximityJudge()
        _ = step(j, t0 + 1_000, scanner(a, rssi: -50, tick: t0 + 900, receiving: true),
                 gatt(healthy: true, reportTick: t0 + 1_000))
        var lowered = scanner(a, rssi: -50, tick: t0 + 900, receiving: true)
        lowered.available = false
        XCTAssertEqual(step(j, t0 + 2_000, lowered, gatt(healthy: false, reportTick: t0 + 1_000)).state, .far)
    }

    /// GATT 없이 광고만 쓰는 Mac: 꺼져 있는 동안 keepAliveSec(5초)가 지나도 NEAR. 다시 켜면 새 샘플로 이어진다.
    func testAdvertOnlyMacKeepsNearPastKeepAlive() {
        let t0 = ScanAvailabilityJudgeTests.t0
        var a = ScanAvailability()
        _ = a.scanIssued(now: t0)
        let j = ProximityJudge()
        let none = GattSnapshot()
        XCTAssertEqual(step(j, t0 + 1_000, scanner(a, rssi: -55, tick: t0 + 1_000, receiving: true), none).state, .near)
        a.scanLost(now: t0 + 2_000)
        let stopped = scanner(a, rssi: -55, tick: t0 + 1_000, receiving: true)
        XCTAssertTrue(stopped.scanStopped)
        XCTAssertTrue(stopped.available)
        XCTAssertEqual(step(j, t0 + 20_000, stopped, none).state, .near)
        // 예전처럼 내렸다면 keepAliveSec 뒤 FAR 였다
        let k = ProximityJudge()
        _ = step(k, t0 + 1_000, scanner(a, rssi: -55, tick: t0 + 1_000, receiving: true), none)
        var lowered = stopped
        lowered.available = false
        XCTAssertEqual(step(k, t0 + 20_000, lowered, none).state, .far)
        // 다시 켜짐: 멈춤이 풀리고 새 샘플로 판정한다
        XCTAssertEqual(a.scanIssued(now: t0 + 22_000), 20_000)
        let back = scanner(a, rssi: -52, tick: t0 + 23_000, receiving: true)
        XCTAssertFalse(back.scanStopped)
        XCTAssertEqual(step(j, t0 + 23_000, back, none).state, .near)
    }

    /// 상태바: 멈춘 동안은 초당 수신 건수 자리(또는 "BLE: N/A" 자리)에 그렇게 적는다. Windows 와 같은 글자.
    func testStatusBarSaysTheScanIsStopped() {
        var r = ProbeResult()
        r.state = .near
        r.prevState = .near
        r.rssiDbm = -50
        r.bleAvailable = true
        r.reachable = true
        XCTAssertEqual(Texts.statusBar(r, targetName: "등록된 폰", packetRate: 0, nearThr: -65, gattThr: -61,
                                       idSt: "토큰 대기", gattSt: "waiting", countdown: 15, scanStopped: true),
                       "  \"등록된 폰\"  |  NEAR  |  RSSI: -50 dBm  |  광고 스캔 멈춤 - 다시 켜는 중  |  Near>=-65 dBm"
                       + "  |  ID: 토큰 대기  |  GATT: waiting  |  Idle: 15s")
        XCTAssertEqual(Texts.statusBar(r, targetName: "등록된 폰", packetRate: 0.4, nearThr: -65, gattThr: -61,
                                       idSt: "토큰", gattSt: "waiting", countdown: 15, scanStopped: false),
                       "  \"등록된 폰\"  |  NEAR  |  RSSI: -50 dBm  |  0.4/s  |  Near>=-65 dBm"
                       + "  |  ID: 토큰  |  GATT: waiting  |  Idle: 15s")
        var u = ProbeResult()
        u.state = .far
        XCTAssertEqual(Texts.statusBar(u, targetName: "등록된 폰", packetRate: 0, nearThr: -65, gattThr: -65,
                                       idSt: "토큰 대기", gattSt: "off", countdown: 30, scanStopped: true),
                       "  \"등록된 폰\"  |  FAR  |  Latency: 0 ms  |  BLE: 광고 스캔 멈춤 - 다시 켜는 중"
                       + "  |  ID: 토큰 대기  |  GATT: off  |  Idle: 30s")
        XCTAssertEqual(Texts.scanStoppedField, "광고 스캔 멈춤 - 다시 켜는 중")
    }
}
