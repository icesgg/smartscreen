import Foundation

// [폰 등록] 상자의 글과 [등록 내역 삭제] 가 지울 것 (Windows client/main.cpp 의 ID_BTN_REGISTER_PHONE).
//
// 글자는 Windows 와 한 바이트도 다르면 안 된다 - 두 판을 나란히 놓고 보는 사람이 있고, 안내 문서도
// 한 벌이다. 둘째 줄들의 들여쓰기는 7 칸, "[예]  " 뒤는 두 칸이다.
//
// [등록 내역 삭제] 는 이 PC 의 것만 지운다: 폰 토큰(phoneToken, 배운 overflow 비트 phoneOvfBit 와
// 함께)과 기기 키(bleIrk). 구글 로그인(authRefresh/authEmail/authUserId)과 클립보드 공유는 그대로
// 둔다 - 폰을 바꾸려는 사람이 로그인부터 다시 하게 만들 이유가 없다. 서버의 등록(device_tokens)과
// 다른 PC 는 건드리지 않는다 (같은 계정의 다른 PC 는 여전히 그 폰을 알아봐야 한다).
// Mac 은 IRK 를 쓰지 않지만 키 이름이 Windows 와 같으므로 bleIrk 도 같이 지운다 - 같은 단추가
// 두 판에서 같은 것을 지워야 문서가 한 벌로 남는다.
public enum PhoneRegistration {
    /// 상자 제목 (Windows 캡션)
    public static let title = "폰 등록"

    /// 넷째 단추. Windows 는 "등록 내역 삭제(&D)" (Alt+D) 이고 Mac 단추에는 단축 글자가 없다.
    public static let deleteButton = "등록 내역 삭제"

    /// [폰 등록] 의 첫 질문. 마지막 문단은 이 PC 에 지울 것이 있을 때만 붙는다 (단추도 그때만 있다) -
    /// 지울 것이 없는데 [등록 내역 삭제] 가 보이면 누른 사람이 무엇이 지워졌는지 묻게 된다.
    public static func question(withDelete: Bool) -> String {
        let base = "어떻게 등록할까요?\n\n"
            + "[예]  구글 계정으로 등록  (권장)\n"
            + "       아이폰 앱에서도 같은 계정으로 로그인하면 끝납니다.\n"
            + "       폰을 가까이 둘 필요도, 앱을 띄울 필요도 없습니다.\n\n"
            + "[아니오]  블루투스로 직접 등록\n"
            + "       앱을 화면에 띄우고 폰을 PC 가까이 두세요.\n"
            + "       인터넷 없이 됩니다."
        if !withDelete { return base }
        return base + "\n\n"
            + "[등록 내역 삭제]  이 PC 에서 폰 등록을 지웁니다\n"
            + "       구글 로그인과 클립보드 공유는 그대로입니다."
    }

    // MARK: - 무엇이 있는가 / 무엇을 지우는가

    /// 이 PC 에 남아 있는 등록. token 과 irk 중 하나라도 있으면 단추를 보인다.
    public struct Present: Equatable {
        public let token: Bool
        public let irk: Bool
        public var any: Bool { return token || irk }
        public init(token: Bool, irk: Bool) {
            self.token = token
            self.irk = irk
        }
    }

    /// pendingToken 은 아직 config.ini 에 못 쓴 로그인 결과의 토큰이다 (Mac AuthSave.phoneToken). 다시
    /// 쓰는 타이머가 곧 config 에 적으므로 이것도 등록이다 - 빼고 보면 단추가 안 보이는데, 몇 초 뒤
    /// 토큰이 config 에 나타난다.
    public static func present(configToken: String, pendingToken: String, bleIrk: String) -> Present {
        return Present(token: !configToken.isEmpty || !pendingToken.isEmpty, irk: !bleIrk.isEmpty)
    }

    /// 지울 것을 지운다. 토큰과 함께 overflow 비트도 처음(-1)으로 - 그 폰에서 배운 값이라 다음에 등록할
    /// 폰의 후보를 엉뚱하게 좁힌다. 계정 값, 클립보드, 임계값, 그림 경로는 손대지 않는다.
    public static func clear(_ c: inout AppConfig) {
        c.phoneToken = ""
        c.phoneOvfBit = -1
        c.bleIrk = ""
    }

    // MARK: - 확인, 완료, 로그

    /// "지울 것:" 뒤의 목록. 아무것도 없으면 빈 글 (부르는 쪽이 그 전에 그만둔다).
    public static func deleteItems(_ p: Present) -> String {
        if p.token && p.irk { return "폰 토큰, 기기 키" }
        if p.token { return "폰 토큰" }
        if p.irk { return "기기 키" }
        return ""
    }

    /// 지우기 전 확인 (MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2).
    /// monitoring: 보호가 켜져 있으면 함께 끈다고 미리 말한다 - 등록이 없으면 PC 가 폰을 알아보지 못해
    /// 곧바로 화면을 가린다. 꺼져 있으면 그 줄이 통째로 빠진다 (빈 줄을 남기지 않는다).
    /// irkReimport: 지운 기기 키를 [기기 키] 단추로 다시 넣을 수 있는 판인가. Windows 만 true 다 -
    /// Mac 의 [기기 키] 는 "Windows 에서만" 이라고 안내만 하므로 Mac 은 늘 false 를 넘긴다.
    public static func deleteConfirm(_ p: Present, monitoring: Bool, irkReimport: Bool) -> String {
        let protection = monitoring ? "보호가 켜져 있어 함께 끕니다.\n" : ""
        let irkLine = (p.irk && irkReimport) ? "\n기기 키는 고급 설정의 [기기 키] 로 다시 넣을 수 있습니다." : ""
        return "이 PC 에서 폰 등록 내역을 지울까요?\n\n"
            + "지울 것: \(deleteItems(p))\n"
            + protection
            + "\n구글 로그인과 클립보드 공유는 그대로입니다.\n"
            + "다른 PC 와 서버의 등록은 건드리지 않습니다."
            + irkLine
    }

    /// 지운 뒤 (MB_ICONINFORMATION)
    public static func deleteDone(protectionStopped: Bool) -> String {
        return "이 PC 의 폰 등록 내역을 지웠습니다." + (protectionStopped ? "\n보호를 껐습니다." : "")
    }

    /// events.log 한 줄. 무엇이 있었는지를 0/1 로 남긴다 - "폰을 못 알아본다" 는 문의가 오면 지운
    /// 적이 있는지부터 여기서 갈린다.
    public static func deleteLogLine(_ p: Present, protectionStopped: Bool) -> String {
        return "register phone: registration deleted (token=\(p.token ? 1 : 0) irk=\(p.irk ? 1 : 0)"
            + (protectionStopped ? ", protection stopped" : "") + ")"
    }

    /// 로그인이 도는 중에는 지우지 않는다. 그 로그인이 끝나면 계정의 토큰을 config 에 쓰므로, 지금
    /// 지워도 몇 분 뒤 되살아난다 - "지웠습니다" 가 거짓말이 된다.
    public static let deleteLoginBusyText = "로그인 중에는 지울 수 없습니다.\n브라우저 창을 확인하세요."

    /// config.ini 를 못 썼다. 지운 것이 없으므로 "지웠습니다" 라고 하지 않는다.
    public static let deleteSaveFailedText = "설정을 저장하지 못했습니다. 다시 시도하세요."
}
