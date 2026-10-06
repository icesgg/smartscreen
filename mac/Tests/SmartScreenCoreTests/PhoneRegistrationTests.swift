import XCTest
@testable import SmartScreenCore

// [폰 등록] 상자와 [등록 내역 삭제] (PhoneRegistration). 기대값은 Windows client/main.cpp 와 같은 원문을
// 통째로 적는다 - 조각을 같은 식으로 이어 붙여 비교하면 둘이 함께 틀려도 통과한다.
final class PhoneRegistrationTests: XCTestCase {

    private static let questionBase =
        "어떻게 등록할까요?\n\n[예]  구글 계정으로 등록  (권장)\n       아이폰 앱에서도 같은 계정으로 로그인하면 끝납니다.\n       폰을 가까이 둘 필요도, 앱을 띄울 필요도 없습니다.\n\n[아니오]  블루투스로 직접 등록\n       앱을 화면에 띄우고 폰을 PC 가까이 두세요.\n       인터넷 없이 됩니다."

    private static let tokenOnly = PhoneRegistration.Present(token: true, irk: false)
    private static let irkOnly = PhoneRegistration.Present(token: false, irk: true)
    private static let both = PhoneRegistration.Present(token: true, irk: true)
    private static let nothing = PhoneRegistration.Present(token: false, irk: false)

    // ------------------------------------------------------------------ 첫 질문

    func testQuestionWithoutDeleteIsTheOldText() {
        // 지울 것이 없으면 1.1.11 까지의 글 그대로
        XCTAssertEqual(PhoneRegistration.question(withDelete: false), PhoneRegistrationTests.questionBase)
    }

    func testQuestionWithDelete() {
        XCTAssertEqual(PhoneRegistration.question(withDelete: true),
                       "어떻게 등록할까요?\n\n[예]  구글 계정으로 등록  (권장)\n       아이폰 앱에서도 같은 계정으로 로그인하면 끝납니다.\n       폰을 가까이 둘 필요도, 앱을 띄울 필요도 없습니다.\n\n[아니오]  블루투스로 직접 등록\n       앱을 화면에 띄우고 폰을 PC 가까이 두세요.\n       인터넷 없이 됩니다.\n\n[등록 내역 삭제]  이 PC 에서 폰 등록을 지웁니다\n       구글 로그인과 클립보드 공유는 그대로입니다.")
    }

    func testTitleAndButton() {
        XCTAssertEqual(PhoneRegistration.title, "폰 등록")
        XCTAssertEqual(PhoneRegistration.deleteButton, "등록 내역 삭제")
    }

    // ------------------------------------------------------------------ 무엇이 있는가

    func testPresent() {
        XCTAssertEqual(PhoneRegistration.present(configToken: "", pendingToken: "", bleIrk: ""),
                       PhoneRegistrationTests.nothing)
        XCTAssertFalse(PhoneRegistration.present(configToken: "", pendingToken: "", bleIrk: "").any)
        XCTAssertEqual(PhoneRegistration.present(configToken: "AB12", pendingToken: "", bleIrk: ""),
                       PhoneRegistrationTests.tokenOnly)
        XCTAssertEqual(PhoneRegistration.present(configToken: "", pendingToken: "", bleIrk: "00112233"),
                       PhoneRegistrationTests.irkOnly)
        XCTAssertEqual(PhoneRegistration.present(configToken: "AB12", pendingToken: "", bleIrk: "00112233"),
                       PhoneRegistrationTests.both)
        // 아직 config 에 못 쓴 로그인 결과의 토큰도 등록이다 (곧 config 에 나타난다)
        XCTAssertEqual(PhoneRegistration.present(configToken: "", pendingToken: "CD34", bleIrk: ""),
                       PhoneRegistrationTests.tokenOnly)
        XCTAssertTrue(PhoneRegistrationTests.tokenOnly.any)
        XCTAssertTrue(PhoneRegistrationTests.irkOnly.any)
        XCTAssertTrue(PhoneRegistrationTests.both.any)
    }

    func testClearTouchesOnlyTheRegistration() {
        var c = AppConfig()
        c.phoneToken = "0123456789ABCDEF0123456789ABCDEF"
        c.phoneOvfBit = 17
        c.bleIrk = "00112233445566778899AABBCCDDEEFF"
        c.authRefresh = "sealed-refresh"
        c.authEmail = "me@example.com"
        c.authUserId = "user-1"
        c.clipSync = true
        c.nearRssiThreshold = -61
        c.centerImagePath = "/tmp/a.png"
        c.loaded = true

        var expected = c
        expected.phoneToken = ""
        expected.phoneOvfBit = -1
        expected.bleIrk = ""

        PhoneRegistration.clear(&c)
        // 구글 로그인, 클립보드 공유, 그 밖의 설정은 그대로 (AppConfig 는 Equatable - 다른 칸이 바뀌면 여기서 걸린다)
        XCTAssertEqual(c, expected)
        XCTAssertEqual(c.authRefresh, "sealed-refresh")
        XCTAssertEqual(c.authEmail, "me@example.com")
        XCTAssertEqual(c.authUserId, "user-1")
        XCTAssertTrue(c.clipSync)
    }

    // ------------------------------------------------------------------ 확인

    func testDeleteItems() {
        XCTAssertEqual(PhoneRegistration.deleteItems(PhoneRegistrationTests.tokenOnly), "폰 토큰")
        XCTAssertEqual(PhoneRegistration.deleteItems(PhoneRegistrationTests.irkOnly), "기기 키")
        XCTAssertEqual(PhoneRegistration.deleteItems(PhoneRegistrationTests.both), "폰 토큰, 기기 키")
        XCTAssertEqual(PhoneRegistration.deleteItems(PhoneRegistrationTests.nothing), "")
    }

    func testConfirmTokenOnly() {
        XCTAssertEqual(PhoneRegistration.deleteConfirm(PhoneRegistrationTests.tokenOnly, monitoring: false, irkReimport: false),
                       "이 PC 에서 폰 등록 내역을 지울까요?\n\n지울 것: 폰 토큰\n\n구글 로그인과 클립보드 공유는 그대로입니다.\n다른 PC 와 서버의 등록은 건드리지 않습니다.")
        XCTAssertEqual(PhoneRegistration.deleteConfirm(PhoneRegistrationTests.tokenOnly, monitoring: true, irkReimport: false),
                       "이 PC 에서 폰 등록 내역을 지울까요?\n\n지울 것: 폰 토큰\n보호가 켜져 있어 함께 끕니다.\n\n구글 로그인과 클립보드 공유는 그대로입니다.\n다른 PC 와 서버의 등록은 건드리지 않습니다.")
        // 기기 키가 없으면 Windows 에서도 [기기 키] 줄이 붙지 않는다
        XCTAssertEqual(PhoneRegistration.deleteConfirm(PhoneRegistrationTests.tokenOnly, monitoring: false, irkReimport: true),
                       "이 PC 에서 폰 등록 내역을 지울까요?\n\n지울 것: 폰 토큰\n\n구글 로그인과 클립보드 공유는 그대로입니다.\n다른 PC 와 서버의 등록은 건드리지 않습니다.")
    }

    func testConfirmIrkOnlyOnMac() {
        // Mac 은 [기기 키] 로 다시 넣을 수 없으므로 그 줄이 없다
        XCTAssertEqual(PhoneRegistration.deleteConfirm(PhoneRegistrationTests.irkOnly, monitoring: false, irkReimport: false),
                       "이 PC 에서 폰 등록 내역을 지울까요?\n\n지울 것: 기기 키\n\n구글 로그인과 클립보드 공유는 그대로입니다.\n다른 PC 와 서버의 등록은 건드리지 않습니다.")
        XCTAssertEqual(PhoneRegistration.deleteConfirm(PhoneRegistrationTests.irkOnly, monitoring: true, irkReimport: false),
                       "이 PC 에서 폰 등록 내역을 지울까요?\n\n지울 것: 기기 키\n보호가 켜져 있어 함께 끕니다.\n\n구글 로그인과 클립보드 공유는 그대로입니다.\n다른 PC 와 서버의 등록은 건드리지 않습니다.")
    }

    func testConfirmBothOnMac() {
        XCTAssertEqual(PhoneRegistration.deleteConfirm(PhoneRegistrationTests.both, monitoring: false, irkReimport: false),
                       "이 PC 에서 폰 등록 내역을 지울까요?\n\n지울 것: 폰 토큰, 기기 키\n\n구글 로그인과 클립보드 공유는 그대로입니다.\n다른 PC 와 서버의 등록은 건드리지 않습니다.")
        XCTAssertEqual(PhoneRegistration.deleteConfirm(PhoneRegistrationTests.both, monitoring: true, irkReimport: false),
                       "이 PC 에서 폰 등록 내역을 지울까요?\n\n지울 것: 폰 토큰, 기기 키\n보호가 켜져 있어 함께 끕니다.\n\n구글 로그인과 클립보드 공유는 그대로입니다.\n다른 PC 와 서버의 등록은 건드리지 않습니다.")
    }

    func testConfirmWindowsIrkLine() {
        // Windows 판 (irkReimport = true) 의 글. 같은 빌더가 두 판의 글을 낸다는 것을 여기서 묶어 둔다.
        XCTAssertEqual(PhoneRegistration.deleteConfirm(PhoneRegistrationTests.irkOnly, monitoring: false, irkReimport: true),
                       "이 PC 에서 폰 등록 내역을 지울까요?\n\n지울 것: 기기 키\n\n구글 로그인과 클립보드 공유는 그대로입니다.\n다른 PC 와 서버의 등록은 건드리지 않습니다.\n기기 키는 고급 설정의 [기기 키] 로 다시 넣을 수 있습니다.")
        XCTAssertEqual(PhoneRegistration.deleteConfirm(PhoneRegistrationTests.both, monitoring: true, irkReimport: true),
                       "이 PC 에서 폰 등록 내역을 지울까요?\n\n지울 것: 폰 토큰, 기기 키\n보호가 켜져 있어 함께 끕니다.\n\n구글 로그인과 클립보드 공유는 그대로입니다.\n다른 PC 와 서버의 등록은 건드리지 않습니다.\n기기 키는 고급 설정의 [기기 키] 로 다시 넣을 수 있습니다.")
    }

    // ------------------------------------------------------------------ 완료, 로그, 거절

    func testDone() {
        XCTAssertEqual(PhoneRegistration.deleteDone(protectionStopped: false), "이 PC 의 폰 등록 내역을 지웠습니다.")
        XCTAssertEqual(PhoneRegistration.deleteDone(protectionStopped: true), "이 PC 의 폰 등록 내역을 지웠습니다.\n보호를 껐습니다.")
    }

    func testLogLine() {
        XCTAssertEqual(PhoneRegistration.deleteLogLine(PhoneRegistrationTests.both, protectionStopped: true),
                       "register phone: registration deleted (token=1 irk=1, protection stopped)")
        XCTAssertEqual(PhoneRegistration.deleteLogLine(PhoneRegistrationTests.both, protectionStopped: false),
                       "register phone: registration deleted (token=1 irk=1)")
        XCTAssertEqual(PhoneRegistration.deleteLogLine(PhoneRegistrationTests.tokenOnly, protectionStopped: false),
                       "register phone: registration deleted (token=1 irk=0)")
        XCTAssertEqual(PhoneRegistration.deleteLogLine(PhoneRegistrationTests.tokenOnly, protectionStopped: true),
                       "register phone: registration deleted (token=1 irk=0, protection stopped)")
        XCTAssertEqual(PhoneRegistration.deleteLogLine(PhoneRegistrationTests.irkOnly, protectionStopped: false),
                       "register phone: registration deleted (token=0 irk=1)")
        XCTAssertEqual(PhoneRegistration.deleteLogLine(PhoneRegistrationTests.irkOnly, protectionStopped: true),
                       "register phone: registration deleted (token=0 irk=1, protection stopped)")
        // 확인 뒤 다시 읽어 보니 다른 길로 이미 지워졌던 때 (Windows 도 완료로 처리하고 이 줄을 남긴다)
        XCTAssertEqual(PhoneRegistration.deleteLogLine(PhoneRegistrationTests.nothing, protectionStopped: false),
                       "register phone: registration deleted (token=0 irk=0)")
    }

    func testFailureAndNothingLogLines() {
        // Windows client/main.cpp UnregisterPhone 의 DbgEvent 와 같은 글자
        XCTAssertEqual(PhoneRegistration.deleteSaveFailedLogLine,
                       "register phone: delete NOT saved - registration kept")
        XCTAssertEqual(PhoneRegistration.deleteNothingLogLine,
                       "register phone: delete - nothing registered on this PC")
    }

    func testRefuseAndSaveFailedTexts() {
        XCTAssertEqual(PhoneRegistration.deleteLoginBusyText, "로그인 중에는 지울 수 없습니다.\n브라우저 창을 확인하세요.")
        XCTAssertEqual(PhoneRegistration.deleteSaveFailedText, "설정을 저장하지 못했습니다. 다시 시도하세요.")
    }
}
