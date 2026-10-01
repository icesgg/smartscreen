import XCTest
@testable import SmartScreenCore

// --probe-scan 의 "결과:" 줄과 AdvScanner 의 "via ..." / "locked adverts" 글자.
// 이 줄들만 보고 어느 스캔을 살릴지 정하므로, 확인하지 않은 것을 확인했다고 말하면 안 된다.
final class ProbeScanResultTests: XCTestCase {

    private typealias C = ProbeScanResult.Candidate
    private typealias V = ProbeScanResult.Verdict
    private let mineTok = String(repeating: "AB", count: 16)
    private let otherTok = String(repeating: "CD", count: 16)

    private func filterCand(_ a: ProbeScanResult.Attempt) -> C {
        return C(byFilter: true, rawList: false, bit: -1, attempt: a)
    }

    private func bitCand(_ bit: Int, _ a: ProbeScanResult.Attempt) -> C {
        return C(byFilter: false, rawList: false, bit: bit, attempt: a)
    }

    private func listCand(_ a: ProbeScanResult.Attempt) -> C {
        return C(byFilter: false, rawList: true, bit: -1, attempt: a)
    }

    private func decide(_ cands: [C], registered: String = "", rawTested: Bool = true,
                        scanned: Bool = true) -> V {
        return ProbeScanResult.decide(scanned: scanned, rawTested: rawTested, registered: registered,
                                      candidates: cands)
    }

    private func firstLine(_ v: V, rawTested: Bool = true, skipped: Int = 0) -> String {
        return ProbeScanResult.lines(v, rawTested: rawTested, skipped: skipped, maxProbes: 6).first ?? ""
    }

    // MARK: 토큰으로 정한 길

    func testFilterTokenIsFilterPath() {
        XCTAssertEqual(decide([filterCand(.token(mineTok))], registered: mineTok), .filter)
        XCTAssertEqual(firstLine(.filter),
                       "결과: 필터 경로 - macOS 의 서비스 필터가 잠긴 폰을 찾아 줍니다 (직접 읽기로는 못 찾았습니다).")
    }

    func testFilterPathWithoutRawScanDoesNotClaimRawFailed() {
        let v = decide([filterCand(.token(mineTok))], registered: mineTok, rawTested: false)
        XCTAssertEqual(v, .filter)
        let l = firstLine(v, rawTested: false)
        XCTAssertFalse(l.contains("직접 읽기로는 못 찾았습니다"))
        XCTAssertTrue(l.contains("직접 읽기는 시험하지 못했습니다 - 다시 실행해 보세요"))
    }

    func testBothPaths() {
        let c = C(byFilter: true, rawList: false, bit: 31, attempt: .token(mineTok))
        XCTAssertEqual(decide([c], registered: mineTok), .both)
        // 서로 다른 두 후보가 각각 내 토큰을 줘도 둘 다
        XCTAssertEqual(decide([filterCand(.token(mineTok)), bitCand(31, .token(mineTok))], registered: mineTok), .both)
    }

    func testRawPathByBitAndByListOnly() {
        XCTAssertEqual(decide([bitCand(31, .token(mineTok))], registered: mineTok), .raw(bitLearned: true))
        XCTAssertEqual(decide([listCand(.token(mineTok))], registered: mineTok), .raw(bitLearned: false))
        XCTAssertEqual(firstLine(.raw(bitLearned: true)),
                       "결과: 직접 읽기 경로 - 필터로는 못 찾고, 제조사 데이터의 overflow 비트로 찾았습니다.")
        XCTAssertEqual(firstLine(.raw(bitLearned: false)),
                       "결과: 직접 읽기 경로 - 필터로는 못 찾고, 거르지 않은 스캔의 UUID 목록으로 찾았습니다 (비트는 배우지 않음).")
    }

    func testNoRegisteredTokenAcceptsAnyToken() {
        XCTAssertEqual(decide([bitCand(5, .token(otherTok))], registered: ""), .raw(bitLearned: true))
    }

    func testRegisteredTokenComparedCaseInsensitively() {
        XCTAssertEqual(decide([filterCand(.token(mineTok.lowercased()))], registered: mineTok), .filter)
        XCTAssertEqual(decide([filterCand(.token(mineTok))], registered: mineTok.lowercased()), .filter)
    }

    func testOnlyMyTokenDecidesThePath() {
        // 남의 폰은 필터로, 내 폰은 비트로 -> 직접 읽기 경로 (남의 것이 "둘 다" 로 만들지 않는다)
        let v = decide([filterCand(.token(otherTok)), bitCand(31, .token(mineTok))], registered: mineTok)
        XCTAssertEqual(v, .raw(bitLearned: true))
    }

    func testOnlyOtherTokensIsUndecided() {
        let v = decide([filterCand(.token(otherTok))], registered: mineTok)
        XCTAssertEqual(v, .otherTokens(filter: true, raw: false))
        let l = ProbeScanResult.lines(v, rawTested: true, skipped: 0, maxProbes: 6)
        XCTAssertEqual(l.first, "결과: 판정 못 함 - 읽은 토큰이 모두 등록된 토큰과 다릅니다 (그 폰은 필터로 찾았습니다).")
        XCTAssertFalse(l.joined().contains("둘 다 안 됨"))
        XCTAssertEqual(decide([bitCand(3, .token(otherTok))], registered: mineTok), .otherTokens(filter: false, raw: true))
    }

    // MARK: 봤지만 토큰을 못 읽음 = 판정 못 함 (첫 판은 "둘 다 안 됨")

    func testFilterSawPhoneButConnectionFailed() {
        let v = decide([filterCand(.unreachable)])
        XCTAssertEqual(v, .seenNoToken(filter: true, list: false, reason: .unreachable))
        let l = ProbeScanResult.lines(v, rawTested: true, skipped: 0, maxProbes: 6)
        XCTAssertEqual(l[0], "결과: 판정 못 함 - 광고로 폰을 찾았지만 (필터) 토큰을 못 읽었습니다.")
        XCTAssertTrue(l[1].contains("연결 실패 - 1~2분 뒤 다시 실행"))
        XCTAssertFalse(l.joined().contains("둘 다 안 됨"))
        XCTAssertFalse(l.joined().contains("GATT"))
    }

    func testListSawPhoneConnectedWithoutIdentService() {
        let v = decide([listCand(.noIdentService)])
        XCTAssertEqual(v, .seenNoToken(filter: false, list: true, reason: .noIdentService))
        let l = ProbeScanResult.lines(v, rawTested: true, skipped: 0, maxProbes: 6)
        XCTAssertEqual(l[0], "결과: 판정 못 함 - 광고로 폰을 찾았지만 (UUID 목록) 토큰을 못 읽었습니다.")
        XCTAssertTrue(l[1].contains("연결은 됨, 신원 서비스 없음 - 폰 앱 버전"))
    }

    func testBothScansSawPhoneNamesBoth() {
        let v = decide([filterCand(.unreachable), listCand(.unreachable)])
        XCTAssertEqual(v, .seenNoToken(filter: true, list: true, reason: .unreachable))
        XCTAssertEqual(firstLine(v), "결과: 판정 못 함 - 광고로 폰을 찾았지만 (필터, UUID 목록) 토큰을 못 읽었습니다.")
    }

    func testReasonComesFromStrongCandidatesOnly() {
        // 비트 하나짜리(남의 앱일 수 있다)가 붙어서 신원 서비스가 없었어도, 필터가 준 폰은 못 붙었다
        let v = decide([filterCand(.unreachable), bitCand(9, .noIdentService)])
        XCTAssertEqual(v, .seenNoToken(filter: true, list: false, reason: .unreachable))
    }

    func testReasonPrefersFurthestStep() {
        XCTAssertEqual(decide([filterCand(.unreachable), filterCand(.noIdentService), filterCand(.noToken)]),
                       .seenNoToken(filter: true, list: false, reason: .noToken))
        XCTAssertEqual(decide([filterCand(.unreachable), filterCand(.noIdentService)]),
                       .seenNoToken(filter: true, list: false, reason: .noIdentService))
        XCTAssertEqual(decide([filterCand(.notTried)]),
                       .seenNoToken(filter: true, list: false, reason: .notTried))
    }

    func testBitOnlyIsUndecided() {
        let v = decide([bitCand(9, .noIdentService), bitCand(31, .unreachable)])
        XCTAssertEqual(v, .bitOnlyNoToken)
        XCTAssertEqual(firstLine(v),
                       "결과: 판정 못 함 - 비트 하나짜리 기기는 있었지만 SmartScreen 폰인지 토큰으로 확인하지 못했습니다 - 다시 실행하세요.")
    }

    func testSkippedCandidatesAreMentionedWhenUndecided() {
        let l = ProbeScanResult.lines(.bitOnlyNoToken, rawTested: true, skipped: 3, maxProbes: 6)
        XCTAssertTrue(l.contains { $0.contains("후보 3대는 6대 상한에 걸려 붙어 보지 못했습니다") })
        // 정해진 결과에는 붙이지 않는다
        let d = ProbeScanResult.lines(.filter, rawTested: true, skipped: 3, maxProbes: 6)
        XCTAssertEqual(d.count, 1)
    }

    func testUndecidedSaysDoNotConclude() {
        for v: V in [.otherTokens(filter: true, raw: false), .bitOnlyNoToken,
                     .seenNoToken(filter: true, list: false, reason: .unreachable)] {
            let l = ProbeScanResult.lines(v, rawTested: true, skipped: 0, maxProbes: 6)
            XCTAssertTrue(l[0].hasPrefix("결과: 판정 못 함 - "), "\(v)")
            XCTAssertEqual(l.last, "      이 결과로 어느 길인지 결론 내지 마세요.")
        }
    }

    // MARK: 아무것도 못 봄

    func testNothingSeenWithBothScansIsNone() {
        let v = decide([])
        XCTAssertEqual(v, .none)
        let l = ProbeScanResult.lines(v, rawTested: true, skipped: 0, maxProbes: 6)
        XCTAssertEqual(l[0], "결과: 둘 다 안 됨 - 광고로는 잠긴 폰을 찾지 못했습니다. 남은 길은 GATT 경로뿐입니다:")
        XCTAssertTrue(l[1].contains("GATT"))
    }

    func testNothingSeenWithoutRawScanIsNotNone() {
        let v = decide([], rawTested: false)
        XCTAssertEqual(v, .nothingRawUntested)
        let l = ProbeScanResult.lines(v, rawTested: false, skipped: 0, maxProbes: 6)
        XCTAssertEqual(l, ["결과: 필터로는 못 찾음, 직접 읽기는 시험하지 못함 - 다시 실행해 보세요."])
    }

    func testFilterSawPhoneWithoutRawScanMentionsIt() {
        let v = decide([filterCand(.unreachable)], rawTested: false)
        XCTAssertEqual(v, .seenNoToken(filter: true, list: false, reason: .unreachable))
        let l = ProbeScanResult.lines(v, rawTested: false, skipped: 0, maxProbes: 6)
        XCTAssertTrue(l.contains { $0.contains("직접 읽기는 시험하지 못했습니다") })
    }

    func testNotScanned() {
        XCTAssertEqual(decide([filterCand(.token(mineTok))], registered: mineTok, scanned: false), .notScanned)
        XCTAssertEqual(firstLine(.notScanned), "결과: 식별자를 주어 스캔을 건너뛰었습니다 - 어느 길인지는 가리지 않습니다.")
    }

    func testPathlessCandidatesAreIgnored() {
        // 길이 없는 후보는 식별자 모드에서만 생긴다 - 스캔 결과로 치지 않는다
        let pathless = C(byFilter: false, rawList: false, bit: -1, attempt: .token(mineTok))
        XCTAssertEqual(decide([pathless], registered: mineTok), .none)
    }
}

final class ScanSourceTimesTests: XCTestCase {

    func testNoteSetsOnlyTheMatchingSource() {
        var t = ScanSourceTimes()
        t.note(fromRaw: false, bit: -1, listed: false, plain: false, now: 1000)
        XCTAssertEqual(t.filter, 1000)
        XCTAssertEqual(t.rawBit, 0)
        t.note(fromRaw: true, bit: 31, listed: false, plain: false, now: 2000)
        XCTAssertEqual(t.rawBit, 2000)
        XCTAssertEqual(t.bit, 31)
        XCTAssertEqual(t.rawList, 0)
        // 비트도 목록도 없는 R 광고 (같은 기기의 다른 Apple 광고) 는 아무 길도 아니다
        t.note(fromRaw: true, bit: -1, listed: false, plain: false, now: 3000)
        XCTAssertEqual(t.rawBit, 2000)
        XCTAssertEqual(t.bit, 31)
        t.note(fromRaw: true, bit: -1, listed: true, plain: true, now: 4000)
        XCTAssertEqual(t.rawList, 4000)
        XCTAssertEqual(t.plain, 4000)
        XCTAssertEqual(t.filter, 1000)
    }

    func testViaTextUsesOnlyRecentSources() {
        var t = ScanSourceTimes()
        // 앱이 화면에 떠 있을 때 필터가 줬고, 잠근 뒤로는 R 의 비트만 온다
        t.note(fromRaw: false, bit: -1, listed: false, plain: true, now: 1_000)
        t.note(fromRaw: true, bit: 31, listed: false, plain: false, now: 30_000)
        XCTAssertEqual(t.viaText(now: 31_000), "raw bit 31")
        // 둘 다 최근이면 순서대로
        t.note(fromRaw: false, bit: -1, listed: false, plain: false, now: 30_500)
        XCTAssertEqual(t.viaText(now: 31_000), "filter + raw bit 31")
    }

    func testViaTextFlagsAppOnScreen() {
        var t = ScanSourceTimes()
        t.note(fromRaw: false, bit: -1, listed: false, plain: true, now: 5_000)
        XCTAssertEqual(t.viaText(now: 6_000), "filter, app on screen")
        // 10초 넘게 지난 앱 화면은 말하지 않는다
        t.note(fromRaw: false, bit: -1, listed: false, plain: false, now: 20_000)
        XCTAssertEqual(t.viaText(now: 20_500), "filter")
    }

    func testViaTextWindowEdge() {
        var t = ScanSourceTimes()
        t.note(fromRaw: true, bit: 7, listed: true, plain: false, now: 10_000)
        XCTAssertEqual(t.viaText(now: 20_000), "raw bit 7 + raw list")   // 정확히 10초 = 안
        XCTAssertEqual(t.recent(now: 20_001, windowMs: 10_000), [])
    }

    func testViaTextFallsBackToNewestWithAge() {
        var t = ScanSourceTimes()
        t.note(fromRaw: false, bit: -1, listed: false, plain: false, now: 1_000)
        t.note(fromRaw: true, bit: 31, listed: false, plain: false, now: 5_000)
        // 25초 동안 아무도 안 줬다 -> 가장 최근(5초 시점) 기준 10초 안의 길 + 나이
        XCTAssertEqual(t.viaText(now: 30_000), "filter + raw bit 31, last seen 25s ago")
        XCTAssertEqual(ScanSourceTimes().viaText(now: 30_000), "")
    }

    func testClockGoingBackwardsCountsAsRecent() {
        var t = ScanSourceTimes()
        t.note(fromRaw: false, bit: -1, listed: false, plain: false, now: 5_000)
        XCTAssertEqual(t.recent(now: 4_000, windowMs: 10_000), [.filter])
    }

    func testTextOrder() {
        XCTAssertEqual(ScanSourceTimes.text([.rawList, .filter, .rawBit], bit: 3), "filter + raw bit 3 + raw list")
        XCTAssertEqual(ScanSourceTimes.text([.rawBit], bit: -1), "raw bit ?")
        XCTAssertEqual(ScanSourceTimes.text([], bit: 3), "")
    }
}

final class LockedPathLogTests: XCTestCase {

    private func locked(filter: UInt64 = 0, rawBit: UInt64 = 0, bit: Int = 31) -> ScanSourceTimes {
        var t = ScanSourceTimes()
        t.filter = filter
        t.rawBit = rawBit
        if rawBit != 0 { t.bit = bit }
        return t
    }

    func testFirstLockedAdvertIsLoggedOnce() {
        var log = LockedPathLog()
        XCTAssertNil(log.update(locked(), now: 1_000))   // 아직 잠긴 광고가 없다
        XCTAssertEqual(log.update(locked(rawBit: 2_000), now: 3_000), "raw bit 31")
        XCTAssertNil(log.update(locked(rawBit: 4_000), now: 5_000))
        XCTAssertNil(log.update(locked(rawBit: 6_500), now: 7_000))
    }

    func testNewSourceIsLogged() {
        var log = LockedPathLog()
        XCTAssertEqual(log.update(locked(rawBit: 2_000), now: 3_000), "raw bit 31")
        XCTAssertEqual(log.update(locked(filter: 4_000, rawBit: 4_100), now: 5_000), "filter + raw bit 31")
    }

    func testSporadicSourceDoesNotFlap() {
        // 필터가 가끔만 준다: 10초 창을 벗어나도 60초 안이면 빠지지 않는다
        var log = LockedPathLog()
        XCTAssertEqual(log.update(locked(filter: 1_000, rawBit: 1_000), now: 1_000), "filter + raw bit 31")
        var lines = 0
        var now: UInt64 = 3_000
        while now < 50_000 {
            if log.update(locked(filter: 1_000, rawBit: now - 500), now: now) != nil { lines += 1 }
            now += 2_000
        }
        XCTAssertEqual(lines, 0)
    }

    func testSourceSilentForAMinuteIsDropped() {
        var log = LockedPathLog()
        XCTAssertEqual(log.update(locked(filter: 1_000, rawBit: 1_000), now: 1_000), "filter + raw bit 31")
        XCTAssertNil(log.update(locked(filter: 1_000, rawBit: 60_000), now: 61_000))
        XCTAssertEqual(log.update(locked(filter: 1_000, rawBit: 61_500), now: 61_001 + 1_000), "raw bit 31")
    }

    func testQuietPhoneKeepsTheLoggedSet() {
        var log = LockedPathLog()
        XCTAssertEqual(log.update(locked(rawBit: 1_000), now: 1_000), "raw bit 31")
        XCTAssertNil(log.update(locked(rawBit: 1_000), now: 100_000))   // 조용하다 - 줄도, 잊기도 없다
        XCTAssertEqual(log.logged, [.rawBit])
        XCTAssertNil(log.update(locked(rawBit: 101_000), now: 102_000)) // 같은 길로 돌아왔다
    }

    func testResetLogsAgain() {
        var log = LockedPathLog()
        XCTAssertEqual(log.update(locked(rawBit: 1_000), now: 1_000), "raw bit 31")
        log.reset()
        XCTAssertEqual(log.update(locked(rawBit: 2_000), now: 2_000), "raw bit 31")
    }
}
