import AppKit
import AVFoundation
import ImageIO
import SmartScreenCore

// LockScreen.swift - 검은 화면(커튼). Windows client/blackscreen.cpp + client/video/player.cpp.
//
// 이것은 보안 잠금이 아니다. 자리를 비웠을 때 지나가는 사람에게서 화면을 가리는 막이다.
// 마우스/키보드 입력이 있으면 GuardEngine 이 바로 걷는다. 이 파일은 막을 만들고, 그리고,
// 치우는 일만 한다 - 언제 치고 언제 걷는지는 GuardEngine (SmartScreenCore) 이 정한다.
//
// Windows 는 가상 화면 전체를 덮는 창 하나에 모니터마다 따로 배치했다. Mac 은 "디스플레이마다
// 별도의 Spaces" 가 켜져 있으면 창 하나가 두 화면에 걸칠 수 없으므로 NSScreen 마다 창을 하나씩
// 만든다. 모니터마다의 배치 규칙(아래)은 Windows 와 같으니 사용자가 보는 것도 같다.
//
// 쌓이는 순서: 배너, [해제] > 영상 > 커튼 바탕 > 오버레이 > 다른 앱 전부.
// 커튼은 CGShieldingWindowLevel 이라 오버레이(.floating)와 우리 알림 창까지 덮는다 -
// Windows 에서도 잠금 창이 가장 나중에 앞으로 나와 오버레이를 덮었다.

final class LockScreen {
    static let shared = LockScreen()

    /// [해제] (어느 화면의 것이든). AppController 가 잠금 해제 경로를 건다.
    var onRelease: (() -> Void)?

    var isShown: Bool { return shown }

    // ---- 막이 떠 있는 동안의 상태 ----
    private var shown = false
    private var windows: [LockWindow] = []
    /// 창을 만들 때의 화면 배치. 화면 설정 알림이 와도 이것과 같으면 다시 만들지 않는다
    /// (영상이 처음부터 다시 도는 것을 막는다).
    private var builtFrames: [NSRect] = []
    private var render: LockRender?
    private var video: LockVideo?
    private var videoTimer: Timer?
    /// 이번 잠금에서 영상이 이미 실패했다. 화면 배치가 바뀌어 창을 다시 만들 때 또 시도하고
    /// 또 기록하지 않게 한다.
    private var videoFailed = false
    /// show() 때 받은 경로. 잠금 중에 경로가 바뀌어도(기업 콘텐츠 동기화 결과는 작업 스레드에서
    /// 오므로 잠금 중에도 도착한다) 떠 있는 막은 보여 주던 것을 그대로 보여 준다.
    private var centerPath = ""
    private var bannerPath = ""
    private var previousApp: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?
    /// 다른 앱을 쓰던 중에 잠겼을 때, 다른 앱의 창 아래에 깔려 있던 우리 창 (간단/고급 설정 창)과
    /// 그 바로 위에 겹쳐 있던 다른 앱의 창 번호. 앞에서 뒤 순서. 풀 때 그 창 바로 아래로 되돌린다
    /// (restoreFrontmost). 위에 겹친 다른 앱 창이 없던 우리 창은 여기 없다 - 풀 때 건드리지 않는다.
    private var windowsUnder: [WindowUnder] = []
    private var rebuildQueued = false
    private var screenObserver: NSObjectProtocol?

    // 디코딩한 그림 (Windows s_imgCenter / s_imgBanner). 잠글 때 읽고, 풀 때마다 버린다.
    private var imgCenter: NSImage?
    private var imgBanner: NSImage?

    private init() {
        // Windows 는 잠근 순간의 모니터로 창 크기를 한 번 정하고, 잠금 중 모니터 연결/분리는
        // 다루지 않았다 (Q10). Mac 은 화면 설정이 바뀌면 창을 다시 만든다 - 새로 꽂은 화면이
        // 가려지지 않은 채 남는 것보다 낫다.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenParametersChanged()
        }
    }

    // MARK: - 공개 동작

    /// 화면마다 커튼 창을 만들고 띄운다 (Windows ActivateBlackScreen 의 창 부분 + WM_CREATE).
    /// 그 전에 맨 앞 앱을 기억해 두었다가 hide() 때 되돌린다.
    func show(centerPath: String, bannerPath: String) {
        // GuardEngine 은 이미 잠긴 동안 다시 부르지 않는다. 그래도 두 겹으로 만들지 않는다.
        if shown { return }
        shown = true
        self.centerPath = centerPath
        self.bannerPath = bannerPath
        videoFailed = false
        rememberFrontmost()
        // Windows 도 WM_CREATE 에서, 창을 보이기 전에 동기로 읽었다.
        loadImages()
        build()
        activateSelf()
    }

    /// 커튼을 걷는다 (Windows DeactivateBlackScreen 의 창 부분): 영상을 세우고, 창을 치우고,
    /// 그림을 버리고, 잠그기 전에 쓰던 앱을 다시 앞으로.
    func hide() {
        let wasShown = shown
        if wasShown {
            shown = false
            teardown()
        }
        // 잠금 중에 그림 경로가 바뀌었을 수 있다. 떠 있는 동안에는 보여 주던 것을 그대로 두고,
        // 여기서 버려서 다음 잠금이 새 경로로 다시 읽게 한다. 창이 다 사라진 다음에 버린다.
        freeImages()
        if wasShown { restoreFrontmost() }
    }

    /// 디코딩해 둔 그림을 버린다. 다음 show() 가 다시 읽는다. 떠 있는 막은 자기 그림을
    /// 따로 쥐고 있으므로 지금 보이는 것은 바뀌지 않는다.
    func freeImages() {
        imgCenter = nil
        imgBanner = nil
    }

    // MARK: - 창 만들기 / 치우기

    private func build() {
        let areas = LockScreen.monitorAreas()
        builtFrames = areas
        let r = LockRender(center: imgCenter, banner: imgBanner)
        render = r

        var made: [LockWindow] = []
        for (i, frame) in areas.enumerated() {
            // 주 화면 = NSScreen.screens.first (메뉴 막대가 있는 화면). NSScreen.main 은
            // 키 창이 있는 화면이라 주 화면이 아니다.
            made.append(makeWindow(frame: frame, primary: i == 0, render: r))
        }
        windows = made

        // 영상은 주 화면 하나에만 가둬서 튼다. Windows 는 MFPlay 가 호스트 창을 가득 채우는
        // 방식이라 큰 창에 그대로 태우면 두 모니터에 걸쳐 늘어났고, 플레이어도 한 개짜리라
        // 영상은 주 모니터에만 나왔다. 여기서도 그대로 한다.
        if wantsVideo(), let host = made.first?.contentView as? LockContentView {
            startVideo(in: host, render: r)
        }

        for w in made { w.orderFrontRegardless() }
    }

    private func makeWindow(frame: NSRect, primary: Bool, render r: LockRender) -> LockWindow {
        let w = LockWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        // 메뉴 막대, Dock, 다른 앱의 전체 화면 Space 까지 덮는다.
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isMovable = false
        w.canHide = false
        w.animationBehavior = .none
        w.isExcludedFromWindowsMenu = true
        w.tabbingMode = .disallowed
        w.title = ""
        // 다크 모드여도 [해제] 는 Windows 의 밝은 고전 단추 모양 그대로다.
        w.appearance = NSAppearance(named: .aqua)
        // kiosk presentationOptions 는 쓰지 않는다 - 이것은 막이지 잠금이 아니다.
        // 커서도 숨기거나 가두지 않는다 (Windows 도 IDC_ARROW 그대로였다).

        let mw = Int(frame.width)
        let content = LockContentView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height),
                                      render: r, primary: primary)
        w.contentView = content
        w.setFrame(frame, display: false)

        // [해제] 와 배너는 모니터마다 하나씩. 버튼이 한쪽에만 있으면 다른 화면을 보던 사람은
        // 빠져나갈 곳이 안 보인다.
        let releaseFrame = NSRect(x: mw - 125, y: 15, width: 110, height: 42)
        let releaseButton = LockReleaseButton(frame: releaseFrame, title: "해제") { [weak self] in
            self?.releaseClicked()
        }
        content.addSubview(releaseButton)

        // 배너는 이미지가 있을 때만 만든다. 없으면 자리만 차지하는 빈 상자가 화면 오른쪽에
        // 남는데, 그건 설정이 비었다는 개발용 표시였지 사용자에게 보일 것이 아니다.
        if let banner = r.banner {
            let bannerFrame = NSRect(x: mw - 300 - 40, y: 80, width: 300, height: 400)
            content.addSubview(LockBannerView(frame: bannerFrame, image: banner))
        }
        return w
    }

    private func teardown() {
        // 영상을 먼저 세운다. 영상 뷰는 커튼 창 안에 있어 뒤따라 사라지는데, 플레이어가 아직
        // 그 뷰(레이어)를 들고 있으면 안 된다.
        stopVideo()
        render?.videoMode = false
        render = nil
        let dying = windows
        windows = []
        builtFrames = []
        for w in dying {
            w.orderOut(nil)
            w.close()
        }
        // [해제] 를 눌러 여기까지 왔다면 지금은 그 단추의 동작 한가운데다. 창을 바로 놓아 버리면
        // AppKit 이 아직 쓰고 있는 창이 사라진다. 다음 차례까지 붙들어 두었다가 놓는다.
        DispatchQueue.main.async {
            withExtendedLifetime(dying) {}
        }
    }

    private func releaseClicked() {
        // [해제] 는 직접 잠금이든 자동 잠금이든 푼다. 실제로는 단추까지 마우스를 옮기는 동안
        // 입력 감시가 먼저 푼다 (Q3, 그대로 둔다).
        onRelease?()
    }

    // MARK: - 화면 배치 변경

    private func screenParametersChanged() {
        guard shown, !rebuildQueued else { return }
        // 화면 하나를 꽂으면 알림이 몇 번 연달아 온다. 한 번으로 모은다.
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rebuildQueued = false
            guard self.shown else { return }
            if LockScreen.monitorAreas() == self.builtFrames { return }
            self.teardown()
            // 떠 있는 동안 freeImages() 가 불렸다면 show() 때의 경로로 다시 읽는다.
            self.loadImages()
            self.build()
            if NSApp.isActive {
                self.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// 모니터 목록 (Windows MonitorAreas). 첫 번째가 주 화면이다.
    private static func monitorAreas() -> [NSRect] {
        var v: [NSRect] = []
        for s in NSScreen.screens where s.frame.width >= 1 && s.frame.height >= 1 {
            v.append(s.frame)
        }
        if v.isEmpty {
            // 열거가 실패해도 화면은 가려야 한다. 아는 대로 주 디스플레이 하나로 취급한다.
            if let m = NSScreen.main, m.frame.width >= 1, m.frame.height >= 1 {
                v.append(m.frame)
            } else {
                let b = CGDisplayBounds(CGMainDisplayID())
                if b.width >= 1 && b.height >= 1 {
                    // 주 디스플레이는 AppKit 좌표에서 원점이 (0,0) 이다.
                    v.append(NSRect(x: 0, y: 0, width: b.width, height: b.height))
                }
            }
        }
        return v
    }

    // MARK: - 앞에 있던 앱

    /// 우리 창 하나와, 잠글 때 그 위에 가장 가까이 겹쳐 있던 다른 앱의 창 번호.
    /// 창은 붙잡지 않고 가리키기만 한다 (잠긴 동안 설정 창이 닫혀도 남지 않게).
    private struct WindowUnder {
        weak var window: NSWindow?
        let above: Int
    }

    /// 화면에 보이는 0 층(보통 창) 창 하나 (CGWindowListCopyWindowInfo 의 항목).
    /// bounds 는 전역 좌표다: 주 화면 왼쪽 위가 원점, 아래로 +y.
    private struct ScreenWindow {
        let number: Int
        let pid: Int
        let bounds: CGRect
    }

    private func rememberFrontmost() {
        previousApp = nil
        previousKeyWindow = nil
        windowsUnder = []
        let me = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != me.processIdentifier {
            previousApp = front
            // 다른 앱을 쓰던 중이었다. 다른 앱의 창 아래에 깔려 있던 우리 설정 창과, 그 바로 위의
            // 창을 적어 둔다 - 잠글 때의 활성화가 그 창을 끌어올렸으면 풀 때 제자리로 돌려놓는다.
            windowsUnder = LockScreen.settingsWindowsUnderOthers(pid: Int(me.processIdentifier))
        } else {
            // 우리 창(간단 창의 "지금 가리기" 등)을 쓰던 중이었다.
            previousKeyWindow = NSApp.keyWindow
        }
    }

    /// 잠그는 순간의 실제 z-순서에서, 우리 설정 창마다 그 위에 가장 가까이 있으면서 겹치는 다른 앱의
    /// 창을 찾는다. 그런 창이 없는 우리 창(다른 앱 창들 위에 있던 창, 다른 Space 에 있어 화면 목록에
    /// 없는 창)은 목록에 넣지 않는다 - 풀 때 건드리지 않는다.
    ///
    /// 왜 이렇게까지 하나: R1-1 - 잠글 때의 활성화가 다른 앱 뒤에 있던 간단/고급 창을 그 앱들 위로
    /// 끌어올려, 풀어도 그대로 남았다. 그 고침은 풀 때 보이는 우리 창을 전부 orderBack 으로 맨 뒤에
    /// 보냈는데 (RG-2), 그러면 다른 앱 창들 위에 있던 창까지 묻힌다. 특히 updateTick 이 일부러
    /// orderFrontRegardless 로 올린 업데이트 띠가 묻혀서 다시는 보이지 않았다. Windows 는 잠금 창이
    /// 사라져도 다른 창의 z-순서를 건드리지 않는다 (spec 6.5) - 그래서 잠그기 전 자리로만 되돌린다.
    /// CGWindowListCopyWindowInfo 는 번호·주인·층·위치만 쓰므로 화면 기록 권한을 묻지 않는다.
    private static func settingsWindowsUnderOthers(pid me: Int) -> [WindowUnder] {
        let ours = visibleSettingsWindows()
        if ours.isEmpty { return [] }
        let list = onScreenNormalWindows()
        let primaryHeight = primaryScreenHeight()
        var out: [WindowUnder] = []
        // 목록은 앞에서 뒤 순서다. 우리 창마다 그보다 앞(위)의 항목을 가까운 것부터 본다.
        for (i, entry) in list.enumerated() where entry.pid == me {
            guard let w = ours[entry.number] else { continue }
            // NSWindow 의 frame 은 주 화면 왼쪽 아래가 원점이고 위로 +y 다. 전역 좌표로 바꾼다.
            let f = w.frame
            let mine = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            for j in stride(from: i - 1, through: 0, by: -1) {
                let other = list[j]
                if other.pid != me && overlaps(other.bounds, mine) {
                    out.append(WindowUnder(window: w, above: other.number))
                    break
                }
            }
        }
        return out
    }

    /// 보이는 우리 일반 창 (커튼, 오버레이 같은 패널, 알림 창은 뺀다), 창 번호로.
    private static func visibleSettingsWindows() -> [Int: NSWindow] {
        var out: [Int: NSWindow] = [:]
        for w in NSApp.windows where w.isVisible && !(w is LockWindow) && !(w is NSPanel)
            && w.level == .normal && w.windowNumber > 0 {
            out[w.windowNumber] = w
        }
        return out
    }

    /// 화면에 보이는 0 층 창들, 앞에서 뒤 순서 (CGWindowListCopyWindowInfo 가 주는 순서 그대로).
    private static func onScreenNormalWindows() -> [ScreenWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [ScreenWindow] = []
        for d in raw {
            guard let layer = d[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = d[kCGWindowNumber as String] as? Int,
                  let pid = d[kCGWindowOwnerPID as String] as? Int else { continue }
            var bounds = CGRect.null
            if let bd = d[kCGWindowBounds as String] as? NSDictionary,
               let r = CGRect(dictionaryRepresentation: bd as CFDictionary) {
                bounds = r
            }
            out.append(ScreenWindow(number: number, pid: pid, bounds: bounds))
        }
        return out
    }

    /// 두 사각형이 넓이가 있게 겹치는가 (모서리만 닿는 것은 겹친 것이 아니다).
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        if a.isNull || b.isNull || a.isEmpty || b.isEmpty { return false }
        let i = a.intersection(b)
        return !i.isNull && i.width > 0 && i.height > 0
    }

    /// 주 화면(메뉴 막대가 있는 화면)의 높이. AppKit 좌표와 전역(CG) 좌표를 오가는 데 쓴다.
    private static func primaryScreenHeight() -> CGFloat {
        if let s = NSScreen.screens.first { return s.frame.height }
        return CGDisplayBounds(CGMainDisplayID()).height
    }

    /// Windows 는 SetForegroundWindow(잠금 창). 거절되어도 커튼은 맨 위에 보인다 - 여기도 같다.
    ///
    /// Windows 의 SetForegroundWindow 는 잠금 창 하나만 올리고 다른 창의 z-순서는 건드리지 않는다.
    /// Mac 의 NSApp.activate(ignoringOtherApps:) 는 앱의 창을 전부 앞으로 올려서, 다른 앱 뒤에 있던
    /// 간단/고급 창이 잠글 때마다 그 앱들 위로 올라왔다 (풀어도 그대로 남았다). 그래서 커튼을 먼저
    /// 키 창이자 주 창으로 만든 뒤, 키/주 창만 앞으로 올리는 방식으로 활성화한다
    /// (.activateAllWindows 를 넣지 않는다). 그래도 올라온 창은 restoreFrontmost 가 잠그기 전의
    /// 자리(그 위에 겹쳐 있던 다른 앱 창 바로 아래)로 돌려놓는다.
    private func activateSelf() {
        if let w = windows.first {
            w.makeKeyAndOrderFront(nil)
            // 주 창도 커튼으로 바꿔 둔다 - 아니면 예전 주 창(설정 창)이 활성화에 같이 딸려 온다.
            w.makeMain()
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Windows 는 잠금 창이 사라지면 z-순서상 다음 창(보통 쓰던 앱)이 저절로 활성화된다.
    /// Mac 은 그런 것이 없으므로 기억해 둔 앱을 직접 되돌린다.
    /// 다른 앱을 쓰다가 잠겼으면, 다른 앱 창 아래에 있던 우리 설정 창을 그 창 바로 아래로 되돌린다 -
    /// Windows 에서는 잠금 창이 사라져도 다른 창의 z-순서가 잠그기 전 그대로다 (spec 6.5). 다른 앱
    /// 창들 위에 있던 우리 창(업데이트 띠를 보이려고 올린 간단 창 같은 것)은 건드리지 않는다.
    /// 우리 앱을 쓰던 중이었으면 예전 그대로 그 키 창을 다시 앞으로 한다.
    /// 어느 쪽이든 잠긴 동안 열린 알림이 남아 있으면 그 상자가 앞에 보이게 한다 (raisePendingModal).
    private func restoreFrontmost() {
        let app = previousApp
        let keyWindow = previousKeyWindow
        let under = windowsUnder
        previousApp = nil
        previousKeyWindow = nil
        windowsUnder = []
        guard NSApp.isActive else {
            // 그 사이 다른 앱이 앞으로 나왔다면 사용자가 고른 것이니 활성화는 건드리지 않는다.
            // 잠글 때 같이 올라왔을 수 있는 우리 창만 제자리로 돌려놓는다 (우리 앱을 쓰던 중에
            // 잠겼으면 목록이 비어 있다).
            LockScreen.restoreOrder(under)
            LockScreen.raisePendingModal()
            return
        }
        if let app = app {
            if app.isTerminated { return }
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: app)
            }
            _ = app.activate(options: [])
            LockScreen.restoreOrder(under)
            LockScreen.raisePendingModal()
        } else if let m = NSApp.modalWindow, m.isVisible {
            // 잠긴 동안 열린 알림이 남아 있다. 앱 전체가 그 모달에 막혀 있으니 예전 키 창이 아니라 그것이
            // 키 창이어야 한다 (Return 이 그 상자에 가게).
            m.makeKeyAndOrderFront(nil)
        } else if let w = keyWindow, w.isVisible, !(w is LockWindow) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// 잠긴 동안 열린 알림(로그인·등록 결과, 업데이트 실패...)이 남아 있으면 떠 있는 층에 올려 앞에 놓는다.
    /// 그 알림은 커튼이 앱을 활성화해 둔 동안 열려서 Alerts.present 가 층을 올리지 않았다. 활성화를
    /// 잠그기 전의 앱에 돌려주면 그 앱의 창이 알림 위로 올라오고, 앱 전체가 그 모달에 막혀 간단 창 단추는
    /// 삑 소리만 낸다. Alerts.present 가 앱이 활성이 아닐 때 하는 것과 같다 (초점은 돌려준 앱에 남는다).
    /// 같은 일을 간단 창에는 하지 않는다: 일반 층 창은 돌려준 앱의 활성화가 늦게 반영될 때 그 창들에
    /// 다시 덮인다. 상자만 보이면 닫은 뒤 돌아갈 길(오버레이 [설정])은 있다.
    private static func raisePendingModal() {
        guard let m = NSApp.modalWindow, m.isVisible else { return }
        m.level = .floating
        m.orderFrontRegardless()
    }

    /// 잠글 때 적어 둔 우리 창을 각각 그 위에 겹쳐 있던 다른 앱 창 바로 아래로 놓는다. 그 창이 이제
    /// 화면에 없으면 (닫혔거나, 숨었거나, 다른 Space) 그 우리 창은 그대로 둔다. orderBack 은 쓰지
    /// 않는다 - 같은 층의 맨 뒤로 가서, 다른 앱 창들 위에 있던 창까지 묻는다 (RG-2).
    /// order(.below, relativeTo:) 는 키/주 창도, 활성 앱도 바꾸지 않는다.
    private static func restoreOrder(_ list: [WindowUnder]) {
        if list.isEmpty { return }
        let onScreen = Set(onScreenNormalWindows().map { $0.number })
        // 뒤에서 앞 순서로 놓는다. 우리 창 여럿이 같은 창 아래로 가면 나중에 놓인 것이 그 바로 아래에
        // 오므로, 뒤의 것부터 놓아야 우리 창끼리의 순서가 잠그기 전 그대로다.
        for item in list.reversed() {
            guard let w = item.window, w.isVisible, !(w is LockWindow), onScreen.contains(item.above) else {
                continue
            }
            w.order(.below, relativeTo: item.above)
        }
    }

    // MARK: - 그림 (Windows LoadBlackScreenImages / FreeBlackScreenImages)

    /// 설정 경로를 먼저, 안 되면 앱 묶음의 images/center.* (banner.*) 를 png, jpg, bmp, jpeg
    /// 순서로. 배포본에는 images 폴더가 없으므로 보통은 찾지 못한다 (Windows 도 같다).
    /// 영상 경로도 그림으로 한 번 읽어 본다 - 당연히 실패하고 대체 그림으로 넘어간다 (Windows 와 같다).
    private func loadImages() {
        if imgCenter == nil && !centerPath.isEmpty {
            imgCenter = LockScreen.decode(path: centerPath)
        }
        if imgCenter == nil {
            imgCenter = LockScreen.fallbackImage("center")
        }
        if imgBanner == nil && !bannerPath.isEmpty {
            imgBanner = LockScreen.decode(path: bannerPath)
        }
        if imgBanner == nil {
            imgBanner = LockScreen.fallbackImage("banner")
        }
    }

    /// Windows 는 exe 옆의 images\ 를 본다. Mac 의 그 자리(앱 묶음 안)는 서명돼 있고 업데이트마다
    /// 통째로 바뀌므로 사람이 그림을 넣어 둘 곳이 못 된다. 그래서 설정 폴더의 images/ 를 먼저 보고,
    /// 그다음 묶음 안을 본다 (설치 안내.txt 9장).
    private static func fallbackImage(_ base: String) -> NSImage? {
        var dirs: [URL] = [Paths.configDir.appendingPathComponent("images", isDirectory: true)]
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("images", isDirectory: true))
        }
        for dir in dirs {
            for ext in ["png", "jpg", "bmp", "jpeg"] {
                if let img = decode(path: dir.appendingPathComponent("\(base).\(ext)").path) {
                    return img
                }
            }
        }
        return nil
    }

    /// GDI+ Image(path) 대신 ImageIO. 첫 프레임만 쓴다 - Windows 에서도 움직이는 GIF 는 프레임을
    /// 넘기는 것이 없어 첫 장만 보였다. EXIF 회전도 하지 않는다 (GDI+ 와 같다).
    /// 실패하면 nil. 커튼을 띄우기 전에 다 읽어 둔다.
    private static func decode(path: String) -> NSImage? {
        if path.isEmpty { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil), CGImageSourceGetCount(src) > 0 else {
            return nil
        }
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
        if cg.width < 1 || cg.height < 1 { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - 영상 (Windows video/player.cpp)

    private func wantsVideo() -> Bool {
        return !videoFailed && !centerPath.isEmpty && MediaKind.isVideoFile(centerPath)
    }

    private func startVideo(in host: LockContentView, render r: LockRender) {
        let path = centerPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            // Windows 는 MFPCreateMediaPlayer 가 그 자리에서 실패하고 그림/자리표시자로 돌아갔다.
            noteVideoFailure()
            return
        }
        let v = LockVideo(url: URL(fileURLWithPath: path), frame: host.bounds)
        // 영상은 [해제] 와 배너 아래. Windows 에서는 형제 자식 창끼리의 z-순서가 애매했지만
        // 여기서는 분명히 정한다: 단추와 배너가 영상 위에 보인다.
        host.addSubview(v.view, positioned: .below, relativeTo: nil)
        if v.hasFailed {
            v.stop()
            v.view.removeFromSuperview()
            noteVideoFailure()
            return
        }
        video = v
        r.videoMode = true
        // AVFoundation 은 실패를 나중에(비동기로) 알린다. Windows 의 500 ms 영상 타이머
        // (IDT_VIDEO_TICK) 자리에서 실패를 살핀다. 반복 재생은 AVPlayerLooper 가 이음매 없이
        // 한다 - Windows 는 끝나면 플레이어를 다시 만들어 최대 500 ms 끊겼다 (Q8, "Seamless loop"
        // 가 원래 뜻이었다).
        videoTimer = MainTimer.every(0.5) { [weak self] in
            self?.videoTick()
        }
    }

    private func videoTick() {
        guard let v = video, v.hasFailed else { return }
        // 재생할 수 없는 영상(avi/wmv/mkv/webm 등 AVFoundation 이 못 여는 것)이다. Windows 가
        // 그 자리에서 실패했을 때처럼 영상 없이 그린다: 그림이 있으면 그림, 없으면 자리표시자.
        stopVideo()
        noteVideoFailure()
        render?.videoMode = false
        for w in windows {
            w.contentView?.needsDisplay = true
        }
    }

    private func stopVideo() {
        videoTimer?.invalidate()
        videoTimer = nil
        if let v = video {
            v.stop()
            v.view.removeFromSuperview()
        }
        video = nil
    }

    private func noteVideoFailure() {
        if videoFailed { return }
        videoFailed = true
        EventLog.write("lock: video could not be played (\(LockScreen.extensionOf(centerPath)))")
    }

    /// 경로 전체에서 마지막 '.' 뒤, 소문자 (IsVideoFile 과 같은 규칙).
    private static func extensionOf(_ path: String) -> String {
        guard let dot = path.lastIndex(of: ".") else { return "" }
        return String(path[path.index(after: dot)...]).lowercased()
    }
}

// MARK: - 커튼이 그리는 데 쓰는 것

/// 한 번의 잠금(또는 다시 만들기)에서 모든 화면이 함께 보는 상태.
private final class LockRender {
    let center: NSImage?
    let banner: NSImage?
    /// 주 화면에서 영상이 도는 중. 실패하면 false 가 되고 화면을 다시 그린다.
    var videoMode = false

    init(center: NSImage?, banner: NSImage?) {
        self.center = center
        self.banner = banner
    }
}

private enum LockColors {
    static func srgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        return NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0,
                       blue: CGFloat(b) / 255.0, alpha: 1.0)
    }
    static let placeholderFill = srgb(20, 20, 30)       // #14141E
    static let placeholderDots = srgb(60, 60, 80)       // #3C3C50
    static let placeholderText = srgb(80, 80, 100)      // #505064
    // 고전 Win32 단추 색 (COLOR_3DFACE / 3DHILIGHT / 3DLIGHT / 3DSHADOW / 3DDKSHADOW)
    static let face = srgb(240, 240, 240)
    static let hilight = srgb(255, 255, 255)
    static let light = srgb(227, 227, 227)
    static let shadow = srgb(160, 160, 160)
    static let darkShadow = srgb(105, 105, 105)
}

/// 커튼 창. 테두리 없음. 키 창이 될 수 있어야 활성화했을 때 키 입력이 다른 앱으로 새지 않는다.
private final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { return true }

    /// 테두리 없는 창은 기본으로 주 창이 될 수 없다. 그러면 활성화할 때 예전 주 창(설정 창)이
    /// 주 창으로 남아 같이 앞으로 올라온다. 커튼이 주 창을 맡아 그것을 막는다 (activateSelf).
    override var canBecomeMain: Bool { return true }

    /// 메뉴 막대 자리까지 덮어야 한다. AppKit 이 창을 화면 안쪽으로 밀어 넣지 않게 한다.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    /// 키를 누르면 입력 감시가 막을 걷는다. 여기서는 아무도 받지 않은 키의 경고음만 막는다.
    override func keyDown(with event: NSEvent) {}

    /// Windows 의 WM_CLOSE → 0 (Alt+F4 무시). 닫기 명령으로 커튼이 닫히지 않는다.
    override func performClose(_ sender: Any?) {}
}

/// 화면 하나의 커튼 바탕. 뒤집힌 좌표(왼쪽 위 원점)라 Windows 의 모니터 기준 픽셀 값을
/// 그대로 포인트로 쓴다.
private final class LockContentView: NSView {
    private let render: LockRender
    private let primary: Bool

    init(frame frameRect: NSRect, render: LockRender, primary: Bool) {
        self.render = render
        self.primary = primary
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    /// 커서는 보이는 화살표 그대로 (숨기지도 가두지도 않는다).
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath.fill(bounds)

        // 영상이 도는 화면은 영상 뷰가 덮고 있으므로 건너뛴다.
        if render.videoMode && primary { return }

        let box = LockContentView.centerBox(mw: Int(bounds.width), mh: Int(bounds.height))
        if let img = render.center {
            // 그림 자체의 비율은 지키지 않고 4:3 상자에 늘려 채운다 (GDI+ DrawImage 와 같다, Q9 -
            // 기업 관리자는 1024x768 로 만든다).
            img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1.0,
                     respectFlipped: true, hints: nil)
        } else if render.videoMode {
            // 영상을 트는 중인데 쓸 이미지가 없다. 아래 자리표시자는 설정이 비었을 때 보여 주는
            // 개발용 상자라, 이럴 때 내보내면 안 된다. 보조 화면은 검은 채로 둔다.
        } else {
            LockContentView.drawPlaceholder(box)
        }
    }

    /// 화면마다 한가운데의 1024x768 상자. 작은 화면에서 1024x768 을 그대로 쓰면 넘친다.
    /// 화면의 80% 로 제한하되 상자 비율(4:3)은 지킨다. 정수 나눗셈까지 Windows 와 같다.
    private static func centerBox(mw: Int, mh: Int) -> NSRect {
        let fit = min(1.0, min(Double(mw) * 0.8 / 1024.0, Double(mh) * 0.8 / 768.0))
        let w = max(0, Int(1024.0 * fit))
        let h = max(0, Int(768.0 * fit))
        let x = (mw - w) / 2
        let y = (mh - h) / 2
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// 설정도 없고 images 폴더도 없을 때 보이는 개발용 상자. 새로 설치한 PC 는 잠글 때마다
    /// 이것이 보인다 - 지금 사용자가 보는 동작이라 그대로 옮긴다 (Q7).
    private static func drawPlaceholder(_ box: NSRect) {
        LockColors.placeholderFill.setFill()
        NSBezierPath.fill(box)

        // GDI 의 MoveTo/LineTo 처럼 픽셀 중심을 잇는다. 오른쪽/아래 선은 채운 상자 한 칸 밖이다.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: box.minX + 0.5, y: box.minY + 0.5))
        path.line(to: NSPoint(x: box.maxX + 0.5, y: box.minY + 0.5))
        path.line(to: NSPoint(x: box.maxX + 0.5, y: box.maxY + 0.5))
        path.line(to: NSPoint(x: box.minX + 0.5, y: box.maxY + 0.5))
        path.close()
        path.lineWidth = 1
        // PS_DOT 1 px 펜: 3 칸 켜고 3 칸 끈다 (GDI 의 점선 무늬).
        let dash: [CGFloat] = [3, 3]
        path.setLineDash(dash, count: dash.count, phase: 0)
        LockColors.placeholderDots.setStroke()
        path.stroke()

        // 두 줄, 가운데 정렬, 상자 위쪽부터 (여러 줄 글자에는 DT_VCENTER 가 듣지 않는다).
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: LockColors.placeholderText,
            .paragraphStyle: ps,
        ]
        let text = "center.png (1024x768)\nimages\\" as NSString
        text.draw(with: box, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
    }
}

/// 화면마다의 배너 (Windows 는 따로 뜨는 WS_BORDER 팝업). 1 pt 검은 테두리 안쪽 298x398 에
/// 그림을 늘려 채운다 - 비율은 지키지 않는다.
private final class LockBannerView: NSView {
    private let image: NSImage?

    init(frame frameRect: NSRect, image: NSImage?) {
        self.image = image
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        // 이 뷰는 이미지가 있을 때만 만들어진다. 그래도 방어적으로 검게 채운다 - 자리표시자를
        // 그리면, 만드는 조건이 나중에 바뀌었을 때 사용자 화면에 개발용 상자가 뜬다.
        NSColor.black.setFill()
        NSBezierPath.fill(bounds)
        guard let img = image else { return }
        img.draw(in: bounds.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver, fraction: 1.0,
                 respectFlipped: true, hints: nil)
    }
}

/// [해제]. 실행 파일에 공용 컨트롤 v6 매니페스트가 없어 Windows 에서는 테마 없는 고전 단추로
/// 보인다: 밝은 회색 면, 입체 테두리, 검은 글씨. 다크 모드에 끌려가지 않게 직접 그린다.
private final class LockReleaseButton: NSButton {
    private var handler: (() -> Void)?
    private static let titleFont = NSFont.systemFont(ofSize: 10.5)   // Segoe UI 14 px 셀 높이

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
        // Windows 에서 이 단추는 포커스를 받지 않았다 (대화 상자가 아니다). 키보드로 눌리지 않게.
        refusesFirstResponder = true
        target = self
        action = #selector(clicked(_:))
    }

    @objc private func clicked(_ sender: Any?) {
        handler?()
    }

    override var isFlipped: Bool { return true }
    override var wantsUpdateLayer: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        let pressed = isHighlighted

        LockColors.face.setFill()
        NSBezierPath.fill(bounds)

        if pressed {
            // 눌린 고전 단추: 짙은 테 한 겹 + 안쪽 그림자, 글자가 1 pt 오른쪽 아래로.
            LockColors.darkShadow.setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: 1))
            NSBezierPath.fill(NSRect(x: 0, y: h - 1, width: w, height: 1))
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: h))
            NSBezierPath.fill(NSRect(x: w - 1, y: 0, width: 1, height: h))
            LockColors.shadow.setFill()
            NSBezierPath.fill(NSRect(x: 1, y: 1, width: w - 2, height: 1))
            NSBezierPath.fill(NSRect(x: 1, y: 1, width: 1, height: h - 2))
        } else {
            // 솟은 고전 단추: 바깥 위/왼쪽 흰색, 아래/오른쪽 짙은 그림자; 안쪽 위/왼쪽 밝은 회색,
            // 아래/오른쪽 그림자.
            LockColors.hilight.setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: w - 1, height: 1))
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: h - 1))
            LockColors.darkShadow.setFill()
            NSBezierPath.fill(NSRect(x: 0, y: h - 1, width: w, height: 1))
            NSBezierPath.fill(NSRect(x: w - 1, y: 0, width: 1, height: h))
            LockColors.light.setFill()
            NSBezierPath.fill(NSRect(x: 1, y: 1, width: w - 3, height: 1))
            NSBezierPath.fill(NSRect(x: 1, y: 1, width: 1, height: h - 3))
            LockColors.shadow.setFill()
            NSBezierPath.fill(NSRect(x: 1, y: h - 2, width: w - 2, height: 1))
            NSBezierPath.fill(NSRect(x: w - 2, y: 1, width: 1, height: h - 2))
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: LockReleaseButton.titleFont,
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

/// 주 화면의 영상 (Windows MFPlay). AVQueuePlayer + AVPlayerLooper 를 AVPlayerLayer 에 태운다.
/// 화면 전체에 비율을 지켜 검은 여백으로 맞추고(MFPlay 기본값), 소리도 낸다 (MFPlay 도 냈다).
private final class LockVideo {
    let view: NSView
    private let player: AVQueuePlayer
    private let playerLayer: AVPlayerLayer
    private var looper: AVPlayerLooper?

    init(url: URL, frame: NSRect) {
        let p = AVQueuePlayer()
        let item = AVPlayerItem(url: url)
        // 견본 항목은 플레이어 대기열에 넣지 않는다. 루퍼가 복제본을 넣고 끝나면 이어 붙인다.
        let lp = AVPlayerLooper(player: p, templateItem: item)
        let layer = AVPlayerLayer(player: p)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        // 레이어를 직접 들고 있는 뷰 (layer 를 먼저 넣고 wantsLayer 를 켠다).
        let v = NSView(frame: frame)
        v.layer = layer
        v.wantsLayer = true
        player = p
        looper = lp
        playerLayer = layer
        view = v
        p.play()
    }

    /// AVFoundation 이 열지 못했거나 재생 중에 실패했다.
    var hasFailed: Bool {
        if player.status == .failed { return true }
        if let item = player.currentItem, item.status == .failed { return true }
        if let l = looper {
            if l.status == .failed { return true }
            for item in l.loopingPlayerItems where item.status == .failed {
                return true
            }
        }
        return false
    }

    /// 멈추고, 항목을 빼고, 레이어에서 플레이어를 떼어 낸다. 뷰를 치우기 전에 부른다.
    func stop() {
        looper?.disableLooping()
        player.pause()
        player.removeAllItems()
        playerLayer.player = nil
        looper = nil
    }
}
