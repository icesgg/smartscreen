import AppKit
import SmartScreenCore

// main.swift - 진입점 (Windows wWinMain).
//
// 순서:
//  1. 보조 모드: argv[1] 만 정확히(대소문자 구분) 본다. 한 번만 하고 끝나는 일이라 창을 만들지 않는다.
//     단일 실행 잠금보다 먼저다 - 본 프로그램이 떠 있는 채로 돌려 봐야 쓸모가 있다 (적용기는 원래
//     프로세스가 아직 살아 있을 때 시작된다).
//  2. 단일 실행 잠금 (10 초까지 기다린다)
//  3. NSApplication: .accessory (Dock 아이콘 없음 - Windows 의 "작업 표시줄 없음, 트레이 없음"),
//     AppDelegate, 보이지 않는 편집 메뉴. 나머지는 applicationDidFinishLaunching → AppController.launch.

/// Finder/Xcode 가 붙이는 인자(-psn_..., -NSDocumentRevisionsDebugMode YES 같은 -NS... 와 그 값)를 뺀
/// 명령줄. 0 번은 실행 파일 경로 그대로다.
private func ssFilteredArguments() -> [String] {
    let raw = CommandLine.arguments
    var out: [String] = []
    var i = 0
    while i < raw.count {
        let a = raw[i]
        if i > 0 && a.hasPrefix("-psn_") {
            i += 1
            continue
        }
        if i > 0 && a.hasPrefix("-NS") {
            // "-NSKey value" 짝이면 값도 버린다
            if i + 1 < raw.count && !raw[i + 1].hasPrefix("-") { i += 1 }
            i += 1
            continue
        }
        out.append(a)
        i += 1
    }
    return out
}

private func ssWriteStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

/// --clip-test 의 결과를 일꾼과 메인 사이에서 넘기는 상자. 메인 스레드에서만 만진다.
private final class SSClipTestBox {
    var report = ""
    var ok = false
    var done = false
}

/// --clip-test: 클립보드 왕복 진단. 세션을 살리고, 올리고 받아 보고, 결과를 파일과 상자로 보인다.
/// 파일로도 남기는 이유: 창에 뜬 글자를 손으로 옮겨 적게 만들면 아무도 그러지 않고, 실패한 줄의
/// 상태코드가 그대로 사라진다.
private func ssRunClipTest() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // 네트워크는 일꾼에서 돌리고 메인 런 루프는 돌려 둔다 (Http 는 메인에서 부르지 않는다는 약속)
    let box = SSClipTestBox()
    let worker = Thread {
        let c = ConfigStore.load()
        let url = ServerDefaults.url(c)
        let key = ServerDefaults.key(c)
        var rep = ""
        var good = false
        let s = AccountSession.shared.start(url: url, key: key, sealed: c.authRefresh)
        if !s.err.isEmpty {
            rep = "[X] 세션: \(s.err)\n"
        } else {
            good = ClipSync.roundTrip(url: url, key: key, report: &rep)
        }
        let finalReport = rep
        let finalOk = good
        DispatchQueue.main.async {
            box.report = finalReport
            box.ok = finalOk
            box.done = true
        }
    }
    worker.start()
    while !box.done {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }

    var report = box.report
    let file = Paths.configDir.appendingPathComponent("clip-test.txt", isDirectory: false)
    // Windows 는 ccs=UTF-8 로 써서 BOM 이 붙는다. 같은 모양으로 남긴다.
    var data = Data([0xEF, 0xBB, 0xBF])
    data.append(Data(report.utf8))
    if (try? data.write(to: file, options: .atomic)) != nil {
        report += "\n이 내용을 파일로도 적어 두었습니다:\n\(file.path)\n"
    }
    if box.ok {
        Alerts.info(report, title: "클립보드 왕복 진단")
    } else {
        Alerts.warning(report, title: "클립보드 왕복 진단")
    }
    return box.ok ? 0 : 1
}

// ---- 1. 보조 모드 ----
private let ssArgs = ssFilteredArguments()

if ssArgs.count >= 2 {
    switch ssArgs[1] {
    case "--version":
        // build_app.sh 가 이 줄(마지막 줄)을 그대로 읽어 버전을 맞춰 본다. 창을 띄우지 않고 끝난다.
        print("SmartScreen \(BuildInfo.version)")
        exit(0)
    case "--apply-update":
        // Windows 처럼 인자가 모자라면(<pid> <src> <dst> 가 없으면) 보조 모드가 아니라 보통 시작이다.
        // 넘기는 것은 걸러낸 명령줄 전체다 ([0] 실행 파일, [1] "--apply-update", [2] pid ...).
        if ssArgs.count >= 5 {
            exit(Updater.applyMain(ssArgs))
        }
    case "--clip-test":
        exit(ssRunClipTest())
    case "--probe-scan":
        exit(BLEDiagnostics.probeScan(args: ssArgs))
    case "--adv-scan":
        exit(BLEDiagnostics.advScan(args: ssArgs))
    case "--bt-check":
        exit(BLEDiagnostics.btCheck(args: ssArgs))
    case "--dump-irk", "--import-irk":
        // IRK 는 CoreBluetooth 로는 얻을 수 없다 (주소도 본딩 키도 내주지 않는다). Mac 은 토큰만 쓴다.
        ssWriteStderr("Mac 에서는 쓰지 않습니다\n")
        exit(1)
    default:
        break
    }
}

// ---- 2. 단일 실행 ----
private let ssApp = NSApplication.shared
ssApp.setActivationPolicy(.accessory)
SingleInstance.acquireOrExit()

// ---- 3. 앱 ----
// delegate 는 약한 참조라 여기 전역에 붙잡아 둔다
private let ssDelegate = AppDelegate()
ssApp.delegate = ssDelegate
MainMenu.install()
ssApp.run()
