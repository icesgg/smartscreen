import XCTest
@testable import SmartScreenCore

final class RelVerTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(SemVer("1.2.3"), SemVer(1, 2, 3))
        XCTAssertEqual(SemVer("0.0.0"), SemVer(0, 0, 0))
        XCTAssertNil(SemVer(""))
        XCTAssertNil(SemVer("1.2"))
        XCTAssertNil(SemVer("1.2.3.4"))
        XCTAssertNil(SemVer(" 1.2.3"))
        XCTAssertNil(SemVer("1.2.3 "))
        XCTAssertNil(SemVer("+1.2.3"))
        XCTAssertNil(SemVer("1.2.3-beta"))
        XCTAssertNil(SemVer("1..3"))
        XCTAssertNil(SemVer(".1.2"))
        XCTAssertNil(SemVer("1.2."))
        XCTAssertNil(SemVer("1234567890.0.0"))   // 자리당 9 글자까지
        XCTAssertNotNil(SemVer("123456789.0.0"))
    }

    func testCompareIsNumeric() {
        XCTAssertTrue(SemVer("1.9.0")! < SemVer("1.10.0")!)
        XCTAssertTrue(SemVer("1.1.7")! < SemVer("1.1.8")!)
        XCTAssertFalse(SemVer("2.0.0")! < SemVer("1.99.99")!)
        XCTAssertEqual(SemVer("1.1.7"), SemVer("1.1.7"))
    }
}

final class KalmanTests: XCTestCase {
    func testFirstSampleInitializes() {
        var k = KalmanFilter()
        XCTAssertEqual(k.update(-60), -60)
    }

    func testMatchesWindowsArithmetic() {
        // Windows: P=1, Q=1, R=10. dt=1 → Ppred=2, K=2/12, x=-60+(1/6)(-72+60)=-62
        var k = KalmanFilter()
        k.update(-60)
        XCTAssertEqual(k.update(-72, dtSec: 1.0), -62, accuracy: 1e-9)
    }

    func testDtIsClamped() {
        var a = KalmanFilter(), b = KalmanFilter()
        a.update(-50); b.update(-50)
        XCTAssertEqual(a.update(-80, dtSec: 0.0), b.update(-80, dtSec: 0.05), accuracy: 1e-12)
        var c = KalmanFilter(), d = KalmanFilter()
        c.update(-50); d.update(-50)
        XCTAssertEqual(c.update(-80, dtSec: 1000), d.update(-80, dtSec: 60), accuracy: 1e-12)
    }

    // Windows 판은 스무딩 값을 C 의 lround 로 정수로 만든다 (0.5 는 0 에서 먼 쪽).
    // 이 앱도 Darwin 의 lround 를 쓴다.
    func testLroundAwayFromZero() {
        XCTAssertEqual(lround(-62.5), -63)
        XCTAssertEqual(lround(-62.4), -62)
        XCTAssertEqual(lround(2.5), 3)
    }
}
