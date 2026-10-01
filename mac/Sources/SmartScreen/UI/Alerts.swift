import AppKit

// Alerts.swift - Windows MessageBoxW 자리.
//
// Windows 의 알림 상자는 주인 창이 숨어 있어도 뜬다 (고급 창은 늘 숨어 있고, 간단 창의
// 단추도 그 창으로 명령을 넘긴다). Mac 앱은 LSUIElement 라 Dock 아이콘도 메뉴 막대도 없어서,
// 앱을 먼저 앞으로 불러오지 않으면 알림이 다른 앱 창 뒤에 깔려 아무도 못 본다.
//
// 단추 글자는 한국어로 고정한다 (예 / 아니오 / 취소 / 확인). 본문이 "[예] 구글 계정으로 등록",
// "[아니오] 블루투스로 직접 등록", "준비되면 확인을 누르세요" 처럼 단추 이름을 직접 부르므로
// 시스템 언어에 따라 바뀌면 안 된다.
//
// Windows 캡션(제목 막대)은 Mac 알림에 없으므로 굵은 제목 줄(messageText)로 보이고,
// 본문은 그 아래 informativeText 로 간다.
//
// runModal() 은 앱 전체를 막는 모달이지만, 타이머는 .common 모드에 걸려 있고 main 큐도
// 모달 중에 돈다 - Windows MessageBox 가 메시지를 계속 돌려 카운트다운과 잠금이 이어지던
// 것과 같다 (spec ui-advanced §13).
//
// 주의: main 큐는 "DispatchQueue.main.async 블록 바깥" 에서 띄운 모달 동안에만 돈다.
// libdispatch 는 main 큐를 겹쳐 비우지 않으므로, main.async 블록 안에서 이 함수를 부르면
// 알림이 떠 있는 동안 다른 main.async 블록(스캔 결과, 입력 전달...)이 전부 기다린다.
// 작업 스레드의 결과를 받아 알림을 띄울 때는 MainTimer.once(after: 0) 로 한 번 넘겨서 부른다.
// 단추 동작과 타이머 안에서 부르는 것은 괜찮다.

enum Alerts {
    /// MB_OK | MB_ICONINFORMATION
    static func info(_ text: String, title: String) {
        _ = present(text, title: title, warning: false, buttons: ["확인"], returnIndex: 0, escIndex: nil)
    }

    /// MB_OK | MB_ICONWARNING
    static func warning(_ text: String, title: String) {
        _ = present(text, title: title, warning: true, buttons: ["확인"], returnIndex: 0, escIndex: nil)
    }

    /// MB_OKCANCEL: true = 확인. Esc = 취소.
    static func okCancel(_ text: String, title: String) -> Bool {
        return present(text, title: title, warning: false, buttons: ["확인", "취소"],
                       returnIndex: 0, escIndex: 1) == 0
    }

    /// MB_YESNOCANCEL | MB_ICONQUESTION: 0 예 (Return), 1 아니오, 2 취소 (Esc).
    static func yesNoCancel(_ text: String, title: String) -> Int {
        let i = present(text, title: title, warning: false, buttons: ["예", "아니오", "취소"],
                        returnIndex: 0, escIndex: 2)
        // 알 수 없는 응답은 취소로 본다 - 아무것도 하지 않는 쪽이 안전하다.
        return (i == 0 || i == 1) ? i : 2
    }

    /// MB_YESNO. defaultNo = MB_DEFBUTTON2 (Return 이 [아니오]): 되돌리기 어려운 일을 묻는 곳
    /// (기업 등록 해제, 등록된 조직 바꾸기) 에서 Return 한 번에 일이 벌어지지 않게 한다.
    /// warning = MB_ICONWARNING, 아니면 MB_ICONQUESTION.
    static func yesNo(_ text: String, title: String, defaultNo: Bool, warning: Bool) -> Bool {
        // [예] 가 기본일 때만 Esc 를 [아니오] 에 준다. [아니오] 가 기본이면 그 단추가 Return 을
        // 갖고 (단추 하나는 단축키 하나), Windows MB_YESNO 도 Esc 를 받지 않는다.
        return present(text, title: title, warning: warning, buttons: ["예", "아니오"],
                       returnIndex: defaultNo ? 1 : 0, escIndex: defaultNo ? nil : 1) == 0
    }

    // MARK: - 내부

    /// 알림을 띄우고 누른 단추의 번호(0부터)를 돌려준다. 알 수 없으면 -1.
    private static func present(_ text: String, title: String, warning: Bool, buttons: [String],
                                returnIndex: Int?, escIndex: Int?) -> Int {
        // AppKit 은 main 에서만 만진다. 작업 스레드에서 잘못 불려도 죽지 않게 main 으로 넘긴다
        // (계약상 모든 호출자는 main 이다).
        if !Thread.isMainThread {
            var result = -1
            DispatchQueue.main.sync {
                result = present(text, title: title, warning: warning, buttons: buttons,
                                 returnIndex: returnIndex, escIndex: escIndex)
            }
            return result
        }

        activateApp()

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = warning ? .warning : .informational
        if warning, let caution = NSImage(named: NSImage.cautionName) {
            // Mac 의 .warning 은 앱 아이콘만 보인다. Windows 의 노란 삼각형과 같은 뜻이 보이게 한다.
            alert.icon = caution
        }
        for b in buttons {
            alert.addButton(withTitle: b)
        }
        // NSAlert 는 첫 단추에 Return 을 주고, 영어 "Cancel" 이라는 이름의 단추에만 Esc 를 준다.
        // 한국어 단추에는 직접 정해 준다.
        for (i, button) in alert.buttons.enumerated() {
            if let r = returnIndex, i == r {
                button.keyEquivalent = "\r"
            } else if let e = escIndex, i == e {
                button.keyEquivalent = "\u{1b}"
            } else {
                button.keyEquivalent = ""
            }
        }

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0 && index < buttons.count {
            return index
        }
        return -1
    }

    /// 숨은 창이 주인인 알림도 보이게 앱을 앞으로 부른다.
    /// NSApp 대신 NSApplication.shared: --clip-test 처럼 NSApplication 을 돌리기 전에 불려도 죽지 않는다.
    private static func activateApp() {
        let application = NSApplication.shared
        if #available(macOS 14.0, *) {
            application.activate()
        } else {
            application.activate(ignoringOtherApps: true)
        }
    }
}
