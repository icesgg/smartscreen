import AppKit
import SmartScreenCore

// 간단 화면과 재보기 마법사가 쓰는 그림 부품들 (Windows client/main.cpp 의 kPanelBg.. 색,
// DrawTile, 트랙바 NM_CUSTOMDRAW, 색을 칠한 PROGRESS_CLASS).
//
// 윈도우 11 빠른 설정 패널의 생김새를 따른다. 기본 Win32 버튼은 회색 입체 테두리라 옆에
// 두면 20년쯤 낡아 보인다. 둥근 사각형에 평면 색으로 직접 그린다. Mac 의 기본 단추를 쓰지
// 않는 것도 같은 이유다 - 두 판이 같은 화면으로 보여야 하고, 시스템 색은 다크 모드에서
// 바뀌지만 이 창은 Windows 처럼 늘 밝은 패널이다. 그래서 색은 전부 여기서 정한 값만 쓴다.
//
// 이름은 모두 SS 로 시작한다 - 다른 모듈의 내부 이름과 부딪히지 않게.

/// 색 (Windows main.cpp 의 상수와 같은 값). sRGB 로 만든다 - Windows 의 RGB() 값이 sRGB 다.
enum SSColors {
    /// kPanelBg: 창 바탕(두 창 모두), 라벨 바탕, "ghost" 타일
    static var panelBg: NSColor { return rgb(0xF3, 0xF3, 0xF3) }
    /// kTileBg: 보통 타일
    static var tileBg: NSColor { return rgb(0xFB, 0xFB, 0xFB) }
    /// kTileEdge: 타일 테두리 1pt. 흰 타일이 흰 바탕에 묻히지 않게 늘 그린다.
    static var tileEdge: NSColor { return rgb(0xE1, 0xE1, 0xE1) }
    /// kTilePress: 보통/ghost 타일을 누르고 있을 때
    static var tilePress: NSColor { return rgb(0xEA, 0xEA, 0xEA) }
    /// kAccent: 강조 타일, 슬라이더 채움과 손잡이, 진행 막대, 마법사의 "남은 시간" 줄
    static var accent: NSColor { return rgb(0x00, 0x67, 0xC0) }
    /// kAccentDn: 강조 타일을 누르고 있을 때
    static var accentDn: NSColor { return rgb(0x00, 0x55, 0x9E) }
    /// kInk: 보통 타일 글, 마법사 제목
    static var ink: NSColor { return rgb(0x1A, 0x1A, 0x1A) }
    /// kInkSoft: 모든 라벨, ghost 타일 글, 마법사 본문
    static var inkSoft: NSColor { return rgb(0x5D, 0x5D, 0x5D) }
    /// 슬라이더 홈과 진행 막대 바탕
    static var groove: NSColor { return rgb(0xC4, 0xC4, 0xC4) }
    /// 마법사 결과가 실패일 때의 제목
    static var wizardError: NSColor { return rgb(0xC0, 0x30, 0x30) }

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        return NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0,
                       blue: CGFloat(b) / 255.0, alpha: 1.0)
    }

    /// Core 의 RGB (상태 카드, 오버레이 색) 를 NSColor 로
    static func from(_ c: RGB) -> NSColor {
        return rgb(Int(c.r), Int(c.g), Int(c.b))
    }
}

/// 글꼴. Windows 의 g_hFont (Segoe UI 14px 셀 = 약 10.5px 글자) 와 g_hFontBig (24px 셀, 굵게).
/// Mac 에는 같은 글꼴이 없으므로 시스템 글꼴 12pt / 18pt 굵게를 쓴다 (한글은 Apple SD Gothic Neo
/// 로 넘어간다).
enum SSFonts {
    static var normal: NSFont { return NSFont.systemFont(ofSize: 12) }
    static var big: NSFont { return NSFont.systemFont(ofSize: 18, weight: .bold) }
}

/// 글 그리기 (DrawTextW 자리). 보기들은 모두 뒤집힌(flipped) 좌표라 rect 의 위가 글의 위다.
enum SSDraw {
    /// DT_LEFT (| DT_WORDBREAK): rect 의 왼쪽 위에서 시작한다. wrap 이면 여러 줄, 아니면 한 줄
    /// (넘치면 끝을 … 으로).
    static func text(_ s: String, in rect: NSRect, font: NSFont, color: NSColor,
                     wrap: Bool, align: NSTextAlignment = .left) {
        if s.isEmpty || rect.width <= 0 || rect.height <= 0 { return }
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        str.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS: 가운데 한 줄, 넘치면 끝을 … 으로.
    static func centeredLine(_ s: String, in rect: NSRect, font: NSFont, color: NSColor) {
        if s.isEmpty { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = ceil(str.size().height)
        // 양옆 4pt 는 둥근 모서리에 글이 닿지 않게 둔 것이다.
        let r = NSRect(x: rect.minX + 4, y: rect.minY + floor((rect.height - h) / 2),
                       width: max(rect.width - 8, 0), height: h)
        if r.width <= 0 || r.height <= 0 { return }
        str.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}

/// 타일의 세 모양 (Windows SimpleProc WM_DRAWITEM 의 accent / ghost / 보통).
enum SSTileStyle {
    /// 파란 타일: 켜져 있는 것(보호, 클립보드), 지금 고른 시간, 이 화면의 주 동작
    case accent
    /// 머리의 버전 단추, [고급 설정], [나중에], 마법사의 [그만두기]
    case ghost
    /// 그 밖의 타일
    case normal
}

/// 둥근 타일 단추 (Windows DrawTile + BS_OWNERDRAW 버튼).
///
/// RoundRect 의 마지막 인자는 모서리 *타원* 크기라, Windows 의 14 는 반지름 7pt, 10 은 5pt 다.
/// 테두리 1pt 는 늘 그린다 - 흰 타일이 흰 바탕에 묻히지 않게. 글은 가운데 한 줄, 넘치면 끝을
/// … 으로. 포커스 사각형은 그리지 않는다 (Windows 도 안 그린다).
///
/// 그리기는 셀(SSTileCell)이 한다. 누르는 동안의 강조는 NSButtonCell 이 추적하면서 셀을 다시
/// 그리게 하므로, 셀에서 그려야 눌린 색이 확실히 나온다.
final class SSTileButton: NSButton {
    var tileStyle: SSTileStyle = .normal {
        didSet { if tileStyle != oldValue { needsDisplay = true } }
    }

    override class var cellClass: AnyClass? {
        get { return SSTileCell.self }
        set { }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    convenience init(frame: NSRect, title: String, style: SSTileStyle) {
        self.init(frame: frame)
        self.title = title
        self.tileStyle = style
    }

    private func setUp() {
        // cellClass 를 무시하는 경로가 있더라도 우리 셀로 그리게 한다.
        if !(cell is SSTileCell) {
            cell = SSTileCell(textCell: "")
        }
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        font = SSFonts.normal
    }

    override var isFlipped: Bool { return true }

    /// Windows 는 비활성 창의 단추도 첫 클릭에 눌린다. 초점을 뺏지 않고 띄운 간단 창(업데이트
    /// 알림)의 [업데이트] 가 두 번 눌러야 먹으면 이상하다.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

/// SSTileButton 의 셀. 바탕, 테두리, 글을 모두 직접 그린다.
private final class SSTileCell: NSButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let style = (controlView as? SSTileButton)?.tileStyle ?? .normal
        let down = isHighlighted
        let fill: NSColor
        let edge: NSColor
        let ink: NSColor
        let radius: CGFloat
        switch style {
        case .accent:
            fill = down ? SSColors.accentDn : SSColors.accent
            edge = fill
            ink = NSColor.white
            radius = 7
        case .ghost:
            fill = down ? SSColors.tilePress : SSColors.panelBg
            edge = SSColors.tileEdge
            ink = SSColors.inkSoft
            radius = 5
        case .normal:
            fill = down ? SSColors.tilePress : SSColors.tileBg
            edge = SSColors.tileEdge
            ink = SSColors.ink
            radius = 7
        }

        // 1pt 선이 픽셀 경계에 걸치지 않게 반 점 안으로 들인다.
        let r = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        if r.width > 0 && r.height > 0 {
            let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            fill.setFill()
            path.fill()
            edge.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        SSDraw.centeredLine(title, in: cellFrame, font: SSFonts.normal, color: ink)
    }
}

/// 간단 화면의 거리 3단계 슬라이더 (가까이 / 보통 / 멀리 = 0 / 1 / 2).
///
/// 기본 트랙바는 가는 홈에 각진 손잡이라, 옆의 둥근 타일과 안 어울린다. 굵은 막대와 동그란
/// 손잡이로 직접 그린다 (SSDistanceSliderCell). 눈금은 그리지 않는다 - 값을 0/1/2 에만 멈추게
/// 하려고 눈금 셋을 두었을 뿐이다 (Windows TBS_NOTICKS).
final class SSDistanceSlider: NSSlider {
    override class var cellClass: AnyClass? {
        get { return SSDistanceSliderCell.self }
        set { }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        if !(cell is SSDistanceSliderCell) {
            cell = SSDistanceSliderCell()
        }
        isVertical = false
        minValue = 0
        maxValue = 2
        numberOfTickMarks = 3
        allowsTickMarkValuesOnly = true
        isContinuous = true
        focusRingType = .none
        doubleValue = 1
    }

    /// 지금 단계 0...2
    var distStep: Int {
        get {
            let v = doubleValue
            if !v.isFinite { return 1 }
            return min(max(Int(v.rounded()), 0), 2)
        }
        set {
            doubleValue = Double(min(max(newValue, 0), 2))
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

/// 슬라이더 모양: 4pt 회색 막대 위에 손잡이 가운데까지 강조색, 손잡이는 지름 18pt 강조색
/// 원에 3pt 흰 테. (Windows NM_CUSTOMDRAW: TBCD_CHANNEL / TBCD_THUMB, TBCD_TICS 는 건너뜀)
private final class SSDistanceSliderCell: NSSliderCell {
    /// 손잡이 반지름 9 + 흰 테 바깥쪽 1.5 + 여유. 양 끝에서 손잡이가 잘리지 않을 만큼 들인다.
    private static let inset: CGFloat = 11

    private func geometry(_ b: NSRect) -> (left: CGFloat, right: CGFloat, midY: CGFloat, knobX: CGFloat) {
        let left = b.minX + SSDistanceSliderCell.inset
        let right = max(b.maxX - SSDistanceSliderCell.inset, left)
        let span = maxValue - minValue
        var t = span > 0 ? (doubleValue - minValue) / span : 0
        if !t.isFinite { t = 0 }
        t = min(max(t, 0), 1)
        let knobX = left + (right - left) * CGFloat(t)
        return (left, right, b.midY, knobX)
    }

    private func paintBar(_ b: NSRect) {
        let g = geometry(b)
        SSColors.groove.setFill()
        NSBezierPath.fill(NSRect(x: g.left, y: g.midY - 2, width: g.right - g.left, height: 4))
        // 손잡이까지는 강조색으로 채운다 - 어디까지 왔는지가 보인다
        if g.knobX > g.left {
            SSColors.accent.setFill()
            NSBezierPath.fill(NSRect(x: g.left, y: g.midY - 2, width: g.knobX - g.left, height: 4))
        }
    }

    private func paintKnob(_ b: NSRect) {
        let g = geometry(b)
        let circle = NSBezierPath(ovalIn: NSRect(x: g.knobX - 9, y: g.midY - 9, width: 18, height: 18))
        SSColors.accent.setFill()
        circle.fill()
        // GDI 의 3px 펜은 원 둘레 가운데에 걸린다. NSBezierPath.stroke 도 같다.
        NSColor.white.setStroke()
        circle.lineWidth = 3
        circle.stroke()
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // 눈금은 그리지 않는다 - 막대와 손잡이만.
        paintBar(cellFrame)
        paintKnob(cellFrame)
    }

    // 시스템이 draw(withFrame:in:) 를 거치지 않고 아래 둘을 따로 부르는 경우에도 같은 모양이
    // 나오게 한다. 위치는 넘겨받은 rect 가 아니라 컨트롤 전체를 기준으로 셈한다.
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        paintBar(controlView?.bounds ?? rect)
    }

    override func drawKnob(_ knobRect: NSRect) {
        if let v = controlView {
            paintKnob(v.bounds)
        } else {
            paintKnob(NSRect(x: knobRect.midX - SSDistanceSliderCell.inset, y: knobRect.minY,
                             width: SSDistanceSliderCell.inset * 2, height: knobRect.height))
        }
    }
}

/// 마법사의 얇은 진행 막대 (PROGRESS_CLASS, PBS_SMOOTH, 막대 kAccent, 바탕 #C4C4C4).
/// NSProgressIndicator 는 색을 믿을 만하게 바꿀 수 없어서 직접 그린다.
final class SSProgressBar: NSView {
    var maxValue: Double = 100 {
        didSet { if maxValue != oldValue { needsDisplay = true } }
    }
    var value: Double = 0 {
        didSet { if value != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        SSColors.groove.setFill()
        NSBezierPath.fill(bounds)
        var t = maxValue > 0 ? value / maxValue : 0
        if !t.isFinite { t = 0 }
        t = min(max(t, 0), 1)
        if t > 0 {
            SSColors.accent.setFill()
            NSBezierPath.fill(NSRect(x: bounds.minX, y: bounds.minY,
                                     width: bounds.width * CGFloat(t), height: bounds.height))
        }
    }
}
