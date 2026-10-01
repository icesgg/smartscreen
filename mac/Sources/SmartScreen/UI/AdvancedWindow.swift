import AppKit
import SmartScreenCore

// AdvancedWindow.swift - 고급 설정 창 ("SmartScreen - 설정", Windows 창 클래스 SmartScreenBT).
//
// 간단 창이 생긴 뒤로 이 창은 시작할 때 만들어지지만 숨어 있고, 간단 창의 [고급 설정] 으로만
// 열린다. Windows 에서는 이 창의 WndProc 이 앱 전체의 지휘소였다 (WM_CREATE 의 자동 시작,
// 작업 스레드 메시지, 1초 카운트다운...). Mac 에서는 그 일이 창과 상관없는 AppController 로
// 옮겨 갔고, 이 파일은 화면만 맡는다:
//   - 컨트롤을 Windows 와 같은 자리에 둔다 (96 DPI 픽셀 값을 그대로 포인트로, 뒤집힌 좌표계).
//   - 단추는 AppController 의 명령을 부른다. 간단 창도 같은 명령을 부르므로 여기서 다시
//     구현하지 않는다.
//   - 값(신호 강도 칸, 유휴/해제 지연 고르기)은 AppController 의 모델이 원본이다. 바꾸면 곧바로
//     모델에 쓴다. 교훈 (NEXT_SESSION "설정 창이 둘이면"): [시작] 은 이 창의 값을 다시 읽는다.
//     다른 곳(간단 창 슬라이더, 유휴 단추)이 같은 값을 바꾸면 여기에도 보여야 한다 - 안 그러면
//     다음 [시작] 이 조용히 되돌린다 ("재시작하면 바뀌어 있다"). 그래서 syncFromModel 은 꺼져 있는
//     컨트롤까지 모두 다시 채운다.

// NSWindowDelegate 는 아래 확장에서 따른다. 주 선언에 적으면 Swift 5 모드에서 클래스 전체가
// @MainActor 로 추론되어, AppController 가 타이머·GCD 에서 부르는 insertRow/setStatus 들이 격리
// 위반이 될 수 있다 (간단 창과 같은 선택). 바깥에서 보면 같은 타입이다.
final class AdvancedWindowController: NSObject {
    let window: NSWindow
    private unowned let app: AppController

    // ---- 글꼴 (spec ui-advanced §3: Segoe UI 14/14 bold/24 bold/15 bold) ----
    private static let uiFont = NSFont.systemFont(ofSize: 11)
    private static let uiBold = NSFont.boldSystemFont(ofSize: 11)
    private static let bigFont = NSFont.boldSystemFont(ofSize: 18)
    private static let sectionFont = NSFont.boldSystemFont(ofSize: 11.5)

    private static let listCap = 500
    private static let defaultPathText = "(기본)"

    // ---- 고정 위치 컨트롤 (WM_SIZE 가 옮기지 않는다) ----
    private let content = AdvFlippedView(frame: NSRect(x: 0, y: 0, width: 804, height: 741))
    private let deviceLabel = AdvancedWindowController.makeLabel("블루투스 기기:", bold: true)
    private let devicePopup = AdvancedWindowController.makePopup([])
    private let refreshButton = AdvancedWindowController.makeButton("새로고침")
    private let startButton = AdvancedWindowController.makeButton("시작")
    private let stopButton = AdvancedWindowController.makeButton("중지")
    private let btButton = AdvancedWindowController.makeButton("BT")
    private let registerButton = AdvancedWindowController.makeButton("폰 등록")
    private let irkButton = AdvancedWindowController.makeButton("기기 키")
    // 앞뒤 공백까지 Windows 캡션 그대로
    private let protectBox = AdvancedWindowController.makeGroup(" 보호 설정 ")
    private let thresholdLabel = AdvancedWindowController.makeLabel("신호 강도:", align: .right)
    private let thresholdField = AdvancedWindowController.makeThresholdField()
    private let thresholdUnit = AdvancedWindowController.makeLabel("dBm 이상")
    private let delayLabel = AdvancedWindowController.makeLabel("잠금 해제 지연:", align: .right)
    private let delayPopup = AdvancedWindowController.makePopup(Choices.delayLabels)
    private let idleLabel = AdvancedWindowController.makeLabel("유휴 시간:", align: .right)
    private let idlePopup = AdvancedWindowController.makePopup(Choices.idleLabels)
    private let lockNowButton = AdvancedWindowController.makeButton("지금 잠금")
    private let reconnectButton = AdvancedWindowController.makeButton("재연결")

    // ---- WM_SIZE 가 옮기는 컨트롤 ----
    private let banner = AdvTextStrip(frame: .zero)
    private let clearButton = AdvancedWindowController.makeButton("초기화")
    private let countdownLabel = AdvancedWindowController.makeLabel("")
    private let listScroll = NSScrollView(frame: .zero)
    private let table = AdvancedWindowController.makeTable()
    private let chart = ChartView(frame: .zero)
    private let imageBox = AdvancedWindowController.makeGroup(" 화면 이미지 설정 ")
    private let centerCaption = AdvancedWindowController.makeLabel("중앙 이미지:")
    private let centerPathLabel = AdvancedWindowController.makePathLabel()
    private let centerBrowse = AdvancedWindowController.makeButton("찾아보기")
    private let bannerCaption = AdvancedWindowController.makeLabel("배너 이미지:")
    private let bannerPathLabel = AdvancedWindowController.makePathLabel()
    private let bannerBrowse = AdvancedWindowController.makeButton("찾아보기")
    private let enterpriseButton = AdvancedWindowController.makeButton("기업용 둘러보기", tall: true)
    private let statusBar = AdvTextStrip(frame: .zero)

    /// 목록 줄 (맨 위가 최신, 최대 500). insertRow 가 채운다.
    private var rows: [[String]] = []

    init(app: AppController) {
        self.app = app
        // Windows 바깥 820x780 = 클라이언트 약 804x741. 최소 바깥 700x600 = 클라이언트 약 684x561.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 804, height: 741),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: true)
        super.init()

        window.title = "SmartScreen - 설정"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 684, height: 561)
        // Windows 의 이 창은 흰 바탕의 고전 컨트롤이다. 상태 띠의 고정 색(회색/초록/빨강)이
        // 그 바탕을 전제로 하므로 밝은 모양으로 고정한다 (오버레이와 같은 선택).
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self
        window.contentView = content

        buildFixedControls()
        buildDynamicControls()
        wire()

        // Windows 초기값 (config 를 읽지 못했을 때 그대로 남는 값들).
        thresholdField.stringValue = "-65"
        delayPopup.selectItem(at: 0)
        idlePopup.selectItem(at: Choices.idleDefaultIndex)
        banner.text = Texts.stateLabelStopped
        statusBar.text = Texts.statusInitial
        centerPathLabel.stringValue = AdvancedWindowController.defaultPathText
        bannerPathLabel.stringValue = AdvancedWindowController.defaultPathText
        stopButton.isEnabled = false
        // Windows 는 페어링된 Classic 기기가 대상일 때만 [재연결] 을 켰다. Mac 에는 그런 대상이
        // 없으므로 늘 꺼 둔다 (자리는 Windows 와 같게 남긴다).
        reconnectButton.isEnabled = false

        content.onResize = { [weak self] size in
            self?.layoutDynamic(size)
        }
        layoutDynamic(content.bounds.size)
        centerOnPrimaryScreen()

        // 모델 값으로 다시 채우는 일은 AppController 의 launch() 가 끝난 뒤에 한다. 지금은
        // AppController.advanced 가 아직 비어 있다 (이 생성자 안이다).
        DispatchQueue.main.async { [weak self] in
            self?.syncFromModel()
        }
    }

    // MARK: - 계약 API

    /// makeKeyAndOrderFront + activate. 숨어 있는 동안 바뀐 값도 다시 읽는다.
    func show() {
        syncFromModel()
        if window.isMiniaturized { window.deminiaturize(nil) }
        AdvancedWindowController.activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    /// 모든 컨트롤을 AppController 의 모델에서 다시 채운다. 꺼져 있는 컨트롤도 바꾼다.
    func syncFromModel() {
        setThresholdText(app.thresholdFieldText)
        selectIndex(delayPopup, app.delayComboIndex, count: Choices.delayValues.count, fallback: 0)
        selectIndex(idlePopup, app.idleComboIndex, count: Choices.idleValues.count, fallback: Choices.idleDefaultIndex)

        // 기기 목록: Mac 에는 등록된 폰 한 줄 (또는 "(등록된 폰 없음)") 뿐이다. 그 줄을 고른다.
        let entries = app.deviceEntries
        if devicePopup.itemTitles != entries {
            devicePopup.removeAllItems()
            devicePopup.addItems(withTitles: entries)
        }
        if devicePopup.numberOfItems > 0 && devicePopup.indexOfSelectedItem != 0 {
            devicePopup.selectItem(at: 0)
        }

        centerPathLabel.stringValue = AdvancedWindowController.pathText(app.centerImagePath)
        bannerPathLabel.stringValue = AdvancedWindowController.pathText(app.bannerImagePath)

        // 상태 띠와 상태 줄은 Windows 에서 비는 일이 없다. 모델이 아직 비어 있으면 지금 글자를 둔다.
        let state = app.stateLabelText
        if !state.isEmpty { banner.text = state }
        countdownLabel.stringValue = app.countdownLabelText
        let status = app.statusText
        if !status.isEmpty { statusBar.text = status }

        // 로그인 중에는 [폰 등록] 을 막는다 (WM_LOGIN_RESULT 가 다시 켠다).
        registerButton.isEnabled = !app.loginBusy
        setMonitoringUI(app.monitoring)
        chart.needsDisplay = true
    }

    /// StartMon 끝 / StopMon: 감시 중에는 [시작], 기기 목록, 신호 강도 칸, 유휴/해제 지연을 끄고
    /// [중지] 를 켠다. [시작] 은 등록된 폰이 없을 때도 꺼 둔다 (PopulateCombo).
    /// Windows 버그 (WM_LOGIN_RESULT 의 PopulateCombo 가 감시 중에 [시작] 을 다시 켰다 -> 감시가
    /// 둘 뜬다) 는 따라 하지 않는다: 감시 중이면 언제나 꺼져 있다.
    func setMonitoringUI(_ monitoring: Bool) {
        if monitoring, thresholdField.currentEditor() != nil {
            // 고치던 중이면 편집을 먼저 끝낸다 (꺼진 칸에 편집기가 남지 않게).
            _ = window.makeFirstResponder(nil)
        }
        startButton.isEnabled = !monitoring && app.hasPhoneEntry
        stopButton.isEnabled = monitoring
        devicePopup.isEnabled = !monitoring
        thresholdField.isEnabled = !monitoring
        idlePopup.isEnabled = !monitoring
        delayPopup.isEnabled = !monitoring
        reconnectButton.isEnabled = false
        recolorBanner()
    }

    /// 큰 상태 띠. 색은 그때그때 AppController 상태로 정한다 (WM_CTLCOLORSTATIC).
    func setStateLabel(_ text: String) {
        banner.text = text
        recolorBanner()
    }

    func setCountdownLabel(_ text: String) {
        countdownLabel.stringValue = text
        // Windows 는 카운트다운 타이머로 잠긴 경우 다음 스캔 결과(2초 안)에야 띠 색을 바꿨다.
        // Mac 은 매 초 다시 정한다 (spec: 글자나 상태가 바뀔 때마다 다시 정한다).
        recolorBanner()
    }

    func setStatus(_ text: String) {
        statusBar.text = text
    }

    /// 목록 맨 위에 한 줄 넣고, 500 줄을 넘으면 맨 아래 줄을 지운다.
    /// insertRows/removeRows 대신 reloadData 를 쓴다: 창이 한 번도 안 그려진 동안 표가 줄 수를
    /// 아직 세지 않았으면 증감 갱신이 어긋나 예외로 앱이 죽을 수 있다. 보이는 줄의 뷰만 다시
    /// 만들므로 2초마다 해도 가볍다. 고른 줄은 ListView 처럼 그 줄을 따라간다.
    func insertRow(_ columns: [String]) {
        rows.insert(columns, at: 0)
        if rows.count > AdvancedWindowController.listCap {
            rows.removeLast(rows.count - AdvancedWindowController.listCap)
        }
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 {
            let next = selected + 1
            if next < rows.count {
                table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }
    }

    func clearRows() {
        rows.removeAll()
        table.reloadData()
    }

    func chartNeedsDisplay() {
        chart.needsDisplay = true
    }

    func setRegisterButtonEnabled(_ on: Bool) {
        registerButton.isEnabled = on
    }

    // MARK: - 단추

    @objc private func onRefresh() { app.refreshDevices() }

    @objc private func onStart() {
        // 칸을 고치던 중이어도 지금 보이는 글자로 시작한다 (controlTextDidChange 가 이미 썼지만
        // 입력기 조합 중인 글자 같은 틈을 막는다).
        app.thresholdFieldText = thresholdField.stringValue
        app.startMon()
    }

    @objc private func onStop() { app.stopMon() }
    @objc private func onBluetooth() { app.openBluetoothSettings() }
    @objc private func onRegister() { app.registerPhone() }
    @objc private func onImportIrk() { app.importIrk() }
    @objc private func onLockNow() { app.lockNow() }
    @objc private func onReconnect() { /* Mac 에서는 늘 꺼져 있다 (setMonitoringUI). */ }
    @objc private func onClear() { app.clearLog() }
    @objc private func onCenterImage() { app.pickCenterImage() }
    @objc private func onBannerImage() { app.pickBannerImage() }
    @objc private func onEnterprise() { app.openEnterprise() }

    @objc private func onDelayChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        if i >= 0 { app.delayComboIndex = i }
    }

    @objc private func onIdleChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        if i >= 0 { app.idleComboIndex = i }
    }

    // MARK: - 만들기

    private func buildFixedControls() {
        // y0 = 12 (기기 줄), 묶음 상자 y = 48, row1Y = 72, row2Y = 108
        place(deviceLabel, 10, 15, 105, 20)
        place(devicePopup, 115, 12, 290, 25)
        place(refreshButton, 412, 12, 64, 28)
        place(startButton, 480, 12, 58, 28)
        place(stopButton, 542, 12, 52, 28)
        place(btButton, 598, 12, 34, 28)
        // 폰이 내주는 토큰으로 신원을 잡는다. Phone Link 설정도 IRK 도 필요 없다.
        place(registerButton, 636, 12, 74, 28)
        // Windows 의 예전 방식 (레지스트리의 IRK). Mac 에서는 안내만 띄운다 (AppController.importIrk).
        place(irkButton, 714, 12, 66, 28)

        place(protectBox, 10, 48, 760, 130)
        place(thresholdLabel, 20, 75, 80, 20)
        place(thresholdField, 105, 72, 50, 24)
        place(thresholdUnit, 160, 75, 55, 20)
        // "자리비움 감지" 고르기는 일부러 없다: 조작해도 아무 일이 안 일어나는 설정을 보여 주는
        // 것은, 없는 것보다 나쁘다 (Windows 도 만들지 않는다).
        place(delayLabel, 20, 111, 110, 20)
        place(delayPopup, 135, 108, 150, 25)
        place(idleLabel, 300, 111, 120, 20)
        place(idlePopup, 420, 108, 150, 25)
        place(lockNowButton, 600, 106, 80, 26)
        place(reconnectButton, 688, 106, 70, 26)
    }

    private func buildDynamicControls() {
        banner.font = AdvancedWindowController.bigFont
        banner.edge = true
        content.addSubview(banner)
        content.addSubview(clearButton)
        content.addSubview(countdownLabel)

        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .bezelBorder
        content.addSubview(listScroll)

        chart.app = app
        content.addSubview(chart)

        // 묶음 상자가 먼저 (아래에 깔린다), 그 위에 글자와 단추.
        content.addSubview(imageBox)
        content.addSubview(centerCaption)
        content.addSubview(centerPathLabel)
        content.addSubview(centerBrowse)
        content.addSubview(bannerCaption)
        content.addSubview(bannerPathLabel)
        content.addSubview(bannerBrowse)
        content.addSubview(enterpriseButton)

        statusBar.font = AdvancedWindowController.uiFont
        statusBar.edge = true
        content.addSubview(statusBar)
    }

    private func wire() {
        hook(refreshButton, #selector(onRefresh))
        hook(startButton, #selector(onStart))
        hook(stopButton, #selector(onStop))
        hook(btButton, #selector(onBluetooth))
        hook(registerButton, #selector(onRegister))
        hook(irkButton, #selector(onImportIrk))
        hook(lockNowButton, #selector(onLockNow))
        hook(reconnectButton, #selector(onReconnect))
        hook(clearButton, #selector(onClear))
        hook(centerBrowse, #selector(onCenterImage))
        hook(bannerBrowse, #selector(onBannerImage))
        hook(enterpriseButton, #selector(onEnterprise))

        delayPopup.target = self
        delayPopup.action = #selector(onDelayChanged(_:))
        idlePopup.target = self
        idlePopup.action = #selector(onIdleChanged(_:))

        thresholdField.delegate = self

        table.dataSource = self
        table.delegate = self
        table.reloadData()
    }

    private func hook(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
    }

    private func place(_ v: NSView, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        v.frame = AdvancedWindowController.rect(x, y, w, h)
        content.addSubview(v)
    }

    // MARK: - WM_SIZE

    /// Windows WM_SIZE 의 식 그대로 (w, h = 클라이언트 크기). 기본 804x741 에서
    /// lH=311, chartY=548, imgGroupY=636, 상태 줄 y=713.
    private func layoutDynamic(_ size: NSSize) {
        let w = Int(size.width), h = Int(size.height)
        let sH = 25
        let cH = 80                      // CHART_HEIGHT
        let stateY = 183
        let listY = stateY + 50
        let imgGroupH = 68
        let bottomPad = sH + 8 + imgGroupH + 8
        let lH = max(60, h - listY - bottomPad - cH - 8)
        let chartY = listY + lH + 4
        let imgGroupY = chartY + cH + 8

        banner.frame = AdvancedWindowController.rect(10, stateY, w - 290, 42)
        clearButton.frame = AdvancedWindowController.rect(w - 270, stateY + 7, 65, 28)
        countdownLabel.frame = AdvancedWindowController.rect(w - 195, stateY + 12, 180, 20)
        listScroll.frame = AdvancedWindowController.rect(10, listY, w - 20, lH)
        chart.frame = AdvancedWindowController.rect(10, chartY, w - 20, cH)
        imageBox.frame = AdvancedWindowController.rect(10, imgGroupY, w - 20, imgGroupH)

        let r1 = imgGroupY + 20, r2 = imgGroupY + 42
        let entW = 140, entX = w - entW - 20
        let browseX = entX - 75, labelW = browseX - 115
        centerCaption.frame = AdvancedWindowController.rect(20, r1 + 2, 85, 20)
        centerPathLabel.frame = AdvancedWindowController.rect(108, r1 + 2, labelW, 20)
        centerBrowse.frame = AdvancedWindowController.rect(browseX, r1, 65, 22)
        bannerCaption.frame = AdvancedWindowController.rect(20, r2 + 2, 85, 20)
        bannerPathLabel.frame = AdvancedWindowController.rect(108, r2 + 2, labelW, 20)
        bannerBrowse.frame = AdvancedWindowController.rect(browseX, r2, 65, 22)
        enterpriseButton.frame = AdvancedWindowController.rect(entX, imgGroupY + 16, entW, 40)

        statusBar.frame = AdvancedWindowController.rect(0, h - sH - 3, w, sH)

        // 직접 그리는 뷰는 크기가 바뀌면 다시 그린다 (차트는 폭에 따라 눈금이 달라진다).
        chart.needsDisplay = true
        banner.needsDisplay = true
        statusBar.needsDisplay = true
    }

    // MARK: - 내부 도우미

    /// WM_CTLCOLORSTATIC (상태 띠만):
    ///   감시 중 + 잠김 -> 흰 글자 / RGB(220,60,60)
    ///   감시 중 + NEAR -> 흰 글자 / RGB(46,160,67)
    ///   감시 중 (FAR)  -> RGB(60,60,60) / RGB(200,200,200)
    ///   감시 안 함     -> 시스템 기본
    private func recolorBanner() {
        let monitoring = app.monitoring
        if monitoring && app.guardEngine.blackActive {
            banner.setColors(text: NSColor.white, background: AdvancedWindowController.rgb(220, 60, 60))
        } else if monitoring && app.isNear {
            banner.setColors(text: NSColor.white, background: AdvancedWindowController.rgb(46, 160, 67))
        } else if monitoring {
            banner.setColors(text: AdvancedWindowController.rgb(60, 60, 60),
                             background: AdvancedWindowController.rgb(200, 200, 200))
        } else {
            banner.setColors(text: nil, background: nil)
        }
    }

    /// 모델 글자가 지금 칸과 다를 때만 바꾼다 (같은 글자를 다시 넣으면 고치는 중의 커서가 튄다).
    private func setThresholdText(_ s: String) {
        if thresholdField.stringValue == s { return }
        if thresholdField.currentEditor() != nil {
            // 고치는 중이면 편집을 먼저 끝내고 넣는다. 그러지 않으면 편집이 끝날 때 편집기에
            // 남은 옛 글자가 새 값을 덮는다.
            _ = window.makeFirstResponder(nil)
        }
        thresholdField.stringValue = s
    }

    /// 잘못된 번호는 Windows 처럼 기본값으로 (해제 지연 0, 유휴 2).
    private func selectIndex(_ popup: NSPopUpButton, _ index: Int, count: Int, fallback: Int) {
        let i = (index >= 0 && index < count && index < popup.numberOfItems) ? index : fallback
        if i >= 0 && i < popup.numberOfItems && popup.indexOfSelectedItem != i {
            popup.selectItem(at: i)
        }
    }

    private func centerOnPrimaryScreen() {
        // 주 화면 = NSScreen.screens.first (메뉴 막대가 있는 화면).
        guard let screen = NSScreen.screens.first else {
            window.center()
            return
        }
        let vf = screen.visibleFrame
        let fr = window.frame
        // 화면보다 크면 제목 막대가 보이게 위쪽을 맞춘다.
        let y = min(vf.maxY - fr.height, vf.midY - fr.height / 2)
        window.setFrameOrigin(NSPoint(x: (vf.midX - fr.width / 2).rounded(), y: y.rounded()))
    }

    private static func pathText(_ p: String) -> String {
        return p.isEmpty ? defaultPathText : Texts.truncPath(p)
    }

    private static func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> NSRect {
        return NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(max(0, w)), height: CGFloat(max(0, h)))
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        return NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0,
                       blue: CGFloat(b) / 255.0, alpha: 1.0)
    }

    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    // ---- 컨트롤 공장 (생성자보다 먼저 불리므로 self 를 쓰지 않는다) ----

    private static func makeLabel(_ text: String, bold: Bool = false,
                                  align: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? uiBold : uiFont
        l.alignment = align
        l.lineBreakMode = .byClipping
        l.isSelectable = false
        return l
    }

    /// 경로 칸: SS_ENDELLIPSIS. 글자는 TruncPath 로 이미 줄였고, 그래도 넘치면 끝을 "…" 로.
    private static func makePathLabel() -> NSTextField {
        let l = NSTextField(labelWithString: defaultPathText)
        l.font = uiFont
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.cell?.truncatesLastVisibleLine = true
        l.isSelectable = false
        return l
    }

    private static func makeButton(_ title: String, tall: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        // 보통 높이(28 이하)는 둥근 단추, 키가 큰 단추(40)는 높이만큼 늘어나는 네모 단추.
        b.bezelStyle = tall ? .regularSquare : .rounded
        b.font = uiFont
        return b
    }

    private static func makePopup(_ items: [String]) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.font = uiFont
        if !items.isEmpty { p.addItems(withTitles: items) }
        return p
    }

    /// "신호 강도" 칸: 가운데 맞춤, 숫자 전용이 아니다 ('-' 를 칠 수 있어야 한다).
    private static func makeThresholdField() -> NSTextField {
        let f = NSTextField(string: "-65")
        f.font = uiFont
        f.alignment = .center
        f.isEditable = true
        f.isSelectable = true
        f.isBezeled = true
        f.bezelStyle = .squareBezel
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.cell?.usesSingleLineMode = true
        return f
    }

    private static func makeGroup(_ title: String) -> NSBox {
        let b = NSBox(frame: .zero)
        b.boxType = .primary
        b.title = title
        b.titlePosition = .atTop
        b.titleFont = sectionFont
        return b
    }

    /// 보고서 모양 목록: 한 줄 선택, 줄 전체 선택, 격자선, 정렬 머리 없음.
    private static func makeTable() -> NSTableView {
        let t = NSTableView(frame: .zero)
        t.style = .plain
        t.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        t.allowsMultipleSelection = false
        t.allowsEmptySelection = true
        t.allowsColumnSelection = false
        t.allowsColumnReordering = false
        t.usesAlternatingRowBackgroundColors = false
        t.columnAutoresizingStyle = .noColumnAutoresizing
        t.rowHeight = 17
        if t.headerView == nil { t.headerView = NSTableHeaderView() }
        let columns: [(String, CGFloat)] = [
            ("Time", 70), ("신호 강도", 70), ("Signal", 80), ("Distance", 80),
            ("State", 80), ("Timer", 55), ("Event", 250),
        ]
        for (i, c) in columns.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "c\(i)"))
            col.title = c.0
            col.width = c.1
            col.minWidth = 10
            col.resizingMask = .userResizingMask
            col.headerCell.font = uiFont
            t.addTableColumn(col)
        }
        return t
    }
}

// MARK: - 창 위임

extension AdvancedWindowController: NSWindowDelegate {
    /// [X] 는 숨기기만 한다. 끝내는 길은 오버레이의 [종료] 하나다 (그래야 화면을 지키는 프로그램이
    /// 실수로 꺼지지 않는다). 예전에는 감시가 멈춰 있을 때만 예외로 프로그램을 끝냈는데, 그 조건을
    /// 아는 사람이 없어서 "[중지] 하고 X 를 눌렀더니 프로그램이 죽는다" 가 됐다.
    /// Windows 는 오버레이가 없을 때(정상 실행에서는 없다)만 끝냈다 - 돌아올 길이 없어서. Mac 은
    /// Finder/Launchpad 에서 앱을 다시 열면 간단 창이 돌아오므로 늘 숨기기만 한다.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - 신호 강도 칸 -> 모델

extension AdvancedWindowController: NSTextFieldDelegate {
    /// 한 글자 칠 때마다 모델에 쓴다. 간단 창 슬라이더와 [시작] 이 같은 값을 본다.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === thresholdField else { return }
        app.thresholdFieldText = field.stringValue
    }
}

// MARK: - 목록 (7칸)

extension AdvancedWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row >= 0, row < rows.count else { return nil }
        let id = column.identifier
        let index = Int(id.rawValue.dropFirst()) ?? 0
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.font = AdvancedWindowController.uiFont
            cell.lineBreakMode = .byTruncatingTail
            cell.maximumNumberOfLines = 1
            cell.isSelectable = false
        }
        let values = rows[row]
        cell.stringValue = (index >= 0 && index < values.count) ? values[index] : ""
        return cell
    }
}

// MARK: - 내부 뷰

/// 뒤집힌 내용 뷰. 크기가 바뀌면 WM_SIZE 처럼 다시 배치한다 (자동 배치 규칙은 쓰지 않는다).
private final class AdvFlippedView: NSView {
    var onResize: ((NSSize) -> Void)?

    override var isFlipped: Bool { return true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
    }
}

/// 한 줄 글자 띠: 상태 띠 (SS_CENTERIMAGE, 큰 글꼴, 색 바탕) 와 상태 줄 (SS_SUNKEN).
/// NSTextField 는 세로 가운데 맞춤과 바탕색 바꾸기가 불편해서 직접 그린다.
private final class AdvTextStrip: NSView {
    var text: String = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var font: NSFont = NSFont.systemFont(ofSize: 11) {
        didSet { needsDisplay = true }
    }
    /// 움푹한 테두리 (WS_EX_CLIENTEDGE / SS_SUNKEN)
    var edge = false {
        didSet { needsDisplay = true }
    }
    /// nil = 시스템 기본
    private var textColor: NSColor?
    private var backgroundColor: NSColor?

    override var isFlipped: Bool { return true }

    func setColors(text: NSColor?, background: NSColor?) {
        textColor = text
        backgroundColor = background
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        if let bg = backgroundColor {
            bg.setFill()
            NSBezierPath.fill(b)
        }
        if edge {
            let border = NSBezierPath(rect: b.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            NSColor(srgbRed: 160.0 / 255.0, green: 160.0 / 255.0, blue: 160.0 / 255.0, alpha: 1).setStroke()
            border.stroke()
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byClipping
        para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor ?? NSColor.labelColor,
            .paragraphStyle: para,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let h = ceil(s.size().height)
        let inset: CGFloat = edge ? 2 : 0
        let y = floor((b.height - h) / 2)
        s.draw(in: NSRect(x: inset, y: y, width: max(0, b.width - inset * 2), height: h))
    }
}
