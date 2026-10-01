import AppKit
import UniformTypeIdentifiers
import SmartScreenCore

// AppController.swift - 앱의 심장. Windows client/main.cpp 의 고급 창(SmartScreenBT) WM_CREATE +
// WndProc 가 하던 일을 창과 떼어 옮겼다.
//
// Windows 는 이 일들이 전부 고급 창에 들어 있어서, 그 창을 숨긴 채로라도 만들지 않으면 프로그램이
// 뜨지 않는 것과 같았다 ("자동 시작이나 기업 콘텐츠 동기화 같은 일이 전부 그 창의 WM_CREATE 에
// 들어 있어서, 안 만들면 프로그램이 뜨지 않는 것과 같다"). Mac 은 창과 상관없는 이 컨트롤러가
// 맡고, 두 설정 창과 오버레이는 여기의 명령을 부르기만 한다 ("폰 등록이나 그림 고르기를 여기서
// 다시 구현하면 두 벌이 되고, 한쪽만 고쳐지는 날이 온다").
//
// 맡는 것:
//   - 고급 창 칸들의 모델 (신호 강도 칸, 유휴/지연 콤보, 기기 목록, 그림 경로). 두 창이 같은 값을
//     본다 - [시작] 은 이 모델을 다시 읽으므로, 간단 창이 바꾼 값도 여기에 들어와 있어야 한다
//     ("재시작하면 바뀌어 있다").
//   - StartMon / StopMon, 판정 결과(OnResult), 1 초 틱, 입력, 잠금 창 띄우기/내리기 (GuardEngine 의 host)
//   - 시작 순서, 계정 세션과 회전한 토큰 저장(FlushAuthSave), 구글 로그인 일꾼, BLE 직접 등록
//   - 기업 콘텐츠 동기화(시작할 때), 업데이트 틱, 클립보드 타일, 정상 종료
//
// 스레드: 전부 메인 스레드. 일꾼(로그인, 세션 시작, 기업 동기화)은 결과만 DispatchQueue.main.async
// 로 넘긴다 (Windows 의 PostMessage). 판정 스레드는 MainLoop.perform 으로 넘긴다 (알림이 떠 있어도
// 결과가 닿아야 한다). config.ini 쓰기도 메인에서만 한다 - SaveAppConfig 는 파일 전체를 다시 쓰므로
// 두 스레드가 쓰면 서로의 변경을 덮는다.
//
// 알림(NSAlert.runModal)은 DispatchQueue.main.async 블록 안에서 띄우지 않는다. 그 블록이 끝날 때까지
// main 큐가 다시 비워지지 않아 세션 회전 저장, 업데이트 알림 같은 뒤이은 블록이 알림이 닫힐 때까지
// 기다린다. 그런 결과에서 알림을 띄울 수 있으면 MainTimer.once(after: 0) 로 한 번 넘겨서 부른다
// (Alerts.swift 머리말).
//
// Windows 와 일부러 다르게 한 것 (Q4·Q5·Q6 은 Windows 도 다음 릴리스부터 같게 고쳤다 - 아래 "Windows 는" 은 1.1.7 까지):
//   - 판정 결과마다 세션 번호를 싣고, [중지] 뒤에 도착한 결과나 지난 세션의 결과는 버린다 (Q6).
//     Windows 에서는 [중지] 직전에 보낸 결과가 "정지됨" 을 덮어쓰고 FAR 전환이면 화면을 잠글 수도 있었다.
//   - [중지] 때 오버레이를 새로 그린다 (Q4). Windows 는 마지막 상태("근처 • 보호 중")가 남았다.
//   - 고른 그림을 바로 저장한다 (Q5). Windows 는 다음 [시작] 때에야 저장해서, 감시 중에 고르고
//     [종료] 하면 다음 실행의 자동 시작이 예전 경로를 다시 저장했다.
//   - [시작] 은 이미 감시 중이면 아무것도 하지 않는다. Windows 는 로그인 결과의 PopulateCombo 가
//     [시작] 을 다시 켜서, 누르면 감시가 두 벌 돌 수 있었다.
//   - BLE 직접 등록과 세션 복원은 메인을 막지 않고 비동기로 돈다 (Windows 는 6 초 넘게 UI 가 멎었다).

final class AppController: NSObject, GuardEngineHost {
    static var shared: AppController!

    let guardEngine = GuardEngine()

    // MARK: - 고급 창 칸들의 모델 (두 창이 함께 고친다)

    /// "신호 강도" 칸. [시작] 이 _wtoi 로 다시 읽는다.
    var thresholdFieldText = "-65"
    /// Choices.idleValues 의 칸 번호 (기본 2 = 30초)
    var idleComboIndex = Choices.idleDefaultIndex
    /// Choices.delayValues 의 칸 번호 (기본 0 = 즉시)
    var delayComboIndex = 0
    var deviceEntries: [String] = [AppController.noPhoneEntry]
    var hasPhoneEntry = false
    var centerImagePath = ""
    var bannerImagePath = ""

    // MARK: - 실행 상태

    private(set) var monitoring = false
    /// g_targetName. 등록된 폰이면 "등록된 폰" (표시 전용, 광고 이름과 맞춰 보지 않는다)
    private(set) var targetName = ""
    /// g_hasToken: [시작] 과 로그인 결과가 정한다. 상태바 "ID:" 에 쓴다.
    private(set) var hasToken = false
    private(set) var loginBusy = false
    private(set) var lastResult: ProbeResult?
    private(set) var stateLabelText = Texts.stateLabelStopped
    private(set) var countdownLabelText = ""
    private(set) var statusText = Texts.statusInitial
    /// 목록 행, 새것이 앞. 최대 500.
    private(set) var listRows: [[String]] = []
    /// 판정 스레드의 지금 상태 (g_proxState). 결과의 state 보다 한 샘플 새로울 수 있다.
    var isNear: Bool { return Shared.shared.proxState == .near }
    private(set) var overlay: OverlayPanel?
    private(set) var simple: SimpleWindowController!
    private(set) var advanced: AdvancedWindowController!
    /// 정상 종료가 시작됐다. applicationShouldTerminate 가 이것을 보고 다시 종료 절차를 돌리지 않는다.
    private(set) var isExiting = false

    // MARK: - 상수

    /// 토큰이 없을 때 기기 목록의 유일한 항목 (Mac 에는 페어링된 기기 목록이 없다)
    private static let noPhoneEntry = "(등록된 폰 없음)"
    /// [시작] 이 늘 같은 값으로 고정하는 것들 (Windows StartMon)
    private static let fixedNearLatencyMs: UInt32 = 200
    private static let fixedKeepAliveSec: UInt32 = 5
    private static let fixedScanIntervalSec: UInt32 = 2
    private static let listCap = 500
    /// 백그라운드 업데이트 확인 간격 (kUpdateEveryMs)
    private static let updateEveryMs: UInt64 = 60 * 60 * 1000
    private static let registerScanSec = 6
    private static let loginTimeoutSec = 180
    private static let registerTitle = "폰 등록"
    /// [폰 등록] 의 첫 질문. 둘째 줄들의 들여쓰기는 7 칸 (Windows 원문 그대로).
    private static let registerQuestion =
        "어떻게 등록할까요?\n\n[예]  구글 계정으로 등록  (권장)\n       아이폰 앱에서도 같은 계정으로 로그인하면 끝납니다.\n       폰을 가까이 둘 필요도, 앱을 띄울 필요도 없습니다.\n\n[아니오]  블루투스로 직접 등록\n       앱을 화면에 띄우고 폰을 PC 가까이 두세요.\n       인터넷 없이 됩니다."
    /// 등록이 이미 하나 도는 중일 때의 답. 두 방법이 나란히 돌면 나중에 끝난 쪽이 먼저 저장한 토큰을
    /// 덮는다 (registerPhone).
    private static let registerBleBusyText = "블루투스 등록이 진행 중입니다. 잠시 기다려 주세요."
    private static let registerLoginBusyText = "이미 로그인 중입니다.\n브라우저 창을 확인하세요."
    private static let clipTitle = "클립보드 공유"
    /// 계정 값 다시 쓰기 간격: 30 초에서 두 배씩, 10 분까지
    private static let authSaveFirstWaitSec: Double = 30
    private static let authSaveMaxWaitSec: Double = 600

    // MARK: - 내부 상태

    private var launched = false
    private var exitSequenceDone = false
    private var judge: JudgeThread?
    /// [시작] 마다 하나씩 늘린다. 결과에 실려 와서 낡은 결과를 가른다.
    private var session = 0
    private var inputWatcher: InputWatcher?
    private var countdownTimer: Timer?
    private var simpleTimer: Timer?
    private var updateTimer: Timer?
    private var authSaveTimer: Timer?
    /// 감시 중에 잡아 두는 App Nap 방지. 창이 다 숨어 있으면 macOS 가 1 초 틱, 100 ms 입력 폴링,
    /// 판정 스레드를 늦출 수 있고 그러면 잠금과 해제가 늦는다.
    private var activity: NSObjectProtocol?
    /// 오버레이에 마지막으로 넘긴 두 줄과 색. 입력은 셋째 줄만 지운다 (Windows 는 다시 그리기만 했다).
    private var lastOverlay: (line1: String, line2: String, color: RGB)?
    /// BLE 직접 등록이 도는 중 (6 초 스캔 + 토큰 읽기). 간단 창의 업데이트 띠도 읽는다.
    private(set) var bleRegisterBusy = false
    /// 블루투스 권한이 없다는 알림을 이번 실행에서 이미 보였다 ([시작] 마다 띄우지 않는다)
    private var bluetoothDeniedShown = false
    /// 등록이 도는 동안 눌린 [시작]. Windows 는 그동안 UI 스레드가 막혀 있어서 클릭이 등록 뒤에
    /// 처리됐다 - 같은 순서로 등록이 끝난 다음에 시작한다.
    private var startAfterRegister = false
    /// 로그인 결과의 이메일 (등록 완료 상자에 쓴다)
    private var lastLoginEmail = ""
    /// 잠자기 / 화면 꺼짐 알림의 구독 (observePowerEvents). 앱이 사는 동안 쥔다.
    private var powerObservers: [NSObjectProtocol] = []

    // 업데이트 (UpdateTick)
    private var updLastCheck: UInt64 = 0
    /// 띠를 보이려고 간단 창을 띄운 버전 ("1.1.8|A" / "1.1.8|F"). 버전마다 한 번만 띄운다.
    private var updShownFor = ""
    private var inUpdateTick = false

    // 계정 값 저장 (Windows g_authSave). 회전한 refresh 토큰과 로그인 결과는 "썼다" 를 확인해야
    // 하는 값이다. 못 쓰면 지금 실행은 멀쩡하다가 다음 실행에서 로그인이 풀린다.
    private struct AuthSave {
        var pending = false      // 아래에 아직 못 쓴 것이 있다
        var refresh = ""         // 봉한 refresh 토큰. 빈 값이면 authRefresh 를 덮지 않는다
        var login = false        // 로그인 결과도 같이 쓴다 (아래 셋)
        var userId = ""
        var email = ""
        var phoneToken = ""
        var tries = 0            // 연달아 실패한 횟수 (다시 쓰는 간격을 벌린다)
    }
    private var authSave = AuthSave()

    /// 세션 층이 (아무 스레드에서) 알려 준 회전한 refresh 토큰. 최신 것이 이긴다.
    private let rotatedLock = NSLock()
    private var rotatedSealed = ""

    /// 로그인 일꾼의 결과 (Windows LoginResult)
    private struct LoginResult {
        var ok = false
        var err = ""
        var email = ""
        var userId = ""
        var refresh = ""
        var phoneToken = ""
    }

    override init() {
        super.init()
    }

    // MARK: - 시작

    /// AppDelegate.applicationDidFinishLaunching 이 부른다. Windows wWinMain 의 2~11 단계와
    /// 고급 창 WM_CREATE 를 합친 것.
    func launch() {
        if launched { return }
        launched = true

        // 로그를 읽을 때 이 줄로 실행을 가른다. Mac 은 세션 복원이 백그라운드에서 끝나므로 그 결과
        // 줄보다 먼저, 이 실행의 첫 줄로 남긴다.
        EventLog.write("start: SmartScreen \(BuildInfo.version)")
        observePowerEvents()
        Updater.cleanupAfterStart()
        // 창이 하나도 안 보이는 앱이라 자동 종료 대상이 되면 안 된다 (화면을 지키는 프로그램이다)
        ProcessInfo.processInfo.disableAutomaticTermination("SmartScreen guards the screen")

        guardEngine.host = self
        guardEngine.liveState = {
            return (state: Shared.shared.proxState, lastNearTick: Shared.shared.lastNearTick)
        }
        LockScreen.shared.onRelease = { [weak self] in self?.releaseLock() }
        inputWatcher = InputWatcher(onInput: { [weak self] tick in self?.onInput(eventTick: tick) })

        // ---- 고급 창 WM_CREATE: config 를 전역값과 칸들에 싣는다 (읽힌 경우에만) ----
        let cfg = ConfigStore.load()
        if cfg.loaded { applyConfigToModel(cfg) }
        populateDevices()

        // 고급 창은 만들어 두되 띄우지 않는다. 간단 창의 [고급 설정] 으로만 연다.
        advanced = AdvancedWindowController(app: self)

        // 기업 콘텐츠 동기화는 일꾼에서. 예전에는 창을 만드는 중에 UI 스레드에서 돌아서, 서버가
        // 느리거나 닿지 않으면 앱이 안 뜬 것처럼 보였고 자동 시작도 그만큼 밀렸다. 결과가 올
        // 때까지는 config 에 저장돼 있던 경로로 잠근다.
        startEnterpriseSync(cfg)

        // 오버레이: 설정 여부와 상관없이 처음부터 보인다. 트레이가 없으므로 앱으로 돌아오는 길이다.
        let ovl = OverlayPanel(onExit: { [weak self] in self?.normalExit() },
                               onLock: { [weak self] in self?.lockNow() },
                               onSettings: { [weak self] in self?.overlaySettings() })
        ovl.show()
        overlay = ovl

        simple = SimpleWindowController(app: self)

        // 설정이 없으면 창을 띄워 안내하고, 있으면 조용히 시작한다.
        // 등록된 폰을 쓰면 btAddress 는 0 이므로 토큰 쪽도 같이 본다.
        let configured = cfg.loaded && (cfg.btAddress != 0 || !cfg.phoneToken.isEmpty)

        // ---- 계정 세션과 클립보드 동기화 ----
        startSession(cfg)

        // ---- 프로그램 업데이트 ----
        // 조직 id 는 여기서 한 번만 넘긴다. 그래서 기업 등록 창이 "다시 켠 뒤부터" 라고 말한다.
        if cfg.updateCheck {
            Updater.initialize(url: ServerDefaults.url(cfg), key: ServerDefaults.key(cfg),
                               org: cfg.enterpriseRegistered ? cfg.orgId : "",
                               channel: cfg.updateChannel,
                               notify: { [weak self] in self?.updateTick(fromNotify: true) })
            updLastCheck = Mono.now()
            Updater.checkAsync(manual: false)
            updateTimer = MainTimer.every(60) { [weak self] in self?.updateTick(fromNotify: false) }
        } else {
            EventLog.write("update: checks disabled (updateCheck=0)")
        }

        if !configured { simple.showAndActivate() }
        simple.refresh()
        // 간단 창은 숨어 있어도 1 초마다 전역 상태로 자기를 다시 그린다 (IDT_SIMPLE)
        simpleTimer = MainTimer.every(1.0) { [weak self] in self?.simple?.refresh() }

        // 자동 시작: 토큰이 있으면 "등록된 폰" 이 0 번이고 그것으로 시작한다. Windows 처럼 바로
        // 부르지 않고 큐에 넣는다 - 위의 일이 다 끝난 뒤에 START 가 찍힌다.
        // (Mac 에는 페어링된 Classic 기기 목록이 없으므로 btAddress 로 고르는 갈래는 없다.)
        if hasPhoneEntry {
            DispatchQueue.main.async { [weak self] in self?.startMon() }
        }
    }

    /// 잠자기와 화면 꺼짐을 events.log 에 남긴다 ("SLEEP" / "WAKE" / "DISPLAY OFF" / "DISPLAY ON").
    /// 행동은 바꾸지 않는다 (잠자기를 막는 전원 assertion 도 잡지 않는다) - 기록만 한다.
    ///
    /// 왜: 맥북은 배터리로 쓰면 2분쯤 뒤 화면을 끄고 곧 잠든다 (전원을 꽂으면 10분). 그 뒤에는 이 앱도
    /// 멎어 있어서 돌아와도 아무것도 풀 수 없고, macOS 가 Touch ID / 암호를 묻는다 - 정상인데 사용자는
    /// "안 풀렸다" 고 알려 온다. 이 줄들이 있으면 events.log 만 보고 "그때 Mac 이 자고 있었다 / 화면이
    /// 꺼져 있었다" 를 가를 수 있다. NSWorkspace 의 알림은 메인으로 온다 (queue: .main).
    private func observePowerEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        let lines: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "SLEEP"),
            (NSWorkspace.didWakeNotification, "WAKE"),
            (NSWorkspace.screensDidSleepNotification, "DISPLAY OFF"),
            (NSWorkspace.screensDidWakeNotification, "DISPLAY ON"),
        ]
        for (name, line) in lines {
            powerObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                EventLog.write(line)
            })
        }
    }

    /// WM_CREATE 의 "Load config and apply to UI". gattRssiThreshold 는 여기서 읽지 않는다 -
    /// [시작] 이 신호 강도 칸의 값 + gattRssiOffset 으로 맞춘다 (config 의 값은 사본일 뿐이다).
    private func applyConfigToModel(_ cfg: AppConfig) {
        Shared.shared.nearRssiThreshold = cfg.nearRssiThreshold
        Shared.shared.keepAliveSec = cfg.keepAliveSec
        guardEngine.keepAliveSec = Int(cfg.keepAliveSec)
        guardEngine.setIdle(cfg.idleCountdownSec)
        guardEngine.unlockDelaySec = cfg.unlockDelaySec
        centerImagePath = cfg.centerImagePath
        bannerImagePath = cfg.bannerImagePath
        thresholdFieldText = "\(cfg.nearRssiThreshold)"
        // 가장 가까운 칸 (같으면 앞 칸). config 기본값 20 초는 15초 칸이 된다.
        delayComboIndex = Texts.comboFindValue(Choices.delayValues, cfg.unlockDelaySec)
        idleComboIndex = Texts.comboFindValue(Choices.idleValues, cfg.idleCountdownSec)
    }

    /// PopulateCombo. 목록은 원래 "페어링된 기기" 였다. 등록된 폰은 페어링할 필요가 없는 것이
    /// 요점이라 그 목록에 없고, 그대로 두면 엉뚱한 페어링 기기(헤드폰)가 대상으로 잡혔다. Mac 은
    /// 페어링된 기기 목록이 아예 없으므로 등록된 폰 하나뿐이고, 없으면 [시작] 이 꺼진다.
    private func populateDevices() {
        let cfg = ConfigStore.load()
        if !cfg.phoneToken.isEmpty {
            deviceEntries = [Texts.phoneEntry(token: cfg.phoneToken)]
            hasPhoneEntry = true
        } else {
            deviceEntries = [AppController.noPhoneEntry]
            hasPhoneEntry = false
        }
        advanced?.syncFromModel()
    }

    // MARK: - 계정 세션

    private func startSession(_ cfg: AppConfig) {
        let url = ServerDefaults.url(cfg)
        let key = ServerDefaults.key(cfg)
        let sealed = cfg.authRefresh
        let wantClip = cfg.clipSync
        let clipMax = Int(cfg.clipMaxKB) * 1024
        // 회전 콜백을 시작보다 먼저 건다. 시작 자체가 refresh 를 하므로 토큰이 바로 회전한다 -
        // 콜백이 없으면 새 refresh 토큰이 저장되지 않고 다음 실행에서 로그인이 풀린다.
        AccountSession.shared.onRotated { [weak self] sealedToken in
            self?.sessionRotated(sealedToken)
        }
        // 네트워크를 타서 실패하면 몇 초가 걸린다. Windows 는 창을 띄운 뒤 UI 스레드에서 기다렸다.
        // Mac 은 기다리지 않는다 - 자리비움 감지는 계정과 무관하게 돌아간다.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = AccountSession.shared.start(url: url, key: key, sealed: sealed)
            let email = AccountSession.shared.email
            DispatchQueue.main.async {
                self?.sessionStarted(ok: r.ok, err: r.err, email: email, wantClip: wantClip,
                                     url: url, key: key, clipMax: clipMax)
            }
        }
    }

    private func sessionStarted(ok: Bool, err: String, email: String, wantClip: Bool,
                                url: String, key: String, clipMax: Int) {
        if ok {
            EventLog.write("session: restored (\(email))")
        } else if !err.isEmpty {
            // 로그인한 적은 있는데 되살리지 못했다. 앱을 막을 일은 아니다.
            EventLog.write("session: restore failed - \(err)")
        } else {
            EventLog.write("session: no account yet")
        }
        if isExiting { return }
        // 클립보드 동기화는 "세션을 되살렸는가" 가 아니라 "계정이 있는가" 로 켠다. 켜는 순간
        // 네트워크가 잠깐 없으면 그 실행 내내 꺼진 채였고 타일은 오류도 없이 "꺼져 있어요" 였다.
        // 일꾼은 세션이 없으면 30 초마다 다시 물으므로 띄워 두기만 하면 된다. 다른 PC 의 config 를
        // 복사해 와 봉인이 안 풀리는 경우는 계정이 없는 것으로 남으므로 켜지 않는다.
        if wantClip && AccountSession.shared.hasAccount && !ClipSync.isRunning {
            _ = ClipSync.start(url: url, key: key, maxBytes: clipMax)
        }
        simple?.refresh()
    }

    /// OnSessionRotated: 아무 스레드에서나 온다. 값만 맡겨 두고 메인에서 쓴다.
    private func sessionRotated(_ sealed: String) {
        rotatedLock.lock()
        rotatedSealed = sealed
        rotatedLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onSessionRotatedMain() }
    }

    /// WM_SESSION_ROTATED. Supabase 는 refresh 할 때마다 예전 토큰을 무효로 만든다. 새 값을
    /// 저장하지 않으면 다음 실행이 로그아웃된다 (증상은 하루 뒤에 나타난다).
    private func onSessionRotatedMain() {
        rotatedLock.lock()
        let sealed = rotatedSealed
        rotatedSealed = ""
        rotatedLock.unlock()
        if sealed.isEmpty { return }
        // 아직 못 쓴 로그인 결과가 있으면 같이 나간다 (다른 칸은 그대로 둔다)
        authSave.refresh = sealed
        authSave.pending = true
        // 예전에는 결과를 보지 않고 "rotated, saved" 라고 적었다. 못 썼는데도 로그는 매번 성공이었다.
        if flushAuthSave() {
            EventLog.write("session: refresh token rotated, saved")
        } else {
            EventLog.write("session: refresh token rotated but NOT saved - will retry "
                           + "(if the app exits first, the next start may need a new login)")
        }
    }

    /// FlushAuthSave (메인 전용). 썼으면 true. 못 썼으면 다시 쓰는 타이머를 건다.
    private func flushAuthSave() -> Bool {
        if !authSave.pending { return true }
        // 파일이 없는 것은 괜찮다 - 처음 로그인하는 Mac 이다. "있는데 못 읽었다" 면 save 가
        // 거절하고, 그러면 아래에서 다시 건다.
        var c = ConfigStore.load()
        if authSave.login {
            // 서버 주소/키는 여기서 적지 않는다. 한 번 적힌 기본값은 실행 파일의 기본값이 바뀌어도
            // 그 PC 에 남는다.
            //
            // 봉인이 실패해 새 토큰이 없을 때: 저장돼 있던 토큰을 빈 값으로 덮지 않는다 - 같은
            // 계정이면 아직 살아 있을 수 있다. 다른 계정의 것이면 지운다. 남겨 두면 다음 실행에서
            // 화면은 새 계정인데 세션은 예전 계정이 된다.
            if authSave.refresh.isEmpty && c.authUserId != authSave.userId {
                c.authRefresh = ""
            }
            c.authUserId = authSave.userId
            c.authEmail = authSave.email
            if !authSave.phoneToken.isEmpty {
                c.phoneToken = authSave.phoneToken
                c.phoneOvfBit = -1   // 비트는 잠긴 폰을 처음 탐색할 때 배운다 (직접 읽기 스캔이 읽는다)
            }
        }
        if !authSave.refresh.isEmpty { c.authRefresh = authSave.refresh }

        if ConfigStore.save(c) {
            authSave = AuthSave()
            authSaveTimer?.invalidate()
            authSaveTimer = nil
            return true
        }
        // 30 초, 1 분, 2 분 ... 10 분. 파일이 계속 안 써지는 Mac 에서 로그가 이것으로 차지 않게
        // 벌린다. 실패 사유는 ConfigStore.save 가 적는다.
        var wait = AppController.authSaveFirstWaitSec
        var i = 0
        while i < authSave.tries && wait < AppController.authSaveMaxWaitSec {
            wait *= 2
            i += 1
        }
        if wait > AppController.authSaveMaxWaitSec { wait = AppController.authSaveMaxWaitSec }
        authSave.tries += 1
        authSaveTimer?.invalidate()
        authSaveTimer = MainTimer.every(wait) { [weak self] in self?.authSaveTimerFired() }
        return false
    }

    /// IDT_AUTHSAVE
    private func authSaveTimerFired() {
        if !authSave.pending {
            authSaveTimer?.invalidate()
            authSaveTimer = nil
            return
        }
        if flushAuthSave() {
            EventLog.write("session: account values saved on retry")
        }
    }

    // MARK: - 감시 시작 / 중지

    /// [시작] (StartMon). 순서가 중요하다: GATT 서버를 스캐너보다 먼저, SetIdentity 를 스캐너 시작보다
    /// 먼저, lastInputTick 은 GATT 서버의 틱보다 먼저 찍는다.
    func startMon() {
        if monitoring || isExiting { return }
        if bleRegisterBusy {
            startAfterRegister = true
            return
        }
        // 고를 것이 없으면 조용히 아무것도 안 한다 (Windows: 콤보가 비었을 때와 같다)
        guard hasPhoneEntry else { return }

        // 신호 강도 칸: _wtoi, 양수면 음수로, [-100, -30] 으로 자른다 (빈 칸/엉뚱한 글자는 -30).
        // 연결(GATT) 경로는 이 숫자를 따라간다: 이 숫자 + 재보기가 잰 차이(gattRssiOffset), [-100, -30].
        // 처음에는 "폰이 잰 값이라 눈금이 다르다" 고 따로 뒀다가, 따로 두었더니 광고 -67 / 연결 -61 로
        // 갈라진 채 앉은 자리에서 잠겨서 (2026-10-01) 1.1.6 부터 같은 값을 썼다. Windows 노트북에서는
        // 두 경로가 2 dB 안에서 같이 움직였지만 M1 맥북에서는 연결이 광고보다 12~15 dB 낮았다 - 그래서
        // 숫자는 하나로 두고 차이는 재보기가 잰다. 차이를 재지 않은 config (예전 파일 포함) 는 0 이라
        // 두 경로가 예전처럼 같은 값을 쓴다.
        let thr = Texts.parseThresholdField(thresholdFieldText)
        var cfg = ConfigStore.load()
        let gattThr = Choices.gattThreshold(near: thr, offset: cfg.gattRssiOffset)
        Shared.shared.nearRssiThreshold = thr
        Shared.shared.gattRssiThreshold = gattThr
        thresholdFieldText = "\(thr)"

        // 자리비움 콤보는 없앴다 (조작해도 아무 일이 안 일어나는 설정은 없는 것보다 나쁘다) → 늘 5 초
        let keepAlive = AppController.fixedKeepAliveSec
        Shared.shared.keepAliveSec = keepAlive
        guardEngine.keepAliveSec = Int(keepAlive)

        var idleIdx = idleComboIndex
        if idleIdx < 0 || idleIdx >= Choices.idleValues.count { idleIdx = Choices.idleDefaultIndex }   // 30초
        guardEngine.setIdle(Choices.idleValues[idleIdx])
        var delayIdx = delayComboIndex
        if delayIdx < 0 || delayIdx >= Choices.delayValues.count { delayIdx = 0 }
        guardEngine.unlockDelaySec = Choices.delayValues[delayIdx]

        // 신원은 토큰으로만 확인한다. 주소나 이름으로도 맞추게 두면 이름이 겹치는 남의 기기 광고가
        // 같은 칼만 필터에 섞여 들어온다. 이름은 표시용이다.
        targetName = Choices.registeredPhoneName

        // cfg 는 위 임계값 자리에서 읽었다.
        // Mac 은 IRK 를 쓸 수 없다 (CoreBluetooth 는 주소도 본딩 키도 내주지 않는다): irk.txt 를
        // 가져오지 않고, bleIrk 는 config 에 그대로 둔 채 irk=0 으로 적는다.
        Shared.shared.bleLostMeansFar = cfg.bleLostMeansFar
        let idle = guardEngine.idleCountdownSec
        let delay = guardEngine.unlockDelaySec
        EventLog.write("START thr=\(thr) dBm keepAlive=\(keepAlive)s idle=\(idle)s unlockDelay=\(delay)s "
                       + "bleTimeout=\(cfg.bleTimeoutSec)s lostMeansFar=\(cfg.bleLostMeansFar ? 1 : 0) irk=0")
        EventLog.write("ident: token=\(cfg.phoneToken.isEmpty ? 0 : 1) ovfBit=\(cfg.phoneOvfBit)")

        Shared.shared.gattSeen = cfg.gattSeen
        Shared.shared.gattGraceSec = cfg.gattGraceSec
        // [시작] 도 입력으로 친다: 시작 직후 5 초는 아무것도 자동으로 잠그지 않는다.
        let now = Mono.now()
        Shared.shared.monStartTick = now
        Shared.shared.lastInputTick = now

        if cfg.bleGattServer {
            // 진단 로그는 bleDebugLog 를 따른다. 예전에는 경로를 조건 없이 넘겨서 광고 로그만 꺼지고
            // 이쪽은 계속 자랐다 - 끈 줄 알고 둔 채로.
            let gattLog: String? = cfg.bleDebugLog
                ? Paths.configDir.appendingPathComponent("gatt_rssi_log.csv", isDirectory: false).path
                : nil
            let ok = GattServer.shared.start(plain: !cfg.bleGattEncrypt, logPath: gattLog)
            // 연결 경로의 임계값을 적는다 (Windows 는 g_gattRssiThreshold). 차이가 0 이면 위 START 의 thr 와 같다.
            EventLog.write("GATT server start: \(ok ? "OK" : "FAILED") "
                           + "(encrypt=\(cfg.bleGattEncrypt ? 1 : 0), thr=\(gattThr) dBm)")
        } else {
            EventLog.write("GATT server disabled by config")
        }
        // 광고 스캔은 늘 켠다. 라디오를 나눠 쓰는 게 걱정되어 껐던 적이 있는데, 그 뒤로 어떤 USB
        // 동글에서는 광고 자체가 폰에 잡히지 않았다.
        EventLog.write("v1 advertisement scan: on")

        // 연결해서 신원을 확인하는 경로. 탐색 하한은 임계값보다 10 dB 낮게 - 그보다 멀면 어차피
        // 자리 판정에 쓸 수 없어 남의 폰에 연결을 시도할 이유가 없다.
        hasToken = !cfg.phoneToken.isEmpty
        AdvScanner.shared.setIdentity(tokenHex: cfg.phoneToken, ovfBit: cfg.phoneOvfBit, probeFloor: thr - 10)
        AdvScanner.shared.setTimeoutSec(cfg.bleTimeoutSec)
        AdvScanner.shared.setDebugLog(path: cfg.bleDebugLog
            ? Paths.configDir.appendingPathComponent("ble_scan_log.csv", isDirectory: false).path
            : nil)
        AdvScanner.shared.start(targetName: targetName)

        // 블루투스 권한이 없으면 말해 준다. 감시는 그대로 시작한다: 스캐너는 "쓸 수 없음" 으로 남고
        // 목록은 시간 초과를 보이며, 유휴 잠금은 그대로 된다 - 블루투스가 없는 PC 와 같다. 권한은
        // 사용자만 켤 수 있으므로 상자는 실행마다 한 번만. 자동 시작은 main.async 로 여기에 오므로
        // 타이머로 한 번 넘겨 GCD 블록 밖에서 띄운다 (알림이 떠 있는 동안 main 큐가 멎지 않게).
        if AdvScanner.shared.bluetoothDenied {
            EventLog.write("start: Bluetooth permission denied")
            noteBluetoothDenied()
        }

        cfg.btAddress = 0
        cfg.nearLatencyMs = AppController.fixedNearLatencyMs
        cfg.nearRssiThreshold = thr
        cfg.gattRssiThreshold = gattThr   // 광고 값 + 차이의 사본 (위 주석)
        cfg.gattSeen = Shared.shared.gattSeen
        cfg.keepAliveSec = keepAlive
        cfg.scanIntervalSec = AppController.fixedScanIntervalSec
        cfg.idleCountdownSec = idle
        cfg.unlockAuto = true
        cfg.unlockDelaySec = delay
        cfg.centerImagePath = centerImagePath
        cfg.bannerImagePath = bannerImagePath
        ConfigStore.save(cfg)   // 실패는 ConfigStore 가 적는다 (Windows 도 결과를 보지 않는다)

        // 판정 스레드: 세션 번호를 새로 받는다. 지난 세션의 늦은 결과는 onResult 가 버린다.
        session += 1
        let j = JudgeThread(session: session,
                            onResult: { [weak self] r in self?.onResult(r) },
                            onGattSeen: { [weak self] in self?.onGattSeen() })
        judge = j
        j.start()
        monitoring = true
        guardEngine.start(now: now)
        Shared.shared.lastInputTick = guardEngine.lastInputTick
        // 입력 감시(Windows 의 저수준 훅)와 1 초 틱은 감시 중에만 돈다
        inputWatcher?.start()
        countdownTimer?.invalidate()
        countdownTimer = MainTimer.every(1.0) { [weak self] in self?.countdownTick() }
        beginMonitoringActivity()

        advanced?.syncFromModel()
        advanced?.setMonitoringUI(true)
    }

    /// [중지] (StopMon). 판정 스레드를 먼저 멈춘다 (최대 15 초) - 멈춘 스캐너를 읽지 않게.
    func stopMon() {
        if !monitoring { return }
        judge?.stop()
        judge = nil
        AdvScanner.shared.stop()
        GattServer.shared.stop()
        monitoring = false
        countdownTimer?.invalidate()
        countdownTimer = nil
        inputWatcher?.stop()
        // 가려져 있으면 걷는다 (BLACK OFF 를 남긴다)
        guardEngine.stop(now: Mono.now())
        Shared.shared.blackActive = guardEngine.blackActive
        endMonitoringActivity()

        stateLabelText = Texts.stateLabelStopped
        advanced?.setMonitoringUI(false)
        advanced?.setStateLabel(stateLabelText)
        advanced?.syncFromModel()
        // Q4: Windows 는 [중지] 때 오버레이를 다시 쓰지 않아 "근처 • 보호 중" 이 남았다. "정지됨" 으로.
        updateOverlay()
    }

    private func beginMonitoringActivity() {
        if activity != nil { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "SmartScreen proximity monitoring")
    }

    private func endMonitoringActivity() {
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    // MARK: - 판정 결과 (WM_SCAN_RESULT → OnResult)

    private func onResult(_ r: ProbeResult) {
        // [중지] 직전에 보낸 결과나 지난 세션의 결과는 버린다 (Q6). Windows 는 이것이 "정지됨" 을
        // 덮어쓰고, FAR 전환이면 입력 훅도 없는 채로 화면을 잠글 수도 있었다.
        guard monitoring, r.session == session else { return }
        lastResult = r

        let transition = r.state != r.prevState
        if transition {
            // 판정한 임계값(히스테리시스 적용)과 설정값을 나란히 적는다. 설정값만 적으면 로그를 봐도
            // 판정을 재현할 수 없다. 설정값은 지금 메인에서 읽는다 (슬라이더가 도중에 바꿀 수 있다).
            let path = r.gatt ? "GATT" : (r.bleAvailable ? "adv" : "latency")
            let setThr = r.gatt ? Shared.shared.gattRssiThreshold : Shared.shared.nearRssiThreshold
            // 확인 연결이 돌고 있거나 막 끝났으면 꼬리에 붙인다 (", probing for 1.3s" /
            // ", probe ended 0.4s ago", 아니면 ""). 연결을 맺는 동안 같은 라디오의 광고 수신이 줄 수 있어
            // 그것이 전환을 불렀는지는 이 꼬리가 없으면 STATE 줄만 보고 가를 수 없다.
            let probeTag = AdvScanner.shared.probeTagForLog(now: Mono.now())
            EventLog.write("STATE \(r.prevState.name) -> \(r.state.name)  (\(path) rssi=\(r.rssiDbm) dBm "
                           + "thr=\(r.thresholdDbm) set=\(setThr), latency=\(r.latencyMs)ms "
                           + "reachable=\(r.reachable ? 1 : 0)\(probeTag))")
        }

        let now = Mono.now()
        // 순서: FAR 전환 잠금 → NEAR 자동 해제 → FAR 면 지연 해제 취소 (GuardEngine 안에서)
        guardEngine.onResult(r, now: now)
        advanced?.chartNeedsDisplay()

        stateLabelText = Texts.stateLabel(r, countdown: guardEngine.nCountdown)
        advanced?.setStateLabel(stateLabelText)

        // Mac 에는 latency 경로가 없다: 실패 횟수는 늘 0, 재연결 웜업도 없다
        let nearThr = Shared.shared.nearRssiThreshold
        let gattThr = Shared.shared.gattRssiThreshold
        let row = Texts.listRow(r, nearThr: nearThr, gattThr: gattThr, nearLatencyMs: AppController.fixedNearLatencyMs,
                                inWarmup: false, fails: 0)
        listRows.insert(row, at: 0)
        if listRows.count > AppController.listCap {
            listRows.removeLast(listRows.count - AppController.listCap)
        }
        advanced?.insertRow(row)

        // 상태바. "ID:" 는 잠긴 아이폰을 특정하는 수단이다 - 없으면 원천적으로 특정할 방법이 없는데도
        // 화면은 멀쩡해 보이므로 여기에 드러낸다.
        let scan = AdvScanner.shared.snapshot(now: now)
        let gatt = GattServer.shared.snapshot(now: now)
        statusText = Texts.statusBar(r, targetName: targetName, packetRate: scan.packetRate,
                                     nearThr: nearThr, gattThr: gattThr,
                                     idSt: Texts.idStatus(hasToken: hasToken, bound: scan.bound),
                                     gattSt: Texts.gattStatus(running: gatt.running, subscribed: gatt.subscribed),
                                     countdown: guardEngine.nCountdown)
        advanced?.setStatus(statusText)
        updateOverlay()
    }

    /// WM_GATT_SEEN: 컴패니언 앱이 처음 구독했다. 판정 스레드 대신 여기서 쓴다 - 거기서
    /// Load → Save 하면 그 사이에 메인이 쓴 값(회전한 refresh 토큰)을 낡은 사본으로 덮는다.
    /// 못 써도 다시 걸지 않는다: 다음 [시작] 이 gattSeen=0 을 다시 읽고, 앱이 붙으면 또 온다.
    private func onGattSeen() {
        var c = ConfigStore.load()
        if !c.gattSeen {
            c.gattSeen = true
            if !ConfigStore.save(c) {
                EventLog.write("companion app seen - gattSeen NOT saved (it will be set again on a later run)")
            }
        }
    }

    // MARK: - 1 초 틱 (IDT_COUNTDOWN)

    /// 블루투스 권한이 없다고 실행마다 한 번 말한다. [시작] 에서 이미 거부돼 있을 때와, 처음 [시작]
    /// 이 띄운 macOS 의 허용 창에서 "허용 안 함" 을 누른 뒤(그때는 [시작] 이 이미 지나갔다 - 1 초
    /// 틱이 알아챈다) 둘 다 여기로 온다.
    private func noteBluetoothDenied() {
        if bluetoothDeniedShown { return }
        bluetoothDeniedShown = true
        _ = MainTimer.once(after: 0) { [weak self] in
            guard let self = self, !self.isExiting else { return }
            Alerts.warning("블루투스 권한이 없어요. 시스템 설정 > 개인정보 보호 및 보안 > 블루투스에서 "
                           + "SmartScreen 을 켜 주세요.", title: "SmartScreen")
        }
    }

    private func countdownTick() {
        guard monitoring else { return }
        // 프로버가 잠긴 폰을 찾아내면서 overflow 비트를 새로 배웠으면 저장한다 (Windows IDT_COUNTDOWN).
        // 다음 실행 때 후보를 훨씬 빨리 좁힌다 (없어도 동작은 한다). 비트는 직접 읽기 스캔(R)이
        // 제조사 데이터에서 읽은 것이고 번호는 Windows 와 같다 - 같은 config.ini 를 옮겨도 뜻이 같다.
        let learned = AdvScanner.shared.takeLearnedOverflowBit()
        if learned >= 0 {
            var c = ConfigStore.load()
            c.phoneOvfBit = learned
            // 못 읽은 config 는 save 가 거절한다 (그 사유는 ConfigStore 가 적는다). 다시 걸지 않는다:
            // 스캐너는 이미 이 비트로 고르고 있고, 다음 실행에서 처음 묶을 때 또 배운다.
            if !ConfigStore.save(c) {
                EventLog.write("ident: overflow bit \(learned) NOT saved (it will be learned again on a later run)")
            }
        }
        if !bluetoothDeniedShown && AdvScanner.shared.bluetoothDenied {
            EventLog.write("start: Bluetooth permission denied")
            noteBluetoothDenied()
        }
        let now = Mono.now()
        guardEngine.tick(now: now)
        countdownLabelText = Texts.countdownLabel(black: guardEngine.blackActive,
                                                  unlockTimer: guardEngine.unlockTimer,
                                                  manual: guardEngine.manualLock,
                                                  near: isNear,
                                                  countdown: guardEngine.nCountdown)
        // (고급 창은 이때 상태 띠 색도 다시 정한다. Windows 는 다음 결과(≤2 초)에야 다시 칠했다.)
        advanced?.setCountdownLabel(countdownLabelText)
        updateOverlay()
    }

    // MARK: - 입력 (ResetCountdown)

    private func onInput(eventTick: UInt64) {
        guard monitoring else { return }
        let infoBefore = guardEngine.ovlInfo
        // 입력은 언제나 곧바로 화면을 걷는다 - 직접 잠금도.
        guardEngine.onInput(eventTick: eventTick, now: Mono.now())
        // GATT 틱(폴링 간격)이 읽는 사본
        Shared.shared.lastInputTick = guardEngine.lastInputTick
        // Windows 는 셋째 줄(잠금 기록)만 지우고 다시 그렸다. 나머지 두 줄은 다음 틱에 바뀐다.
        if guardEngine.ovlInfo != infoBefore { repaintOverlayInfo() }
    }

    // MARK: - GuardEngineHost

    func guardShowLock() {
        // GATT 틱 스레드가 읽는다 (잠긴 동안 폴링 2000 ms)
        Shared.shared.blackActive = true
        LockScreen.shared.show(centerPath: centerImagePath, bannerPath: bannerImagePath)
    }

    func guardHideLock() {
        Shared.shared.blackActive = false
        // 창과 영상을 내리고 그림을 놓는다. 잠금 중에 경로가 바뀌었을 수 있으므로 다음 잠금이 다시 읽는다.
        LockScreen.shared.hide()
    }

    func guardIsRemoteSession() -> Bool {
        return RemoteSession.isRemote()
    }

    // MARK: - 오버레이

    /// UpdateOverlayState
    private func updateOverlay() {
        guard let o = overlay else { return }
        let l1 = Texts.overlayLine1(monitoring: monitoring, targetName: targetName)
        let l2 = Texts.overlayLine2(monitoring: monitoring, black: guardEngine.blackActive,
                                    unlockTimer: guardEngine.unlockTimer, manual: guardEngine.manualLock,
                                    near: isNear, countdown: guardEngine.nCountdown)
        lastOverlay = (line1: l1, line2: l2.text, color: l2.color)
        o.update(line1: l1, line2: l2.text, color: l2.color, info: guardEngine.ovlInfo)
    }

    private func repaintOverlayInfo() {
        guard let o = overlay else { return }
        guard let last = lastOverlay else {
            updateOverlay()
            return
        }
        o.update(line1: last.line1, line2: last.line2, color: last.color, info: guardEngine.ovlInfo)
    }

    /// 오버레이 [설정]: 간단 창이 사용자가 보는 창이다. 고급 창은 거기서 연다.
    private func overlaySettings() {
        if simple != nil {
            showSimple()
        } else {
            showAdvanced()
        }
    }

    // MARK: - 명령 (두 창과 오버레이가 부른다)

    /// 간단 창 보호 타일
    func toggleGuard() {
        if monitoring { stopMon() } else { startMon() }
        simple?.refresh()
    }

    /// [새로고침]: 감시 중에는 조용히 무시한다
    func refreshDevices() {
        if !monitoring { populateDevices() }
    }

    /// [BT]: 블루투스 설정을 연다 (Windows ms-settings:bluetooth)
    func openBluetoothSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings"),
           NSWorkspace.shared.open(u) {
            return
        }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Bluetooth.prefPane"))
    }

    /// [기기 키]: IRK 가져오기는 Windows 전용이다. CoreBluetooth 는 원래 주소도 본딩 키도 내주지 않고,
    /// macOS 는 IRK 를 root 만 읽는 곳에 둔다. 단추는 배치를 맞추려고 남겨 두고 안내만 한다.
    func importIrk() {
        Alerts.info("이 기능은 Windows 에서만 쓸 수 있습니다.\n\nMac 에서는 '폰 등록' 으로 폰을 알아봅니다.",
                    title: "기기 키 가져오기")
    }

    /// 지금 잠금 / 지금 가리기 / 오버레이 [잠금]. 관문을 보지 않고, 감시 중이 아니면 조용히 아무것도 안 한다.
    func lockNow() {
        guardEngine.manualLockNow(now: Mono.now())
    }

    /// 잠금 화면 [해제] (직접 잠금, 자동 잠금 모두)
    func releaseLock() {
        guardEngine.deactivate(now: Mono.now())
    }

    /// [초기화]
    func clearLog() {
        listRows.removeAll()
        advanced?.clearRows()
        guardEngine.clearFarEvents()
        advanced?.chartNeedsDisplay()
    }

    func pickCenterImage() {
        guard let p = browseImage() else { return }
        centerImagePath = p
        afterImagePicked { $0.centerImagePath = p }
    }

    func pickBannerImage() {
        guard let p = browseImage() else { return }
        bannerImagePath = p
        afterImagePicked { $0.bannerImagePath = p }
    }

    /// 고른 뒤: 올려 둔 그림을 버리고(다음 잠금이 다시 읽는다) 바로 저장한다.
    /// Q5: Windows 는 다음 [시작] 이나 기업 동기화 때에야 저장해서, 감시 중에 고른 그림이 [종료] 뒤
    /// 다음 실행의 자동 시작에 예전 경로로 덮였다. Mac 은 그 자리에서 저장한다 (같은 키).
    private func afterImagePicked(_ change: (inout AppConfig) -> Void) {
        // 떠 있는 잠금 화면은 보여 주던 것을 그대로 둔다 (풀릴 때 LockScreen 이 버린다)
        if !guardEngine.blackActive { LockScreen.shared.freeImages() }
        var c = ConfigStore.load()
        change(&c)
        ConfigStore.save(c)   // 못 읽은 구조체는 save 가 거절한다
        advanced?.syncFromModel()
        simple?.refresh()
    }

    /// BrowseImage: 파일이 있어야 한다. 형식 목록은 Windows 의 네 줄 그대로 (기본은 첫 줄).
    private func browseImage() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowsOtherFileTypes = true
        let filter = ImageFilterAccessory(panel: panel)
        panel.accessoryView = filter.view
        panel.isAccessoryViewDisclosed = true
        NSApp.activate(ignoringOtherApps: true)
        let response = withExtendedLifetime(filter) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return nil }
        let path = url.path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// [기업용 둘러보기]
    func openEnterprise() {
        EnterpriseDialogs.showShowcase(app: self)
    }

    /// 간단 창 클립보드 타일. 로그인이 먼저다 - 여기서 말해 주지 않으면 타일이 그냥 안 켜지고 이유는
    /// 어디에도 안 보인다. 이 타일이 근접과 무관한데도 간단 창에 있는 것은 트레이가 없어서 이 창이
    /// 앱으로 돌아오는 유일한 길이기 때문이다.
    func toggleClip() {
        var c = ConfigStore.load()
        if ClipSync.isRunning {
            ClipSync.stop()
            c.clipSync = false
            ConfigStore.save(c)
        } else {
            if !AccountSession.shared.hasAccount {
                Alerts.info("먼저 구글 계정으로 로그인하세요.\n\n[내 폰] 의 [등록하기] 에서 계정으로 등록하면 로그인됩니다.\n"
                            + "다른 PC 에서도 같은 계정으로 로그인해야 서로 주고받습니다.",
                            title: AppController.clipTitle)
                return   // 바로 새로 그리지 않는다 - 1 초 타이머가 따라잡는다
            }
            let url = ServerDefaults.url(c)
            let key = ServerDefaults.key(c)
            if ClipSync.start(url: url, key: key, maxBytes: Int(c.clipMaxKB) * 1024) {
                c.clipSync = true
                ConfigStore.save(c)
                Alerts.info("클립보드 공유를 켰습니다.\n\n복사한 그림과 글이 이 계정의 다른 PC 로 넘어갑니다.\n"
                            + "복사한 내용이 서버를 지나가므로, 필요할 때만 켜 두세요.",
                            title: AppController.clipTitle)
            }
        }
        simple?.refresh()
    }

    func showSimple() {
        guard let s = simple else {
            showAdvanced()
            return
        }
        s.showAndActivate()
        s.refresh()
    }

    func showAdvanced() {
        advanced?.show()
    }

    func openWizard() {
        WizardWindowController.open(app: self, parent: simple?.window)
    }

    /// g_measuring: 재보기 창이 열려 있는 동안. 자리를 비우는 것이 절차의 일부라 자동 잠금과
    /// 업데이트 재시작을 막는다 (직접 잠금은 그대로 된다).
    /// 그동안 GATT TICK 은 입력과 무관하게 1 초마다 간다 (GattServer 가 Shared.measuring 을 읽는다) -
    /// 앉아서 재는 1 분 동안 타자를 쳐도 연결 표본이 쌓이게. 스캐너는 직접 읽기 스캔(R)을 켠다 -
    /// 광고 기준을 평소 광고 경로와 같은 조건에서 재야 한다.
    func setMeasuring(_ on: Bool) {
        guardEngine.measuring = on
        Shared.shared.measuring = on
        AdvScanner.shared.setMeasuring(on)
    }

    /// 간단 창 거리 슬라이더 (SimpleApplyDist). 두 경로를 따로 물어볼 화면이 아니므로 둘 다 바꾼다:
    /// 광고는 이 값, 연결은 이 값 + 재보기가 잰 차이 (Choices.gattThreshold). 재보기의 [이대로 쓰기] 도
    /// 차이를 저장한 뒤 여기로 온다.
    /// 고급 창의 "신호 강도" 칸도 같은 값으로 - 그 칸은 [시작] 때 다시 읽히므로, 안 맞춰 두면 슬라이더로
    /// 바꾼 값이 다음 [시작] 에 예전 숫자로 되돌아간다 (실제로 두 창이 다른 값을 보여 줬다, 2026-10-01).
    /// 판정 스레드는 공유값을 매번 읽으므로 바로 듣는다. 탐색 하한(threshold-10)은 다음 [시작] 까지 그대로다.
    func simpleApplyDist(_ step: Int) {
        guard step >= 0 && step < Choices.distOffsets.count else { return }
        var c = ConfigStore.load()
        let v = Choices.distValue(base: Choices.distBase(measured: c.measuredBaseRssi), step: step)
        let g = Choices.gattThreshold(near: v, offset: c.gattRssiOffset)
        Shared.shared.nearRssiThreshold = v
        Shared.shared.gattRssiThreshold = g
        thresholdFieldText = "\(v)"
        advanced?.syncFromModel()
        c.nearRssiThreshold = v
        c.gattRssiThreshold = g
        ConfigStore.save(c)
        EventLog.write(Texts.distLogLine(step: step, near: v, gatt: g))
    }

    /// 간단 창 유휴 단추. 고급 창 콤보도 가장 가까운 칸으로 옮긴다 - 두 창이 같은 선택지를 가져야
    /// 다음 [시작] 이 되돌리지 않는다 ("바로" 가 콤보에 없던 동안 15초로 돌아갔다).
    func simpleSetIdle(_ index: Int) {
        guard index >= 0 && index < Choices.simpleIdle.count else { return }
        let v = Choices.simpleIdle[index]
        guardEngine.setIdle(v)
        idleComboIndex = Texts.comboFindValue(Choices.idleValues, v)
        advanced?.syncFromModel()
        var c = ConfigStore.load()
        c.idleCountdownSec = v
        ConfigStore.save(c)
    }

    // MARK: - 업데이트

    /// 머리글 버전 단추. 업데이트가 꺼져 있으면 아무것도 안 한다 (글자가 이미 그렇게 말한다).
    func updateCheckManual() {
        if Updater.enabled { Updater.checkAsync(manual: true) }
        simple?.refresh()
    }

    /// 띠 [업데이트] / [다시 시도]. 버전이 아니라 "후보" 가 있는지로 고른다 - 승인 대기는 버전은
    /// 있어도 후보가 없어서, 버전으로 고르면 [다시 시도] 가 "받을 버전이 정해지지 않았어요" 를 돌았다.
    func updateApplyOrRetry() {
        let us = Updater.status()
        var failed = false
        if case .failed = us.phase { failed = true }
        if failed && !Updater.hasCandidate() {
            Updater.checkAsync(manual: true)
        } else {
            Updater.downloadAsync()
        }
        simple?.refresh()
    }

    /// 띠 [나중에]
    func updateLater() {
        Updater.dismiss()
        simple?.refresh()
    }

    /// UpdateTick: 1 분 타이머(fromNotify=false)와 업데이터의 상태 알림(true).
    private func updateTick(fromNotify: Bool) {
        if inUpdateTick {
            // 업데이터가 이 안에서 (launchApplier 등) 바로 알려 오면 다 끝난 뒤에 다시 본다
            DispatchQueue.main.async { [weak self] in self?.updateTick(fromNotify: fromNotify) }
            return
        }
        if isExiting { return }
        inUpdateTick = true
        defer { inUpdateTick = false }

        let now = Mono.now()
        if !fromNotify && updLastCheck != 0 && now >= updLastCheck
            && now - updLastCheck >= AppController.updateEveryMs && !Updater.busy() {
            updLastCheck = now
            Updater.checkAsync(manual: false)
        }
        let us = Updater.status()
        var isAvailable = false
        var isFailed = false
        var isReady = false
        switch us.phase {
        case .available: isAvailable = true
        case .failed: isFailed = true
        case .ready: isReady = true
        default: break
        }
        // 개인 PC: 설정이 끝난 PC 에서 간단 창은 숨겨져 있다. 띠가 거기에만 뜨면 아무도 못 본다.
        // 새 버전마다 한 번, 초점을 빼앗지 않고 창을 띄운다. 기업 PC 는 묻지 않고 적용하므로 띄울
        // 이유가 없다. 지난번 적용 실패 기록도 마찬가지다 - 그것은 대화상자를 대신하는 것이라 기업
        // PC 도 봐야 한다. 가리는 중이거나 재는 중에는 띄우지 않는다.
        let wantShow = (isAvailable && !us.autoApply) || (isFailed && us.fromMarker)
        let showKey = us.version + (isFailed ? "|F" : "|A")
        if wantShow && !us.dismissed && updShownFor != showKey
            && !guardEngine.blackActive && !guardEngine.measuring, let s = simple {
            updShownFor = showKey
            // 최소화된 창도 '보이는' 창이다 - 복원까지 해야 한다
            if !s.window.isVisible || s.window.isMiniaturized { s.showWithoutActivating() }
        }
        if isReady {
            if guardEngine.blackActive || guardEngine.measuring || loginBusy || bleRegisterBusy {
                // 나중에 다시 - 1 분 타이머가 다시 온다. 가리는 동안 다시 시작하면 그 1~2 초 동안
                // 화면이 드러난다. 그 화면을 지키는 것이 이 프로그램의 일이다.
                // BLE 직접 등록도 기다린다: Windows 는 등록하는 동안 UI 스레드가 막혀 이 틱이 돌 수
                // 없었다. Mac 은 비동기라, 여기서 나가면 읽던 토큰이 저장되지 않고 상자도 안 뜬다.
                // (간단 창 띠의 "화면이 풀리면 적용해요" 도 같은 조건을 본다.)
            } else {
                let r = Updater.launchApplier()
                if r.ok {
                    EventLog.write("update: exiting to apply \(us.version)")
                    // 오버레이 [종료] 와 같은 길로 나간다 - 그것이 유일한 정상 종료 경로다.
                    normalExit()
                    return
                }
                EventLog.write("update: could not launch applier - \(r.err)")
            }
        }
        simple?.refresh()
    }

    // MARK: - 기업 콘텐츠

    private func startEnterpriseSync(_ cfg: AppConfig) {
        if cfg.enterpriseRegistered && !cfg.orgId.isEmpty {
            // config 에 주소/키가 없으면 내장 기본값으로 묻는다 (config 에 적어 넣지는 않는다)
            let url = ServerDefaults.url(cfg)
            let key = ServerDefaults.key(cfg)
            let org = cfg.orgId
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let res = Enterprise.sync(url: url, key: key, org: org)
                DispatchQueue.main.async {
                    self?.onEnterpriseSyncResult(res.outcome, org: org, center: res.center, banner: res.banner)
                }
            }
        } else if cfg.enterpriseRegistered {
            EventLog.write("enterprise sync: skipped - 설정이 비어 있다")
        }
    }

    /// WM_ENTERPRISE_SYNC
    private func onEnterpriseSyncResult(_ outcome: EnterpriseOutcome, org: String, center: String, banner: String) {
        // 도는 사이에 등록이 바뀌었으면(해제했거나 다른 조직으로 다시 등록) 이 결과는 지금의 조직 것이
        // 아니다. 반영하면 방금 비운 경로를 되살린다.
        let c = ConfigStore.load()
        let current = c.loaded && c.enterpriseRegistered
            && c.orgId.caseInsensitiveCompare(org) == .orderedSame
        if !current {
            EventLog.write("enterprise sync: result dropped - registration changed while it ran")
            return
        }
        if case .requestFailed = outcome {
            // 아무것도 건드리지 않는다. 오프라인인 Mac 은 갖고 있던 것을 계속 보여 준다.
            EventLog.write("enterprise sync: FAILED (org=\(String(org.prefix(40)))) - keeping what this PC already shows")
            return
        }
        let changed = applyEnterpriseSync(outcome, center: center, banner: banner)
        var ready = false
        if case .ready = outcome { ready = true }
        EventLog.write("enterprise sync: \(ready ? "OK" : "no active content") "
                       + "(center=\(center.isEmpty ? 0 : 1) banner=\(banner.isEmpty ? 0 : 1))"
                       + (changed ? " - image paths updated" : ""))
    }

    /// ApplyEnterpriseSync (메인 전용). 바뀐 것이 있으면 true.
    ///
    /// 경로의 주인: enterprise_content 폴더 안을 가리키는 경로는 동기화의 것이다. 물어본 결과가 나올
    /// 때마다 그 자리의 새 경로로 바꾸고, 서버에 그 자리 것이 없으면 비운다. 사용자가 다른 곳에서 고른
    /// 그림은 건드리지 않고, 빈 자리는 채운다. 예전에는 "비어 있을 때만 채운다" 였는데, 한 번 채운
    /// 경로가 저장되므로 다음 실행부터는 비어 있는 적이 없었고 관리자가 바꾸거나 송출을 멈춰도 PC 는
    /// 처음 받은 파일을 계속 띄웠다. 요청이 실패했으면 아무것도 건드리지 않는다.
    @discardableResult
    func applyEnterpriseSync(_ outcome: EnterpriseOutcome, center: String, banner: String) -> Bool {
        if case .requestFailed = outcome { return false }
        var changed = false
        if (centerImagePath.isEmpty || Enterprise.isEnterpriseContentPath(centerImagePath))
            && centerImagePath != center {
            centerImagePath = center
            changed = true
        }
        if (bannerImagePath.isEmpty || Enterprise.isEnterpriseContentPath(bannerImagePath))
            && bannerImagePath != banner {
            bannerImagePath = banner
            changed = true
        }
        if !changed { return false }
        // 잠금 화면이 떠 있는 동안에는 그림을 버리지 않는다 - 영상은 잠금 창을 만들 때만 시작하므로
        // 여기서 버리면 다음에 그려질 때 자리표시자가 나온다. 풀릴 때 LockScreen 이 버린다.
        if !guardEngine.blackActive { LockScreen.shared.freeImages() }
        // StartMon 이 저장하는 것과 같은 두 값이다. 여기서도 저장해야 감시를 다시 시작하지 않아도 남는다.
        var c = ConfigStore.load()
        if c.loaded {
            c.centerImagePath = centerImagePath
            c.bannerImagePath = bannerImagePath
            ConfigStore.save(c)
        }
        advanced?.syncFromModel()
        return true
    }

    // MARK: - 폰 등록

    /// [폰 등록] / 간단 창 [등록하기]·[바꾸기]. 방법이 둘이다. 목적이 같으므로 단추를 늘리지 않고 여기서 고른다.
    ///  - 계정: 폰과 PC 가 같은 구글 계정으로 로그인하면 서버가 같은 토큰을 준다.
    ///  - 블루투스: 예전 방식. 인터넷이 없어도 되고 서버가 죽어도 된다.
    func registerPhone() {
        // 블루투스 등록(6 초 스캔 + 최대 20 초 토큰 읽기)이 도는 중이면 공통 입구에서 막는다. 고급 창의
        // [폰 등록] 만 꺼 두면 간단 창 [등록하기]/[바꾸기] 와 마법사가 여전히 이리로 온다. 그때 [아니오] 는
        // 말없이 아무것도 안 했고, [예] 는 BLE 읽기와 나란히 구글 로그인을 시작해서, 몇 분 뒤 끝난
        // 로그인이 BLE 가 방금 저장하고 알린 토큰을 덮었다 (RG-3). 부르는 쪽은 모두 단추 동작이다
        // (main.async 블록이 아니다) - 여기서 바로 알림을 띄워도 뒤의 main 큐 블록이 멎지 않는다.
        if bleRegisterBusy {
            Alerts.info(AppController.registerBleBusyText, title: AppController.registerTitle)
            return
        }
        // 본문이 [예] / [아니오] 를 이름으로 부르므로 단추도 예 / 아니오 / 취소 여야 한다 (Alerts 가 그렇게 단다)
        let how = Alerts.yesNoCancel(AppController.registerQuestion, title: AppController.registerTitle)
        if how == 0 {
            registerViaAccount()
        } else if how == 1 {
            registerViaBluetooth()
        }
        // 2 (취소) → 아무것도 안 한다
    }

    private func registerViaAccount() {
        // [폰 등록] 은 로그인 중에 꺼져 있지만 간단 창은 여전히 이 명령을 보낼 수 있다
        if loginBusy {
            Alerts.info(AppController.registerLoginBusyText, title: AppController.registerTitle)
            return
        }
        // 블루투스 등록과 나란히 로그인하지 않는다 - 나중에 끝난 쪽이 먼저 저장한 토큰을 덮는다
        if bleRegisterBusy {
            Alerts.info(AppController.registerBleBusyText, title: AppController.registerTitle)
            return
        }
        Alerts.info("브라우저가 열립니다. 구글 계정으로 로그인하세요.\n\n"
                    + "로그인이 끝나면 브라우저 창을 닫고 여기로 돌아오면 됩니다.",
                    title: AppController.registerTitle)
        if loginBusy || bleRegisterBusy || isExiting { return }
        loginBusy = true
        updateRegisterButton()
        startLoginWorker()
    }

    /// LoginThread. 브라우저에서 사용자가 쓰는 시간이 있어 최악 몇 분이다 - 메인에서 기다리면 다 멎는다.
    private func startLoginWorker() {
        let timeout = AppController.loginTimeoutSec
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cfg = ConfigStore.load()   // 읽기만 한다
            let url = ServerDefaults.url(cfg)
            let key = ServerDefaults.key(cfg)
            var r = LoginResult()
            let signed = Auth.signInWithGoogle(url: url, key: key, timeoutSec: timeout)
            if let s = signed.0 {
                // 여기까지 왔으면 로그인은 됐다. 뒤에서 무엇이 실패하든 세션은 저장할 값이다.
                r.ok = true
                r.email = s.email
                r.userId = s.userId
                r.refresh = SecretSeal.protect(s.refresh) ?? ""
                // 살아 있는 세션으로 심는다. 이게 없으면 방금 로그인해도 클립보드 동기화는 앱을
                // 다시 켤 때까지 "로그인하지 않았다" 로 남는다.
                AccountSession.shared.adopt(s)
                let fetched = Auth.fetchDeviceToken(url: url, key: key, access: s.access)
                if let token = fetched.0 {
                    r.phoneToken = token   // 빈 값일 수 있다 = 폰에서 아직 로그인 안 함
                } else {
                    r.err = fetched.1
                }
            } else {
                r.err = signed.1
            }
            let result = r
            // onLoginResult 는 알림을 띄운다. main.async 블록 안에서 띄우면 알림이 떠 있는 동안 뒤이은
            // main 큐 블록(세션 회전 저장, 업데이트 알림...)이 전부 멎으므로 타이머로 한 번 넘긴다.
            DispatchQueue.main.async {
                _ = MainTimer.once(after: 0) { self?.onLoginResult(result) }
            }
        }
    }

    /// 등록·로그인 결과 상자를 띄우기 직전에 간단 창도 초점을 빼앗지 않고 앞에 놓는다 (업데이트 띠와 같은
    /// orderFrontRegardless). 결과는 사용자가 브라우저에 있을 때 오는데, macOS 14+ 는 그때 우리 앱의
    /// 활성화를 거절하고 이 앱은 Dock 도 Cmd-Tab 도 없다. 상자는 Alerts 가 떠 있는 층으로 올리지만,
    /// 상자를 닫은 뒤 바뀐 "내 폰" 줄을 보여 줄 창도 앞에 있어야 돌아올 곳이 보인다.
    /// 부르는 곳은 모두 타이머 콜백이나 단추 동작이다 (main.async 블록 안이 아니다).
    /// 재보기 창이 열려 있으면 (로그인을 기다리는 동안 열 수 있다) 그것을 다시 간단 창 위로 올린다.
    private func showSimpleForResult() {
        guard !isExiting, let s = simple else { return }
        s.showWithoutActivating()
        WizardWindowController.raiseIfOpen()
    }

    /// WM_LOGIN_RESULT
    private func onLoginResult(_ r: LoginResult) {
        loginBusy = false
        updateRegisterButton()

        if !r.ok {
            EventLog.write("google login failed: \(r.err)")
            showSimpleForResult()
            Alerts.warning("로그인하지 못했습니다.\n\n\(r.err)", title: AppController.registerTitle)
            return
        }

        // 봉인이 실패했으면 refresh 가 비어 있다. 예전에는 그 빈 값을 authRefresh 에 그대로 써서
        // 저장돼 있던 토큰까지 지웠다. 지금은 덮지 않는다 (flushAuthSave).
        if r.refresh.isEmpty {
            EventLog.write("google login: could not seal the refresh token (seal) - this login will not survive a restart")
        }

        // 새 로그인이 앞의 것을 대신한다. 못 쓴 채 남아 있던 예전 세션의 값은 버린다.
        var a = AuthSave()
        a.pending = true
        a.login = true
        a.refresh = r.refresh
        a.userId = r.userId
        a.email = r.email
        a.phoneToken = r.phoneToken
        authSave = a
        let saved = flushAuthSave()
        EventLog.write("google login: \(r.email) (phone token: \(r.phoneToken.isEmpty ? "none yet" : "received"))"
                       + (saved ? "" : " - NOT saved to config.ini yet, will retry"))
        lastLoginEmail = r.email

        // 돌고 있는 스캐너에도 알려 준다. 계정 등록은 블루투스 등록과 달리 감시를 멈추지 않고 할 수
        // 있어서 StartMon 을 다시 지나지 않는다 - 여기서 알리지 않으면 "등록했습니다" 라고 말한 뒤에도
        // config 에만 토큰이 있고, 스캐너는 끝까지 폰을 확인하지 못한다.
        if !r.phoneToken.isEmpty {
            hasToken = true
            AdvScanner.shared.setIdentity(tokenHex: r.phoneToken, ovfBit: -1,
                                          probeFloor: Shared.shared.nearRssiThreshold - 10)
        }

        // config.ini 에 쓴 뒤라 간단 창이 새 계정과 "내 폰" 줄을 읽는다
        showSimpleForResult()
        if !r.err.isEmpty {
            // 로그인은 됐는데 토큰 조회가 실패했다. 다시 로그인시킬 일은 아니다.
            Alerts.warning("\(r.email) 로 로그인했습니다.\n\n다만 폰 정보를 가져오지 못했습니다:\n\(r.err)"
                           + "\n\n잠시 뒤 다시 시도하세요.", title: AppController.registerTitle)
        } else if r.phoneToken.isEmpty {
            // 오류가 아니다. 순서상 폰이 아직 안 올라온 것뿐이라 그렇게 말해 준다 (PC 를 먼저 설정하는 흔한 순서).
            Alerts.info("\(r.email) 로 로그인했습니다.\n\n아직 이 계정에 등록된 폰이 없습니다.\n"
                        + "아이폰에서 SSBeacon 앱을 열고 같은 계정으로 로그인한 뒤,\n"
                        + "여기서 다시 [폰 등록] 을 누르세요.", title: AppController.registerTitle)
        } else {
            onRegisteredPhoneToken(r.phoneToken, viaLogin: true)
        }
        simple?.refresh()
    }

    private func registerViaBluetooth() {
        // 폰이 GATT 로 내주는 토큰을 한 번 읽어 저장해 둔다. 앱을 화면에 띄워 두는 것이 조건이다 -
        // 포그라운드 광고에만 서비스 UUID 가 실려 후보가 모호하지 않다. 잠긴 폰으로 등록하면 남의 폰을
        // 집을 수 있다.
        // 구글 로그인이 도는 중이면 하지 않는다. 그 로그인이 끝나면 계정의 토큰을 저장하므로 여기서
        // 읽어 저장한 토큰을 덮는다 (registerViaAccount 가 BLE 등록 중에 거절하는 것과 같은 이유).
        if loginBusy {
            Alerts.info(AppController.registerLoginBusyText, title: AppController.registerTitle)
            return
        }
        if monitoring {
            Alerts.info("먼저 중지를 누른 뒤 등록하세요.\n스캔과 연결이 같은 안테나를 나눠 쓰면 연결이 실패합니다.",
                        title: AppController.registerTitle)
            return
        }
        if bleRegisterBusy { return }   // 이미 도는 중 (registerPhone 이 먼저 알리고 막는다)
        if !Alerts.okCancel("아이폰에서 SSBeacon 앱을 실행해 화면에 띄우세요.\n폰을 PC 가까이 두고, 준비되면 확인을 누르세요.",
                            title: AppController.registerTitle) {
            return
        }
        // 상자가 떠 있는 동안 감시가 시작됐을 수 있다
        if monitoring {
            Alerts.info("먼저 중지를 누른 뒤 등록하세요.\n스캔과 연결이 같은 안테나를 나눠 쓰면 연결이 실패합니다.",
                        title: AppController.registerTitle)
            return
        }
        if bleRegisterBusy || loginBusy || isExiting { return }
        // Windows 는 여기서 모래시계를 띄우고 UI 스레드를 6 초 넘게 막았다. Mac 은 단추만 끄고 기다린다.
        bleRegisterBusy = true
        updateRegisterButton()
        // 완료는 AdvScanner 가 main.async 로 보낸다. onBleRegisterResult 는 알림을 띄우므로 타이머로
        // 한 번 넘겨 GCD 블록 밖에서 부른다 (startLoginWorker 와 같은 이유).
        AdvScanner.shared.registerPhone(scanSec: AppController.registerScanSec) { [weak self] outcome in
            _ = MainTimer.once(after: 0) { self?.onBleRegisterResult(outcome) }
        }
    }

    private func onBleRegisterResult(_ outcome: RegisterOutcome) {
        bleRegisterBusy = false
        updateRegisterButton()
        switch outcome {
        case .success(let token):
            EventLog.write("register phone: OK")
            onRegisteredPhoneToken(token, viaLogin: false)
        case .failure(let why):
            EventLog.write("register phone: \(why)")
            showSimpleForResult()
            Alerts.warning("등록하지 못했습니다.\n\n\(why)\n\n앱이 화면에 떠 있는지, 폰이 PC 가까이 있는지 확인하세요.",
                           title: AppController.registerTitle)
        }
        simple?.refresh()
        if startAfterRegister {
            startAfterRegister = false
            startMon()
            simple?.refresh()
        }
    }

    /// 등록이 끝났다 (BLE 직접 등록 또는 계정). 목록 맨 앞에 "등록된 폰" 이 생기도록 다시 채우고 알린다.
    /// BLE 경로는 여기서 토큰을 저장한다 (계정 경로는 flushAuthSave 가 이미 저장했다). BLE 경로는
    /// 스캐너에 SetIdentity 를 하지 않는다 - 감시가 멈춰 있고 다음 [시작] 이 config 에서 읽는다.
    func onRegisteredPhoneToken(_ token: String, viaLogin: Bool) {
        if !viaLogin {
            var c = ConfigStore.load()
            c.phoneToken = token
            c.phoneOvfBit = -1   // 비트는 잠긴 폰을 처음 탐색할 때 배운다 (직접 읽기 스캔이 읽는다)
            ConfigStore.save(c)
        }
        populateDevices()
        // 토큰을 저장한 뒤라 간단 창의 "내 폰" 줄이 "등록됨" 으로 바뀌어 보인다
        showSimpleForResult()
        let head = Texts.tokenPrefix(token)
        if viaLogin {
            let email = lastLoginEmail.isEmpty ? AccountSession.shared.email : lastLoginEmail
            Alerts.info("폰을 등록했습니다.\n\n계정 \(email)\n기기 토큰 \(head)\n\n"
                        + "이 계정으로 로그인하면 다른 PC 에서도 같은 폰을 알아봅니다.",
                        title: AppController.registerTitle)
        } else {
            Alerts.info("폰을 등록했습니다.\n\n기기 토큰 \(head)\n\n앱 화면에 같은 값이 보이는지 확인하세요.\n"
                        + "이제 Phone Link 설정이나 기기 키 없이도 이 폰을 알아봅니다.",
                        title: AppController.registerTitle)
        }
    }

    private func updateRegisterButton() {
        advanced?.setRegisterButtonEnabled(!loginBusy && !bleRegisterBusy)
    }

    // MARK: - 종료

    /// 오버레이 [종료] (그리고 업데이트 적용). 화면을 지키는 프로그램이 실수로 꺼지면 안 되므로 정상
    /// 종료는 이 길 하나다. 설정 창들의 닫기 단추는 숨기기만 한다.
    func normalExit() {
        if isExiting { return }
        isExiting = true
        runExitSequence()
        NSApp.terminate(nil)
        // terminate 가 돌아오는 일은 없어야 한다 (applicationShouldTerminate 가 .terminateNow).
        // 모달 상자 같은 것 때문에 돌아오더라도 끝낸다.
        exit(0)
    }

    /// applicationShouldTerminate (로그아웃, 시스템 종료, osascript quit): 같은 절차를 돌린 뒤
    /// AppDelegate 가 .terminateNow 를 돌려준다. 로그아웃을 막으면 안 된다.
    func prepareForTermination() {
        isExiting = true
        runExitSequence()
    }

    /// [종료] 의 순서. 판정 스레드를 먼저 멈춘다 (최대 15 초). 스캐너와 GATT 서버, 잠금 창은 Windows 처럼
    /// 프로세스와 함께 사라진다 - 잠금을 "해제" 하지 않으므로 BLACK OFF 줄도 남지 않는다.
    private func runExitSequence() {
        if exitSequenceDone { return }
        exitSequenceDone = true
        if monitoring {
            judge?.stop()
            judge = nil
            monitoring = false
            guardEngine.monitoring = false
        }
        countdownTimer?.invalidate()
        countdownTimer = nil
        inputWatcher?.stop()
        updateTimer?.invalidate()
        updateTimer = nil
        simpleTimer?.invalidate()
        simpleTimer = nil
        // 클립보드 스레드가 그림을 굽는 중일 수 있다 - 먼저 멈춘다
        ClipSync.stop()
        Updater.shutdown()
        // 못 쓴 계정 값이 남아 있으면 나가기 전에 한 번 더 써 본다. 마지막 기회다.
        if authSave.pending && !flushAuthSave() {
            EventLog.write("session: account values still NOT saved at exit - the next start may need a new login")
        }
        authSaveTimer?.invalidate()
        authSaveTimer = nil
        LockScreen.shared.hide()
        overlay?.close()
        overlay = nil
        endMonitoringActivity()
    }
}

// MARK: - 그림 고르기 형식 목록

/// NSOpenPanel 의 형식 고르기. Windows GetOpenFileNameW 의 lpstrFilter 네 줄과 같은 글자, 같은 확장자.
/// "All Files" 를 고르면 아무 파일이나 고를 수 있다 (allowedContentTypes 가 비면 전부 허용).
private final class ImageFilterAccessory: NSObject {
    private static let filters: [(label: String, exts: [String])] = [
        ("Images & Videos (*.png;*.jpg;*.bmp;*.mp4;*.avi;*.wmv;*.mkv;*.mov;*.webm)",
         ["png", "jpg", "jpeg", "bmp", "mp4", "avi", "wmv", "mkv", "mov", "webm"]),
        ("Images (*.png;*.jpg;*.bmp)", ["png", "jpg", "jpeg", "bmp"]),
        ("Videos (*.mp4;*.avi;*.wmv;*.mkv)", ["mp4", "avi", "wmv", "mkv", "mov", "webm"]),
        ("All Files", []),
    ]

    let view: NSView
    private let popup: NSPopUpButton
    private weak var panel: NSOpenPanel?

    init(panel: NSOpenPanel) {
        self.panel = panel
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 44))
        popup = NSPopUpButton(frame: NSRect(x: 20, y: 9, width: 440, height: 26), pullsDown: false)
        super.init()
        for f in ImageFilterAccessory.filters {
            popup.addItem(withTitle: f.label)
        }
        popup.selectItem(at: 0)
        popup.target = self
        popup.action = #selector(filterChanged(_:))
        view.addSubview(popup)
        apply(0)
    }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        apply(sender.indexOfSelectedItem)
    }

    private func apply(_ index: Int) {
        guard let p = panel, index >= 0, index < ImageFilterAccessory.filters.count else { return }
        p.allowedContentTypes = ImageFilterAccessory.filters[index].exts.compactMap {
            UTType(filenameExtension: $0)
        }
    }
}
