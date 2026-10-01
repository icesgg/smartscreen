// make_icon.swift - SmartScreen.app 의 아이콘을 그린다 (build_app.sh 가 부른다).
//
//   swift mac/tools/make_icon.swift <출력.iconset 폴더>
//   iconutil -c icns <출력.iconset> -o AppIcon.icns
//
// 그림 파일을 저장소에 넣지 않고 코드로 그리는 이유: 이 저장소를 쓰는 사람은 Mac 이 없어
// 그림 도구로 .icns 를 만들 수 없다. 색은 오버레이 위젯(OverlayPanel)과 같다 - 화면 오른쪽
// 위의 작은 상자를 알아보는 사람이 Finder 에서도 같은 앱으로 알아보게.
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// 1024 기준 좌표로 그린 뒤 size 로 줄인다.
func render(_ size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx
    let s = CGFloat(size) / 1024
    let t = NSAffineTransform()
    t.scale(by: s)
    t.concat()

    // 바탕: macOS 아이콘 격자(824 사각, 둥근 모서리 185) 안의 어두운 판 - 오버레이 배경색
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
    NSGradient(starting: rgb(36, 40, 52), ending: rgb(20, 22, 28))?.draw(in: platePath, angle: -90)
    rgb(55, 58, 68).setStroke()
    platePath.lineWidth = 6
    platePath.stroke()

    // 모니터: 밝은 테두리 + 검은 화면 (가려진 화면)
    let screen = NSRect(x: 232, y: 390, width: 560, height: 360)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 36, yRadius: 36)
    rgb(220, 222, 228).setFill()
    screenPath.fill()
    let inner = screen.insetBy(dx: 30, dy: 30)
    let innerPath = NSBezierPath(roundedRect: inner, xRadius: 14, yRadius: 14)
    rgb(8, 9, 12).setFill()
    innerPath.fill()

    // 받침
    let neck = NSBezierPath(rect: NSRect(x: 472, y: 300, width: 80, height: 92))
    rgb(220, 222, 228).setFill()
    neck.fill()
    let base = NSBezierPath(roundedRect: NSRect(x: 372, y: 262, width: 280, height: 48), xRadius: 24, yRadius: 24)
    base.fill()

    // 화면 가운데의 초록 점: 오버레이의 "근처 • 보호 중" 색
    let dot = NSBezierPath(ovalIn: NSRect(x: 512 - 58, y: 570 - 58, width: 116, height: 116))
    rgb(60, 210, 90).setFill()
    dot.fill()
    // 점을 둘러싼 전파 고리 둘
    rgb(60, 210, 90, 0.55).setStroke()
    for r in [100.0, 150.0] {
        let ring = NSBezierPath()
        ring.appendArc(withCenter: NSPoint(x: 512, y: 570), radius: CGFloat(r), startAngle: 20, endAngle: 160)
        ring.lineWidth = 18
        ring.lineCapStyle = .round
        ring.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    guard let png = render(px) else {
        FileHandle.standardError.write(Data("render failed: \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("iconset: \(outDir.path)")
