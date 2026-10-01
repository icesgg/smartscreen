import AppKit
import SmartScreenCore

// AppDelegate.swift - NSApplication 이 부르는 몇 곳만 받는다. 앱의 일은 전부 AppController 가 한다.
//
// 종료 규칙: 화면을 지키는 프로그램이 실수로 꺼지면 안 되므로 정상 종료는 오버레이의 [종료] 하나다
// (설정 창들의 닫기 단추는 숨기기만 한다). 메뉴에 "종료" 항목도 없다. 그래도 로그아웃, 재시동, 시스템
// 종료, `osascript -e 'quit app "SmartScreen"'` 는 applicationShouldTerminate 로 온다 - 그때는 [종료] 와
// 같은 절차를 돌리고 바로 끝낸다. 로그아웃을 막는 앱이 되면 안 된다.

// NSApplicationDelegate 는 아래 확장에서 따른다. 주 선언에 적으면 Swift 5 모드에서 클래스 전체가
// @MainActor 로 추론되어, main.swift 의 최상위 코드(격리 없음)에서 만드는 것이 격리 위반이 될 수
// 있다 (설정 창 컨트롤러들과 같은 선택).
final class AppDelegate: NSObject {
}

extension AppDelegate: NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppController.shared == nil {
            AppController.shared = AppController()
        }
        AppController.shared.launch()
    }

    /// Finder / Launchpad 에서 이미 떠 있는 앱을 다시 열었다. Dock 아이콘도 트레이도 없는 앱이라
    /// 오버레이 [설정] 말고는 이것이 간단 창으로 돌아오는 길이다 (길을 하나 더할 뿐 빼는 것은 없다).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.shared?.showSimple()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // [종료] (normalExit) 에서 왔으면 절차는 이미 끝났다. 아니면 (로그아웃, quit 이벤트) 여기서 돌린다.
        if let app = AppController.shared, !app.isExiting {
            app.prepareForTermination()
        }
        return .terminateNow
    }

    /// 마지막 창을 닫아도 끝나지 않는다 (창은 숨기기만 하고, 앱은 오버레이로 계속 산다)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
