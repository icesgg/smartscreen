import AppKit
import SmartScreenCore

// OverlayPanel.swift - 떠 있는 작은 상태 창 (Windows client/main.cpp OverlayProc, "SmartScreenOverlay").
//
// 주 화면 오른쪽 위에 늘 떠 있는 280x100 반투명 판. 기기 이름과 상태(정지됨, 근처, 멀리, 잠금,
// 남은 초)를 보이고 단추 셋을 가진다:
//   [종료] - 앱을 끝내는 유일한 정상 경로. 화면을 지키는 프로그램이 실수로 닫히면 안 된다.
//   [잠금] - 직접 잠금.
//   [설정] - 간단 창을 다시 연다. 트레이 아이콘이 없어서 이 판이 앱으로 돌아오는 유일한 길이다.
//
// 이 파일은 그리기와 단추만 맡는다. 글자와 색은 AppController 가 Texts.overlayLine1/2 로 만들어
// update() 로 넘긴다. 위치는 저장하지 않는다 - 시작할 때마다 오른쪽 위로 돌아간다 (Windows 와 같다).

final class OverlayPanel {
    private static let width: CGFloat = 280    // OVL_W
    private static let height: CGFloat = 100   // OVL_H

    private var panel: NSPanel?
    private let view: OverlayPanelView

    init(onExit: @escaping () -> Void, onLock: @escaping () -> Void, onSettings: @escaping () -> Void) {
        let size = NSSize(width: OverlayPanel.width, height: OverlayPanel.height)
        view = OverlayPanelView(frame: NSRect(origin: .zero, size: size))

        let p = NSPanel(contentRect: NSRect(origin: OverlayPanel.initialOrigin(), size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.title = "SmartScreen"            // Windows 오버레이 창 제목. 어디에도 보이지 않는다.
        // WS_EX_TOPMOST | WS_EX_TOOLWINDOW: 늘 위, 작업 표시줄/Alt-Tab 에 없음.
        p.isFloatingPanel = true
        p.level = .floating
        // NSPanel 은 기본으로 앱이 비활성이 되면 숨는다. 그러면 다른 앱을 누를 때마다 판이
        // 사라진다 - Windows 판은 늘 보인다.
        p.hidesOnDeactivate = false
        p.canHide = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 바탕을 끌어 옮긴다 (단추는 그대로 눌린다). 화면 밖으로 끌어도 막지 않고 위치는 저장하지 않는다.
        p.isMovableByWindowBackground = true
        // WS_EX_LAYERED + LWA_ALPHA 200: 단추까지 창 전체가 반투명.
        p.alphaValue = 200.0 / 255.0
        p.hasShadow = false
        p.isOpaque = false
        p.backgroundColor = OverlayPanelStyle.background
        p.animationBehavior = .none
        p.isExcludedFromWindowsMenu = true
        // 밝은 평면 단추는 다크 모드에서도 밝다 (직접 그리지만 혹시 모를 시스템 그림도 밝게).
        p.appearance = NSAppearance(named: .aqua)
        // Windows 에서 MessageBox 는 자기 주인 창만 막고 오버레이는 계속 눌렸다. 알림 창이 떠
        // 있는 동안에도 [종료]/[잠금]/[설정] 이 듣게 한다.
        p.worksWhenModal = true
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = view

        let exitButton = OverlayPanelButton(frame: NSRect(x: 10, y: 66, width: 60, height: 26), title: "종료") {
            onExit()
        }
        let lockButton = OverlayPanelButton(frame: NSRect(x: 78, y: 66, width: 60, height: 26), title: "잠금") {
            onLock()
        }
        let settingsButton = OverlayPanelButton(frame: NSRect(x: 146, y: 66, width: 60, height: 26), title: "설정") {
            onSettings()
        }
        view.addSubview(exitButton)
        view.addSubview(lockButton)
        view.addSubview(settingsButton)

        panel = p
    }

    deinit {
        close()
    }

    /// 앱을 활성화하지 않고 띄운다.
    func show() {
        panel?.orderFrontRegardless()
    }

    /// UpdateOverlayState 의 결과를 그린다. info 가 비어 있지 않으면 셋째 줄로 나온다.
    func update(line1: String, line2: String, color: RGB, info: String) {
        if view.line1 == line1 && view.line2 == line2 && view.info == info && view.accentRGB == color {
            return
        }
        view.line1 = line1
        view.line2 = line2
        view.info = info
        view.accentRGB = color
        view.accent = OverlayPanelStyle.color(color)
        view.needsDisplay = true
    }

    /// 판을 없앤다 ([종료] 경로). 다시 쓸 수 없다.
    func close() {
        guard let p = panel else { return }
        panel = nil
        p.orderOut(nil)
        p.close()
        // [종료] 단추의 동작 안에서 불릴 수 있다. 그 단추가 든 창을 바로 놓지 않고 다음 차례에 놓는다.
        DispatchQueue.main.async {
            withExtendedLifetime(p) {}
        }
    }

    /// 주 화면(NSScreen.screens.first) visibleFrame 의 오른쪽 위, 오른쪽과 위에서 20 pt.
    /// Windows 의 (화면 너비 − 300, 20) 은 작업 표시줄이 아래에 있다는 전제였다. Mac 은 위에
    /// 메뉴 막대가 있으므로 visibleFrame 기준으로 그 아래에 둔다.
    private static func initialOrigin() -> NSPoint {
        let area: NSRect
        if let s = NSScreen.screens.first {
            area = s.visibleFrame
        } else if let s = NSScreen.main {
            area = s.visibleFrame
        } else {
            let b = CGDisplayBounds(CGMainDisplayID())
            area = NSRect(x: 0, y: 0, width: b.width, height: b.height)
        }
        return NSPoint(x: area.maxX - width - 20, y: area.maxY - 20 - height)
    }
}

// MARK: - 그리기

private enum OverlayPanelStyle {
    static func srgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        return NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0,
                       blue: CGFloat(b) / 255.0, alpha: 1.0)
    }
    static func color(_ c: RGB) -> NSColor {
        return NSColor(srgbRed: CGFloat(c.r) / 255.0, green: CGFloat(c.g) / 255.0,
                       blue: CGFloat(c.b) / 255.0, alpha: 1.0)
    }

    static let background = srgb(20, 22, 28)       // #14161C
    static let border = srgb(55, 58, 68)           // #373A44
    static let nameText = srgb(220, 222, 228)      // #DCDEE4
    static let infoText = srgb(160, 160, 120)      // #A0A078
    static let buttonFace = srgb(240, 240, 240)    // #F0F0F0 (COLOR_BTNFACE)
    static let buttonFacePressed = srgb(220, 220, 220)
    static let buttonFrame = srgb(100, 100, 100)   // COLOR_WINDOWFRAME

    // Windows 글꼴은 셀 높이(px)로 만들었다: 14 px → 10.5 pt, 20 px semibold → 15 pt, 13 px → 10 pt.
    // 한글은 Windows 에서 맑은 고딕으로, Mac 에서 Apple SD Gothic Neo 로 대체된다.
    static let nameFont = NSFont.systemFont(ofSize: 10.5)
    static let stateFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let infoFont = NSFont.systemFont(ofSize: 10)
    static let buttonFont = NSFont.systemFont(ofSize: 10)
}

/// 판 전체를 그리는 뷰 (Windows 는 WM_ERASEBKGND 에서 다 그렸다). 뒤집힌 좌표라 Windows 의
/// 클라이언트 좌표를 그대로 쓴다.
private final class OverlayPanelView: NSView {
    // 첫 갱신 전: "Stopped", 빈 둘째 줄, 회색 띠 (Windows g_ovlLine1/g_ovlLine2/g_ovlColor 초기값).
    var line1 = "Stopped"
    var line2 = ""
    var info = ""
    var accentRGB = RGB(128, 128, 128)
    var accent = OverlayPanelStyle.srgb(128, 128, 128)

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return true }
    /// 바탕(단추가 아닌 곳)을 누르고 끌면 판이 움직인다.
    override var mouseDownCanMoveWindow: Bool { return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height

        OverlayPanelStyle.background.setFill()
        NSBezierPath.fill(bounds)

        // 바깥 가장자리 1 px 테두리 (0,0)-(279,99)
        OverlayPanelStyle.border.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: 1))
        NSBezierPath.fill(NSRect(x: 0, y: h - 1, width: w, height: 1))
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: h))
        NSBezierPath.fill(NSRect(x: w - 1, y: 0, width: 1, height: h))

        // 왼쪽 가장자리 4 px 상태 색 띠
        accent.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 4, height: h))

        let right = w - 10
        // 1줄: 기기 이름. 넘치면 끝을 "…" 로.
        drawLine(line1, font: OverlayPanelStyle.nameFont, color: OverlayPanelStyle.nameText,
                 in: NSRect(x: 14, y: 6, width: right - 14, height: 22), ellipsis: true)
        // 2줄: 상태. 넘치면 그냥 잘린다 (말줄임 없음).
        drawLine(line2, font: OverlayPanelStyle.stateFont, color: accent,
                 in: NSRect(x: 14, y: 30, width: right - 14, height: 26), ellipsis: false)
        // 3줄: "Lock hh:mm -> Unlock hh:mm (..)". 2줄 다음에 그린다 - 두 칸은 6 px 겹친다.
        if !info.isEmpty {
            drawLine(info, font: OverlayPanelStyle.infoFont, color: OverlayPanelStyle.infoText,
                     in: NSRect(x: 14, y: 50, width: right - 14, height: 16), ellipsis: false)
        }
    }

    /// DT_LEFT | DT_VCENTER | DT_SINGLELINE (+ DT_END_ELLIPSIS): 한 줄, 칸 안에서 세로 가운데,
    /// 칸 밖은 잘라 낸다.
    private func drawLine(_ text: String, font: NSFont, color: NSColor, in rect: NSRect, ellipsis: Bool) {
        if text.isEmpty { return }
        let ps = NSMutableParagraphStyle()
        ps.alignment = .left
        ps.lineBreakMode = ellipsis ? .byTruncatingTail : .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: ps,
        ]
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let y = rect.minY + ((rect.height - lineHeight) / 2).rounded(.down)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        // 그리는 칸은 넉넉히 준다: 한글 대체 글꼴로 줄이 조금 높아져도 줄이 통째로 빠지지 않게.
        // 한 줄 모드라 둘째 줄은 생기지 않고, 실제로 보이는 곳은 위의 잘라 내기 칸이다.
        let drawRect = NSRect(x: rect.minX, y: y, width: rect.width, height: lineHeight + 20)
        (text as NSString).draw(with: drawRect, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// BS_FLAT 고전 단추: 평평한 밝은 회색 면, 얇은 짙은 테, 검은 글씨. 원래 주석은
/// "Dark-themed buttons" 였지만 실제로는 어두운 판 위의 밝은 평면 단추다 - 보이는 대로 옮긴다.
private final class OverlayPanelButton: NSButton {
    private var handler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    convenience init(frame frameRect: NSRect, title: String, handler: @escaping () -> Void) {
        self.init(frame: frameRect)
        self.title = title
        self.handler = handler
    }

    private func setUp() {
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        refusesFirstResponder = true
        target = self
        action = #selector(clicked(_:))
    }

    @objc private func clicked(_ sender: Any?) {
        handler?()
    }

    override var isFlipped: Bool { return true }
    override var wantsUpdateLayer: Bool { return false }
    /// 판은 앱을 활성화하지 않는다. 첫 클릭이 바로 단추를 누르게 한다 (Windows 도 한 번에 눌렸다).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
    override var mouseDownCanMoveWindow: Bool { return false }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        let pressed = isHighlighted

        (pressed ? OverlayPanelStyle.buttonFacePressed : OverlayPanelStyle.buttonFace).setFill()
        NSBezierPath.fill(bounds)

        OverlayPanelStyle.buttonFrame.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: 1))
        NSBezierPath.fill(NSRect(x: 0, y: h - 1, width: w, height: 1))
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: h))
        NSBezierPath.fill(NSRect(x: w - 1, y: 0, width: 1, height: h))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: OverlayPanelStyle.buttonFont,
            .foregroundColor: NSColor.black,
        ]
        let s = title as NSString
        let size = s.size(withAttributes: attrs)
        let offset: CGFloat = pressed ? 1 : 0
        let origin = NSPoint(x: ((w - size.width) / 2).rounded(.down) + offset,
                             y: ((h - size.height) / 2).rounded(.down) + offset)
        s.draw(at: origin, withAttributes: attrs)
    }
}
