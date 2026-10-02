import XCTest
@testable import SmartScreenCore

// 확인 연결의 재시도 간격, 연속 실패 줄, STATE 줄 꼬리. 글자는 Windows(client/ble_rssi.cpp)와 같아야 한다 -
// 두 판의 events.log 를 같은 grep 으로 본다.
final class ProbeBackoffTests: XCTestCase {

    func testDelaysDoubleFromFifteenAndStopAtTwoMinutes() {
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: 1), 15_000)
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: 2), 30_000)
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: 3), 60_000)
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: 4), 120_000)
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: 5), 120_000)   // 240 이 아니라 상한
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: 6), 120_000)
        // 아주 큰 n 에서도 넘치지 않는다
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: 1_000_000), 120_000)
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: Int.max), 120_000)
        // 0 이하는 첫 간격으로 본다 (부르는 쪽은 1 부터 준다)
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: 0), 15_000)
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: -3), 15_000)
    }

    func testNotOursHoldIsTenMinutes() {
        XCTAssertEqual(ProbePolicy.notOursMs, 600_000)
    }

    func testFailureCountDrivesTheDelay() {
        var s = ProbeFailStreaks<String>()
        var delays: [UInt64] = []
        for i in 0..<6 {
            let r = s.fail("A", why: "Unreachable", ms: 100, now: 1_000 + UInt64(i) * 1_000, wallClock: "09:00:00")
            delays.append(ProbePolicy.unreachableDelayMs(failures: r.n))
        }
        XCTAssertEqual(delays, [15_000, 30_000, 60_000, 120_000, 120_000, 120_000])
        // 되돌리면 다음 실패는 다시 15초
        _ = s.endAll()
        let r = s.fail("A", why: "Unreachable", ms: 100, now: 20_000, wallClock: "09:01:00")
        XCTAssertEqual(r.n, 1)
        XCTAssertEqual(ProbePolicy.unreachableDelayMs(failures: r.n), 15_000)
    }
}

final class ProbeFailStreakTests: XCTestCase {

    private func failN(_ s: inout ProbeFailStreaks<String>, _ id: String, _ n: Int,
                       startTick: UInt64 = 1_000) -> [ProbeFailStreaks<String>.Line] {
        var lines: [ProbeFailStreaks<String>.Line] = []
        for i in 0..<n {
            let r = s.fail(id, why: i % 2 == 0 ? "Unreachable" : "service discovery timeout",
                           ms: 1_000 + UInt64(i), now: startTick + UInt64(i) * 15_000,
                           wallClock: i == 0 ? "09:05:03" : "09:59:59")
            lines.append(r.line)
        }
        return lines
    }

    func testFirstFailureIsLoggedThenEveryTenth() {
        var s = ProbeFailStreaks<String>()
        let lines = failN(&s, "A", 21)
        XCTAssertEqual(lines[0], .first)
        for i in 1..<9 { XCTAssertEqual(lines[i], .silent, "failure \(i + 1)") }
        XCTAssertEqual(lines[9], .summary)    // 10번째
        for i in 10..<19 { XCTAssertEqual(lines[i], .silent, "failure \(i + 1)") }
        XCTAssertEqual(lines[19], .summary)   // 20번째
        XCTAssertEqual(lines[20], .silent)
        XCTAssertEqual(s.failures("A"), 21)
    }

    func testSummaryTextUsesFirstWallClockAndLastFailure() {
        var s = ProbeFailStreaks<String>()
        _ = failN(&s, "A", 10)
        // 10번째 실패: i = 9 -> 홀수라 "service discovery timeout", 1009ms
        XCTAssertEqual(s.streaks["A"]?.summaryText,
                       "probe failed x10 since 09:05:03 (last: service discovery timeout, 1009ms)")
        // 줄 전체 모양 (AdvScanner 가 앞에 "ident: <id> " 를 붙인다)
        XCTAssertEqual("ident: 4E33E1C031B2 " + (s.streaks["A"]?.summaryText ?? ""),
                       "ident: 4E33E1C031B2 probe failed x10 since 09:05:03 (last: service discovery timeout, 1009ms)")
    }

    func testEndSummarisesOnlyUnloggedStreaksOfTwoOrMore() {
        // 한 번뿐: 첫 줄이 다 말했다
        var s = ProbeFailStreaks<String>()
        _ = failN(&s, "A", 1)
        XCTAssertNil(s.end("A"))
        XCTAssertTrue(s.isEmpty)
        // 둘: 두 번째가 안 남았다
        _ = failN(&s, "A", 2)
        XCTAssertEqual(s.end("A")?.summaryText, "probe failed x2 since 09:05:03 (last: service discovery timeout, 1001ms)")
        // 정확히 10: 10번째 요약이 이미 남았다
        _ = failN(&s, "A", 10)
        XCTAssertNil(s.end("A"))
        // 11: 11번째가 안 남았다
        _ = failN(&s, "A", 11)
        XCTAssertEqual(s.end("A")?.count, 11)
        // 없는 주소
        XCTAssertNil(s.end("nope"))
    }

    func testEndForgetsTheStreak() {
        var s = ProbeFailStreaks<String>()
        _ = failN(&s, "A", 3)
        _ = s.end("A")
        XCTAssertEqual(s.failures("A"), 0)
        // 다음 실패는 새 연속의 첫 줄이다 (since 도 새로)
        let r = s.fail("A", why: "Unreachable", ms: 5, now: 999_000, wallClock: "10:00:00")
        XCTAssertEqual(r.n, 1)
        XCTAssertEqual(r.line, .first)
        XCTAssertEqual(s.streaks["A"]?.since, "10:00:00")
    }

    func testStreaksArePerAddress() {
        var s = ProbeFailStreaks<String>()
        _ = failN(&s, "A", 3)
        let r = s.fail("B", why: "Unreachable", ms: 7, now: 5_000, wallClock: "09:06:00")
        XCTAssertEqual(r.n, 1)
        XCTAssertEqual(r.line, .first)
        XCTAssertEqual(s.failures("A"), 3)
        XCTAssertEqual(s.failures("B"), 1)
        // B 를 끝내도 A 는 그대로
        XCTAssertNil(s.end("B"))
        XCTAssertEqual(s.failures("A"), 3)
    }

    func testEndAllReturnsSummariesInFirstFailureOrderAndClears() {
        var s = ProbeFailStreaks<String>()
        _ = failN(&s, "late", 4, startTick: 50_000)
        _ = failN(&s, "early", 2, startTick: 10_000)
        _ = failN(&s, "single", 1, startTick: 1_000)     // 요약 없음
        _ = failN(&s, "ten", 10, startTick: 20_000)      // 이미 다 남겼다
        let out = s.endAll()
        XCTAssertEqual(out.map { $0.id }, ["early", "late"])
        XCTAssertEqual(out.map { $0.streak.count }, [2, 4])
        XCTAssertTrue(s.isEmpty)
        XCTAssertTrue(s.endAll().isEmpty)
    }

    func testExpireAfterFiveMinutesWithoutAProbe() {
        var s = ProbeFailStreaks<String>()
        _ = failN(&s, "A", 3, startTick: 1_000)          // 마지막 실패 = 31_000
        _ = failN(&s, "B", 1, startTick: 1_000)          // 마지막 실패 = 1_000
        // B 는 5분이 되면 끝나지만 요약할 것이 없다
        XCTAssertTrue(s.expire(now: 1_000 + 300_000).isEmpty)
        XCTAssertEqual(s.failures("B"), 0)
        XCTAssertEqual(s.failures("A"), 3)
        // A: 4분 59.999초는 아직
        XCTAssertTrue(s.expire(now: 31_000 + 299_999).isEmpty)
        XCTAssertEqual(s.failures("A"), 3)
        // 5분이 되면 끝나고 요약한다
        let out = s.expire(now: 31_000 + 300_000)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.id, "A")
        XCTAssertEqual(out.first?.streak.summaryText, "probe failed x3 since 09:05:03 (last: Unreachable, 1002ms)")
        XCTAssertTrue(s.isEmpty)
    }

    func testExpireIgnoresClockGoingBackwards() {
        var s = ProbeFailStreaks<String>()
        _ = failN(&s, "A", 2, startTick: 500_000)
        XCTAssertTrue(s.expire(now: 1_000).isEmpty)
        XCTAssertEqual(s.failures("A"), 2)
    }

    /// 첫 실패가 같은 시각이면 주소의 글자 순 (사전 순서는 실행마다 다르다 - 로그 순서가 흔들리면 안 된다).
    func testSummariesWithTheSameFirstFailureAreOrderedById() {
        for _ in 0..<20 {
            var s = ProbeFailStreaks<String>()
            _ = failN(&s, "D4", 2, startTick: 10_000)
            _ = failN(&s, "late", 2, startTick: 20_000)
            _ = failN(&s, "A1", 3, startTick: 10_000)
            _ = failN(&s, "C3", 2, startTick: 10_000)
            _ = failN(&s, "B2", 4, startTick: 10_000)
            _ = failN(&s, "early", 2, startTick: 5_000)
            XCTAssertEqual(s.endAll().map { $0.id }, ["early", "A1", "B2", "C3", "D4", "late"])
        }
        // expire 도 같은 순서
        var s = ProbeFailStreaks<String>()
        _ = failN(&s, "Z", 2, startTick: 1_000)
        _ = failN(&s, "M", 2, startTick: 1_000)
        _ = failN(&s, "A", 2, startTick: 1_000)
        XCTAssertEqual(s.expire(now: 1_000 + 15_000 + 300_000).map { $0.id }, ["A", "M", "Z"])
    }

    /// UUID 주소도 글자(uuidString) 순이다 (AdvScanner 가 쓰는 모양).
    func testUUIDTieBreakUsesTheIdString() {
        let a = UUID(uuidString: "0A000000-0000-0000-0000-000000000000")!
        let b = UUID(uuidString: "0B000000-0000-0000-0000-000000000000")!
        let c = UUID(uuidString: "FF000000-0000-0000-0000-000000000000")!
        var s = ProbeFailStreaks<UUID>()
        for id in [c, a, b] {
            _ = s.fail(id, why: "Unreachable", ms: 1, now: 1_000, wallClock: "09:00:00")
            _ = s.fail(id, why: "Unreachable", ms: 1, now: 16_000, wallClock: "09:00:15")
        }
        XCTAssertEqual(s.endAll().map { $0.id }, [a, b, c])
    }
}

// 재시도 금지 (Windows Hold { until, set, notOurs }). 되돌리기는 못 붙음 금지를 15초로 줄이고, GATT 링크가
// 끊기면 아예 지운다. 남의 폰 판정은 어느 쪽도 건드리지 않는다.
final class ProbeHoldsTests: XCTestCase {

    func testHoldsAndPick() {
        var h = ProbeHolds<String>()
        h.holdUnreachable("A", now: 1_000, ms: 120_000)
        h.holdNotOurs("B", now: 1_000)
        XCTAssertEqual(h.count, 2)
        XCTAssertEqual(h.untilById, ["A": 121_000, "B": 601_000])
        XCTAssertEqual(h.holds["A"], ProbeHolds<String>.Hold(until: 121_000, set: 1_000, notOurs: false))
        XCTAssertEqual(h.holds["B"]?.notOurs, true)
        // 후보 고르기가 그대로 쓴다
        let cands = [IdentCandidate(id: "A", rssi: -50, sure: true, bit: -1),
                     IdentCandidate(id: "B", rssi: -40, sure: true, bit: -1)]
        XCTAssertNil(IdentCandidatePick.pick(cands, learnedBit: -1, probeFloor: -75,
                                             probedUntil: h.untilById, now: 60_000))
        XCTAssertEqual(IdentCandidatePick.pick(cands, learnedBit: -1, probeFloor: -75,
                                               probedUntil: h.untilById, now: 121_000)?.id, "A")
    }

    /// 깨어남, GATT 링크가 생김: 못 붙음 금지를 "첫 실패였다면" 의 15초(건 때 + 15초)로 줄인다.
    func testResetShortensUnreachableToFirstDelayAndKeepsNotOurs() {
        var h = ProbeHolds<String>()
        h.holdUnreachable("A", now: 10_000, ms: 120_000)    // 2분을 기다리던 주소
        h.holdUnreachable("B", now: 20_000, ms: 15_000)     // 이미 짧다 - 늘리지 않는다
        h.holdNotOurs("C", now: 10_000)
        h.resetBackoff(clearUnreachable: false)
        XCTAssertEqual(h.untilById, ["A": 25_000, "B": 35_000, "C": 610_000])
        XCTAssertEqual(h.holds["C"]?.notOurs, true)
    }

    /// GATT 링크가 끊김 (건강 -> 아님): 못 붙음 금지를 아예 지워 다음 틱에 바로 찾는다. 남의 폰은 그대로.
    func testLinkEndClearsUnreachableHoldsOutright() {
        var h = ProbeHolds<String>()
        h.holdUnreachable("A", now: 10_000, ms: 120_000)
        h.holdUnreachable("B", now: 11_000, ms: 15_000)     // 잠정 잠금도 못 붙음 쪽이다
        h.holdNotOurs("C", now: 10_000)
        h.resetBackoff(clearUnreachable: true)
        XCTAssertEqual(h.untilById, ["C": 610_000])
        // 지운 주소는 곧바로 고를 수 있다 (15초를 기다리지 않는다)
        let cands = [IdentCandidate(id: "A", rssi: -60, sure: true, bit: -1),
                     IdentCandidate(id: "C", rssi: -40, sure: true, bit: -1)]
        XCTAssertEqual(IdentCandidatePick.pick(cands, learnedBit: -1, probeFloor: -75,
                                               probedUntil: h.untilById, now: 12_000)?.id, "A")
    }

    /// 앞서 줄여 둔 금지도 끊기면 지운다 (연속 실패 기록이 이미 없어도 - 그것으로 고르지 않는다).
    func testLinkEndAfterAnEarlierShorteningStillClears() {
        var h = ProbeHolds<String>()
        h.holdUnreachable("A", now: 10_000, ms: 120_000)
        h.resetBackoff(clearUnreachable: false)             // 링크가 생김: 25_000 으로
        XCTAssertEqual(h.untilById, ["A": 25_000])
        h.resetBackoff(clearUnreachable: true)              // 곧 끊김
        XCTAssertEqual(h.count, 0)
    }

    func testNotOursReplacesUnreachableAndViceVersa() {
        var h = ProbeHolds<String>()
        h.holdUnreachable("A", now: 1_000, ms: 15_000)
        h.holdNotOurs("A", now: 5_000)
        h.resetBackoff(clearUnreachable: true)
        XCTAssertEqual(h.untilById, ["A": 605_000])
        // 토큰이 바뀌면 다시 못 붙음으로 걸릴 수 있다
        h.removeAll()
        h.holdUnreachable("A", now: 700_000, ms: 30_000)
        XCTAssertEqual(h.holds["A"]?.notOurs, false)
    }

    func testPruneDropsLongExpiredHolds() {
        var h = ProbeHolds<String>()
        h.holdUnreachable("A", now: 1_000, ms: 15_000)      // 16_000 에 풀림
        h.holdNotOurs("B", now: 1_000)                      // 601_000 에 풀림
        h.prune(now: 316_000, keepMs: 300_000)
        XCTAssertEqual(h.count, 2)
        h.prune(now: 316_001, keepMs: 300_000)
        XCTAssertEqual(h.untilById, ["B": 601_000])
        // 시계가 거꾸로 가도 지우지 않는다
        h.prune(now: 0, keepMs: 300_000)
        XCTAssertEqual(h.count, 1)
        h.removeAll()
        XCTAssertEqual(h.count, 0)
    }
}

final class ProbeTagTests: XCTestCase {

    func testProbing() {
        XCTAssertEqual(ProbeTag.text(now: 11_300, runningSince: 10_000, endedAt: 0), ", probing for 1.3s")
        XCTAssertEqual(ProbeTag.text(now: 10_000, runningSince: 10_000, endedAt: 0), ", probing for 0.0s")
        XCTAssertEqual(ProbeTag.text(now: 30_000, runningSince: 10_000, endedAt: 0), ", probing for 20.0s")
        // 진행 중이면 앞의 탐색이 막 끝났어도 진행 중이라고 말한다
        XCTAssertEqual(ProbeTag.text(now: 11_300, runningSince: 10_000, endedAt: 9_900), ", probing for 1.3s")
        // 다른 스레드가 잰 시각이 now 보다 뒤: 0
        XCTAssertEqual(ProbeTag.text(now: 9_000, runningSince: 10_000, endedAt: 0), ", probing for 0.0s")
    }

    func testEndedWithinThreeSeconds() {
        XCTAssertEqual(ProbeTag.text(now: 10_400, runningSince: 0, endedAt: 10_000), ", probe ended 0.4s ago")
        XCTAssertEqual(ProbeTag.text(now: 10_000, runningSince: 0, endedAt: 10_000), ", probe ended 0.0s ago")
        // 3.0초는 넣는다 (경계 포함), 그 뒤는 없다
        XCTAssertEqual(ProbeTag.text(now: 13_000, runningSince: 0, endedAt: 10_000), ", probe ended 3.0s ago")
        XCTAssertEqual(ProbeTag.text(now: 13_001, runningSince: 0, endedAt: 10_000), "")
        XCTAssertEqual(ProbeTag.text(now: 90_000, runningSince: 0, endedAt: 10_000), "")
    }

    func testNothing() {
        XCTAssertEqual(ProbeTag.text(now: 10_000, runningSince: 0, endedAt: 0), "")
    }

    func testDecimalPointIsAlwaysADot() {
        XCTAssertEqual(ProbeTag.seconds(1_300), "1.3")
        XCTAssertEqual(ProbeTag.seconds(12_340), "12.3")
        XCTAssertEqual(ProbeTag.seconds(999), "1.0")
        XCTAssertFalse(ProbeTag.seconds(1_300).contains(","))
    }

    func testStateLineExample() {
        // 판정 쪽이 STATE 줄의 닫는 괄호 앞에 붙인다 (계약의 예)
        let head = "STATE NEAR -> FAR  (adv rssi=-71 dBm thr=-67 set=-67, latency=0ms reachable=1"
        let tag = ProbeTag.text(now: 5_300, runningSince: 4_000, endedAt: 0)
        XCTAssertEqual(head + tag + ")",
                       "STATE NEAR -> FAR  (adv rssi=-71 dBm thr=-67 set=-67, latency=0ms reachable=1, probing for 1.3s)")
    }
}
