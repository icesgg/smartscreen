import AppKit
import SmartScreenCore

// EnterpriseDialogs.swift - [기업용 둘러보기] 의 두 단계 (Windows main.cpp ID_BTN_ENTERPRISE).
//
//  1단계 "쇼케이스": 테두리 없는 560x520 어두운 판. 카드 셋과 단추 둘.
//      [관리자 대시보드] -> 대시보드 주소를 연다 (판은 그대로).
//      [지금 시작하기]   -> 판을 닫고, 대시보드를 열고, 2단계.
//  2단계 "무료 체험 시작": 조직 ID 를 붙여 넣고 [연결 및 동기화]. 같은 단추로 등록과 해제를 다 한다
//      (칸을 비우고 누르면 해제).
//
// Windows 는 두 창을 중첩 메시지 루프로 띄우고 주인(고급 창)만 막았다. 그동안에도 오버레이, 검은
// 화면의 [해제], 간단 창은 눌렸다. Mac 에서 NSApp.runModal(for:) 을 쓰면 앱 전체가 막혀 그것들까지
// 못 누르게 되므로, 모달 없이 늘 위에 뜨는 창으로 띄우고 한 번에 하나만 열리게 한다 (이미 열려
// 있으면 그 창을 앞으로). 고급 창이 막혀 있던 것과 같은 결과: 두 번째 창이 생기지 않는다.
//
// Windows 는 [연결 및 동기화] 의 서버 확인과 동기화(최대 200 MB 내려받기)를 UI 스레드에서 했다 -
// 그동안 카운트다운도 멎었다. Mac 은 그 둘만 작업 큐에서 하고 단추를 꺼 두며, 나머지 단계는
// 같은 순서로 main 에서 잇는다 (spec enterprise-auth §8.3, §10).

enum EnterpriseDialogs {
    fileprivate static var showcase: EntShowcaseController?
    fileprivate static var setup: EntSetupController?

    /// 1단계. 지금 시작하기 -> 2단계.
    static func showShowcase(app: AppController) {
        if let s = showcase {
            s.bringToFront()
            return
        }
        // Windows 에서는 2단계가 떠 있는 동안 고급 창이 꺼져 있어 이 단추에 닿을 수 없었다.
        if let s = setup {
            s.bringToFront()
            return
        }
        let c = EntShowcaseController(app: app)
        showcase = c
        c.present()
    }

    /// 2단계 "무료 체험 시작" (등록 / 해제).
    static func showSetup(app: AppController) {
        if let s = setup {
            s.bringToFront()
            return
        }
        let c = EntSetupController(app: app)
        setup = c
        c.present()
    }

    // MARK: - 같이 쓰는 도우미

    fileprivate static func openDashboard() {
        guard let u = URL(string: ServerDefaults.dashboardUrl) else { return }
        _ = NSWorkspace.shared.open(u)
    }

    fileprivate static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Windows 는 SM_CXSCREEN/SM_CYSCREEN (주 화면 전체) 의 가운데에 놓았다.
    fileprivate static func centerOnPrimaryScreen(_ w: NSWindow) {
        guard let screen = NSScreen.screens.first else {
            w.center()
            return
        }
        let sf = screen.frame
        let fr = w.frame
        w.setFrameOrigin(NSPoint(x: (sf.midX - fr.width / 2).rounded(),
                                 y: (sf.midY - fr.height / 2).rounded()))
    }

    /// 닫힌 뒤 Windows 는 SetForegroundWindow(고급 창) 을 했다. 고급 창이 보일 때만 앞으로.
    fileprivate static func returnToAdvanced(_ app: AppController) {
        guard let adv = app.advanced else { return }
        let w = adv.window
        if w.isVisible && !w.isMiniaturized {
            w.makeKeyAndOrderFront(nil)
        }
    }

    fileprivate static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        return NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0,
                       blue: CGFloat(b) / 255.0, alpha: 1.0)
    }
}

// MARK: - 1단계: 쇼케이스

// 창 위임은 확장에서 따른다 (주 선언에 적으면 클래스 전체가 @MainActor 로 추론된다 - 고급 창 주석).
fileprivate final class EntShowcaseController: NSObject {
    private unowned let app: AppController
    private let window: EntShowcaseWindow
    private let view: EntShowcaseView
    /// [지금 시작하기] 로 닫힐 때는 2단계가 이어서 뜨므로 고급 창을 앞으로 부르지 않는다.
    private var handingOver = false

    private static let width: CGFloat = 560
    private static let height: CGFloat = 520

    init(app: AppController) {
        self.app = app
        let frame = NSRect(x: 0, y: 0, width: EntShowcaseController.width, height: EntShowcaseController.height)
        window = EntShowcaseWindow(contentRect: frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        view = EntShowcaseView(frame: frame)
        super.init()

        window.isReleasedWhenClosed = false
        window.title = "SmartScreen Enterprise"
        // WS_EX_TOPMOST
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = EnterpriseDialogs.rgb(18, 20, 28)
        window.hasShadow = true
        window.delegate = self
        window.contentView = view
        window.onCloseKey = { [weak self] in
            self?.closeDialog()
        }
        view.onClose = { [weak self] in
            self?.closeDialog()
        }

        // 아래쪽 단추 둘 (y = H - 75), 둥근 모서리, 눌리면 각 색 +30.
        let buttonY = EntShowcaseController.height - 75
        let dash = EntPillButton(frame: NSRect(x: 40, y: buttonY, width: 220, height: 40),
                                 title: "관리자 대시보드",
                                 fill: (79, 140, 255), textColor: NSColor.white)
        dash.onClick = {
            // 판은 그대로 둔다.
            EnterpriseDialogs.openDashboard()
        }
        let start = EntPillButton(frame: NSRect(x: 300, y: buttonY, width: 220, height: 40),
                                  title: "지금 시작하기",
                                  fill: (52, 211, 153), textColor: EnterpriseDialogs.rgb(18, 20, 28))
        start.onClick = { [weak self] in
            self?.startSetup()
        }
        view.addSubview(dash)
        view.addSubview(start)
    }

    func present() {
        EnterpriseDialogs.centerOnPrimaryScreen(window)
        EnterpriseDialogs.activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    func bringToFront() {
        EnterpriseDialogs.activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    private func closeDialog() {
        window.close()
    }

    /// [지금 시작하기]: 이 판을 먼저 닫고, 대시보드를 브라우저로 연 다음, 2단계.
    private func startSetup() {
        let a = app
        handingOver = true
        closeDialog()
        EnterpriseDialogs.openDashboard()
        EnterpriseDialogs.showSetup(app: a)
    }

    fileprivate func didClose() {
        if EnterpriseDialogs.showcase === self {
            EnterpriseDialogs.showcase = nil
        }
        if !handingOver {
            EnterpriseDialogs.returnToAdvanced(app)
        }
    }
}

extension EntShowcaseController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        didClose()
    }
}

/// 테두리 없는 창은 기본으로 키 창이 못 된다. 키 입력(Cmd-W, Esc)을 받으려면 필요하다.
private final class EntShowcaseWindow: NSWindow {
    var onCloseKey: (() -> Void)?

    override var canBecomeKey: Bool { return true }

    override func keyDown(with event: NSEvent) {
        // Esc: Windows 판에는 없지만 (Alt+F4 만), 테두리 없는 Mac 판에서 닫는 자연스러운 길이다.
        if event.keyCode == 53 {
            onCloseKey?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd-W = Windows 의 Alt+F4
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCloseKey?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 쇼케이스 그림 (Windows WM_PAINT). 좌표는 Windows 픽셀 그대로, 뒤집힌 좌표계.
/// 글자 크기: Windows 셀 높이 px 의 약 0.78 배 pt (고급 창과 같은 비율).
private final class EntShowcaseView: NSView {
    var onClose: (() -> Void)?

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    private struct Card {
        let accent: NSColor
        let title: String
        let desc: String
    }

    // NEXT_SESSION: 3번 카드는 이제 없는 P2P 기능을 말한다 (빌드에서 빠졌다). 문구를 바꿀지는
    // 주인이 정한다 - 그때까지 Windows 와 같은 글자를 둔다.
    private let cards: [Card] = [
        Card(accent: EnterpriseDialogs.rgb(79, 140, 255),
             title: "중앙 집중 관리",
             desc: "관리자 대시보드에서 잠금 화면 콘텐츠를 업로드하면\n사내 모든 PC에 자동으로 배포됩니다."),
        Card(accent: EnterpriseDialogs.rgb(52, 211, 153),
             title: "기업 브랜딩 & 보안 공지",
             desc: "회사 로고, 보안 정책, 긴급 공지를 잠금 화면에 표시.\n조직별 콘텐츠 분리로 보안을 강화합니다."),
        Card(accent: EnterpriseDialogs.rgb(251, 191, 36),
             title: "P2P 스마트 배포",
             desc: "사내 네트워크 P2P 전송으로 서버 부하를 최소화.\n설치 후 조직 ID 하나만 입력하면 자동 연동됩니다."),
    ]

    override func draw(_ dirtyRect: NSRect) {
        let W = bounds.width, H = bounds.height

        EnterpriseDialogs.rgb(18, 20, 28).setFill()
        NSBezierPath.fill(bounds)

        // 머리 띠 (위 80 px)
        EnterpriseDialogs.rgb(25, 28, 40).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: W, height: 80))

        EntShowcaseView.drawText("SmartScreen Enterprise",
                                 in: NSRect(x: 32, y: 16, width: W - 40 - 32, height: 32),
                                 font: NSFont.boldSystemFont(ofSize: 20), color: NSColor.white)
        EntShowcaseView.drawText("비즈니스를 위한 스마트한 보안",
                                 in: NSRect(x: 32, y: 48, width: W - 40 - 32, height: 20),
                                 font: NSFont.systemFont(ofSize: 11), color: EnterpriseDialogs.rgb(140, 150, 170))
        // 닫기 글자 (U+2715). 이 칸을 누르면 닫힌다 (mouseDown).
        EntShowcaseView.drawText("\u{2715}", in: EntShowcaseView.closeRect(width: W),
                                 font: NSFont.systemFont(ofSize: 15.5), color: EnterpriseDialogs.rgb(140, 150, 170),
                                 align: .center, vcenter: true)

        // 카드 셋: x 32..W-32, 높이 100, 간격 8, 위 92/200/308
        let cardLeft: CGFloat = 32, cardRight = W - 32
        let cardH: CGFloat = 100, cardGap: CGFloat = 8, cardTop: CGFloat = 92
        let titleFont = NSFont.boldSystemFont(ofSize: 12.5)
        let descFont = NSFont.systemFont(ofSize: 10)
        let dotFont = NSFont.systemFont(ofSize: 22)
        for (i, card) in cards.enumerated() {
            let y = cardTop + CGFloat(i) * (cardH + cardGap)
            EnterpriseDialogs.rgb(30, 34, 48).setFill()
            NSBezierPath.fill(NSRect(x: cardLeft, y: y, width: cardRight - cardLeft, height: cardH))
            card.accent.setFill()
            NSBezierPath.fill(NSRect(x: cardLeft, y: y, width: 4, height: cardH))
            EntShowcaseView.drawText(card.title,
                                     in: NSRect(x: cardLeft + 20, y: y + 14,
                                                width: (cardRight - 50) - (cardLeft + 20), height: 20),
                                     font: titleFont, color: NSColor.white)
            EntShowcaseView.drawText(card.desc,
                                     in: NSRect(x: cardLeft + 20, y: y + 40,
                                                width: (cardRight - 20) - (cardLeft + 20), height: cardH - 8 - 40),
                                     font: descFont, color: EnterpriseDialogs.rgb(170, 175, 190), wrap: true)
            // 오른쪽 장식 점 (U+25CF)
            EntShowcaseView.drawText("\u{25CF}",
                                     in: NSRect(x: cardRight - 48, y: y + 10, width: 40, height: 34),
                                     font: dotFont, color: card.accent, align: .center)
        }

        // 아래 문구
        EntShowcaseView.drawText("무료 체험 \u{00B7} 신용카드 불필요",
                                 in: NSRect(x: 0, y: H - 28, width: W, height: 20),
                                 font: NSFont.systemFont(ofSize: 9.5), color: EnterpriseDialogs.rgb(100, 110, 130),
                                 align: .center)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = EntShowcaseView.closeRect(width: bounds.width)
        // Windows: x 가 [W-40, W-8], y 가 [8, 36] 이면 닫는다 (경계 포함).
        if p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY {
            onClose?()
            return
        }
        super.mouseDown(with: event)
    }

    private static func closeRect(width W: CGFloat) -> NSRect {
        return NSRect(x: W - 40, y: 8, width: 32, height: 28)
    }

    /// DrawTextW 비슷하게: 왼쪽/가운데 맞춤, 한 줄(넘치면 잘림) 또는 낱말 단위 줄바꿈, 세로 가운데 선택.
    fileprivate static func drawText(_ s: String, in r: NSRect, font: NSFont, color: NSColor,
                                     align: NSTextAlignment = .left, wrap: Bool = false,
                                     vcenter: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = wrap ? .byWordWrapping : .byClipping
        // 한글은 기본으로 글자 사이에서도 줄을 바꾼다. DT_WORDBREAK 처럼 띄어쓰기에서 바꾼다.
        para.lineBreakStrategy = .hangulWordPriority
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        let a = NSAttributedString(string: s, attributes: attrs)
        var target = r
        if vcenter {
            let h = ceil(a.size().height)
            target = NSRect(x: r.minX, y: r.minY + floor((r.height - h) / 2), width: r.width, height: h)
        }
        a.draw(in: target)
    }
}

/// 직접 그리는 둥근 단추 (BS_OWNERDRAW). RoundRect(..., 8, 8) 은 지름 8 의 모서리 = 반지름 4.
private final class EntPillButton: NSView {
    var onClick: (() -> Void)?

    private let title: String
    private let fill: (Int, Int, Int)
    private let textColor: NSColor
    private var pressed = false {
        didSet { if pressed != oldValue { needsDisplay = true } }
    }

    init(frame: NSRect, title: String, fill: (Int, Int, Int), textColor: NSColor) {
        self.title = title
        self.fill = fill
        self.textColor = textColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        // 눌린 동안은 각 색을 30 밝게 (255 에서 멈춤).
        let add = pressed ? 30 : 0
        let color = EnterpriseDialogs.rgb(min(fill.0 + add, 255), min(fill.1 + add, 255), min(fill.2 + add, 255))
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        EntShowcaseView.drawText(title, in: bounds, font: NSFont.boldSystemFont(ofSize: 11.5),
                                 color: textColor, align: .center, vcenter: true)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside {
            onClick?()
        }
    }
}

// MARK: - 2단계: 무료 체험 시작 (등록 / 해제)

fileprivate final class EntSetupController: NSObject {
    private unowned let app: AppController
    private let window: NSWindow
    private let orgField: NSTextField
    private let connectButton: NSButton
    private let statusLabel: NSTextField
    /// 서버에 묻는 중. 단추를 꺼 두고, 창도 닫히지 않게 한다 (Windows 는 그동안 UI 전체가 멎어
    /// 닫을 수도 없었다 - 결과를 반영하는 단계가 닫힌 창 뒤에서 돌지 않게 한다).
    private var busy = false

    // Windows 바깥 460x380 (제목 막대 + 얇은 테두리) = 클라이언트 약 444x341.
    private static let contentWidth: CGFloat = 444
    private static let contentHeight: CGFloat = 341

    init(app: AppController) {
        self.app = app
        let cfg = ConfigStore.load()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: EntSetupController.contentWidth,
                                              height: EntSetupController.contentHeight),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // 저장된 조직 ID 로 미리 채운다 (Windows 는 128 칸 버퍼 = 127 글자까지).
        orgField = NSTextField(string: TextSanitize.capUTF16(cfg.orgId, 127))
        connectButton = NSButton(title: "연결 및 동기화", target: nil, action: nil)
        // 이미 등록된 PC 에서는 돌아가는 길을 여기에 적어 둔다. 단추가 하나뿐이라 적어 두지
        // 않으면 해제할 수 있다는 것을 알 방법이 없다.
        statusLabel = NSTextField(labelWithString: cfg.enterpriseRegistered ? "해제: 칸을 비우고 누르기" : "")
        super.init()

        window.title = "무료 체험 시작"
        window.isReleasedWhenClosed = false
        // WS_EX_TOPMOST: 브라우저(대시보드)에서 조직 ID 를 복사해 오는 동안에도 보인다.
        window.level = .floating
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self

        let content = EntSetupFlippedView(frame: NSRect(x: 0, y: 0, width: EntSetupController.contentWidth,
                                                         height: EntSetupController.contentHeight))
        window.contentView = content

        // 안내 (Windows 는 옛 System 글꼴이었다 - Mac 은 보통 시스템 글꼴, spec §15.7)
        add(content, EntSetupController.label("브라우저에서 대시보드가 열렸습니다."), 20, 16, 400, 20)
        add(content, EntSetupController.label("아래 순서대로 진행하세요:"), 20, 40, 400, 20)
        let steps = NSTextField(wrappingLabelWithString:
            "  1. Google 계정으로 로그인\n  2. 조직 이름을 입력하고 조직 생성\n  3. 잠금 화면에 표시할 이미지/동영상 업로드\n  4. 조직 ID를 복사하여 아래에 붙여넣기")
        steps.isSelectable = false
        add(content, steps, 20, 68, 410, 80)

        let separator = NSBox(frame: .zero)
        separator.boxType = .separator
        add(content, separator, 20, 160, 400, 1)

        add(content, EntSetupController.label("조직 ID:"), 20, 175, 60, 20)
        orgField.isEditable = true
        orgField.isSelectable = true
        orgField.cell?.isScrollable = true      // ES_AUTOHSCROLL
        orgField.cell?.wraps = false
        orgField.cell?.usesSingleLineMode = true
        // Windows 칸 높이 26 의 가운데에 Mac 표준 높이(22)로 놓는다.
        add(content, orgField, 85, 174, 330, 22)

        // 키 큰 단추(36)는 높이만큼 늘어나는 네모 단추로.
        connectButton.bezelStyle = .regularSquare
        connectButton.target = self
        connectButton.action = #selector(onConnect)
        add(content, connectButton, 20, 215, 140, 36)

        statusLabel.lineBreakMode = .byClipping
        statusLabel.isSelectable = false
        add(content, statusLabel, 170, 223, 250, 20)

        add(content, EntSetupController.label("대시보드가 열리지 않았나요?"), 20, 267, 200, 18)
        let dashButton = NSButton(title: "대시보드 열기", target: self, action: #selector(onOpenDashboard))
        dashButton.bezelStyle = .rounded
        add(content, dashButton, 20, 288, 120, 28)

        // 붙여 넣기를 바로 할 수 있게 조직 ID 칸에서 시작한다.
        window.initialFirstResponder = orgField
    }

    func present() {
        EnterpriseDialogs.centerOnPrimaryScreen(window)
        EnterpriseDialogs.activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    func bringToFront() {
        EnterpriseDialogs.activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    /// 서버에 묻는 동안은 닫히지 않는다.
    fileprivate var canClose: Bool { return !busy }

    fileprivate func didClose() {
        if EnterpriseDialogs.setup === self {
            EnterpriseDialogs.setup = nil
        }
        EnterpriseDialogs.returnToAdvanced(app)
    }

    // MARK: - 단추

    @objc private func onOpenDashboard() {
        EnterpriseDialogs.openDashboard()
    }

    /// [연결 및 동기화] (spec enterprise-auth §8.3 / ui-advanced §7.12).
    @objc private func onConnect() {
        if busy { return }

        // 붙여 넣은 값에는 앞뒤 공백이나 줄바꿈이 딸려 온다.
        let typed = TextSanitize.capUTF16(orgField.stringValue, 127)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))

        let sc = ConfigStore.load()

        // ---- 돌아가는 길: 빈 칸 + 같은 단추 = 등록 해제 ----
        // 예전에는 enterpriseRegistered 를 끄는 코드가 어디에도 없었다. 한 번 눌러 본 개인 사용자는
        // config.ini 를 손으로 고치기 전에는 기업 PC 로 남았고, 그 PC 의 업데이트는 없는 관리자의
        // 승인을 영영 기다렸다.
        if typed.isEmpty {
            unregister(sc)
            return
        }

        // ---- 등록 ----
        // 조직 id 는 URL 에 그대로 들어가는 값이다. uuid 가 아니면 서버에 묻지도 저장하지도 않는다
        // (대시보드의 다른 복사 단추가 주는 API URL 을 붙여 넣는 일이 실제로 생긴다).
        guard let org = OrgId.normalize(typed) else {
            setStatus("36자 조직 ID 가 아니에요")
            return
        }

        // config 에 값이 있으면 그쪽이 이긴다. 기본값을 config 에 다시 적어 넣지 않는다 (예전에는
        // 그래서 직접 바꿔 둔 서버 주소를 덮어썼다).
        let url = ServerDefaults.url(sc)
        let key = ServerDefaults.key(sc)

        setStatus("연결 중...")
        busy = true
        connectButton.isEnabled = false
        orgField.isEnabled = false

        // 예전에는 서버에 묻기 **전에** 저장했고 실패해도 되돌리지 않았다. 오타 하나로 없는 조직에
        // 등록된 채 남았고, 그 전에 맞게 들어 있던 조직 id 도 같이 사라졌다. 지금은 확인이 끝난
        // 뒤에만 저장한다.
        //
        // -1 (알 수 없다) 은 계속 간다: org_exists 가 아직 서버에 없을 수 있고, 서버에 닿지 못한
        // 것이라면 바로 아래 동기화가 가려 준다.
        DispatchQueue.global(qos: .userInitiated).async {
            let exists = Enterprise.orgExists(url: url, key: key, org: org)
            let synced: (outcome: EnterpriseOutcome, center: String, banner: String)
            if exists == 0 {
                // 없는 조직: 동기화하지 않는다.
                synced = (outcome: .requestFailed, center: "", banner: "")
            } else {
                // Enterprise.sync 는 한 번에 하나씩 돈다 - 시작할 때의 동기화가 돌고 있으면 기다린다.
                synced = Enterprise.sync(url: url, key: key, org: org)
            }
            DispatchQueue.main.async {
                // 이어지는 단계는 알림(runModal)을 띄울 수 있다. GCD main 블록 안에서 모달을 돌리면
                // 그동안 main 큐가 다시 비워지지 않아 (libdispatch 는 main 큐를 겹쳐 비우지 않는다)
                // 스캔 결과와 입력 전달이 멎는다 - Windows MessageBox 는 그동안에도 WM_SCAN_RESULT 를
                // 돌렸다. 그래서 run loop 타이머로 한 번 더 넘겨 블록 밖에서 잇는다.
                MainTimer.once(after: 0) {
                    self.finishRegister(org: org, exists: exists, outcome: synced.outcome,
                                        cp: synced.center, bp: synced.banner)
                }
            }
        }
    }

    /// 서버 답을 받은 뒤의 단계. Windows 와 같은 순서로 main 에서.
    private func finishRegister(org: String, exists: Int, outcome: EnterpriseOutcome, cp: String, bp: String) {
        busy = false
        connectButton.isEnabled = true
        orgField.isEnabled = true

        if exists == 0 {
            EventLog.write("enterprise: register refused - no such org (\(org))")
            setStatus("그런 조직이 없어요")
            return
        }
        if outcome == .requestFailed {
            EventLog.write("enterprise: register failed - server not reached (\(org))")
            setStatus("서버에 닿지 못했어요")
            return
        }

        // 조직이 있는지 확인하지 못했고 (org_exists 가 서버에 아직 없거나 그 요청만 실패했다) 받을
        // 콘텐츠도 없다면, 이 id 가 맞다는 근거가 하나도 없다. 그 상태로 이미 등록된 다른 조직을
        // 덮어쓰면 오타 하나로 맞는 id 가 사라지고 화면의 콘텐츠도 빠진다. 묻고 나서 한다.
        if exists < 0 && outcome == .noContent {
            let cur = ConfigStore.load()
            if cur.enterpriseRegistered, let curOrg = OrgId.normalize(cur.orgId), curOrg != org {
                let yes = Alerts.yesNo(
                    "이 ID 의 조직이 실제로 있는지 서버에서 확인하지 못했고, 받을 콘텐츠도 없어요.\n\n" +
                    "지금 등록된 조직을 이 ID 로 바꿀까요?",
                    title: "기업 등록", defaultNo: true, warning: true)
                if !yes {
                    setStatus("바꾸지 않았어요")
                    return
                }
            }
        }

        var nc = ConfigStore.load()     // 동기화하는 동안 다른 저장이 있었을 수 있다
        let orgChanged = !nc.enterpriseRegistered || nc.orgId.caseInsensitiveCompare(org) != .orderedSame
        nc.orgId = org
        nc.enterpriseRegistered = true
        // 못 썼으면 등록된 것이 아니다 - 다음 실행에 남지 않는다. "연결 완료" 라고 말하기 전에 그만둔다.
        if !ConfigStore.save(nc) {
            EventLog.write("enterprise: register NOT saved (\(org))")
            setStatus("설정을 저장하지 못했어요")
            return
        }
        orgField.stringValue = org      // 저장된 그대로 (다듬은 값) 보여 준다

        _ = app.applyEnterpriseSync(outcome, center: cp, banner: bp)
        refreshImageLabels()
        // 받은 것이 있는데 그 자리가 다른 경로면, 사용자가 고른 그림이 남은 것이다.
        let keptOwn = (!cp.isEmpty && app.centerImagePath != cp) || (!bp.isEmpty && app.bannerImagePath != bp)
        let found = outcome == .ready
        EventLog.write("enterprise: registered org=\(org) (org_exists=\(exists), " +
                       "center=\(cp.isEmpty ? 0 : 1) banner=\(bp.isEmpty ? 0 : 1))")

        setStatus(found ? "연결 완료 - 콘텐츠 받음" : "연결 완료 - 콘텐츠 없음")

        var more = ""
        if !found {
            more += "이 조직에 송출 중인 콘텐츠가 아직 없어요.\n" +
                    "대시보드에서 올리고 [송출 중] 으로 바꾼 뒤 이 단추를 다시 누르세요.\n\n"
            if exists < 0 {
                more += "조직이 실제로 있는지는 서버에서 확인하지 못했어요.\n" +
                        "ID 를 잘못 넣었다면 콘텐츠가 오지 않아요.\n\n"
            }
        }
        if keptOwn {
            more += "직접 고른 그림이 있는 자리는 그 그림을 그대로 써요.\n\n"
        }
        // 업데이트는 켤 때 한 번 조직 id 를 받는다 (Updater.initialize). 이번 실행의 업데이트 확인은
        // 등록하기 전 그대로다.
        if orgChanged && Updater.enabled {
            more += "프로그램 업데이트는 SmartScreen 을 다시 켠 뒤부터\n" +
                    "이 조직 관리자의 승인을 따라요.\n"
        }
        if !more.isEmpty {
            Alerts.info("연결 완료.\n\n" + more, title: "기업 등록")
        }
    }

    /// 빈 칸으로 누른 경우: 기업 등록 해제.
    private func unregister(_ sc: AppConfig) {
        if !sc.enterpriseRegistered {
            setStatus("조직 ID를 입력하세요.")
            return
        }
        let yes = Alerts.yesNo(
            "조직 ID 칸이 비어 있어요.\n\n" +
            "이 PC 의 기업 등록을 해제할까요?\n" +
            "잠금 화면에서 조직 콘텐츠가 빠지고, 저장된 조직 ID 도 지워져요.",
            title: "기업 등록 해제", defaultNo: true, warning: false)
        if !yes { return }

        var c = ConfigStore.load()      // 묻는 동안 다른 저장이 있었을 수 있다
        c.enterpriseRegistered = false
        c.orgId = ""
        if Enterprise.isEnterpriseContentPath(c.centerImagePath) { c.centerImagePath = "" }
        if Enterprise.isEnterpriseContentPath(c.bannerImagePath) { c.bannerImagePath = "" }
        // 저장이 먼저다. 못 썼으면 해제된 것이 아니다 - 다음 실행에 다시 기업 PC 로 뜬다. 화면을
        // 바꾸기 전에 그렇게 말하고 그만둔다.
        if !ConfigStore.save(c) {
            EventLog.write("enterprise: unregister NOT saved - nothing changed")
            setStatus("설정을 저장하지 못했어요")
            return
        }

        // 동기화가 넣어 둔 경로만 지운다. 사용자가 고른 그림은 그대로다.
        var dropped = false
        if Enterprise.isEnterpriseContentPath(app.centerImagePath) {
            app.centerImagePath = ""
            dropped = true
        }
        if Enterprise.isEnterpriseContentPath(app.bannerImagePath) {
            app.bannerImagePath = ""
            dropped = true
        }
        if dropped {
            refreshImageLabels()      // "(기본)"
        }
        // 잠금 화면이 떠 있는 동안에는 그림을 버리지 않는다 (영상은 잠금 창을 만들 때만 시작한다 -
        // 지금 버리면 자리표시가 보인다). 풀릴 때 LockScreen.hide 가 버린다.
        if dropped && !app.guardEngine.blackActive && !LockScreen.shared.isShown {
            LockScreen.shared.freeImages()
        }
        EventLog.write("enterprise: unregistered by the user")
        setStatus("등록을 해제했어요")
        // 업데이트는 켤 때 한 번 조직 id 를 받는다. 그래서 이번 실행의 업데이트 확인은 아직 그
        // 조직의 승인 목록을 본다.
        if Updater.enabled {
            Alerts.info("기업 등록을 해제했어요.\n\n" +
                        "프로그램 업데이트는 SmartScreen 을 다시 켠 뒤부터\n" +
                        "조직의 승인을 기다리지 않고 받아요.",
                        title: "기업 등록 해제")
        }
    }

    // MARK: - 도우미

    private func setStatus(_ s: String) {
        statusLabel.stringValue = s
    }

    /// 그림 경로 글자 (고급 창 "(기본)" / TruncPath, 간단 창).
    private func refreshImageLabels() {
        app.advanced?.syncFromModel()
        app.simple?.refresh()
    }

    private func add(_ parent: NSView, _ v: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        v.frame = NSRect(x: x, y: y, width: w, height: h)
        parent.addSubview(v)
    }

    private static func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.lineBreakMode = .byClipping
        l.isSelectable = false
        return l
    }
}

extension EntSetupController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return canClose
    }

    func windowWillClose(_ notification: Notification) {
        didClose()
    }
}

/// 뒤집힌 내용 뷰 (Windows 클라이언트 좌표를 그대로 쓴다).
private final class EntSetupFlippedView: NSView {
    override var isFlipped: Bool { return true }
}
