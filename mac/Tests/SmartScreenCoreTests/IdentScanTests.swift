import XCTest
@testable import SmartScreenCore

// 잠긴 폰 찾기: overflow 비트 읽기, 붙어 볼 후보 고르기, 두 스캔 관리자의 사본 거르기.
// 비트 번호는 Windows(client/ble_rssi.cpp SingleOverflowBit)와 같아야 한다 - config.ini 의
// phoneOvfBit 를 두 판이 같은 뜻으로 읽는다.
final class AppleOverflowTests: XCTestCase {

    /// CoreBluetooth 모양: 회사 id 4C 00 + 종류 01 + 16바이트 비트필드
    private func adv(_ field: [UInt8]) -> [UInt8] {
        return [0x4C, 0x00, 0x01] + field
    }

    private func field(setting bits: [Int]) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 16)
        for b in bits { f[b / 8] |= UInt8(1 << (b % 8)) }
        return f
    }

    func testSingleBitNumberingMatchesWindows() {
        // 바이트 b 의 비트 k (아래부터) = b*8+k
        XCTAssertEqual(AppleOverflow.singleBit(adv(field(setting: [0]))), 0)
        XCTAssertEqual(AppleOverflow.singleBit(adv(field(setting: [7]))), 7)
        XCTAssertEqual(AppleOverflow.singleBit(adv(field(setting: [8]))), 8)
        XCTAssertEqual(AppleOverflow.singleBit(adv(field(setting: [127]))), 127)
        // Windows 가 이 노트북에서 우리 신원 서비스에 대해 배운 값: 바이트 3 의 맨 위 비트
        var f = [UInt8](repeating: 0, count: 16)
        f[3] = 0x80
        XCTAssertEqual(AppleOverflow.singleBit(adv(f)), 31)
    }

    func testSingleBitNeedsExactlyOneBit() {
        XCTAssertEqual(AppleOverflow.singleBit(adv(field(setting: []))), -1)
        XCTAssertEqual(AppleOverflow.singleBit(adv(field(setting: [3, 31]))), -1)
        XCTAssertEqual(AppleOverflow.singleBit(adv(field(setting: [30, 31]))), -1)   // 같은 바이트의 두 비트
    }

    func testShapeIsExactly19BytesApple01() {
        let good = adv(field(setting: [31]))
        XCTAssertEqual(good.count, 19)
        // 길이 하나 차이
        XCTAssertEqual(AppleOverflow.singleBit(Array(good.dropLast())), -1)
        XCTAssertEqual(AppleOverflow.singleBit(good + [0x00]), -1)
        // 주변에 흔한 24바이트짜리 01 메시지 (01 09 20 22 ...)
        let common: [UInt8] = [0x4C, 0x00, 0x01, 0x09, 0x20, 0x22] + [UInt8](repeating: 0, count: 18)
        XCTAssertEqual(AppleOverflow.singleBit(common), -1)
        XCTAssertNil(AppleOverflow.bits(common))
        // 종류가 01 이 아니다 (0x10 = Nearby Info)
        var nearby = good
        nearby[2] = 0x10
        XCTAssertEqual(AppleOverflow.singleBit(nearby), -1)
        // 회사가 Apple 이 아니다 (바이트 순서가 거꾸로인 것 포함)
        var other = good
        other[0] = 0x06
        XCTAssertEqual(AppleOverflow.singleBit(other), -1)
        var swapped = good
        swapped[0] = 0x00
        swapped[1] = 0x4C
        XCTAssertEqual(AppleOverflow.singleBit(swapped), -1)
        // Windows 모양 (회사 id 없이 17바이트) 은 CoreBluetooth 에서 오지 않는다 - 받지 않는다
        XCTAssertEqual(AppleOverflow.singleBit([0x01] + field(setting: [31])), -1)
        XCTAssertEqual(AppleOverflow.singleBit([]), -1)
    }

    func testBitsListsEverySetBit() {
        XCTAssertEqual(AppleOverflow.bits(adv(field(setting: [31]))), [31])
        XCTAssertEqual(AppleOverflow.bits(adv(field(setting: [77, 3, 31]))), [3, 31, 77])
        XCTAssertEqual(AppleOverflow.bits(adv(field(setting: []))), [])
        XCTAssertEqual(AppleOverflow.bits(adv([UInt8](repeating: 0xFF, count: 16)))?.count, 128)
        XCTAssertNil(AppleOverflow.bits([0x4C, 0x00]))
    }

    func testIsApple() {
        XCTAssertTrue(AppleOverflow.isApple([0x4C, 0x00]))
        XCTAssertTrue(AppleOverflow.isApple([0x4C, 0x00, 0x10, 0x05]))
        XCTAssertFalse(AppleOverflow.isApple([0x4C]))
        XCTAssertFalse(AppleOverflow.isApple([0x00, 0x4C]))
        XCTAssertFalse(AppleOverflow.isApple([0x06, 0x00, 0x01]))
    }
}

final class IdentCandidatePickTests: XCTestCase {

    private typealias C = IdentCandidate<String>

    private func pick(_ cands: [C], learned: Int = -1, floor: Int = -75,
                      until: [String: UInt64] = [:], now: UInt64 = 10_000) -> (String, Int)? {
        guard let p = IdentCandidatePick.pick(cands, learnedBit: learned, probeFloor: floor,
                                              probedUntil: until, now: now) else { return nil }
        return (p.id, p.pass)
    }

    func testEmpty() {
        XCTAssertNil(pick([]))
    }

    func testStrongestWhenNothingIsPreferred() {
        // 비트를 모르고 sure 도 없다 -> 1차는 비고, 2차가 가장 센 것을 고른다
        let r = pick([C(id: "a", rssi: -70, sure: false, bit: 5),
                      C(id: "b", rssi: -50, sure: false, bit: 9),
                      C(id: "c", rssi: -60, sure: false, bit: -1)])
        XCTAssertEqual(r?.0, "b")
        XCTAssertEqual(r?.1, 1)
    }

    func testSureBeatsStrongerUnsure() {
        let r = pick([C(id: "loud", rssi: -40, sure: false, bit: 9),
                      C(id: "sure", rssi: -70, sure: true, bit: -1)])
        XCTAssertEqual(r?.0, "sure")
        XCTAssertEqual(r?.1, 0)
    }

    func testLearnedBitBeatsStrongerOther() {
        // Windows 1차: 배운 비트와 같은 후보만
        let r = pick([C(id: "other", rssi: -40, sure: false, bit: 9),
                      C(id: "ours", rssi: -70, sure: false, bit: 31)], learned: 31)
        XCTAssertEqual(r?.0, "ours")
        XCTAssertEqual(r?.1, 0)
    }

    func testPassZeroTakesStrongestOfSureAndBitMatch() {
        let r = pick([C(id: "sure", rssi: -65, sure: true, bit: -1),
                      C(id: "bit", rssi: -55, sure: false, bit: 31),
                      C(id: "loud", rssi: -30, sure: false, bit: 2)], learned: 31)
        XCTAssertEqual(r?.0, "bit")
        XCTAssertEqual(r?.1, 0)
    }

    func testBitMatchIgnoredWhenNothingLearned() {
        // learned = -1 이면 bit = -1 인 후보가 "같은 비트" 로 1차에 들어가면 안 된다
        let r = pick([C(id: "nobit", rssi: -70, sure: false, bit: -1),
                      C(id: "loud", rssi: -50, sure: false, bit: 4)], learned: -1)
        XCTAssertEqual(r?.0, "loud")
        XCTAssertEqual(r?.1, 1)
    }

    func testFallsBackToPassOneWhenPreferredAreBlocked() {
        // 1차 후보가 금지 시각/하한에 걸리면 2차에서 나머지를 본다
        let r = pick([C(id: "sure", rssi: -60, sure: true, bit: -1),
                      C(id: "weakbit", rssi: -80, sure: false, bit: 31),
                      C(id: "other", rssi: -65, sure: false, bit: 2)],
                     learned: 31, until: ["sure": 20_000])
        XCTAssertEqual(r?.0, "other")
        XCTAssertEqual(r?.1, 1)
    }

    func testFloorAndProbedUntil() {
        let cands = [C(id: "a", rssi: -76, sure: true, bit: -1),   // 하한(-75) 미만
                     C(id: "b", rssi: -75, sure: false, bit: -1)]  // 하한과 같으면 된다
        XCTAssertEqual(pick(cands)?.0, "b")
        // 금지 시각이 now 보다 뒤면 건너뛰고, now 와 같거나 앞이면 다시 본다 (Windows: now < until 이면 건너뜀)
        XCTAssertNil(pick([C(id: "x", rssi: -50, sure: true, bit: -1)], until: ["x": 10_001], now: 10_000))
        XCTAssertEqual(pick([C(id: "x", rssi: -50, sure: true, bit: -1)], until: ["x": 10_000], now: 10_000)?.0, "x")
        XCTAssertEqual(pick([C(id: "x", rssi: -50, sure: true, bit: -1)], until: ["x": 9_000], now: 10_000)?.0, "x")
    }

    func testUnmeasurableIsNeverPicked() {
        XCTAssertNil(pick([C(id: "x", rssi: -127, sure: true, bit: -1)], floor: -200))
        XCTAssertEqual(pick([C(id: "x", rssi: -126, sure: true, bit: -1)], floor: -200)?.0, "x")
    }

    func testTieKeepsFirst() {
        let r = pick([C(id: "first", rssi: -60, sure: true, bit: -1),
                      C(id: "second", rssi: -60, sure: true, bit: -1)])
        XCTAssertEqual(r?.0, "first")
    }
}

final class DualSourceDedupeTests: XCTestCase {

    func testFirstSampleIsAccepted() {
        var d = DualSourceDedupe()
        XCTAssertTrue(d.accept(source: 1, now: 1000))
    }

    func testOtherSourceCopyIsDropped() {
        var d = DualSourceDedupe()
        XCTAssertTrue(d.accept(source: 0, now: 1000))
        XCTAssertFalse(d.accept(source: 1, now: 1005))   // 같은 패킷의 R 사본
        XCTAssertFalse(d.accept(source: 1, now: 1399))
        XCTAssertTrue(d.accept(source: 1, now: 1400))    // 400 ms 뒤 = 새 패킷
    }

    func testSameSourceIsAlwaysAccepted() {
        // 앱이 화면에 떠 있어 광고가 빠를 때: 한 쪽 흐름은 끊기지 않는다
        var d = DualSourceDedupe()
        XCTAssertTrue(d.accept(source: 0, now: 1000))
        XCTAssertTrue(d.accept(source: 0, now: 1030))
        XCTAssertFalse(d.accept(source: 1, now: 1035))
        XCTAssertTrue(d.accept(source: 0, now: 1060))
        // 다른 쪽 판정은 마지막으로 "받은" 샘플부터 잰다
        XCTAssertFalse(d.accept(source: 1, now: 1459))
        XCTAssertTrue(d.accept(source: 1, now: 1460))
        // 이제 R 이 주인이다 - F 사본은 버린다
        XCTAssertFalse(d.accept(source: 0, now: 1462))
        XCTAssertTrue(d.accept(source: 1, now: 1490))
    }

    func testDroppedSampleDoesNotMoveTheWindow() {
        var d = DualSourceDedupe()
        XCTAssertTrue(d.accept(source: 0, now: 1000))
        XCTAssertFalse(d.accept(source: 1, now: 1300))   // 버린 것은 기준 시각을 바꾸지 않는다
        XCTAssertTrue(d.accept(source: 1, now: 1400))
    }

    func testLockedPhoneCadenceKeepsEveryPacketOnce() {
        // 잠긴 폰: 1.7 초마다 한 패킷, 두 관리자가 둘 다 알리고 먼저 오는 쪽은 그때그때 다르다
        var d = DualSourceDedupe()
        var counted = 0
        var t: UInt64 = 10_000
        for i in 0..<20 {
            let first = i % 3 == 0 ? 1 : 0
            if d.accept(source: first, now: t) { counted += 1 }
            if d.accept(source: 1 - first, now: t + 15) { counted += 1 }
            t += 1700
        }
        XCTAssertEqual(counted, 20)
    }

    func testClockGoingBackwardsCountsAsZero() {
        var d = DualSourceDedupe()
        XCTAssertTrue(d.accept(source: 0, now: 5000))
        XCTAssertFalse(d.accept(source: 1, now: 4000))
        XCTAssertTrue(d.accept(source: 0, now: 4000))    // 같은 쪽은 그래도 받는다
    }

    func testResetForgetsTheLastSample() {
        var d = DualSourceDedupe()
        XCTAssertTrue(d.accept(source: 0, now: 1000))
        d.reset()
        XCTAssertTrue(d.accept(source: 1, now: 1001))
    }
}
