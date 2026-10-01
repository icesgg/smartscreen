import Foundation
import Darwin
import SmartScreenCore

// Updater.swift - 프로그램 자동 업데이트의 앱 쪽 (Windows client/update.cpp). 판단(무엇을 받을지,
// 어느 단계로 갈지, 무엇을 적을지)은 SmartScreenCore/UpdateLogic.swift 에 있고, 여기서는 서버에
// 묻고, 파일을 받고, 풀고, 복사본(updater)을 띄운다. 복사본 쪽은 ApplyUpdate.swift.
//
// 흐름 (docs/MAC.md "업데이트는 표를 따로 쓴다"):
//   확인    mac_releases (+ 기업 PC 는 org_mac_release_approvals) 를 anon 키로 읽는다
//   받기    update/SmartScreen-<버전>.zip 으로 흘려 받으며 SHA-256 을 같이 잰다. 크기와 해시가 행과
//           같아야 한다. 맞으면 ditto 로 update/staged-<버전> 에 풀고, 풀린 SmartScreen.app 의 번들
//           id 와 버전이 행과 같은지, 그 앱의 LSMinimumSystemVersion 이 이 macOS 이하인지 본다
//           (Windows 에는 없는 단계 - 파일이 zip 이다). 서버 행의 min_macos 가 더 높은 버전은 확인
//           단계에서 아예 후보가 되지 않는다.
//   적용    자기 실행 파일을 update/updater 로 복사해 `--apply-update` 로 띄우고 정상 종료한다.
//           복사본이 이 프로세스가 끝나기를 기다렸다가 새 앱을 SmartScreen.app 옆의 숨은 자리
//           (.SmartScreen.app.incoming) 에 놓고 확인한 뒤, 한 번에 맞바꾸고 (예전 앱은 .bak) 다시 띄운다.
//
// 실행 중인 exe 는 자기를 덮어쓸 수 없다는 Windows 의 사정은 Mac 에는 없다 (돌고 있는 실행 파일도
// 이름을 바꿀 수 있다). 그래도 같은 구조로 둔다: 묶음은 폴더라서 도는 중에 반쯤 바뀐 앱이 남으면
// 안 되고, 예전 앱이 다 끝난 뒤에 바꿔야 단일 실행 잠금에 걸리지 않는다. 별도 updater 프로그램을
// 만들지 않는 이유도 같다 - 배포를 없애려는 기능이 배포할 것을 늘리면 안 된다.
//
// 화면을 가리는 중에는 다시 시작하지 않는다 (AppController.updateTick 이 Ready 를 보고 정한다).
// 다시 시작하는 1~2초 동안 검은 화면이 사라진다 - 자리를 비운 사람의 화면을 지키는 것이 이
// 프로그램의 일인데, 업데이트가 그 틈을 내면 안 된다.

/// Windows UpdatePhase (숫자는 로그에 찍히므로 같은 번호 - ReleasePhase 와 같다).
enum UpdatePhase: Int {
    case idle = 0, checking, upToDate, pending, available, downloading, ready, applying, failed
}

/// Windows UpdateStatus (UpdateGetStatus 가 돌려주는 복사본).
struct UpdateStatus {
    var phase: UpdatePhase = .idle; var version = ""; var notes = ""; var msg = ""
    var progressPct = 0; var autoApply = false; var dismissed = false; var fromMarker = false
    var checkedTick: UInt64 = 0
}

enum Updater {
    private enum Job { case check, download }

    // 아래 상태는 모두 lock 안에서만 만진다 (Windows s_mx).
    private static let lock = NSLock()
    private static var machine = ReleaseMachine()
    private static var serverUrl = ""          // 비어 있으면 initialize 전 (= 업데이트 꺼짐)
    private static var anonKey = ""
    private static var orgId = ""              // 비어 있으면 개인 PC
    private static var chan = "stable"
    private static var notifyFn: (() -> Void)?
    private static var busyFlag = false        // 일꾼이 하나 돌고 있다 (하나만)
    private static var stopFlag = false
    private static var activeDownload: ZipDownload?

    /// 확인과 내려받기는 이 직렬 큐에서 하나씩 (기업 PC 의 내려받기는 확인 일꾼 안에서 이어서).
    private static let queue = DispatchQueue(label: "com.icesgg.smartscreen.update")
    private static let jobs = DispatchGroup()

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - 공개 함수

    /// 앱을 켤 때 한 번 (updateCheck=1 일 때만). org 가 비어 있으면 개인 PC 로 본다.
    /// 상태가 바뀔 때마다 notify 를 메인 큐에서 부른다.
    static func initialize(url: String, key: String, org: String, channel: String, notify: @escaping () -> Void) {
        // swift run 처럼 묶음(.app) 밖에서 돌면 버전이 0.0.0 이라 서버의 모든 행이 "새 버전" 이고,
        // 바꿀 SmartScreen.app 도 없어서 한 시간마다 같은 실패를 한다. 그런 실행에서는 켜지 않는다.
        if Bundle.main.bundleURL.pathExtension.lowercased() != "app" {
            EventLog.write("update: checks disabled (not running from SmartScreen.app)")
            return
        }
        let ch = UpdateLogic.normalizeChannel(channel)    // 빈 값이나 오타는 stable
        locked { () -> Void in
            serverUrl = url
            anonKey = key
            orgId = org
            chan = ch
            notifyFn = notify
            stopFlag = false
            machine.resetStatus()
        }
    }

    /// initialize 가 불렸는지 (updateCheck=0 이면 안 불린다). UI 가 단추 글을 정하는 데 쓴다.
    static var enabled: Bool {
        return locked { !serverUrl.isEmpty }
    }

    /// 서버에 새 버전이 있는지 묻는다. 일꾼에서 돌고 바로 돌아온다. 기업 PC 에서 승인된 버전을
    /// 찾으면 이어서 내려받기까지 한다. 이미 다른 일이 돌고 있으면 아무 일도 하지 않는다.
    /// 손으로 누른 확인(manual)만 실패를 띠에 띄운다. 한 시간마다 도는 확인이 오프라인이라고 띠를
    /// 띄우면, 닫을 것도 없는 "실패" 가 하루 종일 걸려 있다.
    static func checkAsync(manual: Bool) {
        // 이미 받아 둔 것이 있으면 다시 묻지 않는다 - 곧 적용될 것이다.
        let holds = locked { machine.holdsDownload }
        if holds { return }
        if !startJob(.check, manual: manual) && manual {
            EventLog.write("update: check requested while busy - ignored")
        }
    }

    /// 받을 후보가 정해져 있나 ([다시 시도] 가 "다시 묻기" 와 "다시 받기" 를 가른다).
    static func hasCandidate() -> Bool {
        return locked { machine.hasCandidate }
    }

    /// Available(또는 Failed) 에서 후보를 내려받는다. 이미 검증된 파일이 있으면 다시 받지 않는다.
    /// 그 버전의 실패 기록은 여기서 지운다 - 사용자가 다시 하라고 했다.
    static func downloadAsync() {
        let can = locked { machine.canStartDownload }
        if !can { return }
        // 일이 실제로 시작된 뒤에 기록을 지운다. 배경 확인이 도는 중이면 startJob 이 거절하고,
        // 그때 기록을 지워 두면 다음 확인이 그 버전을 새것처럼 다시 받으러 간다.
        if !startJob(.download, manual: true) { return }
        // 그 사이 배경 확인이 후보를 바꿨을 수 있다 - 지금 후보의 기록을 지운다
        let ver = locked { machine.downloadStarted() }
        Disk.clearMarker(ver)
    }

    /// [나중에]
    static func dismiss() {
        locked { machine.dismiss() }
    }

    /// 일꾼이 돌고 있다
    static func busy() -> Bool {
        return locked { busyFlag }
    }

    static func status() -> UpdateStatus {
        let s = locked { machine.status }
        return UpdateStatus(phase: UpdatePhase(rawValue: s.phase.rawValue) ?? .idle,
                            version: s.version, notes: s.notes, msg: s.msg,
                            progressPct: s.progressPct, autoApply: s.autoApply,
                            dismissed: s.dismissed, fromMarker: s.fromMarker,
                            checkedTick: s.checkedTick)
    }

    /// Ready 에서. 복사본을 띄우고 ok 를 돌려주면 부른 쪽이 앱을 정상 종료해야 한다. 메인 스레드에서
    /// 부른다 - 종료 절차가 메인의 것이다. 실패하면 Failed 로 바꾼다 (띠에 이유가 뜨고 [다시 시도]).
    static func launchApplier() -> (ok: Bool, err: String) {
        let snap = locked { (ready: machine.readyToApply, zip: machine.downloaded, cand: machine.cand) }
        if !snap.ready { return (false, UpdateText.nothingReady) }
        let c = snap.cand

        let bundle = Bundle.main.bundleURL.standardizedFileURL
        // 복사본은 이름이 SmartScreen.app 인 묶음만 바꾼다 (applyMain). 여기서 먼저 보지 않으면 앱은
        // 종료되고 복사본이 거절해서, 사용자에게는 앱이 사라진 것만 보인다. 아래 셋은 다시 켜도 같을
        // 실패라 기록으로 남긴다 - 기업 PC 가 한 시간마다 같은 실패를 조용히 되풀이하지 않게.
        if !UpdateLogic.isAppBundleName(bundle.lastPathComponent) {
            failMarked(c.version, UpdateText.wrongNameApp)
            return (false, UpdateText.wrongNameApp)
        }
        if UpdateLogic.isTranslocated(bundle.path) {
            failMarked(c.version, UpdateText.translocated)
            return (false, UpdateText.translocated)
        }
        // 관리자 암호를 묻지 않는다. 그 창이 대답을 기다리는 동안 앱은 꺼져 있고 화면은 아무도
        // 지키지 않는다 (Windows 가 UAC 를 띄우지 않는 것과 같은 이유). 쓸 수 없는 자리면 옮기라고 한다.
        let parent = bundle.deletingLastPathComponent()
        if access(parent.path, W_OK) != 0 || access(bundle.path, W_OK) != 0 {
            failMarked(c.version, UpdateText.noPermission)
            return (false, UpdateText.noPermission)
        }
        // 받은 zip 은 내려받을 때 풀어서 확인해 뒀다. 그 사이 누가 지웠거나 바뀌었으면 다시 푼다.
        // 다시 푼 것도 안 맞으면 (이 macOS 에서 못 뜨는 앱 포함) 앱을 끄기 전에 여기서 멈춘다.
        if Disk.checkApp(Disk.stagedApp(c.version), ver: c.version) != nil {
            if let why = Disk.stage(zip: URL(fileURLWithPath: snap.zip), ver: c.version) {
                failMarked(c.version, why)
                return (false, why)
            }
        }

        // 지난번 updater 가 아직 끝나지 않았으면 그 파일을 못 바꿀 수 있다. 이름을 바꿔 피한다.
        // 묶음째가 아니라 실행 파일만 복사한다: 묶음이 아니면 번들 id 가 없어서, LaunchServices 가
        // 새 SmartScreen.app 을 띄울 때 이 복사본과 헷갈릴 일이 없다.
        guard let selfExe = Bundle.main.executableURL else {
            let e = UpdateText.updaterCopyFailed(Int(ENOENT))
            fail(e)
            return (false, e)
        }
        let dir = Paths.updateDir
        var updater = dir.appendingPathComponent(UpdateLogic.updaterName, isDirectory: false)
        if Disk.copyExecutable(from: selfExe.path, to: updater.path) != 0 {
            updater = dir.appendingPathComponent("\(UpdateLogic.updaterName)-\(getpid())", isDirectory: false)
            let rc = Disk.copyExecutable(from: selfExe.path, to: updater.path)
            if rc != 0 {
                let e = UpdateText.updaterCopyFailed(Int(rc))
                fail(e)          // Ready 에 갇히지 않게. 파일은 그대로라 [다시 시도] 가 바로 Ready 로 온다
                return (false, e)
            }
        }

        let p = Process()
        p.executableURL = updater
        p.arguments = ApplyArgs.arguments(pid: getpid(), src: Disk.stagedApp(c.version).path,
                                          dst: bundle.path, sha: c.sha256, ver: c.version)
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            let e = UpdateText.updaterLaunchFailed(Disk.errorCode(error))
            fail(e)
            return (false, e)
        }
        // 기다리지 않는다. 복사본은 이 프로세스가 끝나기를 기다리는 쪽이다.
        locked { machine.markApplying() }
        EventLog.write("update: applier launched for \(c.version) (updater pid \(p.processIdentifier))")
        return (true, "")
    }

    /// 새 빌드가 무사히 떴을 때 지난 것들을 치운다: <앱>.bak, 받은 zip, 푼 묶음, updater 복사본,
    /// *.part. 실패 기록(failed-*.txt)은 지우지 않는다 - 실패한 뒤 다시 뜬 예전 앱이 그걸 봐야 한다.
    /// 지금 버전보다 새 버전의 zip/묶음/.bak 은 남긴다 (UpdateLogic.cleanupTarget 의 이유).
    static func cleanupAfterStart() {
        let running = SemVer(BuildInfo.version) ?? SemVer(0, 0, 0)
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        if bundle.pathExtension.lowercased() == "app" {
            let bak = URL(fileURLWithPath: bundle.path + ".bak", isDirectory: true)
            if fm.fileExists(atPath: bak.path)
                && UpdateLogic.shouldRemoveBak(bakVersion: Disk.bundleInfo(bak)?.version, running: running) {
                do {
                    try fm.removeItem(at: bak)
                    EventLog.write("update: removed \(bak.path) (new build started fine)")
                } catch {
                    // 지우지 못했으면 다음에 켤 때 다시 본다
                }
            }
            // 복사본이 새 앱을 먼저 놓는 숨은 자리. 남아 있으면 끊긴 적용의 찌꺼기이거나, 맞바꾼 뒤
            // .bak 으로 못 옮긴 예전 앱이다. 더 새 버전이 들어 있으면 둔다 (shouldRemoveIncoming).
            let incoming = Disk.incomingURL(forApp: bundle)
            if fm.fileExists(atPath: incoming.path)
                && UpdateLogic.shouldRemoveIncoming(version: Disk.bundleInfo(incoming)?.version, running: running) {
                do {
                    try fm.removeItem(at: incoming)
                    EventLog.write("update: removed \(incoming.path) (left over from an update)")
                } catch {
                    // 지우지 못했으면 다음에 켤 때, 또는 다음 적용이 쓰기 전에 다시 지운다
                }
            }
        }
        let dir = Paths.updateDir
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names where UpdateLogic.cleanupTarget(n, running: running) {
            try? fm.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    /// 종료. 일꾼을 5초까지 기다린다.
    static func shutdown() {
        let dl: ZipDownload? = locked { () -> ZipDownload? in
            stopFlag = true
            return activeDownload
        }
        dl?.cancel()
        // 일꾼이 서버 응답을 기다리는 중이면 5초 안에 못 끝날 수 있다. 그때는 그냥 두고 나간다 -
        // 프로세스가 끝나면 같이 끝난다.
        if jobs.wait(timeout: .now() + 5.0) == .timedOut {
            EventLog.write("update: worker did not finish in 5 s - leaving it to process exit")
        }
    }

    // MARK: - 상태 바꾸기

    /// 상태가 바뀌었다고 메인에 알린다 (Windows PostMessage(WM_UPDATE_STATE)).
    private static func notify() {
        guard let fn = locked({ notifyFn }) else { return }
        DispatchQueue.main.async { fn() }
    }

    private static func setPhase(_ p: ReleasePhase, _ msg: String = "", fromMarker: Bool? = nil) {
        locked { machine.setPhase(p, msg: msg, fromMarker: fromMarker) }
        notify()
    }

    private static func fail(_ why: String) {
        EventLog.write("update: FAILED - \(why)")
        setPhase(.failed, why, fromMarker: false)       // 기록에서 온 실패가 아니다
    }

    /// 앱 안에서 난 실패지만 기록으로 남겨야 하는 것 (다시 켜도 같을 실패). 기업 PC 는 한 시간마다
    /// 같은 실패를 조용히 되풀이하게 되므로, 기록이 있어야 띠가 뜨고 사람이 본다.
    private static func failMarked(_ ver: String, _ why: String) {
        EventLog.write("update: FAILED (recorded for \(ver)) - \(why)")
        if !ver.isEmpty { Disk.writeMarker(ver, why) }
        // 지금 난 실패다 - "지난번" 은 다시 켠 뒤 기록을 읽는 확인 쪽의 말이다.
        setPhase(.failed, UpdateText.applyFailedPrefix + why, fromMarker: true)
    }

    // MARK: - 일꾼

    private static func startJob(_ job: Job, manual: Bool) -> Bool {
        let started: Bool = locked { () -> Bool in
            if serverUrl.isEmpty { return false }     // initialize 전
            if busyFlag { return false }              // 하나만
            busyFlag = true
            return true
        }
        if !started { return false }
        jobs.enter()
        queue.async {
            switch job {
            case .check: Updater.checkJob(manual: manual)
            case .download: Updater.downloadJob()
            }
            Updater.locked { () -> Void in Updater.busyFlag = false }
            Updater.jobs.leave()
        }
        return true
    }

    /// 확인이 실패했을 때. 손으로 누른 것이면 띠에 띄우고, 한 시간마다 도는 것이면 로그만 남기고
    /// 보이던 상태를 그대로 둔다.
    private static func checkFailed(_ why: String, manual: Bool, prev: ReleasePhase) {
        if manual {
            fail(why)
            return
        }
        EventLog.write("update: background check failed - \(why) (keeping \(prev.rawValue))")
        locked { machine.keepAfterBackgroundFailure(prev: prev) }
        notify()
    }

    private static func checkJob(manual: Bool) {
        let begin = locked { () -> (prev: ReleasePhase, enterChecking: Bool) in
            let b = machine.beginCheck(manual: manual)
            if b.enterChecking { machine.setPhase(.checking) }
            return b
        }
        if begin.enterChecking { notify() }
        let prev = begin.prev
        let conf = locked { (url: serverUrl, key: anonKey, org: orgId, ch: chan) }
        let running = BuildInfo.version
        let cur = SemVer(running) ?? SemVer(0, 0, 0)
        // 로그인 없이 읽는다 - anon 키가 bearer 이기도 하다.
        let headers = ["apikey": conf.key, "Authorization": "Bearer " + conf.key]

        let r = Http.request("GET", conf.url + UpdateLogic.releasesQuery(channel: conf.ch), headers: headers)
        if !r.ok {
            checkFailed(UpdateText.unreachable, manual: manual, prev: prev)
            return
        }
        if r.status < 200 || r.status >= 300 {
            checkFailed(UpdateLogic.errText(r.body, status: r.status, rest: true), manual: manual, prev: prev)
            return
        }

        // 기업 PC 는 관리자가 승인한 버전만 후보다.
        let enterprise = !conf.org.isEmpty
        var approved = Set<String>()
        if enterprise {
            let a = Http.request("GET", conf.url + UpdateLogic.approvalsQuery(org: conf.org), headers: headers)
            if !a.ok {
                checkFailed(UpdateText.unreachableApprovals, manual: manual, prev: prev)
                return
            }
            if a.status < 200 || a.status >= 300 {
                checkFailed(UpdateText.approvalsPrefix + UpdateLogic.errText(a.body, status: a.status, rest: true),
                            manual: manual, prev: prev)
                return
            }
            approved = UpdateLogic.approvedVersions(a.body)
        }

        let scan = UpdateLogic.scan(r.body, enterprise: enterprise, approved: approved, current: cur,
                                    macOS: ProcessInfo.processInfo.operatingSystemVersion)
        for v in scan.malformed {
            EventLog.write("update: skipping malformed row (version '\(v)')")
        }
        for s in scan.osSkipped {
            EventLog.write(s.logLine)                     // "update: skipping <ver> (needs macOS <x>)"
        }
        // 지난번에 이 버전을 적용하다 실패했나 (더 새 버전에는 기록이 없으니 그대로 진행한다)
        var failedWhy: String? = nil
        if let b = scan.best { failedWhy = Disk.readMarker(b.version) }

        let now = Mono.now()
        locked { machine.adopt(scan, enterprise: enterprise, now: now) }
        let out = UpdateLogic.outcome(scan, failedWhy: failedWhy, enterprise: enterprise, manual: manual,
                                      running: running)
        EventLog.write(out.logLine)
        setPhase(out.phase, out.msg, fromMarker: out.fromMarker)
        if out.downloadNow { downloadJob() }           // 승인됐으면 묻지 않는다 (같은 일꾼에서)
    }

    private static func downloadJob() {
        let snap = locked { (cand: machine.cand, have: machine.downloaded, url: serverUrl, key: anonKey) }
        let c = snap.cand
        if c.version.isEmpty { fail(UpdateText.noVersion); return }
        if c.sha256.utf8.count != 64 { fail(UpdateText.badRowHash); return }

        let file = Disk.zipURL(c.version)

        // updater 를 못 띄워 Failed 가 됐다가 [다시 시도] 로 왔으면 파일은 이미 있다.
        if !snap.have.isEmpty && verifiedFileReady(c, snap.have) {
            EventLog.write("update: \(c.version) already downloaded and verified")
            if let why = Disk.stage(zip: URL(fileURLWithPath: snap.have), ver: c.version) {
                failMarked(c.version, why)
                return
            }
            setPhase(.ready, UpdateText.ready)
            return
        }

        setPhase(.downloading, UpdateText.downloading(c.version))
        EventLog.write("update: downloading \(c.version) (\(c.size) bytes)")

        let dl = ZipDownload(url: snap.url + UpdateLogic.downloadPath(storagePath: c.storagePath),
                             key: snap.key, file: file, expect: c.size,
                             stopRequested: { Updater.locked { Updater.stopFlag } },
                             progress: { pct in
                                 Updater.locked { Updater.machine.setProgress(pct) }
                                 Updater.notify()
                             })
        locked { activeDownload = dl }
        let res = dl.run()
        locked { activeDownload = nil }

        if let err = res.err {
            _ = unlink(file.path)
            fail(err)
            return
        }
        if c.size != 0 && res.got != c.size {
            _ = unlink(file.path)
            fail(UpdateText.sizeMismatch(got: res.got, expect: c.size))
            return
        }
        if res.hex != c.sha256 {
            _ = unlink(file.path)
            // 서버의 파일이 행과 다르다. 전송이 깨졌거나, 누가 파일만 바꿨다. 어느 쪽이든 이 파일은
            // 쓰지 않는다 - 그게 해시가 행에 있는 이유다.
            fail(UpdateText.hashMismatchServer)
            return
        }

        locked { machine.downloaded = file.path }
        EventLog.write("update: \(c.version) verified (\(file.path))")
        // Mac 만: zip 을 풀어 안의 앱이 행이 말한 그 앱인지 지금 본다. 앱을 끈 뒤에야 알게 되면
        // 사용자에게는 앱이 사라졌다 돌아온 것만 보인다. 풀리지 않는 zip 은 다시 받아도 같으므로
        // 기록으로 남긴다 (기업 PC 가 한 시간마다 다시 받지 않게).
        if let why = Disk.stage(zip: file, ver: c.version) {
            failMarked(c.version, why)
            return
        }
        EventLog.write("update: \(c.version) staged (\(Disk.stagedApp(c.version).path))")
        setPhase(.ready, UpdateText.ready)
    }

    /// 이미 검증해 둔 파일이 그대로 있나 (크기와 해시). 있으면 다시 받지 않는다.
    private static func verifiedFileReady(_ c: ReleaseCandidate, _ path: String) -> Bool {
        if path.isEmpty || c.sha256.utf8.count != 64 { return false }
        guard let hex = SHA256Hex.ofFile(URL(fileURLWithPath: path)) else { return false }
        if c.size != 0 {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let n = attrs[.size] as? NSNumber, n.uint64Value == c.size else { return false }
        }
        return hex == c.sha256
    }
}

// MARK: - 앱과 복사본이 같이 쓰는 파일 도구

extension Updater {
    /// update 폴더의 이름들과 묶음 다루기. 복사본(applyMain)은 이 앱의 묶음 밖에서 돌므로
    /// Bundle.main 에 기대지 않는다 - 필요한 것은 모두 경로로 받는다.
    enum Disk {
        static func zipURL(_ ver: String) -> URL {
            return Paths.updateDir.appendingPathComponent(UpdateLogic.zipName(ver), isDirectory: false)
        }

        static func stagedDir(_ ver: String) -> URL {
            return Paths.updateDir.appendingPathComponent(UpdateLogic.stagedDirName(ver), isDirectory: true)
        }

        static func stagedApp(_ ver: String) -> URL {
            return stagedDir(ver).appendingPathComponent(UpdateLogic.appBundleName, isDirectory: true)
        }

        /// 복사본이 새 앱을 먼저 놓는 숨은 자리: app 과 같은 폴더의 .SmartScreen.app.incoming.
        static func incomingURL(forApp app: URL) -> URL {
            return app.deletingLastPathComponent()
                .appendingPathComponent(UpdateLogic.incomingName, isDirectory: true)
        }

        // ---- 실패 기록 ----

        static func markerURL(_ ver: String) -> URL? {
            guard let name = UpdateMarker.fileName(ver) else { return nil }
            return Paths.updateDir.appendingPathComponent(name, isDirectory: false)
        }

        /// 기록이 있으면 그 이유 (빈 글일 수도 있다), 없으면 nil.
        static func readMarker(_ ver: String) -> String? {
            guard let u = markerURL(ver), let d = try? Data(contentsOf: u) else { return nil }
            return UpdateMarker.decode(d)
        }

        static func writeMarker(_ ver: String, _ reason: String) {
            guard let u = markerURL(ver) else { return }
            try? UpdateMarker.encode(reason).write(to: u)
        }

        static func clearMarker(_ ver: String) {
            guard !ver.isEmpty, let u = markerURL(ver) else { return }
            _ = unlink(u.path)
        }

        // ---- 묶음 ----

        /// Contents/Info.plist 를 사전으로 (없거나 못 읽으면 nil).
        private static func infoPlist(_ app: URL) -> [String: Any]? {
            let plist = app.appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist", isDirectory: false)
            guard let data = try? Data(contentsOf: plist),
                  let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            else { return nil }
            return obj as? [String: Any]
        }

        /// Contents/Info.plist 의 번들 id, 버전, 실행 파일 이름.
        static func bundleInfo(_ app: URL) -> (id: String, version: String, executable: String)? {
            guard let dict = infoPlist(app) else { return nil }
            let id = dict["CFBundleIdentifier"] as? String ?? ""
            let ver = dict["CFBundleShortVersionString"] as? String ?? ""
            let exe = dict["CFBundleExecutable"] as? String ?? UpdateLogic.executableName
            if exe.isEmpty || exe.contains("/") || exe == "." || exe == ".." { return nil }
            return (id, ver, exe)
        }

        /// 이 묶음이 행이 말한 그 앱인가: 번들 id 가 우리 것이고, 버전이 정확히 ver 이고, 실행 파일이
        /// 실행할 수 있게 있다.
        static func appMatches(_ app: URL, ver: String) -> Bool {
            guard let info = bundleInfo(app) else { return false }
            if info.id != UpdateLogic.bundleId || info.version != ver { return false }
            let exe = app.appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent(info.executable, isDirectory: false)
            return access(exe.path, X_OK) == 0
        }

        /// 그 앱을 이 Mac 의 macOS 로 띄울 수 있나. 못 띄우면 실패 이유, 되면 nil.
        /// LaunchServices 는 LSMinimumSystemVersion 이 지금 macOS 보다 높은 앱을 열지 않는다. 바꾼 뒤에야
        /// 알면 예전 앱은 .bak 에 있고 새 앱은 안 떠서 아무것도 화면을 지키지 않는다. 서버의 min_macos
        /// 열은 Publish.exe 가 보내지 않아 기본값('13.0') 그대로일 수 있으므로, 묶음 자체를 본다.
        /// 값이 없거나 모양이 틀리면 제약이 없는 것으로 본다 (UpdateLogic.unmetMacOS).
        static func macOSProblem(_ app: URL) -> String? {
            let minimum = infoPlist(app)?["LSMinimumSystemVersion"] as? String
            guard let need = UpdateLogic.unmetMacOS(minimum, running: ProcessInfo.processInfo.operatingSystemVersion)
            else { return nil }
            return UpdateText.needsNewerMacOS(need)
        }

        /// 놓아도 되는 앱인가: 그 버전의 우리 앱이고 (appMatches), 이 macOS 에서 뜬다 (macOSProblem).
        /// 되면 nil, 아니면 실패 기록에 들어갈 이유.
        static func checkApp(_ app: URL, ver: String) -> String? {
            if !appMatches(app, ver: ver) { return UpdateText.appMismatch }
            return macOSProblem(app)
        }

        /// 받은 zip 을 update/staged-<ver> 에 새로 풀고 안의 SmartScreen.app 을 확인한다.
        /// 성공이면 nil, 아니면 실패 이유 (실패 기록에 들어갈 글).
        static func stage(zip: URL, ver: String) -> String? {
            let dir = stagedDir(ver)
            let fm = FileManager.default
            try? fm.removeItem(at: dir)
            // ditto 는 실행 비트, 묶음 안의 심볼릭 링크, 확장 속성을 그대로 푼다. Foundation 에는
            // zip 을 푸는 API 가 없고, unzip 은 확장 속성(__MACOSX)을 따로 된 파일로 풀어 놓는다.
            if !runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], timeout: 300) {
                try? fm.removeItem(at: dir)
                return UpdateText.unzipFailed
            }
            // zip 에는 설치 안내.txt 도 들어 있다 - 앱만 본다.
            let app = stagedApp(ver)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: app.path, isDirectory: &isDir) || !isDir.boolValue {
                try? fm.removeItem(at: dir)
                return UpdateText.noAppInZip
            }
            // 이 macOS 에서 못 뜨는 앱도 여기서 거른다: 앱 쪽은 이 이유를 실패 기록으로 남겨(failMarked)
            // 띠에 보이고, 기업 PC 가 같은 버전을 한 시간마다 다시 받지 않는다.
            if let why = checkApp(app, ver: ver) {
                try? fm.removeItem(at: dir)
                return why
            }
            return nil
        }

        /// 실행 파일을 dst 로 복사한다 (실행 비트 0755). 0 이면 성공, 아니면 errno.
        /// 지난번 복사본이 아직 돌고 있어도 지우는 것은 된다 (돌던 프로세스는 지워진 파일로 계속 돈다).
        /// 새로 쓰는 파일이라 원본에 붙어 있을 수 있는 격리 표시(com.apple.quarantine)는 따라오지 않는다.
        static func copyExecutable(from src: String, to dst: String) -> Int32 {
            if unlink(dst) != 0 {
                let e = errno
                if e != ENOENT { return e }
            }
            let inFd = open(src, O_RDONLY | O_CLOEXEC)
            if inFd < 0 { return errno }
            defer { _ = close(inFd) }
            let outFd = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o755)
            if outFd < 0 { return errno }

            var rc: Int32 = 0
            var buf = [UInt8](repeating: 0, count: 65536)
            copying: while true {
                let n: Int = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                    return read(inFd, raw.baseAddress, raw.count)
                }
                if n == 0 { break }
                if n < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    rc = e
                    break
                }
                var off = 0
                while off < n {
                    let w: Int = buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                        guard let base = raw.baseAddress else { return -1 }
                        return write(outFd, base + off, n - off)
                    }
                    if w < 0 {
                        let e = errno
                        if e == EINTR { continue }
                        rc = e
                        break copying
                    }
                    if w == 0 {
                        rc = EIO
                        break copying
                    }
                    off += w
                }
            }
            // umask 가 실행 비트를 깎았을 수 있다
            if rc == 0 && fchmod(outFd, 0o755) != 0 { rc = errno }
            if close(outFd) != 0 && rc == 0 { rc = errno }
            if rc != 0 { _ = unlink(dst) }
            return rc
        }

        /// 도구(/usr/bin/ditto, xattr, open)를 돌리고 끝나기를 기다린다. 0 으로 끝났으면 true.
        /// 시간을 넘기면 끝내고 false.
        @discardableResult
        static func runTool(_ path: String, _ args: [String], timeout: TimeInterval) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path, isDirectory: false)
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in finished.signal() }
            do {
                try p.run()
            } catch {
                return false
            }
            let limitMs = UInt64(max(1.0, timeout) * 1000.0)
            let start = Mono.now()
            while finished.wait(timeout: .now() + 0.2) == .timedOut {
                if !p.isRunning { break }
                if Mono.now() - start >= limitMs {
                    p.terminate()
                    _ = finished.wait(timeout: .now() + 5.0)
                    return false
                }
            }
            if p.isRunning { return false }
            return p.terminationReason == .exit && p.terminationStatus == 0
        }

        /// 오류의 번호 (POSIX 원인이 있으면 errno, 없으면 NSError 번호) - "(오류 <n>)" 에 쓴다.
        static func errorCode(_ error: Error) -> Int {
            let ns = error as NSError
            if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
                return under.code
            }
            return ns.code
        }
    }
}

// MARK: - 내려받기: 파일로 흘려 쓰면서 SHA-256 을 같이 잰다

/// Windows StreamToFile. Http.download 는 진행률과 중단, 오류 본문을 주지 않으므로 따로 둔다:
/// 사용자가 보는 것은 진행률이고, 해시는 흘려 재는 편이 한 번 덜 읽는다.
///
/// delegate 콜백은 세션의 직렬 큐에서 오고, run() 은 done 을 기다린 뒤에만 값을 읽는다.
private final class ZipDownload: NSObject, URLSessionDataDelegate {
    private let url: String
    private let key: String
    private let file: URL
    private let part: URL
    private let expect: UInt64
    private let stopRequested: () -> Bool
    private let progress: (Int) -> Void
    private let done = DispatchSemaphore(value: 0)
    private let taskLock = NSLock()
    private var task: URLSessionTask?

    // 아래는 delegate 큐에서만 (run() 은 done 뒤에만 읽는다)
    private var decided = false        // 첫 덩이에서 상태 코드를 봤다
    private var status = 0
    private var errorBody = false      // 2xx 가 아니다: 본문은 오류 글이다
    private var errBody = Data()
    private var fd: Int32 = -1
    private var hasher = UpdateHasher()
    private var got: UInt64 = 0
    private var lastPct = -1
    private var err: String?

    init(url: String, key: String, file: URL, expect: UInt64,
         stopRequested: @escaping () -> Bool, progress: @escaping (Int) -> Void) {
        self.url = url
        self.key = key
        self.file = file
        self.part = URL(fileURLWithPath: file.path + ".part", isDirectory: false)
        self.expect = expect
        self.stopRequested = stopRequested
        self.progress = progress
        super.init()
    }

    /// 종료할 때 (다른 스레드에서): 기다리는 덩이를 끊는다.
    func cancel() {
        taskLock.lock()
        let t = task
        taskLock.unlock()
        t?.cancel()
    }

    /// 블로킹. 성공이면 err == nil 이고 파일은 제자리에 있다. 실패면 파일은 남기지 않는다.
    func run() -> (hex: String, got: UInt64, err: String?) {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", u.host != nil else {
            return ("", 0, UpdateText.badAddress)
        }
        // 느린 회선에서 몇 MB 를 받는다. 읽기 제한은 한 덩이 기준이라 30초면 넉넉하다.
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue("SmartScreen/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let t = session.dataTask(with: req)
        taskLock.lock()
        task = t
        taskLock.unlock()
        t.resume()
        // 남은 작업이 끝나면 세션이 스스로 무효가 되고 delegate(self)를 놓는다.
        session.finishTasksAndInvalidate()
        if done.wait(timeout: .now() + 3700.0) == .timedOut {
            t.cancel()
            done.wait()
        }
        taskLock.lock()
        task = nil
        taskLock.unlock()

        if fd >= 0 {
            _ = close(fd)
            fd = -1
        }
        if let e = err {
            _ = unlink(part.path)
            return ("", got, e)
        }
        let hex = hasher.finish()
        _ = unlink(file.path)
        if rename(part.path, file.path) != 0 {
            _ = unlink(part.path)
            return ("", got, UpdateText.renameFailed)
        }
        return (hex, got, nil)
    }

    private func openPart() -> Bool {
        fd = open(part.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        return fd >= 0
    }

    private func writeAll(_ data: Data) -> Bool {
        let outFd = fd
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return raw.count == 0 }
            var off = 0
            while off < raw.count {
                let n = write(outFd, base + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                off += n
            }
            return true
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if err != nil { return }
        if !decided {
            decided = true
            status = (dataTask.response as? HTTPURLResponse)?.statusCode ?? 0
            if status < 200 || status >= 300 {
                errorBody = true
            } else if !openPart() {
                err = UpdateText.cannotCreate
                dataTask.cancel()
                return
            }
        }
        if errorBody {
            // 오류 본문은 이유 한 줄을 고르는 데만 쓴다. 끝없이 모으지 않는다.
            if errBody.count < 65536 { errBody.append(data) }
            return
        }
        if stopRequested() {
            err = UpdateText.aborted
            dataTask.cancel()
            return
        }
        if !writeAll(data) {
            err = UpdateText.diskWrite
            dataTask.cancel()
            return
        }
        hasher.update(data)
        got += UInt64(data.count)
        if let pct = UpdateLogic.progress(got: got, expect: expect, lastPct: lastPct) {
            lastPct = pct
            progress(pct)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if status == 0, let h = task.response as? HTTPURLResponse {
            status = h.statusCode
        }
        if err == nil {
            if let e = error {
                if stopRequested() {
                    err = UpdateText.aborted
                } else if task.response == nil {
                    err = UpdateText.unreachable            // 답을 받기 전에 끊겼다 = 닿지 않았다
                } else if status < 200 || status >= 300 {
                    err = UpdateText.fileFailedPrefix + UpdateLogic.errText(errBody, status: status, rest: false)
                } else {
                    // 읽기가 끊긴 것은 끝난 것이 아니다. 해시 불일치로 보이게 두면 원인을 잘못 짚는다.
                    err = UpdateText.cutOff((e as NSError).code)
                }
            } else if status < 200 || status >= 300 {
                err = UpdateText.fileFailedPrefix + UpdateLogic.errText(errBody, status: status, rest: false)
            } else if !decided {
                // 2xx 인데 본문이 비었다. Windows 처럼 빈 파일을 만들어 둔다 (크기 검사가 걸러 낸다).
                decided = true
                if !openPart() { err = UpdateText.cannotCreate }
            }
        }
        done.signal()
    }
}
