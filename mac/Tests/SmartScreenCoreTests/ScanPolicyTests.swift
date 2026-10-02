import XCTest
@testable import SmartScreenCore

// 거르지 않는 스캔(R)을 끄고 켜는 규칙과 필터 스캔(F) 다시 걸기 (AdvScanner).
final class RawScanPolicyTests: XCTestCase {

    func testOnUntilGattHealthyForTenSeconds() {
        var p = RawScanPolicy()
        XCTAssertTrue(p.wantsRaw(now: 1_000))
        XCTAssertEqual(p.reason(now: 1_000), .gattNotLinked)
        p.observeGatt(healthy: true, now: 10_000)
        XCTAssertTrue(p.wantsRaw(now: 10_000))
        // 다음 관찰이 와도 처음 본 시각에서 센다
        p.observeGatt(healthy: true, now: 12_000)
        XCTAssertEqual(p.healthySince, 10_000)
        // F 가 묶인 폰을 준다 (끄려면 이것도 있어야 한다)
        p.filterDeliveredBound(now: 15_000)
        XCTAssertTrue(p.wantsRaw(now: 19_999))
        XCTAssertEqual(p.reason(now: 19_999), .gattNotLinked)
        XCTAssertFalse(p.wantsRaw(now: 20_000))
        XCTAssertEqual(p.reason(now: 20_000), .gattLinked)
    }

    func testBackOnAtOnceWhenNotHealthy() {
        var p = RawScanPolicy()
        p.observeGatt(healthy: true, now: 10_000)
        p.filterDeliveredBound(now: 25_000)
        XCTAssertFalse(p.wantsRaw(now: 30_000))
        p.observeGatt(healthy: false, now: 32_000)
        XCTAssertTrue(p.wantsRaw(now: 32_000))
        XCTAssertEqual(p.reason(now: 32_000), .gattNotLinked)
        // 다시 건강해지면 10초를 처음부터 센다 (막 붙은 연결은 1초 만에 끊겼다 붙기도 한다)
        p.observeGatt(healthy: true, now: 34_000)
        XCTAssertTrue(p.wantsRaw(now: 43_999))
        XCTAssertFalse(p.wantsRaw(now: 44_000))
    }

    func testMeasuringKeepsRawOn() {
        var p = RawScanPolicy()
        p.observeGatt(healthy: true, now: 10_000)
        p.setMeasuring(true)
        XCTAssertTrue(p.wantsRaw(now: 60_000))
        XCTAssertEqual(p.reason(now: 60_000), .measuring)
        // 건강하지 않아도 까닭은 재보기다
        p.observeGatt(healthy: false, now: 62_000)
        XCTAssertEqual(p.reason(now: 62_000), .measuring)
        p.setMeasuring(false)
        XCTAssertEqual(p.reason(now: 62_000), .gattNotLinked)
    }

    func testRestartForgetsHealthButNotMeasuring() {
        var p = RawScanPolicy()
        p.observeGatt(healthy: true, now: 10_000)
        p.filterDeliveredBound(now: 10_000)
        p.setMeasuring(true)
        p.markLogged(now: 10_000)
        p.restart()
        XCTAssertEqual(p.healthySince, 0)
        XCTAssertEqual(p.filterBoundTick, 0)
        XCTAssertNil(p.logged)
        XCTAssertTrue(p.measuring)
        p.setMeasuring(false)
        // 낡은 건강 시각으로 끄지 않는다
        XCTAssertTrue(p.wantsRaw(now: 100_000))
    }

    func testLinesOnlyWhenTheReasonChanges() {
        var p = RawScanPolicy()
        // START 줄이 raw=on 이라고 말했다
        p.markLogged(now: 1_000)
        XCTAssertNil(p.changedLine(now: 1_000))
        p.observeGatt(healthy: true, now: 2_000)
        p.filterDeliveredBound(now: 3_000)
        XCTAssertNil(p.changedLine(now: 4_000))
        XCTAssertNil(p.changedLine(now: 11_999))
        XCTAssertEqual(p.changedLine(now: 12_000), "scan: raw=off (GATT linked)")
        XCTAssertNil(p.changedLine(now: 14_000))
        // 재보기: 켜고 그 까닭을 말한다
        p.setMeasuring(true)
        XCTAssertEqual(p.changedLine(now: 16_000), "scan: raw=on (measuring)")
        XCTAssertNil(p.changedLine(now: 18_000))
        // 재보기 중에 GATT 가 끊겨도 R 은 이미 켜져 있고 까닭도 그대로다
        p.observeGatt(healthy: false, now: 20_000)
        XCTAssertNil(p.changedLine(now: 20_000))
        // 재보기가 끝나면 지금 까닭으로 (켜진 채)
        p.setMeasuring(false)
        XCTAssertEqual(p.changedLine(now: 22_000), "scan: raw=on (GATT not linked)")
        XCTAssertNil(p.changedLine(now: 24_000))
    }

    func testFirstChangeWithoutAStartLineIsLogged() {
        var p = RawScanPolicy()
        XCTAssertEqual(p.changedLine(now: 1_000), "scan: raw=on (GATT not linked)")
        XCTAssertNil(p.changedLine(now: 2_000))
    }

    func testLineTexts() {
        XCTAssertEqual(RawScanPolicy.line(.gattLinked), "scan: raw=off (GATT linked)")
        XCTAssertEqual(RawScanPolicy.line(.gattNotLinked), "scan: raw=on (GATT not linked)")
        XCTAssertEqual(RawScanPolicy.line(.filterQuiet), "scan: raw=on (filter quiet)")
        XCTAssertEqual(RawScanPolicy.line(.measuring), "scan: raw=on (measuring)")
    }

    /// GATT 가 건강해도 F 가 묶인 폰을 준 적이 없으면 (묶인 폰이 없으면) 끄지 않는다.
    func testGattAloneDoesNotTurnRawOff() {
        var p = RawScanPolicy()
        p.observeGatt(healthy: true, now: 10_000)
        XCTAssertEqual(p.reason(now: 20_000), .filterQuiet)
        XCTAssertTrue(p.wantsRaw(now: 20_000))
        XCTAssertTrue(p.wantsRaw(now: 500_000))
    }

    /// F 가 30초 동안 묶인 폰을 주지 않으면 GATT 가 건강해도 다시 켠다. F 가 다시 주면 다시 끈다.
    func testFilterSilentThirtySecondsTurnsRawBackOnAndResumingTurnsItOff() {
        var p = RawScanPolicy()
        p.observeGatt(healthy: true, now: 10_000)
        p.filterDeliveredBound(now: 25_000)
        XCTAssertFalse(p.wantsRaw(now: 25_000))
        XCTAssertFalse(p.wantsRaw(now: 54_999))
        // 30초째: 조용하다
        XCTAssertTrue(p.wantsRaw(now: 55_000))
        XCTAssertEqual(p.reason(now: 55_000), .filterQuiet)
        XCTAssertTrue(p.wantsRaw(now: 90_000))
        // F 가 다시 준다: 규칙대로 (GATT 는 여전히 10초 넘게 건강하다) 바로 끈다
        p.filterDeliveredBound(now: 91_000)
        XCTAssertFalse(p.wantsRaw(now: 91_000))
        XCTAssertEqual(p.reason(now: 91_000), .gattLinked)
        // F 가 다시 줘도 GATT 가 막 다시 붙었으면 10초를 기다린다
        p.observeGatt(healthy: false, now: 92_000)
        p.observeGatt(healthy: true, now: 94_000)
        p.filterDeliveredBound(now: 95_000)
        XCTAssertEqual(p.reason(now: 103_999), .gattNotLinked)
        XCTAssertFalse(p.wantsRaw(now: 104_000))
    }

    /// 까닭의 순서: 재보기 > GATT 안 붙음 > F 조용함 > GATT 붙음.
    func testReasonPriority() {
        var p = RawScanPolicy()
        // F 가 조용하고 GATT 도 없다: GATT 쪽이 먼저
        XCTAssertEqual(p.reason(now: 50_000), .gattNotLinked)
        p.observeGatt(healthy: true, now: 50_000)
        XCTAssertEqual(p.reason(now: 60_000), .filterQuiet)
        // 재보기는 무엇보다 먼저
        p.setMeasuring(true)
        XCTAssertEqual(p.reason(now: 60_000), .measuring)
        p.setMeasuring(false)
        p.filterDeliveredBound(now: 61_000)
        XCTAssertEqual(p.reason(now: 61_000), .gattLinked)
        p.observeGatt(healthy: false, now: 62_000)
        XCTAssertEqual(p.reason(now: 62_000), .gattNotLinked)
    }

    /// 묶음이 바뀌면 F 의 증거는 처음부터 (앞 폰을 F 가 줬다는 것은 새 폰에 대해 말하지 않는다).
    func testBindingChangeResetsFilterEvidence() {
        var p = RawScanPolicy()
        p.observeGatt(healthy: true, now: 10_000)
        p.filterDeliveredBound(now: 20_000)
        XCTAssertEqual(p.reason(now: 21_000), .gattLinked)
        p.bindingChanged()
        XCTAssertEqual(p.filterBoundTick, 0)
        XCTAssertEqual(p.reason(now: 21_000), .filterQuiet)
        XCTAssertTrue(p.wantsRaw(now: 21_000))
        p.filterDeliveredBound(now: 22_000)
        XCTAssertEqual(p.reason(now: 22_000), .gattLinked)
    }

    /// 광고 콜백이 잰 시각이 now 보다 뒤여도 죽지 않고 방금 준 것으로 본다.
    func testFilterTickAheadOfNow() {
        var p = RawScanPolicy()
        p.observeGatt(healthy: true, now: 10_000)
        p.filterDeliveredBound(now: 30_000)
        XCTAssertEqual(p.reason(now: 25_000), .gattLinked)
    }

    func testFilterQuietLines() {
        var p = RawScanPolicy()
        p.markLogged(now: 1_000)
        p.observeGatt(healthy: true, now: 2_000)
        XCTAssertNil(p.changedLine(now: 11_999))
        // GATT 는 10초 넘게 건강한데 F 가 묶인 폰을 준 적이 없다
        XCTAssertEqual(p.changedLine(now: 12_000), "scan: raw=on (filter quiet)")
        XCTAssertNil(p.changedLine(now: 14_000))
        p.filterDeliveredBound(now: 15_000)
        XCTAssertEqual(p.changedLine(now: 16_000), "scan: raw=off (GATT linked)")
        XCTAssertNil(p.changedLine(now: 44_999))
        XCTAssertEqual(p.changedLine(now: 45_000), "scan: raw=on (filter quiet)")
        p.filterDeliveredBound(now: 46_000)
        XCTAssertEqual(p.changedLine(now: 46_000), "scan: raw=off (GATT linked)")
        // GATT 가 끊기면 그 까닭이 F 보다 먼저다
        p.observeGatt(healthy: false, now: 48_000)
        XCTAssertEqual(p.changedLine(now: 48_000), "scan: raw=on (GATT not linked)")
    }
}

final class FilterScanWatchTests: XCTestCase {

    /// 감시를 t 에 시작한 것
    private func started(at t: UInt64) -> FilterScanWatch {
        var w = FilterScanWatch()
        w.scanStarted(now: t)
        return w
    }

    func testNoRestartWhenThePhoneIsNotEvidentlyNear() {
        var w = started(at: 1_000)
        XCTAssertFalse(w.shouldRestart(now: 100_000, bound: false, gattHealthy: false))
        XCTAssertFalse(w.shouldRestart(now: 100_000, bound: true, gattHealthy: false))
        XCTAssertEqual(w.lastRestart, 0)
    }

    func testRestartAfterThirtyQuietSecondsWhileGattHealthy() {
        var w = started(at: 1_000)
        w.filterDelivered(now: 5_000, boundPhone: false)
        XCTAssertFalse(w.shouldRestart(now: 34_999, bound: false, gattHealthy: true))
        XCTAssertTrue(w.shouldRestart(now: 35_000, bound: false, gattHealthy: true))
        XCTAssertEqual(w.lastRestart, 35_000)
        // 다시 건 뒤로는 공백을 처음부터 센다
        XCTAssertEqual(w.filterQuietMs(now: 35_000, bound: false), 0)
    }

    func testAtMostOncePerTwoMinutes() {
        var w = started(at: 1_000)
        XCTAssertTrue(w.shouldRestart(now: 31_000, bound: false, gattHealthy: true))
        // F 가 계속 아무것도 안 줘도 120초 안에는 다시 걸지 않는다
        XCTAssertFalse(w.shouldRestart(now: 61_000, bound: false, gattHealthy: true))
        XCTAssertFalse(w.shouldRestart(now: 150_999, bound: false, gattHealthy: true))
        XCTAssertTrue(w.shouldRestart(now: 151_000, bound: false, gattHealthy: true))
    }

    func testFilterDeliveringResetsTheQuietClock() {
        var w = started(at: 1_000)
        w.filterDelivered(now: 20_000, boundPhone: false)
        XCTAssertEqual(w.filterQuietMs(now: 45_000, bound: false), 25_000)
        XCTAssertFalse(w.shouldRestart(now: 45_000, bound: false, gattHealthy: true))
        XCTAssertTrue(w.shouldRestart(now: 50_000, bound: false, gattHealthy: true))
    }

    func testScanStartIsTheEarliestReference() {
        // 감시를 막 시작했는데 F 가 아직 아무것도 안 줬다 - 시작 전의 공백은 세지 않는다
        var w = started(at: 100_000)
        XCTAssertFalse(w.shouldRestart(now: 120_000, bound: false, gattHealthy: true))
        XCTAssertTrue(w.shouldRestart(now: 130_000, bound: false, gattHealthy: true))
    }

    func testBoundClockOnlyWhenRawSeesTheBoundPhone() {
        var w = started(at: 1_000)
        w.bindingChanged(now: 2_000)
        // 묶인 뒤 F 는 다른 기기들만 준다
        w.filterDelivered(now: 10_000, boundPhone: false)
        w.filterDelivered(now: 31_000, boundPhone: false)
        XCTAssertEqual(w.filterQuietMs(now: 32_000, bound: true), 30_000)
        XCTAssertEqual(w.filterQuietMs(now: 32_000, bound: false), 1_000)
        // 증거가 GATT 뿐이면 아무 후보로나 잰다 - F 는 살아 있다 (폰이 주소를 바꿨을 수 있다)
        XCTAssertFalse(w.shouldRestart(now: 32_000, bound: true, gattHealthy: true))
        // R 이 묶인 폰을 그 식별자 그대로 줬다: 주소는 그대로이니 F 도 그 폰을 줘야 한다
        w.rawDeliveredBound(now: 31_500)
        XCTAssertTrue(w.rawSeesBound(now: 32_000, bound: true))
        XCTAssertTrue(w.shouldRestart(now: 32_000, bound: true, gattHealthy: true))
    }

    /// 폰이 주소를 바꿨다: 묶인 폰의 시계는 멎었지만 F 는 바뀐 폰을 묶이지 않은 새 식별자로 계속 준다.
    /// GATT 만 건강하면 F 를 다시 걸지 않는다 (30초가 한참 지나도).
    func testAddressRotationDoesNotRestart() {
        var w = started(at: 1_000)
        w.bindingChanged(now: 2_000)
        w.filterDelivered(now: 4_000, boundPhone: true)
        var t: UInt64 = 6_000
        while t <= 200_000 {
            w.filterDelivered(now: t, boundPhone: false)
            XCTAssertFalse(w.shouldRestart(now: t + 1_000, bound: true, gattHealthy: true), "at \(t + 1_000)")
            t += 2_000
        }
        XCTAssertEqual(w.boundTick, 4_000)
        XCTAssertGreaterThan(w.filterQuietMs(now: 201_000, bound: true), FilterScanWatch.quietMs)
        XCTAssertEqual(w.lastRestart, 0)
    }

    /// F 가 정말 멎었다 (아무 후보도 안 준다): GATT 가 건강하면 30초에 다시 걸고, 그 뒤로는 120초에 한 번.
    func testRealFilterSilenceRestartsOncePerTwoMinutes() {
        var w = started(at: 1_000)
        w.bindingChanged(now: 2_000)
        w.filterDelivered(now: 5_000, boundPhone: true)
        var restarts: [UInt64] = []
        var t: UInt64 = 6_000
        while t <= 300_000 {
            if w.shouldRestart(now: t, bound: true, gattHealthy: true) { restarts.append(t) }
            t += 1_000
        }
        XCTAssertEqual(restarts, [35_000, 155_000, 275_000])
    }

    func testBoundPhoneViaFilterKeepsItQuiet() {
        var w = started(at: 1_000)
        w.bindingChanged(now: 2_000)
        w.filterDelivered(now: 20_000, boundPhone: true)
        XCTAssertFalse(w.shouldRestart(now: 49_999, bound: true, gattHealthy: true))
        XCTAssertTrue(w.shouldRestart(now: 50_000, bound: true, gattHealthy: true))
    }

    func testNewBindingStartsItsOwnClock() {
        var w = started(at: 1_000)
        w.filterDelivered(now: 5_000, boundPhone: true)
        // 100초 뒤에 새로 묶었다: 묶인 폰의 시계는 그 순간부터 센다
        w.bindingChanged(now: 100_000)
        XCTAssertEqual(w.boundTick, 100_000)
        // R 이 새 폰을 그 식별자 그대로 준다 (F 는 아직 아무것도)
        w.rawDeliveredBound(now: 125_000)
        XCTAssertFalse(w.shouldRestart(now: 129_999, bound: true, gattHealthy: false))
        XCTAssertTrue(w.shouldRestart(now: 130_000, bound: true, gattHealthy: false))
    }

    func testRawDeliveringTheBoundPhoneIsEvidenceWithinTenSeconds() {
        var w = started(at: 1_000)
        w.bindingChanged(now: 2_000)
        w.rawDeliveredBound(now: 40_000)
        XCTAssertTrue(w.phoneEvidentlyNear(now: 50_000, bound: true, gattHealthy: false))
        XCTAssertFalse(w.phoneEvidentlyNear(now: 50_001, bound: true, gattHealthy: false))
        // 묶이지 않았으면 R 의 묶인 폰은 증거가 아니다 (묶인 폰이 없다)
        XCTAssertFalse(w.phoneEvidentlyNear(now: 45_000, bound: false, gattHealthy: false))
        XCTAssertTrue(w.shouldRestart(now: 45_000, bound: true, gattHealthy: false))
    }

    func testBindingChangeForgetsRawEvidence() {
        var w = started(at: 1_000)
        w.bindingChanged(now: 2_000)
        w.rawDeliveredBound(now: 40_000)
        w.bindingChanged(now: 41_000)
        XCTAssertEqual(w.rawBoundTick, 0)
        XCTAssertFalse(w.phoneEvidentlyNear(now: 42_000, bound: true, gattHealthy: false))
    }

    func testResetStartsOver() {
        var w = started(at: 1_000)
        XCTAssertTrue(w.shouldRestart(now: 31_000, bound: false, gattHealthy: true))
        w.reset()
        XCTAssertEqual(w.lastRestart, 0)
        XCTAssertEqual(w.startTick, 0)
        w.scanStarted(now: 40_000)
        // 새 감시에는 120초 제한이 남지 않는다
        XCTAssertTrue(w.shouldRestart(now: 70_000, bound: false, gattHealthy: true))
    }

    func testClockGoingBackwardsDoesNotRestart() {
        var w = started(at: 50_000)
        XCTAssertFalse(w.shouldRestart(now: 10_000, bound: false, gattHealthy: true))
        XCTAssertEqual(w.filterQuietMs(now: 10_000, bound: false), 0)
    }
}
