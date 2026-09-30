import XCTest
@testable import SmartScreenCore

final class BuildInfoTests: XCTestCase {
    func testVersionIsNotEmpty() {
        XCTAssertFalse(BuildInfo.version.isEmpty)
    }
}
