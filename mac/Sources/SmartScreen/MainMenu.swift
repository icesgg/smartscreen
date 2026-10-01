import AppKit

// MainMenu.swift - 보이지 않는 주 메뉴. 앱이 LSUIElement 라 메뉴 막대는 나오지 않지만, Cmd-C/V/X/A/Z
// 같은 단축키는 주 메뉴의 항목을 거쳐 글자 칸에 닿는다. 메뉴가 없으면 기업 등록 창의 조직 ID 칸에
// 대시보드에서 복사한 값을 Cmd-V 로 붙여 넣을 수 없다 (Windows 에서는 편집 칸이 저절로 해 주던 일).
//
// "종료" 항목은 일부러 없다. 정상 종료는 오버레이의 [종료] 하나다 - 화면을 지키는 프로그램이
// Cmd-Q 한 번에 꺼지면 안 된다.

enum MainMenu {
    static func install() {
        let bar = NSMenu()

        // 앱 메뉴 자리 (첫 항목은 macOS 가 앱 메뉴로 쓴다). 비워 둔다.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "SmartScreen")
        bar.addItem(appItem)

        let edit = NSMenu(title: "편집")
        _ = edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(NSMenuItem.separator())
        _ = edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        _ = edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        _ = edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        _ = edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        bar.addItem(editItem)

        NSApp.mainMenu = bar
    }
}
