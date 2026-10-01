import AppKit
import SmartScreenCore

// ChartView.swift - 고급 창의 "30-min Timeline" (Windows PaintChart, 창 클래스 SmartScreenChart).
//
// 지난 30분 동안 FAR 로 바뀐 순간을 빨간 표시로 찍는다. 초록 띠는 기록이 아니다: 감시 중이면
// 띠 전체를 칠할 뿐이다 (Windows 도 그랬다 - NEAR 였던 구간을 그리는 것이 아니다).
// FAR 사건 목록은 GuardEngine.farEvents (메모리에만 있다, 새 사건이 들어올 때만 30분 넘은 것을
// 버린다). 다시 그리는 때는 스캔 결과마다와 [초기화] 뿐이다 (AppController -> chartNeedsDisplay).
//
// 좌표는 Windows 의 픽셀 값을 그대로 쓴다 (뒤집힌 좌표계, 왼쪽 위가 원점). Windows 의 이 컨트롤은
// WS_EX_CLIENTEDGE 라 2 px 테두리 안쪽(약 76 px 높이)이 그림판이었다 - 여기서도 테두리를 그리고
// 그 안쪽을 W x H 로 삼는다.

final class ChartView: NSView {
    /// 그릴 자료(farEvents, monitoring)를 읽는 곳. AppController 는 앱이 끝날 때까지 산다.
    weak var app: AppController?

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return true }

    // CHART_WINDOW_MS
    private static let windowMs: UInt64 = 1_800_000
    // Windows g_hFontSmall = Consolas 11 px. Mac 에는 Consolas 가 없다 - 같은 고정폭 Menlo 9 pt.
    private static let smallFont: NSFont = NSFont(name: "Menlo", size: 9)
        ?? NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        let full = bounds
        ChartView.rgb(25, 25, 35).setFill()
        NSBezierPath.fill(full)
        drawClientEdge(full)

        guard let ctx = NSGraphicsContext.current else { return }
        let inner = full.insetBy(dx: 2, dy: 2)
        if inner.width <= 0 || inner.height <= 0 { return }
        ctx.saveGraphicsState()
        ctx.cgContext.clip(to: inner)
        // 뒤집힌 좌표계라 (2,2) 만큼 옮기면 오른쪽 아래로 간다 - Windows 클라이언트 영역의 원점.
        ctx.cgContext.translateBy(x: inner.minX, y: inner.minY)
        paint(width: Int(inner.width), height: Int(inner.height))
        ctx.restoreGraphicsState()
    }

    // MARK: - PaintChart

    private func paint(width W: Int, height H: Int) {
        // 바탕은 draw() 가 이미 RGB(25,25,35) 로 칠했다.
        let mL = 55, mR = 15, mT = 22, mB = 20
        let cW = W - mL - mR, cH = H - mT - mB
        // 너무 좁으면 아무것도 그리지 않는다 (Windows 와 같다).
        if cW < 50 || cH < 20 { return }

        // 테두리
        let border = NSBezierPath(rect: NSRect(x: CGFloat(mL) + 0.5, y: CGFloat(mT) + 0.5,
                                               width: CGFloat(cW), height: CGFloat(cH)))
        border.lineWidth = 1
        ChartView.rgb(80, 80, 100).setStroke()
        border.stroke()

        text("30-min Timeline (FAR events)", x: mL, y: 2, ChartView.rgb(200, 200, 220))

        let now = Mono.now()
        let span = ChartView.windowMs
        let ws: UInt64 = now > span ? now - span : 0
        let wall = Date()

        // 5분마다 점선과 "HH:MM" (지금 시각에서 m 분 뺀 지역 시각)
        let gridColor = ChartView.rgb(60, 60, 80)
        let gridLabel = ChartView.rgb(140, 140, 160)
        var m: UInt64 = 0
        while m <= 30 {
            let back = m * 60_000
            // 켠 지 30분이 안 된 PC: C++ 는 부호 없는 뺄셈이 돌아 화면 밖에 그렸다 (보이지 않는다).
            // Swift 는 그 자리에서 죽으므로 여기서 멈춘다 - 보이는 결과는 같다.
            if back > now { break }
            let t = now - back
            if t < ws { break }
            let x = mL + ChartView.xOffset(t - ws, span: span, width: cW)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(mT + 1)))
            line.line(to: NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(mT + cH - 1)))
            line.lineWidth = 1
            // PS_DOT (코스메틱 펜): 3 켜고 3 끈다.
            let dash: [CGFloat] = [3, 3]
            line.setLineDash(dash, count: dash.count, phase: 0)
            gridColor.setStroke()
            line.stroke()
            text(LocalClock.hhmm(wall.addingTimeInterval(-Double(m) * 60.0)),
                 x: x - 15, y: mT + cH + 3, gridLabel)
            m += 5
        }

        text("NEAR", x: 4, y: mT + 2, ChartView.rgb(0, 200, 0))
        text("FAR", x: 4, y: mT + cH - 16, ChartView.rgb(220, 60, 60))

        let bY = mT + 4, bH = cH - 8
        // 감시 중이면 띠 전체를 칠한다 (NEAR 기록이 아니다).
        if app?.monitoring == true {
            ChartView.rgb(0, 120, 0).setFill()
            NSBezierPath.fill(NSRect(x: CGFloat(mL + 1), y: CGFloat(bY),
                                     width: CGFloat(max(0, cW - 2)), height: CGFloat(max(0, bH))))
        }

        // FAR 사건: 2 px 세로선 + 위쪽 삼각형 + "HH:MM:SS"
        let events = app?.guardEngine.farEvents ?? []
        let red = ChartView.rgb(255, 50, 50)
        let redLabel = ChartView.rgb(255, 120, 120)
        var count = 0
        for ev in events where ev.tick >= ws {
            count += 1
            let x = mL + ChartView.xOffset(ev.tick - ws, span: span, width: cW)
            red.setFill()
            NSBezierPath.fill(NSRect(x: CGFloat(x - 1), y: CGFloat(bY), width: 2, height: CGFloat(max(0, bH))))
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: CGFloat(x), y: CGFloat(bY - 2)))
            tri.line(to: NSPoint(x: CGFloat(x - 5), y: CGFloat(bY - 10)))
            tri.line(to: NSPoint(x: CGFloat(x + 5), y: CGFloat(bY - 10)))
            tri.close()
            tri.fill()
            // Polygon 은 같은 색 2 px 펜으로 테두리까지 그렸다.
            tri.lineWidth = 2
            red.setStroke()
            tri.stroke()
            text(LocalClock.hhmmss(ev.date), x: max(x - 24, mL), y: bY - 12, redLabel)
        }

        // "now" 선: 오른쪽 끝
        let nowColor = ChartView.rgb(255, 255, 100)
        let nx = mL + cW - 1
        nowColor.setFill()
        NSBezierPath.fill(NSRect(x: CGFloat(nx - 1), y: CGFloat(bY), width: 2, height: CGFloat(max(0, bH))))
        text("now", x: nx - 12, y: bY - 12, nowColor)

        text("FAR: \(count)", x: mL + cW - 60, y: 2, ChartView.rgb(180, 180, 200))
    }

    // MARK: - 도우미

    /// x = (t - ws) / 30분 * 폭. C 의 (int) 처럼 0 쪽으로 버린다. 터무니없는 값에서 Int 변환이
    /// 죽지 않게 비율을 묶는다 (정상 범위 0...1 에서는 결과가 같다).
    private static func xOffset(_ dt: UInt64, span: UInt64, width: Int) -> Int {
        var ratio = Double(dt) / Double(span)
        if !ratio.isFinite { ratio = 0 }
        ratio = min(max(ratio, -10), 10)
        return Int(ratio * Double(width))
    }

    /// TextOutW: (x, y) 가 글자 칸의 왼쪽 위.
    private func text(_ s: String, x: Int, y: Int, _ color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: ChartView.smallFont, .foregroundColor: color]
        (s as NSString).draw(at: NSPoint(x: CGFloat(x), y: CGFloat(y)), withAttributes: attrs)
    }

    /// WS_EX_CLIENTEDGE 비슷한 2 px 움푹한 테두리.
    private func drawClientEdge(_ b: NSRect) {
        let outer = NSBezierPath(rect: b.insetBy(dx: 0.5, dy: 0.5))
        outer.lineWidth = 1
        ChartView.rgb(160, 160, 160).setStroke()
        outer.stroke()
        let inner = NSBezierPath(rect: b.insetBy(dx: 1.5, dy: 1.5))
        inner.lineWidth = 1
        ChartView.rgb(105, 105, 105).setStroke()
        inner.stroke()
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        return NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0,
                       blue: CGFloat(b) / 255.0, alpha: 1.0)
    }
}
