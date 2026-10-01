import AppKit
import SmartScreenCore

// 재보기 마법사 (Windows client/main.cpp 의 SmartScreenWizard 창: OpenWizard, WizProc,
// WzSetPhase, WzCollect, WzJudge).
//
// 거리 3단계가 근거를 갖게 만드는 곳이다. 같은 "보통"이 자리와 어댑터에 따라 10~20 dB
// 달라져서, 재보지 않으면 3단계는 그냥 임의의 숫자다. 앉아 있을 때와 자리를 비웠을 때의
// 세기를 재서 기준(measuredBaseRssi)을 정하고, 3단계는 그 기준에서의 차이로 둔다.
//
// 재는 김에 어댑터도 본다. 값싼 동글 중에 신호 세기를 제대로 내주지 않는 것이 있는데,
// 드라이버는 멀쩡하다고 보고하므로 실제로 재 보는 것 말고는 확인할 방법이 없다. Mac 은 대개
// 내장 컨트롤러지만, 값이 멎은 스캔이나 캐시된 세기도 같은 검사에 걸리므로 그대로 둔다.
//
// 폰을 들고 나가게 하면 2·3단계 안내를 읽을 사람이 화면 앞에 없다. 그래서 폰만 두고 돌아오게
// 하고, 다 왔는지는 버튼으로 받는다 - 걸어갔다 오는 시간을 초로 못박으면 자리가 먼 사람에게는
// 모자라고 가까운 사람은 기다리기만 한다.
//
// 모달이 아니다: 간단 창은 그대로 쓸 수 있다. 여는 동안 app.setMeasuring(true) 라 자동 잠금과
// 업데이트 재시작이 멈춘다 (수동 잠금은 된다). 어떤 길로 닫혀도 windowWillClose 가 되돌린다.
//
// 판정과 글은 Core 의 WizardJudge 가 한다. 여기서는 표본을 모으고 단계를 넘기고 그린다.
final class WizardWindowController: NSObject {
    /// 한 번에 하나만 (Windows g_hWiz)
    private static var current: WizardWindowController?
    private static let windowTitle = "내 자리에 맞게 재보기"

    private unowned let app: AppController
    private let window: NSWindow
    private let content = WizardContentView(frame: NSRect(x: 0, y: 0, width: 426, height: 293))
    // 진행 막대 (26, 186, 368x8) - 1·3 단계에만 보인다
    private let progress = SSProgressBar(frame: NSRect(x: 26, y: 186, width: 368, height: 8))
    // 다음 단추 (26, WZ_H-96=234, 368x42), 강조 타일
    private let nextButton = SSTileButton(frame: NSRect(x: 26, y: 234, width: 368, height: 42),
                                          title: "시작하기", style: .accent)
    // [그만두기] (WZ_W-140=300, 14, 100x30): 바탕 kPanelBg, 테두리 kTileEdge, 글 kInkSoft, 반지름 5
    private let cancelButton = SSTileButton(frame: NSRect(x: 300, y: 14, width: 100, height: 30),
                                            title: "그만두기", style: .ghost)

    private var timer: Timer?
    /// 0 안내 / 1 착석 / 2 이동 / 3 비움 / 4 결과
    private var phase = 0
    private var left = 0
    /// 타이머는 0.5초, 카운트다운은 1초. Windows 는 함수 안 static 이라 단계와 실행을 넘어
    /// 남았다(그만둔 다음 실행의 첫 1초가 0.5초가 될 수 있었다). 1·3 단계를 시작할 때 0 으로 둔다.
    private var half = 0
    private var seated: [Int] = []
    private var away: [Int] = []
    private var lastTick: UInt64 = 0
    private var verdict: WizardVerdict?
    private var finished = false

    // MARK: - OpenWizard

    /// 간단 창의 [내 자리에 맞게 재보기] (AppController.openWizard 가 부른다).
    static func open(app: AppController, parent: NSWindow?) {
        if let cur = current {
            NSApp.activate(ignoringOtherApps: true)
            cur.window.makeKeyAndOrderFront(nil)
            return
        }
        // 폰을 모르면 잴 것이 없다. 스캐너가 어느 광고가 내 폰인지 가려내지 못하면 표본이 하나도
        // 안 쌓이고, 마법사는 "신호를 거의 못 받았어요" 로 끝난다 - 원인이 등록인데 엉뚱한 곳을
        // 보게 된다.
        let c = ConfigStore.load()
        if c.phoneToken.isEmpty {
            if Alerts.okCancel("먼저 폰을 등록해야 해요.\n\n어느 신호가 내 폰인지 알아야 거리를 잴 수 있어요.\n지금 등록할까요?",
                               title: windowTitle) {
                // 간단 창의 [등록하기] 와 같은 일 (Windows: 부모에 IDS_PHONE 을 보낸다)
                app.registerPhone()
                app.simple?.refresh()
            }
            return
        }
        if !app.monitoring {
            Alerts.info("먼저 보호를 켜야 신호를 받을 수 있어요.\n[고급 설정] 에서 시작을 눌러 주세요.",
                        title: windowTitle)
            return
        }
        // 재는 동안 화면이 꺼지면 측정이 끊긴다. 자리를 비우는 것이 절차의 일부라 그냥 두면
        // 반드시 꺼진다. 창을 만들기 전에 켠다.
        app.setMeasuring(true)
        let wz = WizardWindowController(app: app, parent: parent)
        current = wz
        wz.begin()
    }

    private init(app: AppController, parent: NSWindow?) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 426, height: 293),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()

        window.isReleasedWhenClosed = false
        window.title = WizardWindowController.windowTitle
        // Windows 판에는 다크 모드가 없다 (간단 창과 같은 이유)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = SSColors.panelBg
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = content
        window.delegate = self

        progress.isHidden = true
        content.addSubview(progress)
        nextButton.target = self
        nextButton.action = #selector(onNext(_:))
        content.addSubview(nextButton)
        cancelButton.target = self
        cancelButton.action = #selector(onCancel(_:))
        content.addSubview(cancelButton)

        // Windows: 부모 창의 (왼쪽+20, 위+60). 시트가 아니라 따로 선 창이다 - 간단 창을 막으면 안 된다.
        if let p = parent {
            window.setFrameTopLeftPoint(NSPoint(x: p.frame.minX + 20, y: p.frame.maxY - 60))
        } else {
            window.center()
        }
    }

    private func begin() {
        timer = MainTimer.every(0.5) { [weak self] in
            self?.onTimer()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        setPhase(0)
    }

    // MARK: - 단계

    private func setPhase(_ ph: Int) {
        phase = ph
        // 스캐너에 남아 있던 직전 패킷을 새 구간의 첫 표본으로 세지 않는다.
        let now = Mono.now()
        let g = GattServer.shared.snapshot(now: now)
        lastTick = g.healthy ? g.lastReportTick : AdvScanner.shared.snapshot(now: now).lastReceivedTick

        switch ph {
        case 1:
            left = WizardJudge.seatedSec
            half = 0
        case 3:
            left = WizardJudge.awaySec
            half = 0
        case 4:
            judge()
        default:
            break
        }

        progress.maxValue = Double(ph == 1 ? WizardJudge.seatedSec : WizardJudge.awaySec)
        progress.value = 0
        let progressVisible = (ph == 1 || ph == 3)
        if progress.isHidden == progressVisible { progress.isHidden = !progressVisible }

        let label: String
        switch ph {
        case 0: label = "시작하기"
        case 2: label = "폰을 두고 왔어요"
        case 4: label = (verdict?.ok ?? false) ? "이대로 쓰기" : "닫기"
        default: label = ""
        }
        if nextButton.title != label { nextButton.title = label }
        let nextVisible = (ph == 0 || ph == 2 || ph == 4)
        if nextButton.isHidden == nextVisible { nextButton.isHidden = !nextVisible }

        updateTexts()
    }

    /// WzJudge: 순서와 글은 Core (표본 부족 → 어댑터 → 겹침 → 완료). 결과 화면은 "보통 을
    /// 맞췄어요" 라고 말하지만 [이대로 쓰기] 를 누르기 전에는 아무것도 저장하지 않는다 - 마법사는
    /// 믿지 않는 값을 쓰지 않는다.
    private func judge() {
        let v = WizardJudge.judge(seated: seated, away: away)
        verdict = v
        EventLog.write(v.logLine)
    }

    /// WzCollect: 새 패킷이 왔을 때만 한 번 센다. 같은 값을 반복해서 담으면 표본이 부풀어
    /// 어댑터가 멀쩡한 것처럼 보인다 - 바로 그걸 찾으려는 참인데.
    ///
    /// 0.5초마다 가장 최근 패킷 하나만 본다 (초당 많아야 2개). 광고가 올 때마다 담으면 표본 수와
    /// 범위가 Windows 와 달라져 15/8 개, 1 dB 판정이 다르게 움직인다. 칼만으로 다듬은 값이
    /// 아니라 날값을 쓴다. 연결(GATT)이 살아 있고 보고가 한 번이라도 왔으면 폰이 잰 값, 아니면
    /// 이 Mac 이 받은 광고의 값 - 도중에 바뀔 수 있다 (두 값의 차이는 중앙값 2 dB).
    /// 돌려주는 값은 새 표본, 없으면 nil. 어느 경우든 lastTick 은 앞으로 간다.
    private func collect() -> Int? {
        let now = Mono.now()
        let g = GattServer.shared.snapshot(now: now)
        let tick: UInt64
        let rssi: Int
        if g.healthy && g.lastReportTick != 0 {
            tick = g.lastReportTick
            rssi = g.rawRssi
        } else {
            let s = AdvScanner.shared.snapshot(now: now)
            tick = s.lastReceivedTick
            rssi = s.rawRssi
        }
        if tick == 0 || tick == lastTick { return nil }
        lastTick = tick
        if rssi <= -100 || rssi >= 0 { return nil }   // 측정값이 아니라 표식이다
        return rssi
    }

    // MARK: - 타이머 (IDT_WIZ, 500 ms)

    private func onTimer() {
        if finished { return }
        if phase == 1 {
            if let v = collect() { seated.append(v) }
        } else if phase == 3 {
            if let v = collect() { away.append(v) }
        } else if phase == 2 {
            _ = collect()      // 옮기는 중: 버린다 (lastTick 만 앞으로)
        }

        if phase == 1 || phase == 3 {
            half += 1
            if half >= 2 {     // 타이머는 0.5초, 카운트다운은 1초
                half = 0
                left -= 1
                if left <= 0 {
                    // 마지막 칸은 그리지 않는다 - 그 대신 다음 단계로 넘어간다
                    setPhase(phase + 1)
                } else {
                    let total = phase == 1 ? WizardJudge.seatedSec : WizardJudge.awaySec
                    progress.value = Double(total - left)
                }
            }
        }
        updateTexts()
    }

    private func updateTexts() {
        var title = ""
        var body = ""
        var live = ""
        var isError = false
        if phase >= 0 && phase < 4 {
            if phase < WizardJudge.phaseTitles.count { title = WizardJudge.phaseTitles[phase] }
            if phase < WizardJudge.phaseBodies.count { body = WizardJudge.phaseBodies[phase] }
        } else if let v = verdict {
            title = v.title
            body = v.body
            isError = !v.ok
        }
        // 세 칸씩 띄운 가운뎃점 (Windows 와 같은 글)
        if phase == 1 {
            live = "\(left)초 남음   ·   \(seated.count)번 받음"
        } else if phase == 3 {
            live = "\(left)초 남음   ·   \(away.count)번 받음"
        }
        content.update(title: title, body: body, live: live, titleIsError: isError)
    }

    // MARK: - 단추

    @objc private func onNext(_ sender: Any?) {
        switch phase {
        case 0:
            seated.removeAll()
            away.removeAll()
            setPhase(1)
        case 2:
            setPhase(3)
        case 4:
            if let v = verdict, v.ok {
                var c = ConfigStore.load()
                c.measuredBaseRssi = v.base
                ConfigStore.save(c)
                // 방금 잰 값이 "보통" 이다. 여기서 가장 가까운 단계(SimpleDistStep)를 쓰면 안 된다 -
                // 그건 예전 절대 임계값에 가장 가까운 단계를 찾는데, 기준이 방금 바뀌었으니 그 비교는
                // 뜻이 없다. 실제로 연달아 재면 "가까이" 가 잡혔고, 그 값은 착석 최저값보다 위여서
                // 앉아 있는 사람 앞에서 화면이 꺼진다.
                app.simpleApplyDist(1)
                app.simple?.refresh()
            }
            window.close()
        default:
            break
        }
    }

    @objc private func onCancel(_ sender: Any?) {
        // 어느 단계에서든 저장하지 않고 닫는다
        window.close()
    }

    /// WM_DESTROY: 타이머를 멈추고, 측정 표시를 끄고("다시 잠길 수 있게"), 간단 창을 앞으로.
    /// 그만두기, 결과 단추, 제목줄 X 가 모두 여기로 온다.
    ///
    /// 3단계에서 그만두면 폰은 아직 멀리 있다 - 측정 표시가 꺼지면 상태는 FAR 이고, 입력이 5초
    /// 끊기면 폰을 가지러 가는 사이에 화면이 가려진다. 그게 맞는 동작이다.
    fileprivate func finish() {
        if finished { return }
        finished = true
        timer?.invalidate()
        timer = nil
        window.delegate = nil
        if WizardWindowController.current === self {
            WizardWindowController.current = nil
        }
        app.setMeasuring(false)
        if let sw = app.simple?.window, sw.isVisible {
            sw.makeKeyAndOrderFront(nil)
        }
        // 창이 닫히는 도중이다. 창의 주인인 이 객체는 닫기가 끝날 때까지 살려 둔다.
        let keep = self
        DispatchQueue.main.async {
            _ = keep
        }
    }
}

// 창 위임은 확장에 둔다 (주 선언에 두면 Swift 5 모드에서 클래스 전체가 @MainActor 로 추론된다).
extension WizardWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish()
    }
}

/// 마법사 바탕과 글 (Windows WizProc WM_ERASEBKGND + WM_PAINT). 500 ms 마다 다시 그린다.
private final class WizardContentView: NSView {
    private var title = ""
    private var body = ""
    private var live = ""
    private var titleIsError = false

    override var isFlipped: Bool { return true }

    func update(title: String, body: String, live: String, titleIsError: Bool) {
        self.title = title
        self.body = body
        self.live = live
        self.titleIsError = titleIsError
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SSColors.panelBg.setFill()
        NSBezierPath.fill(dirtyRect)

        // 제목 {26, 56, 394, 96}: 큰 글꼴, 줄바꿈. 결과가 실패면 #C03030.
        // 두 줄이 되어도 본문(104) 앞까지는 그린다.
        SSDraw.text(title, in: NSRect(x: 26, y: 56, width: 368, height: 48),
                    font: SSFonts.big, color: titleIsError ? SSColors.wizardError : SSColors.ink, wrap: true)
        // 본문 {26, 104, 394, 220}. Windows 의 116pt 칸은 긴 어댑터 문구의 마지막 줄을 자를 수
        // 있었다 - 다음 단추(234) 바로 위 230 까지 쓴다.
        SSDraw.text(body, in: NSRect(x: 26, y: 104, width: 368, height: 126),
                    font: SSFonts.normal, color: SSColors.inkSoft, wrap: true)
        // "남은 시간 · 받은 수" {26, 202, 394, 226}: 1·3 단계에만, 강조색 한 줄
        if !live.isEmpty {
            SSDraw.text(live, in: NSRect(x: 26, y: 202, width: 368, height: 24),
                        font: SSFonts.normal, color: SSColors.accent, wrap: false)
        }
    }
}
