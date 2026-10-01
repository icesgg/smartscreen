import AppKit
import SmartScreenCore

// 간단 화면 (Windows client/main.cpp 의 SmartScreenSimple 창, SimpleProc, SimpleRefresh).
//
// 기본으로 열리는 창. 지금까지의 설정 창은 [고급 설정] 으로 물러난다.
//
// 그 창은 dBm 과 이벤트 표를 그대로 보여주는데, 그건 이 프로그램을 만든 사람에게나 읽히는
// 화면이다. 쓰는 사람이 정해야 하는 것은 사실 셋뿐이다: 내 폰이 무엇이고, 얼마나 멀어지면
// 가리고, 몇 초 뒤에 가리는가.
//
// 명령은 전부 AppController 로 넘긴다. 폰 등록이나 그림 고르기를 여기서 다시 구현하면 두 벌이
// 되고, 한쪽만 고쳐지는 날이 온다. 이 창은 그리고, 누른 것을 넘기고, 1초마다 전역 상태를
// 다시 읽어 보여줄 뿐이다 (AppController 가 숨어 있을 때도 1초마다 refresh() 를 부른다).
//
// 트레이 아이콘이 없다. 오버레이의 [설정] (과 Finder/Launchpad 에서 앱을 다시 여는 것) 이 이
// 창으로 돌아오는 길이다. X 는 숨기기만 한다.
//
// 클립보드 공유 한 칸이 늘어 654 -> 750 이 됐다. 이 창은 세로로 자라기만 해 왔고, 다음에 또
// 늘릴 일이 생기면 그때는 접기나 스크롤을 넣어야 한다 - 1200 짜리 화면에서도 작업 표시줄까지
// 치면 여유가 얼마 남지 않았다.
//
// 좌표는 Windows 의 클라이언트 좌표(왼쪽 위 원점, px)를 그대로 pt 로 쓴다 - 내용 보기를
// 뒤집어(isFlipped) 두었다. Windows 바깥 크기 430x750 의 안쪽이 416x713 이다.
final class SimpleWindowController: NSObject {
    let window: NSWindow

    private unowned let app: AppController

    private enum L {
        static let contentW: CGFloat = 416
        static let contentH: CGFloat = 713
        /// SW_UPD_H: 업데이트 띠가 보일 때만 창이 이만큼 자란다 - 상시로 늘릴 자리가 없다.
        static let bandH: CGFloat = 100
        static let x: CGFloat = 22
        static let w: CGFloat = 368      // SW_W - 62
    }

    private let content = SimpleContentView(frame: NSRect(x: 0, y: 0, width: L.contentW, height: L.contentH))

    // 머리: 버전 단추는 늘 있다 - 어느 PC 가 어느 버전인지가 이걸로 보인다.
    private let versionButton = SSTileButton(frame: NSRect(x: 22, y: 14, width: 210, height: 28),
                                             title: "", style: .ghost)
    private let advancedButton = SSTileButton(frame: NSRect(x: 298, y: 14, width: 92, height: 28),
                                              title: "고급 설정", style: .ghost)
    // 상태 카드 (22, 58, 368x78) 는 content 가 그린다.
    // 윈도우 11 의 wifi·블루투스 타일과 같은 규칙: 켜져 있으면 파랗다.
    private let guardTile = SSTileButton(frame: NSRect(x: 22, y: 150, width: 368, height: 44),
                                         title: "보호 꺼짐", style: .normal)
    private let phoneLabel = SimpleWindowController.makeLabel("", NSRect(x: 22, y: 235, width: 272, height: 20),
                                                              lineBreak: .byTruncatingMiddle)
    private let phoneButton = SSTileButton(frame: NSRect(x: 302, y: 230, width: 88, height: 32),
                                           title: "바꾸기", style: .normal)
    private let slider = SSDistanceSlider(frame: NSRect(x: 22, y: 300, width: 368, height: 32))
    private let measureButton = SSTileButton(frame: NSRect(x: 22, y: 356, width: 368, height: 36),
                                             title: "", style: .normal)
    private var idleTiles: [SSTileButton] = []
    private let imageButton = SSTileButton(frame: NSRect(x: 22, y: 500, width: 150, height: 36),
                                           title: "그림 고르기", style: .normal)
    // "지금 가리기" 는 강조색이 아니다. 파란 타일은 켜져 있는 것과 지금 고른 것뿐이다.
    private let lockNowButton = SSTileButton(frame: NSRect(x: 22, y: 552, width: 368, height: 42),
                                             title: "지금 가리기", style: .normal)
    // 클립보드 공유 (ClipSync). 자리비움 감지와 아무 상관이 없는 기능이지만, 이 앱으로 돌아오는
    // 길이 이 창뿐이라 여기 둔다.
    private let clipTile = SSTileButton(frame: NSRect(x: 22, y: 628, width: 368, height: 44),
                                        title: "클립보드 공유 꺼짐", style: .normal)
    // 상태 한 줄을 반드시 같이 둔다 - 서버를 타는 기능이라 조용히 실패할 수 있고, 그러면
    // 사용자는 "켰는데 안 된다" 외에 할 말이 없다.
    private let clipLabel = SimpleWindowController.makeLabel("", NSRect(x: 22, y: 676, width: 368, height: 18),
                                                             lineBreak: .byTruncatingTail)
    // 업데이트 띠. 글은 폭 전체를 쓴다 (세 줄까지). 실패 이유가 여기 뜨는데, 단추 옆 좁은 칸에서는
    // 뒷부분 - 대개 "어떻게 하라" 는 부분 - 이 잘려 나갔다. 단추는 그 아래 줄.
    // 713 아래에 있어서 창이 100 자랄 때만 보인다. 만들 때는 숨겨 둔다.
    private let bandLabel = SimpleWindowController.makeLabel("", NSRect(x: 22, y: 704, width: 368, height: 54),
                                                             lineBreak: .byWordWrapping)
    private let applyButton = SSTileButton(frame: NSRect(x: 214, y: 762, width: 84, height: 30),
                                           title: "업데이트", style: .accent)
    private let laterButton = SSTileButton(frame: NSRect(x: 306, y: 762, width: 84, height: 30),
                                           title: "나중에", style: .ghost)

    /// 슬라이더가 지금 가리키는 단계. 값이 바뀐 때만 적용한다 (Windows 는 WM_HSCROLL 마다
    /// 적용해 한 번 끌 때 여러 번 저장·기록했다 - 결과는 같다).
    private var shownDistStep = 1

    init(app: AppController) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: L.contentW, height: L.contentH),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        build()
    }

    // MARK: - 창 만들기 (WM_CREATE)

    private func build() {
        window.isReleasedWhenClosed = false
        window.title = "SmartScreen \(BuildInfo.version)"
        // Windows 판에는 다크 모드가 없다. 시스템 색을 따르면 #F3F3F3 위의 라벨이 흰색이 된다.
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = SSColors.panelBg
        window.isRestorable = false
        window.tabbingMode = .disallowed
        // 다른 데스크톱(Space)에 있을 때 오버레이 [설정] 을 누르면, 그 Space 로 끌려가지 않고
        // 지금 보는 곳으로 창이 온다.
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = content
        window.delegate = self

        let x = L.x
        let w = L.w

        add(versionButton, #selector(onVersion(_:)))
        add(advancedButton, #selector(onAdvanced(_:)))
        add(guardTile, #selector(onGuard(_:)))

        content.addSubview(SimpleWindowController.makeLabel("내 폰", NSRect(x: x, y: 208, width: 200, height: 18)))
        content.addSubview(phoneLabel)
        add(phoneButton, #selector(onPhone(_:)))

        content.addSubview(SimpleWindowController.makeLabel("얼마나 멀어지면 가릴까요?",
                                                            NSRect(x: x, y: 278, width: 300, height: 18)))
        slider.target = self
        slider.action = #selector(onDist(_:))
        content.addSubview(slider)
        content.addSubview(SimpleWindowController.makeLabel("가까이", NSRect(x: x, y: 332, width: 60, height: 16)))
        content.addSubview(SimpleWindowController.makeLabel("보통", NSRect(x: x + w / 2 - 30, y: 332, width: 60, height: 16),
                                                            align: .center))
        content.addSubview(SimpleWindowController.makeLabel("멀리", NSRect(x: x + w - 60, y: 332, width: 60, height: 16),
                                                            align: .right))
        add(measureButton, #selector(onMeasure(_:)))

        content.addSubview(SimpleWindowController.makeLabel("자리를 뜨고 몇 초 뒤에 가릴까요?",
                                                            NSRect(x: x, y: 406, width: 320, height: 18)))
        // 몇 초 뒤에 가릴지. 고급 창의 유휴 시간 값(Choices.idleValues)에 다 들어 있어야 한다.
        let n = Choices.simpleIdle.count
        let cellW = (w / CGFloat(max(n, 1))).rounded(.down)     // w/4 = 92
        for i in 0..<n {
            let label = i < Choices.simpleIdleLabels.count ? Choices.simpleIdleLabels[i] : ""
            let t = SSTileButton(frame: NSRect(x: x + CGFloat(i) * cellW, y: 428, width: cellW - 8, height: 38),
                                 title: label, style: .normal)
            t.tag = i
            add(t, #selector(onIdle(_:)))
            idleTiles.append(t)
        }

        content.addSubview(SimpleWindowController.makeLabel("가릴 때 보여줄 그림",
                                                            NSRect(x: x, y: 478, width: 300, height: 18)))
        add(imageButton, #selector(onImage(_:)))
        add(lockNowButton, #selector(onLockNow(_:)))

        content.addSubview(SimpleWindowController.makeLabel("다른 PC 와 클립보드 공유",
                                                            NSRect(x: x, y: 606, width: 300, height: 18)))
        add(clipTile, #selector(onClip(_:)))
        content.addSubview(clipLabel)

        bandLabel.maximumNumberOfLines = 3
        bandLabel.cell?.wraps = true
        bandLabel.cell?.truncatesLastVisibleLine = true
        bandLabel.isHidden = true
        content.addSubview(bandLabel)
        applyButton.isHidden = true
        add(applyButton, #selector(onApply(_:)))
        laterButton.isHidden = true
        add(laterButton, #selector(onLater(_:)))

        centerOnPrimaryScreen()
    }

    private func add(_ b: SSTileButton, _ action: Selector) {
        b.target = self
        b.action = action
        content.addSubview(b)
    }

    /// STATIC + WM_CTLCOLORSTATIC: 바탕 없이 kInkSoft 글. Windows 는 이걸 안 두면 라벨마다 회색
    /// 상자가 얹혔다. NSTextField 는 글 양옆에 2pt 씩 여백을 두므로, Windows STATIC 처럼 x 에서
    /// 글이 시작하도록(타일 왼쪽 끝과 맞도록) 2pt 당기고 4pt 넓힌다.
    private static func makeLabel(_ text: String, _ r: NSRect, align: NSTextAlignment = .left,
                                  lineBreak: NSLineBreakMode = .byClipping) -> NSTextField {
        // 여러 줄(SS_LEFT 띠)은 처음부터 줄바꿈 라벨로 만든다 - 한 줄 라벨의 셀은 스크롤형이라
        // 줄바꿈 설정만 바꿔서는 안 접힐 수 있다.
        let wraps = lineBreak == .byWordWrapping
        let f = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        f.frame = NSRect(x: r.minX - 2, y: r.minY, width: r.width + 4, height: r.height)
        f.font = SSFonts.normal
        f.textColor = SSColors.inkSoft
        f.drawsBackground = false
        f.isBezeled = false
        f.isBordered = false
        f.isEditable = false
        f.isSelectable = false
        f.alignment = align
        f.lineBreakMode = lineBreak
        if !wraps {
            f.maximumNumberOfLines = 1
        }
        return f
    }

    /// 주 화면 가운데 (Windows: ((sx-430)/2, (sy-750)/2)).
    private func centerOnPrimaryScreen() {
        guard let screen = NSScreen.screens.first else {
            window.center()
            return
        }
        let vf = screen.visibleFrame
        let f = window.frame
        let ox = vf.minX + ((vf.width - f.width) / 2).rounded(.down)
        let oy = vf.minY + ((vf.height - f.height) / 2).rounded(.down)
        window.setFrameOrigin(NSPoint(x: ox, y: oy))
    }

    // MARK: - 보이기

    /// 오버레이 [설정], 앱 다시 열기: 보이고, 앞으로 가져오고, 새로 읽는다.
    func showAndActivate() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 업데이트 알림 (Windows SW_SHOWNOACTIVATE). 설정이 끝난 PC 에서 이 창은 숨겨져 있어서
    /// 띠가 여기에만 뜨면 아무도 못 본다. 초점은 빼앗지 않는다. 최소화된 창도 '보이는' 창이라
    /// 복원까지 해야 한다.
    func showWithoutActivating() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        refresh()
        window.orderFrontRegardless()
    }

    var isVisibleOrMiniaturized: Bool {
        return window.isVisible || window.isMiniaturized
    }

    // MARK: - SimpleRefresh

    /// 1초마다(숨어 있을 때도) 그리고 누를 때마다 전역 상태를 다시 읽는다.
    func refresh() {
        let c = ConfigStore.load()

        // 1. 내 폰
        let phone: String
        if !c.phoneToken.isEmpty {
            // 메일 주소는 로그인 응답에서 온 값이 config.ini 에 그대로 들어간 것이다. Windows 는
            // 192 칸 버퍼에 찍다가 넘치면 프로세스가 끝났다(켤 때도 불리므로 다시는 안 떴다).
            // Mac 은 죽지 않지만 같은 길이에서 자른다.
            if !c.authEmail.isEmpty {
                phone = "\(c.authEmail) 계정으로 등록됨"
            } else {
                phone = "등록됨 (토큰 \(Texts.tokenPrefix(c.phoneToken)))"
            }
        } else {
            phone = "아직 등록하지 않았어요"
        }
        setText(phoneLabel, TextSanitize.capUTF16(phone, 191))
        // 등록하기 전에 "바꾸기" 라고 쓰여 있으면 무엇을 누르라는 건지 알 수 없다
        setTitle(phoneButton, c.phoneToken.isEmpty ? "등록하기" : "바꾸기")

        // 2. 슬라이더는 지금 임계값에 가장 가까운 단계를 가리킨다. 고급 창에서 dBm 을 직접 고쳤을
        // 때도 엉뚱한 곳을 가리키지 않게. 위치만 옮기고 임계값을 다시 적용하지는 않는다.
        let base = Choices.distBase(measured: c.measuredBaseRssi)
        let step = Choices.distStep(base: base, threshold: Shared.shared.nearRssiThreshold)
        if slider.distStep != step { slider.distStep = step }
        shownDistStep = step

        // 3. 재본 적이 없으면 그렇다고 말해 준다. 3단계가 근거 없는 값이라는 뜻이다.
        setTitle(measureButton, c.measuredBaseRssi != 0 ? "내 자리에 맞게 다시 재기"
                                                        : "내 자리에 맞게 재보기  (아직 안 했어요)")

        // 4. 클립보드 공유 상태 한 줄. 서버를 타는 기능이라 "켜 뒀는데 안 넘어간다" 가 가능하고,
        // 그때 볼 것이 여기 말고는 events.log 뿐이다.
        let cs = ClipSync.status()
        let clipText: String
        if !cs.running {
            clipText = AccountSession.shared.hasAccount ? "꺼져 있어요" : "계정으로 로그인하면 쓸 수 있어요"
        } else if cs.lastMsg.isEmpty {
            clipText = "기다리는 중  ·  보냄 \(cs.sent) / 받음 \(cs.received)"
        } else {
            // lastMsg 에는 서버가 준 오류 문구가 그대로 실릴 수 있다 - Windows 의 256 칸에서 자른다.
            clipText = "\(cs.lastOk ? "" : "안 됨: ")\(cs.lastMsg)  ·  보냄 \(cs.sent) / 받음 \(cs.received)"
        }
        setText(clipLabel, TextSanitize.capUTF16(clipText, 255))

        // 5. 머리의 버전 단추와 아래 띠
        refreshUpdate()

        // 6. 타일들과 상태 카드. Windows 는 그릴 때 상태를 읽었다 - 여기서는 1초마다 같은 값을 넣는다.
        let monitoring = app.monitoring
        setTitle(guardTile, monitoring ? "보호 켜짐" : "보호 꺼짐")
        guardTile.tileStyle = monitoring ? .accent : .normal

        let clipOn = ClipSync.isRunning
        setTitle(clipTile, clipOn ? "클립보드 공유 켜짐" : "클립보드 공유 꺼짐")
        clipTile.tileStyle = clipOn ? .accent : .normal

        // 파란 타일은 둘뿐이다: 지금 고른 시간과, 이 화면의 주 동작. 전부 파랗게 하면 무엇이
        // 켜져 있는지가 안 보인다. 기본값 20초나 고급 창의 2분은 어느 단추와도 같지 않아서
        // 아무것도 파랗지 않다 (첫 [시작] 이 20 을 15 로 맞춘다).
        let idle = app.guardEngine.idleCountdownSec
        for (i, t) in idleTiles.enumerated() {
            let on = i < Choices.simpleIdle.count && idle == Choices.simpleIdle[i]
            t.tileStyle = on ? .accent : .normal
        }

        let card = Texts.simpleCard(monitoring: monitoring,
                                    black: app.guardEngine.blackActive,
                                    manual: app.guardEngine.manualLock,
                                    near: app.isNear)
        content.setCard(title: card.title, subtitle: card.subtitle, color: card.color)
    }

    /// 프로그램 업데이트. 머리의 버전 단추와, 필요할 때만 나타나는 아래 띠. 창은 띠가 보일 때만
    /// 100 만큼 자란다.
    private func refreshUpdate() {
        let us = Updater.status()
        let now = Mono.now()
        let ver = BuildInfo.version

        let header: String
        if !Updater.enabled {
            header = "버전 \(ver) · 자동 업데이트 꺼짐"
        } else if us.phase == .checking {
            header = "업데이트 확인 중…"
        } else if us.phase == .upToDate && (now &- us.checkedTick) < 6000 {
            // C 의 부호 없는 뺄셈처럼 감싼다 (Swift 의 - 는 넘치면 죽는다)
            header = "최신 버전이에요 · \(ver)"
        } else {
            header = "버전 \(ver) · 업데이트 확인"
        }
        setTitle(versionButton, header)

        var show = false
        var showApply = false
        var showLater = false
        var applyLabel = "업데이트"
        var text = ""

        // 글 칸이 세 줄(한글 약 78자)이다. 그 안에 들어갈 만큼만 - 넘치면 잘려 보이지도 않는다.
        // 메모는 첫 줄("새 버전 …") 뒤 두 줄. 기록에서 온 문구는 우리 것이라(영문이 섞여 짧게
        // 그려진다) 조금 길어도 되고, 서버 오류 문구는 앞에 "업데이트 실패: " 가 붙는다.
        // 길이는 UTF-16 단위로 센다 (Windows wstring 과 같은 곳에서 잘리게).
        var note = us.notes.components(separatedBy: CharacterSet(charactersIn: "\r\n")).first ?? ""
        if note.utf16.count > 48 { note = TextSanitize.capUTF16(note, 48) + "…" }
        var msg = us.msg
        let cap = us.fromMarker ? 96 : 68
        if msg.utf16.count > cap { msg = TextSanitize.capUTF16(msg, cap) + "…" }

        switch us.phase {
        case .available:
            show = !us.dismissed
            if us.autoApply {
                text = "관리자가 승인한 \(us.version) 를 받아요"
            } else {
                text = "새 버전 \(us.version) 이 있어요" + (note.isEmpty ? "" : "\n" + note)
                showApply = true
                showLater = true
            }
        case .pending:
            show = !us.dismissed
            showLater = true
            text = "새 버전 \(us.version) 이 있어요 · 관리자 승인을 기다려요"
        case .downloading:
            show = true
            text = "\(us.version) 내려받는 중 · \(us.progressPct)%"
        case .ready:
            show = true
            // 가리는 중, 재는 중, 로그인 중, 블루투스 등록 중에는 다시 시작하지 않는다 (UpdateTick 이
            // 1분마다 다시 본다). 조건은 AppController.updateTick 과 같아야 한다.
            let held = app.guardEngine.blackActive || app.guardEngine.measuring || app.loginBusy
                || app.bleRegisterBusy
            text = held ? "\(us.version) 준비됨 · 화면이 풀리면 적용해요"
                        : "\(us.version) 준비됨 · 곧 다시 시작해요"
        case .applying:
            show = true
            text = "다시 시작하는 중…"
        case .failed:
            show = !us.dismissed
            showApply = true
            showLater = true
            applyLabel = "다시 시도"
            // 기록에서 온 문구는 이미 "지난번 적용 실패: " 로 시작한다
            text = us.fromMarker ? msg : "업데이트 실패: \(msg)"
        default:
            // Idle / Checking / UpToDate: 띠 없음
            break
        }
        // Windows 의 384 칸 버퍼 (_TRUNCATE)
        text = TextSanitize.capUTF16(text, 383)

        setText(bandLabel, show ? text : "")
        if bandLabel.isHidden == show { bandLabel.isHidden = !show }
        // 글이 같으면 다시 넣지 않는다 - 매초 다시 그리지 않게
        setTitle(applyButton, applyLabel)
        let applyVisible = show && showApply
        if applyButton.isHidden == applyVisible { applyButton.isHidden = !applyVisible }
        let laterVisible = show && showLater
        if laterButton.isHidden == laterVisible { laterButton.isHidden = !laterVisible }

        // 최소화된 창의 크기는 만지지 않는다 - 복원될 때 이상한 크기가 된다.
        if !window.isMiniaturized {
            setContentHeight(L.contentH + (show ? L.bandH : 0))
        }
    }

    /// 위쪽 끝을 그대로 두고 안쪽 높이만 바꾼다 (SetWindowPos SWP_NOMOVE | SWP_NOACTIVATE).
    /// 내용 보기는 뒤집혀 있어서, 자라도 위에서부터 잰 자리가 그대로다.
    private func setContentHeight(_ h: CGFloat) {
        let cur = window.contentRect(forFrameRect: window.frame)
        if abs(cur.height - h) < 0.5 { return }
        let want = NSRect(x: cur.minX, y: cur.maxY - h, width: cur.width, height: h)
        window.setFrame(window.frameRect(forContentRect: want), display: true)
    }

    private func setText(_ f: NSTextField, _ s: String) {
        if f.stringValue != s { f.stringValue = s }
    }

    private func setTitle(_ b: NSButton, _ s: String) {
        if b.title != s { b.title = s }
    }

    // MARK: - 누른 것 (WM_COMMAND / WM_HSCROLL)

    @objc private func onVersion(_ sender: Any?) {
        // 꺼져 있으면 단추 글이 이미 그렇게 말한다
        if Updater.enabled { app.updateCheckManual() }
        refresh()
    }

    @objc private func onAdvanced(_ sender: Any?) {
        app.showAdvanced()
    }

    @objc private func onGuard(_ sender: Any?) {
        app.toggleGuard()
        refresh()
    }

    @objc private func onPhone(_ sender: Any?) {
        app.registerPhone()
        refresh()
    }

    @objc private func onDist(_ sender: Any?) {
        // 고급 창의 "신호 강도" 칸도 AppController 가 같은 값으로 맞춘다. 그 칸은 [시작] 때 다시
        // 읽히므로, 안 맞추면 슬라이더로 바꾼 값이 다음 [시작] 에 예전 숫자로 되돌아간다.
        let step = slider.distStep
        if step == shownDistStep { return }
        shownDistStep = step
        app.simpleApplyDist(step)
    }

    @objc private func onMeasure(_ sender: Any?) {
        app.openWizard()
    }

    @objc private func onIdle(_ sender: Any?) {
        guard let b = sender as? NSButton else { return }
        let i = b.tag
        if i < 0 || i >= Choices.simpleIdle.count { return }
        app.simpleSetIdle(i)
        // Windows 는 여기서 다시 읽지 않아 다른 시간 단추가 1초 늦게 꺼졌다. 바로 맞춘다.
        refresh()
    }

    @objc private func onImage(_ sender: Any?) {
        app.pickCenterImage()
    }

    @objc private func onLockNow(_ sender: Any?) {
        app.lockNow()
    }

    @objc private func onClip(_ sender: Any?) {
        app.toggleClip()
        refresh()
    }

    @objc private func onApply(_ sender: Any?) {
        // 실패한 뒤 후보가 없으면 다시 묻는 것부터, 있으면 다시 받는다 - AppController 가 가른다.
        app.updateApplyOrRetry()
        refresh()
    }

    @objc private func onLater(_ sender: Any?) {
        app.updateLater()
        refresh()
    }
}

// 창 위임은 확장에 둔다. 주 선언에 NSWindowDelegate 를 적으면 Swift 5 모드에서 클래스 전체가
// @MainActor 로 추론되어, 타이머·GCD 에서 부르는 refresh() 가 격리 위반이 될 수 있다.
extension SimpleWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 숨기기만 한다 - 오버레이의 [설정] 으로 다시 열 수 있다. 정상 종료는 오버레이 [종료] 뿐이다.
        sender.orderOut(nil)
        return false
    }
}

/// 창 바탕과 상태 카드 (Windows SimpleProc WM_ERASEBKGND + WM_PAINT).
private final class SimpleContentView: NSView {
    private var cardTitle = ""
    private var cardSubtitle = ""
    private var cardColor = RGB(120, 120, 120)

    override var isFlipped: Bool { return true }

    func setCard(title: String, subtitle: String, color: RGB) {
        if title == cardTitle && subtitle == cardSubtitle && color == cardColor { return }
        cardTitle = title
        cardSubtitle = subtitle
        cardColor = color
        setNeedsDisplay(NSRect(x: 22, y: 58, width: 368, height: 78))
    }

    override func draw(_ dirtyRect: NSRect) {
        SSColors.panelBg.setFill()
        NSBezierPath.fill(dirtyRect)

        // 카드: {22, 58, 390, 136}, 모서리 타원 16 = 반지름 8. 테두리도 같은 색이다.
        let card = NSRect(x: 22, y: 58, width: 368, height: 78)
        if !card.intersects(dirtyRect) { return }
        SSColors.from(cardColor).setFill()
        NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
        // 첫 줄 {40, 72, 372, 106}: 큰 글꼴, 흰색, 한 줄
        SSDraw.text(cardTitle, in: NSRect(x: 40, y: 72, width: 332, height: 34),
                    font: SSFonts.big, color: NSColor.white, wrap: false)
        // 둘째 줄 {40, 106, 372, 128}: 보통 글꼴, 흰색, 줄바꿈. 남은 초는 보여주지 않는다.
        SSDraw.text(cardSubtitle, in: NSRect(x: 40, y: 106, width: 332, height: 22),
                    font: SSFonts.normal, color: NSColor.white, wrap: true)
    }
}
