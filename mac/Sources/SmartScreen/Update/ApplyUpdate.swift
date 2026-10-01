import AppKit
import Darwin
import SmartScreenCore

// ApplyUpdate.swift - `SmartScreen --apply-update <pid> <src> <dst> --sha <hex> --ver <버전> [--no-relaunch]`
// (Windows UpdateApplyMain). update/updater 로 복사된 이 앱의 실행 파일이 돌린다.
//
//   pid  끝나기를 기다릴 원래 앱 (0 = 기다리지 않는다, 시험용)
//   src  update/staged-<버전>/SmartScreen.app (앱이 미리 풀어 확인해 둔 것)
//   dst  바꿀 SmartScreen.app (지금 돌던 그 묶음)
//   --sha  받은 zip(update/SmartScreen-<버전>.zip) 의 SHA-256 - 바꾸기 직전에 한 번 더 잰다
//
// 단일 실행 잠금보다 먼저 처리해야 한다 (원래 앱이 아직 살아 있을 때 시작된다). 묶음 밖의 실행
// 파일로 돌므로 Bundle.main 은 쓸모가 없다 - 필요한 것은 모두 명령줄로 받는다. 돌려주는 값이
// 프로세스 종료 코드다.
//
// 아무 묶음이나 바꾸는 도구가 되지 않도록 세 가지를 요구한다: src 는 update 폴더의
// staged-<버전>/SmartScreen.app 그 자리, dst 의 이름은 SmartScreen.app, 그리고 zip 의 해시가 --sha 와
// 같아야 한다. zip 은 해시를 잰 직후 그 zip 에서 다시 풀어 놓는다 - update 폴더에 놓여 있던 사이에
// 풀린 묶음이 바뀌었어도, 놓이는 것은 방금 잰 바이트에서 나온 것이다.
//
// 놓는 순서 (dst 에는 언제나 온전한 앱이 있게): 푼 앱 → dst 옆의 숨은 .SmartScreen.app.incoming
// (같은 볼륨이면 이름 바꾸기, 아니면 ditto) → 그 자리에서 검사 (버전·번들 id, 이 macOS 에서 뜨는지)
// → renamex_np(RENAME_SWAP) 로 dst 와 맞바꾸기 → 예전 앱(이제 incoming 자리)을 .bak 으로.

extension Updater {
    /// `--apply-update ...` 진입점. args 는 CommandLine.arguments 그대로여도, "--apply-update" 뒤의
    /// 부분만이어도 된다.
    static func applyMain(_ args: [String]) -> Int32 {
        guard let a = ApplyArgs.parse(args) else { return 2 }

        // 원래 앱이 끝나면서 이 프로세스를 데려가지 않게: 자기 세션을 만들고, 끊김 신호를 무시한다.
        // 맞바꾸기(RENAME_SWAP)가 없는 볼륨에서는 두 번의 이름 바꾸기 사이에 끝나면 그 자리에 앱이 없다.
        _ = setsid()
        _ = signal(SIGHUP, SIG_IGN)
        _ = signal(SIGTERM, SIG_IGN)
        _ = signal(SIGPIPE, SIG_IGN)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated],
                                                             reason: "SmartScreen update")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let dst = URL(fileURLWithPath: a.dst).standardizedFileURL
        let ver = a.ver
        EventLog.write("update: applier start (pid \(a.pid), ver \(ver)) \(a.src) -> \(dst.path)")

        // 무엇을 하든 - 실패해서 예전 앱을 다시 띄우는 것까지 - 원래 프로세스가 끝난 뒤에 한다.
        // 살아 있는데 다시 띄우면 새 인스턴스가 단일 실행 잠금에 걸려 "이미 실행 중" 으로 끝나고,
        // 원래 것까지 끝나면 아무것도 남지 않는다. 정상 종료가 BLE 정리와 클립보드 일꾼을 기다리므로
        // 넉넉히 준다. 그래도 안 끝나면 종료 절차가 멎은 것이다 - 끝내고 진행한다.
        if a.pid != 0 {
            if kill(a.pid, 0) != 0 && errno == EPERM {
                // 있는데 우리 것이 아니다 = 끝났는지 확인할 길이 없다. 확인 못 한 채 바꾸면 위와 같은
                // 일이 난다. 물러난다 (아무것도 띄우지 않는다).
                EventLog.write("update: cannot open old process \(a.pid) (error \(EPERM)) - giving up")
                if !ver.isEmpty { Disk.writeMarker(ver, UpdateText.cannotConfirmExit) }
                return 1
            }
            // 그 번호가 이미 다른 프로그램의 것이면 원래 앱은 끝났고 번호만 다시 쓰인 것이다.
            var gone = !Applier.isOurApp(a.pid) || Applier.waitGone(a.pid, ms: 120_000)
            if !gone {
                EventLog.write("update: old process \(a.pid) still alive after 120 s - terminating it")
                // Windows 는 열어 둔 핸들이 pid 를 붙잡아 다른 프로세스가 그 번호를 쓸 수 없다.
                // 여기는 그런 것이 없으므로, 죽이기 전에 그 번호가 아직 SmartScreen 인지 본다.
                // 다른 프로그램이면 원래 앱은 이미 끝났고 번호만 다시 쓰인 것이다.
                if Applier.isOurApp(a.pid) {
                    _ = kill(a.pid, SIGKILL)
                    gone = Applier.waitGone(a.pid, ms: 10_000)
                } else {
                    gone = true
                }
            }
            if !gone {
                // 끝내지도 못했다. 다시 띄우면 잠금에 걸린다. 원래 앱은 아직 돌고 있으니 사용자에게
                // 앱은 있다 - 기록만 남기고 물러난다.
                EventLog.write("update: old process \(a.pid) would not exit - giving up")
                if !ver.isEmpty { Disk.writeMarker(ver, UpdateText.wouldNotExit) }
                return 1
            }
        }

        // 아래의 거절들은 dst 를 건드리지 않았으므로 예전 앱을 다시 띄우는 것이 안전하다 - 조용히
        // 끝내면 앱이 사라진 채로 남는다.
        if SemVer(ver) == nil || a.src.contains("..")
            || URL(fileURLWithPath: a.src).standardizedFileURL.path != Disk.stagedApp(ver).standardizedFileURL.path {
            return Applier.applyFailed(ver, UpdateText.badSourcePlace, dst: dst, relaunch: a.relaunch)
        }
        if !UpdateLogic.isAppBundleName(dst.lastPathComponent) {
            return Applier.applyFailed(ver, UpdateText.wrongNameApplier, dst: dst, relaunch: a.relaunch)
        }
        if UpdateLogic.isTranslocated(dst.path) {
            return Applier.applyFailed(ver, UpdateText.translocated, dst: dst, relaunch: a.relaunch)
        }
        if a.sha.utf8.count != 64 {
            return Applier.applyFailed(ver, UpdateText.noExpectedHash, dst: dst, relaunch: a.relaunch)
        }

        // 내려받은 파일이 지금도 행의 해시와 같은지 (두 번째 측정). 받은 뒤 update 폴더에 놓여 있는
        // 사이에 바뀌었으면 여기서 걸린다.
        let zip = Disk.zipURL(ver)
        guard let have = SHA256Hex.ofFile(zip) else {
            return Applier.applyFailed(ver, UpdateText.cannotReadDownload, dst: dst, relaunch: a.relaunch)
        }
        if have != a.sha {
            return Applier.applyFailed(ver, UpdateText.hashMismatchRecord, dst: dst, relaunch: a.relaunch)
        }
        if let why = Disk.stage(zip: zip, ver: ver) {
            return Applier.applyFailed(ver, why, dst: dst, relaunch: a.relaunch)
        }
        let staged = Disk.stagedApp(ver)
        EventLog.write("update: applier staged \(zip.path) -> \(staged.path)")

        // 1) 새 앱을 먼저 dst 옆의 숨은 자리(<폴더>/.SmartScreen.app.incoming)에 놓는다. dst 와 같은
        // 볼륨이라 아래의 바꾸기는 언제나 이름 바꾸기다. update 폴더와 앱이 다른 볼륨이면 여기서 복사가
        // 일어나는데, 그동안 dst 는 손대지 않은 예전 앱 그대로다. (예전에는 .bak 으로 옮긴 뒤 dst 로 바로
        // 복사해서, 그 몇 초 사이에 로그아웃이나 전원이 끊기면 dst 에 앱이 없거나 반쯤 복사된 앱이
        // 남았다 - SIGTERM 을 무시해도 launchd 는 SIGKILL 로 끝낸다.)
        let fm = FileManager.default
        let incoming = Disk.incomingURL(forApp: dst)
        let bak = URL(fileURLWithPath: dst.path + ".bak", isDirectory: true)
        try? fm.removeItem(at: incoming)          // 지난번에 끊긴 적용이 남긴 것
        if rename(staged.path, incoming.path) != 0 {
            let e = errno
            if e != EXDEV {
                return Applier.applyFailed(ver, Applier.permissionText(e) ?? UpdateText.placeFailed(Int(e)),
                                           dst: dst, relaunch: a.relaunch)
            }
            // 다른 볼륨: ditto 로 복사한다 (묶음 안의 링크·실행 비트·확장 속성을 그대로).
            if !Disk.runTool("/usr/bin/ditto", [staged.path, incoming.path], timeout: 300) {
                try? fm.removeItem(at: incoming)
                // ditto 는 errno 를 주지 않는다. 가장 흔한 이유(폴더에 쓸 수 없다)만 가려 말하고, 나머지는
                // 복사로 가게 만든 오류(EXDEV)의 번호를 적는다.
                let why = access(dst.deletingLastPathComponent().path, W_OK) != 0
                    ? UpdateText.noPermission : UpdateText.placeFailed(Int(EXDEV))
                return Applier.applyFailed(ver, why, dst: dst, relaunch: a.relaunch)
            }
        }

        // 격리 표시가 붙어 있으면 Gatekeeper 가 새 앱을 처음 받은 앱처럼 막는다. URLSession 이 받은
        // 파일에는 보통 붙지 않지만, 붙어 있으면 지운다 (실패해도 상관없다). dst 에 놓기 전에 한다.
        Disk.runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", incoming.path], timeout: 60)

        // 2) 놓인 자리에서 다시 본다 (바꾸기 직전의 검사): 그 버전의 우리 앱이고, 이 macOS 에서 뜨는가.
        // 여기서 걸리면 dst 는 아직 손대지 않았다.
        if !Disk.appMatches(incoming, ver: ver) {
            try? fm.removeItem(at: incoming)
            return Applier.applyFailed(ver, UpdateText.placedButDiffers, dst: dst, relaunch: a.relaunch)
        }
        if let why = Disk.macOSProblem(incoming) {
            try? fm.removeItem(at: incoming)
            return Applier.applyFailed(ver, why, dst: dst, relaunch: a.relaunch)
        }

        // 3) 바꾼다. APFS 는 renamex_np(RENAME_SWAP) 로 두 이름을 한 번에 맞바꾼다 - dst 에는 언제나
        // 온전한 앱이 있다 (그 전엔 예전 앱, 그 뒤엔 새 앱). 그러면 incoming 자리에 예전 앱이 오고, 그걸
        // .bak 으로 옮긴다. 맞바꾸기가 없는 볼륨(HFS+, exFAT, 네트워크 - ENOTSUP/EINVAL)에서는 Windows 와
        // 같은 두 번의 이름 바꾸기다: dst → .bak, incoming → dst (같은 볼륨이라 그 틈은 아주 짧다).
        // .bak 은 묶음 확장자가 아니라서 LaunchServices 와 Spotlight 가 앱으로 보지 않는다.
        try? fm.removeItem(at: bak)
        var useSwap = true
        var oldMoved = false          // 예전 앱이 dst 에서 비켜났다 (맞바꾸기면 incoming 으로, 아니면 .bak 으로)
        var lastErr: Int32 = 0
        for _ in 0..<20 {
            if useSwap {
                if renamex_np(incoming.path, dst.path, UInt32(RENAME_SWAP)) == 0 {
                    oldMoved = true
                    break
                }
                lastErr = errno
                if lastErr == ENOTSUP || lastErr == EINVAL {
                    EventLog.write("update: RENAME_SWAP not supported here (error \(lastErr)) - using two renames")
                    useSwap = false
                    continue              // 기다리지 않고 바로 두 번의 이름 바꾸기로
                }
            } else {
                if rename(dst.path, bak.path) == 0 {
                    oldMoved = true
                    break
                }
                lastErr = errno
            }
            // 권한 문제는 기다려도 안 풀린다
            if lastErr == EACCES || lastErr == EPERM || lastErr == EROFS { break }
            usleep(500_000)       // 프로세스가 끝난 직후 잠깐 잡혀 있을 수 있다
        }
        if !oldMoved {
            // dst 는 그대로 예전 앱이다
            try? fm.removeItem(at: incoming)
            return Applier.applyFailed(ver, Applier.permissionText(lastErr) ?? UpdateText.moveOldFailed(Int(lastErr)),
                                       dst: dst, relaunch: a.relaunch)
        }

        let swapped = useSwap         // 여기까지 왔으면 true = 맞바꾸기로 놓았다
        var oldAt = bak               // 예전 앱이 지금 있는 곳 (되돌릴 때 쓴다)
        var placed = false
        var placeErr: Int32 = 0
        if swapped {
            // dst = 새 앱, incoming = 예전 앱
            placed = true
            if rename(incoming.path, bak.path) != 0 {
                // .bak 자리를 비우지 못했거나 해서 옮기지 못했다. 예전 앱은 숨은 자리에 그대로 두고
                // (새 빌드가 뜨면 cleanupAfterStart 가 치운다), 되돌리기는 그 자리에서 한다.
                let e = errno
                EventLog.write("update: old app left at \(incoming.path) (error \(e))")
                oldAt = incoming
            }
        } else if rename(incoming.path, dst.path) == 0 {
            placed = true
        } else {
            placeErr = errno
        }

        // Windows 는 놓은 파일의 해시를 다시 잰다. 여기서는 놓인 묶음이 그 버전의 우리 앱인지 본다.
        let same = placed && Disk.appMatches(dst, ver: ver)
        if !same {
            // 되돌린다. 맞바꿨으면 다시 맞바꾼다 (그 사이에도 dst 에 앱이 있다). 안 되면, 또는 두 번의
            // 이름 바꾸기로 놓았으면 Windows 처럼 지우고 옮긴다. 방금 놓은 새 묶음이나 .bak 을
            // Spotlight·백업이 잠깐 잡고 있을 수 있어 둘 다 되풀이한다.
            var restored = false
            for _ in 0..<20 {
                if swapped && renamex_np(oldAt.path, dst.path, UInt32(RENAME_SWAP)) == 0 {
                    try? fm.removeItem(at: oldAt)         // 이제 여기엔 방금 놓은 틀린 새 앱이 있다
                    restored = true
                    break
                }
                try? fm.removeItem(at: dst)
                if rename(oldAt.path, dst.path) == 0 {
                    restored = true
                    break
                }
                usleep(500_000)
            }
            // 두 번의 이름 바꾸기에서 incoming → dst 가 안 됐으면 새 앱이 숨은 자리에 남아 있다
            if !swapped { try? fm.removeItem(at: incoming) }
            let b = placed ? UpdateText.placedButDiffers : UpdateText.placeFailed(Int(placeErr))
            if !restored {
                // 가장 나쁜 경우: 제대로 된 앱이 없다. 이건 대화상자로 말해야 한다.
                EventLog.write("update: apply FAILED and rollback FAILED - \(b)")
                if oldAt.path != bak.path {
                    EventLog.write("update: the old app is at \(oldAt.path)")
                }
                Disk.writeMarker(ver, b)
                Applier.alert(UpdateText.rollbackFailedDialog(reason: b, folder: dst.deletingLastPathComponent().path))
                return 1
            }
            return Applier.applyFailed(ver, b, dst: dst, relaunch: a.relaunch)
        }

        try? fm.removeItem(at: zip)
        try? fm.removeItem(at: Disk.stagedDir(ver))
        Disk.clearMarker(ver)
        EventLog.write("update: applied \(ver) -> \(dst.path) (old kept as .bak until the new build starts)")
        if a.relaunch && !Applier.launch(dst) {
            Applier.alert(UpdateText.relaunchNewFailedDialog(app: dst.path))
            return 1
        }
        return 0
    }
}

/// 복사본만 쓰는 도구들.
private enum Applier {
    /// 적용 실패의 마무리: 기록을 남기고 예전 앱을 다시 띄운다. 대화상자는 예전 앱을 못 띄웠을 때만 -
    /// 띄웠으면 그 앱의 띠가 기록을 읽어 이유를 보여 준다. 대화상자를 먼저 띄우면 누가 확인을 누를
    /// 때까지 앱이 꺼진 채라 화면을 아무도 지키지 않는다.
    static func applyFailed(_ ver: String, _ why: String, dst: URL, relaunch: Bool) -> Int32 {
        EventLog.write("update: apply FAILED - \(why)")
        if !ver.isEmpty { Updater.Disk.writeMarker(ver, why) }
        if relaunch && !launch(dst) {
            alert(UpdateText.relaunchOldFailedDialog(reason: why, app: dst.path))
        }
        return 1
    }

    /// 앱 폴더를 고치지 못한 오류 번호를 사람이 할 일로: EACCES/EROFS = 쓸 권한이 없는 자리 (읽기 전용
    /// 볼륨, 디스크 이미지 포함), EPERM = macOS 13+ 의 "앱 관리" 보호. 다른 번호면 nil.
    static func permissionText(_ e: Int32) -> String? {
        if e == EACCES || e == EROFS { return UpdateText.noPermission }
        if e == EPERM { return UpdateText.appManagement }
        return nil
    }

    /// LaunchServices 로 띄운다 (/usr/bin/open): 새 Info.plist 를 읽고, 이 복사본과 떨어진 프로세스로
    /// 뜬다. -n = 같은 번들 id 의 앱이 아직 등록돼 있어도 새로 띄운다.
    static func launch(_ app: URL) -> Bool {
        // 묶음(.app)이 아니면 띄울 것이 없다 - open 은 그 자리의 파일을 문서처럼 열어 버린다.
        if app.pathExtension.lowercased() != "app" { return false }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: app.path, isDirectory: &isDir) || !isDir.boolValue {
            return false
        }
        return Updater.Disk.runTool("/usr/bin/open", ["-n", app.path], timeout: 60)
    }

    /// 오류 대화상자 (Windows MessageBox MB_ICONERROR). 이 프로세스는 NSApplication 을 돌리지 않으므로
    /// 여기서 처음 만든다.
    static func alert(_ text: String) {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let al = NSAlert()
        al.alertStyle = .critical
        al.messageText = UpdateText.dialogTitle
        al.informativeText = text
        al.addButton(withTitle: "확인")
        _ = al.runModal()
    }

    /// pid 가 끝났는가. 좀비(부모가 거두기 전 잠깐 남는 껍데기)도 끝난 것이다.
    static func isGone(_ pid: Int32) -> Bool {
        if kill(pid, 0) != 0 {
            return errno == ESRCH
        }
        guard let k = procInfo(pid) else {
            // 그 사이에 끝났거나 sysctl 이 실패했다. kill 로 다시 본다 (모르면 살아 있다고 본다).
            return kill(pid, 0) != 0 && errno == ESRCH
        }
        return k.kp_proc.p_stat == 5        // SZOMB
    }

    /// ms 동안 100 ms 마다 본다. 끝났으면 true.
    static func waitGone(_ pid: Int32, ms: UInt64) -> Bool {
        let start = Mono.now()
        while true {
            if isGone(pid) { return true }
            if Mono.now() - start >= ms { return false }
            usleep(100_000)
        }
    }

    /// 그 pid 가 아직 SmartScreen 인가 (프로세스 이름 p_comm). 알 수 없으면 그렇다고 본다 - 그래야
    /// 멎은 원래 앱을 끝낼 수 있다.
    static func isOurApp(_ pid: Int32) -> Bool {
        guard let k = procInfo(pid) else { return true }
        var comm = k.kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { (raw: UnsafeRawBufferPointer) -> String in
            return String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if name.isEmpty { return true }
        return name == UpdateLogic.executableName
    }

    /// sysctl(KERN_PROC_PID). 그런 프로세스가 없거나 읽지 못하면 nil.
    private static func procInfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) != 0 { return nil }
        if size == 0 { return nil }
        return info
    }
}
