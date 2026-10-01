import Foundation
import CoreBluetooth
import SmartScreenCore

/// 진단용 명령줄 모드 (Windows 의 tools/ProbeScan.exe, AdvScan.exe, BtCheck.exe 자리).
///
///   SmartScreen --probe-scan [초=20] [identifier]   잠긴 아이폰에서 신원 토큰을 읽을 수 있는지
///   SmartScreen --adv-scan [초=30]                  다른 PC 의 SmartScreen 광고가 잡히는지
///   SmartScreen --bt-check                          이 Mac 의 블루투스 역할 지원
///
/// NSApplication 없이 돈다. CoreBluetooth 는 메인 큐(queue: nil)로 콜백을 주고, 여기서는
/// RunLoop.main 을 직접 돌리며 기다린다 - 그래서 코드를 위에서 아래로 차례대로 쓸 수 있다.
/// Windows 도구의 한국어 출력을 그대로 쓰되, Mac 에 없는 것(페어링 상태, GattSession,
/// "아무 키나 누르세요")은 뺐다. 터미널 창은 저절로 닫히지 않는다.
enum BLEDiagnostics {

    // MARK: - --probe-scan

    /// --probe-scan [sec] [identifier]
    /// 배경: 잠긴 아이폰의 광고에는 이름도 서비스 UUID 도 실리지 않고 바뀌는 주소만 남는다.
    /// PC 가 central 로 붙어 토큰 특성을 읽으면 IRK 없이 신원이 확정된다 - 그게 되는지를 본다.
    /// Mac 에서는 특히 "macOS 의 필터 스캔이 overflow 영역의 UUID 를 맞춰 주는가" 를 가른다
    /// (잠긴 폰이 후보로 나오고 토큰을 읽으면 된다).
    static func probeScan(args: [String]) -> Int32 {
        let ops = operands(args, flag: "--probe-scan")
        var seconds = ops.count > 0 ? ConfigStore.wtoi(ops[0]) : 20
        if seconds < 5 { seconds = 5 }
        let only = ops.count > 1 ? ops[1].uppercased() : ""

        emit("아이폰 신원 토큰 읽기 확인")
        emit("=====================================")
        emit("찾는 서비스: {\(BLEIds.identService.uuidString)}")
        emit("읽을 특성  : {\(BLEIds.identToken.uuidString)}\n")
        emit("아이폰에서 SSBeacon 을 실행한 뒤 화면을 끄고 잠근 상태로 두세요.")
        emit("이 PC 와 아이폰이 페어링되어 있지 않아야 실제 배포 상황과 같습니다.\n")

        let d = DiagCentral()
        if !waitPoweredOn(d) {
            emitCentralFailure(d)
            return 1
        }

        var list: [DiagCand] = []
        var needScan = true
        if !only.isEmpty {
            // 식별자(전체 UUID 또는 로그에 찍힌 앞 12자리)를 주면 그 기기만 찔러 본다.
            emit("주소 \(only) 만 확인합니다.")
            if let u = UUID(uuidString: only),
               let p = d.manager.retrievePeripherals(withIdentifiers: [u]).first {
                list = [DiagCand(peripheral: p, rssi: -127, plain: false, overflow: false, name: "")]
                needScan = false
            }
        }
        if needScan {
            emit("\(seconds)초 동안 후보를 찾습니다...")
            var found: [UUID: DiagCand] = [:]
            d.onDiscover = { p, adv, rssi in
                let plain = ((adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])
                    .contains(BLEIds.identService)
                let overflow = ((adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? [])
                    .contains(BLEIds.identService)
                // 우리 서비스를 대놓고 광고했거나(포그라운드), overflow 영역에 실은 기기만 후보다.
                if !plain && !overflow { return }
                if !only.isEmpty && !BLEDiagnostics.matchesFilter(p.identifier, only) { return }
                let r = BLEIds.validRssi(rssi) ? rssi : -127
                let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? ""
                if var c = found[p.identifier] {
                    c.plain = c.plain || plain
                    c.overflow = c.overflow || overflow
                    if c.name.isEmpty { c.name = name }
                    if r > c.rssi { c.rssi = r }
                    found[p.identifier] = c
                } else {
                    found[p.identifier] = DiagCand(peripheral: p, rssi: r, plain: plain,
                                                   overflow: overflow, name: name)
                }
            }
            // 잠긴 폰의 UUID 는 이 UUID 를 명시해서 찾는 스캐너에게만 보인다
            d.manager.scanForPeripherals(withServices: [BLEIds.identService],
                                         options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            _ = spin(Double(seconds)) { false }
            d.manager.stopScan()
            d.onDiscover = nil
            // 가까운 것부터 - 멀리 있는 남의 폰은 어차피 자리 판정에 쓸모가 없다
            list = found.values.sorted { $0.rssi > $1.rssi }
        }

        emit("\n후보 \(list.count)대")
        if list.isEmpty {
            emit("\n결과: 후보가 없습니다.")
            emit("      아이폰에서 SSBeacon 이 실제로 광고 중인지 확인하세요.")
            emit("      (앱을 켠 채 화면을 끄면 잠금 상태에서도 광고가 이어져야 합니다)")
            emit("-------------------------------------")
            return 0
        }

        var discovered = 0
        var tokens = 0
        for c in list {
            let r = probe(d, c)
            if r >= 1 { discovered += 1 }
            if r == 2 { tokens += 1 }
        }

        emit("\n=====================================")
        emit("후보 \(list.count)대 중 서비스 탐색 성공 \(discovered)대, 토큰 읽기 성공 \(tokens)대")
        if tokens > 0 {
            emit("\n결과: 잠긴 폰에서 신원 토큰을 읽었습니다.")
            emit("      IRK 도 Phone Link 도 없이 폰을 특정할 수 있습니다.")
        } else if discovered > 0 {
            emit("\n결과: 연결과 서비스 탐색은 되는데 신원 서비스가 안 보입니다.")
            emit("      아이폰 앱이 신원 서비스를 올리는 버전인지 확인하세요.")
            emit("      (앱을 지웠다 다시 설치한 뒤 한 번 실행해야 반영됩니다)")
        } else {
            emit("\n결과: 붙지 못했습니다.")
            emit("      AccessDenied 면 macOS 가 페어링을 요구하는 것입니다.")
            emit("      전부 Unreachable 이면 폰이 아니라 이 PC 의 어댑터가")
            emit("      직전 연결을 아직 물고 있는 경우가 많습니다. 1~2분 두었다")
            emit("      다시 실행해 보세요.")
        }
        emit("=====================================")
        return 0
    }

    /// 한 후보에 실제로 붙어서 서비스 목록을 받고, 우리 서비스가 있으면 토큰까지 읽는다.
    /// 0 = 실패, 1 = 서비스 탐색 성공, 2 = 토큰 읽음.
    private static func probe(_ d: DiagCentral, _ c: DiagCand) -> Int {
        let p = c.peripheral
        emit("\n-------------------------------------")
        var line = "[시도] 주소 \(BLEIds.shortId(p.identifier))  신호 \(c.rssi) dBm"
        // Mac 은 overflow 비트 번호를 볼 수 없다 (CoreBluetooth 가 UUID 로만 알려 준다)
        if c.overflow { line += "  overflow UUID" }
        if c.plain { line += "  [광고에 서비스 UUID 노출]" }
        if !c.name.isEmpty { line += "  이름 \"\(c.name)\"" }
        emit(line)
        emit("  기기 ID: \(p.identifier.uuidString)")

        guard d.manager.state == .poweredOn else {
            emit("  서비스 탐색: Unreachable (연결 실패)")
            return 0
        }
        d.begin(p)
        // CoreBluetooth 의 connect 는 스스로 끝나지 않는다 - 시간을 재서 끊는다
        d.manager.connect(p, options: nil)
        let settled = spin(10) { d.connected || d.connectFailed }
        if !d.connected {
            if !settled { emit("  연결 상태: Disconnected (10초 대기 후)") }
            emit("  서비스 탐색: \(statusText(d.connectError))")
            release(d, p)
            return 0
        }
        emit("  연결 상태: Connected")

        var result = 0
        p.discoverServices(nil)   // 전체 탐색
        if !spin(20, until: { d.servicesDone || d.disconnected }) {
            emit("  결과: 서비스 탐색 20초 초과 - 연결되지 않았습니다")
            release(d, p)
            return 0
        }
        if !d.servicesDone {
            emit("  서비스 탐색: Unreachable (연결 실패)")
            release(d, p)
            return 0
        }
        if let e = d.servicesError {
            emit("  서비스 탐색: \(statusText(e))")
            release(d, p)
            return 0
        }
        emit("  서비스 탐색: Success")
        result = 1
        let svcs = p.services ?? []
        emit("  서비스 \(svcs.count)개:")
        for s in svcs {
            let mine = s.uuid == BLEIds.identService
            emit("    \(BLEIds.braced(s.uuid))" + (mine ? "   <<< SmartScreen 신원 서비스" : ""))
            if mine && readToken(d, p, s) { result = 2 }
        }
        release(d, p)
        return result
    }

    /// 신원 서비스에서 토큰 특성을 찾아 읽는다. 성공하면 true.
    private static func readToken(_ d: DiagCentral, _ p: CBPeripheral, _ s: CBService) -> Bool {
        d.charsDone = false
        d.charsError = nil
        p.discoverCharacteristics(nil, for: s)
        if !spin(10, until: { d.charsDone || d.disconnected }) {
            emit("      특성 탐색 시간 초과")
            return false
        }
        if !d.charsDone {
            emit("      특성 탐색: Unreachable (연결 실패)")
            return false
        }
        if let e = d.charsError {
            emit("      특성 탐색: \(statusText(e))")
            return false
        }
        emit("      특성 탐색: Success")
        for ch in s.characteristics ?? [] {
            if ch.uuid != BLEIds.identToken {
                emit("      특성 \(BLEIds.braced(ch.uuid))")
                continue
            }
            d.readDone = false
            d.readError = nil
            p.readValue(for: ch)
            if !spin(10, until: { d.readDone || d.disconnected }) {
                emit("      토큰 읽기 시간 초과")
                return false
            }
            if !d.readDone {
                emit("      토큰 읽기: Unreachable (연결 실패)")
                return false
            }
            if let e = d.readError {
                emit("      토큰 읽기: \(statusText(e))")
                return false
            }
            let v = ch.value ?? Data()
            emit("      >>> 토큰 \(Hex.upper(v)) (\(v.count)바이트)")
            return true
        }
        emit("      토큰 특성이 없습니다")
        return false
    }

    /// 연결을 붙잡고 있으면 폰이 광고를 멈출 수 있으니 반드시 놓아준다.
    /// 해제가 끝나기 전에 다음 기기로 넘어가면 같은 증상(전부 Unreachable)이 난다 - 1.5초 쉰다.
    private static func release(_ d: DiagCentral, _ p: CBPeripheral) {
        if d.manager.state == .poweredOn {
            d.manager.cancelPeripheralConnection(p)
        }
        p.delegate = nil
        d.target = nil
        _ = spin(1.5) { false }
    }

    private static func matchesFilter(_ id: UUID, _ only: String) -> Bool {
        return id.uuidString == only || BLEIds.shortId(id) == only
    }

    // MARK: - --adv-scan

    /// --adv-scan [sec]
    /// 다른 PC 에서 실행해서, SmartScreen 이 돌고 있는 PC(또는 Mac)의 BLE 광고가 실제로 잡히는지 본다.
    /// "PC 는 광고 중이라는데 폰이 못 찾는다" 상황에서 PC 쪽 문제인지 폰 쪽 문제인지 가른다.
    static func advScan(args: [String]) -> Int32 {
        let ops = operands(args, flag: "--adv-scan")
        let seconds = max(ops.count > 0 ? ConfigStore.wtoi(ops[0]) : 30, 0)

        emit("SmartScreen 광고 수신 확인")
        emit("=====================================")
        emit("찾는 서비스: {\(BLEIds.pcService.uuidString)}")
        emit("\(seconds)초 동안 주변 BLE 광고를 듣습니다...\n")
        emit("다른 PC에서 SmartScreen 을 실행하고 \"시작\" 을 누른 상태여야 합니다.\n")

        var total = 0
        var hits = 0
        var seen = Set<UUID>()
        var code: Int32 = 0
        let d = DiagCentral()
        if waitPoweredOn(d) {
            d.onDiscover = { p, adv, rssi in
                total += 1
                let uuids = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
                if !uuids.contains(BLEIds.pcService) { return }
                if !seen.insert(p.identifier).inserted { return }   // 기기별 1회만 출력
                hits += 1
                BLEDiagnostics.emit("[발견] \(LocalClock.hhmmss())  주소 \(BLEIds.shortId(p.identifier))  신호 \(rssi) dBm")
            }
            // 주변 광고 전체를 센다 (필터 없음) - "주변은 들리는데 SmartScreen 만 안 보인다" 를 가르려고
            d.manager.scanForPeripherals(withServices: nil,
                                         options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            _ = spin(Double(seconds)) { false }
            d.manager.stopScan()
            d.onDiscover = nil
        } else {
            emitCentralFailure(d)
            code = 1
        }

        emit("\n-------------------------------------")
        emit("주변 광고 \(total)건 수신, 그중 SmartScreen \(hits)대 발견")
        if hits > 0 {
            emit("\n결과: PC 광고는 정상입니다.")
            emit("      폰이 못 찾는다면 아이폰 쪽 문제입니다.")
        } else if total > 0 {
            emit("\n결과: 주변 BLE 는 잘 들리는데 SmartScreen 광고만 안 보입니다.")
            emit("      그 PC 가 실제로는 광고를 못 내보내고 있습니다.")
        } else {
            emit("\n결과: 주변 BLE 광고가 하나도 안 잡힙니다.")
            emit("      이 PC 의 블루투스를 확인하세요.")
        }
        emit("-------------------------------------")
        return code
    }

    // MARK: - --bt-check

    /// --bt-check
    /// 이 Mac 에서 "빠른 모드"(Mac 이 BLE 주변장치가 되어 컴패니언 앱과 연결)를 쓸 수 있는지 확인한다.
    /// 결과를 설정 폴더의 BtCheck_result.txt 로도 남긴다 (UTF-8 BOM). Windows 는 exe 옆에 쓰지만
    /// .app 묶음 안에 쓰면 서명이 깨진다.
    static func btCheck(args: [String]) -> Int32 {
        var text = ""
        func out(_ s: String) {
            emit(s)
            text += s + "\n"
        }

        out("SmartScreen 블루투스 어댑터 점검")
        out("=====================================\n")

        let c = DiagCentral()
        let p = DiagPeripheral()
        _ = spin(10) { c.stateKnown && p.stateKnown }
        let cs = c.manager.state
        let ps = p.manager.state
        let denied = BLEIds.authorizationDenied || cs == .unauthorized || ps == .unauthorized

        var found = false
        var le = false
        var peripheral = false
        var powered = false
        if denied {
            out("[실패] \(permissionText)")
        } else if !c.stateKnown {
            out("[실패] 블루투스 어댑터를 찾을 수 없습니다.")
            out("       블루투스가 꺼져 있거나 어댑터가 없는 PC입니다.")
        } else {
            found = true
            le = cs != .unsupported
            // 주변장치 관리자가 unsupported 가 아니면 역할을 지원한다 (꺼져 있어도 지원 여부는 안다)
            peripheral = le && p.stateKnown && ps != .unsupported
            powered = cs == .poweredOn
            out("  저전력 블루투스(BLE) 지원 : \(yesNo(le))")
            out("  주변장치 역할 지원        : \(yesNo(peripheral))")
            out("  중앙장치 역할 지원        : \(yesNo(le))")
            out("  클래식 블루투스 지원      : 예")   // Mac 은 모두 지원한다
        }

        out("\n-------------------------------------")
        if denied {
            out("결과: 블루투스 권한을 켠 뒤 다시 실행해 주세요.")
        } else if found && le && !powered {
            out("결과: 블루투스를 켠 뒤 다시 실행해 주세요.")
        } else if found && le && peripheral {
            out("결과: 빠른 모드를 쓸 수 있습니다.\n")
            out("아이폰에 컴패니언 앱(SSBeacon)을 설치하면")
            out("자리를 뜬 뒤 10~15초 안에 화면이 잠깁니다.\n")
            // 드라이버가 "예" 라고 해도 실제로 전파를 못 내보내는 어댑터가 있었다 -
            // 바깥에서 보는 것(폰의 연결 표시, 다른 PC 의 AdvScan)만이 확정이다.
            out("[주의] 이 값은 드라이버가 보고하는 것이라 실제와 다를 수 있습니다.")
            out("       일부 USB 동글은 \"예\" 라고 답하면서도 전파를 못 내보냅니다.")
            out("       SmartScreen 을 실행해 폰 앱이 연결되는지로 확인하세요.")
            out("       또는 다른 PC 에서 AdvScan.exe 를 돌려 송출을 확인하세요.")
        } else if found && le {
            out("결과: 빠른 모드를 쓸 수 없습니다. (주변장치 역할 미지원)\n")
            out("느린 모드로는 동작합니다. 다만 아이폰은 잠금 상태에서")
            out("신호를 거의 안 보내므로 감지가 느리거나 끊깁니다.")
            out("블루투스 5.0 이상 USB 동글을 쓰면 빠른 모드가 될 수 있습니다.")
        } else if found {
            out("결과: 이 어댑터로는 SmartScreen을 쓸 수 없습니다. (BLE 미지원)")
        } else {
            out("결과: 블루투스를 켠 뒤 다시 실행해 주세요.")
        }
        out("-------------------------------------")

        let url = Paths.configDir.appendingPathComponent("BtCheck_result.txt")
        out("\n이 내용은 BtCheck_result.txt 파일로도 저장했습니다.")
        out("(\(url.path))")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try? data.write(to: url)
        return 0
    }

    // MARK: - 공통

    private static let permissionText =
        "블루투스 권한이 없어요. 시스템 설정 > 개인정보 보호 및 보안 > 블루투스에서 SmartScreen 을 켜 주세요."

    private static func yesNo(_ b: Bool) -> String {
        return b ? "예" : "아니오"
    }

    /// 출력하고 바로 내보낸다 (파이프로 받을 때도 진행이 보이게).
    private static func emit(_ s: String) {
        print(s)
        fflush(stdout)
    }

    /// 플래그 뒤의 인자만 남긴다. main 이 전체 인자를 넘기든 플래그 뒤만 넘기든 같게 읽는다.
    /// "-" 로 시작하는 것(-psn_..., -NS...)은 버린다.
    private static func operands(_ args: [String], flag: String) -> [String] {
        var a = args
        if let i = a.firstIndex(of: flag) {
            a = Array(a[(i + 1)...])
        }
        return a.filter { !$0.hasPrefix("-") }
    }

    /// 메인 런루프를 돌리며 done() 이 참이 되기를 기다린다. 시간 안에 참이 되면 true.
    /// CoreBluetooth 콜백(메인 큐)은 런루프가 도는 동안 처리된다.
    @discardableResult
    private static func spin(_ seconds: Double, until done: () -> Bool) -> Bool {
        // 런루프에 입력원이 하나도 없으면 run 이 곧바로 돌아와 헛돈다 - 타이머 하나를 걸어 둔다
        let keepAlive = Timer(timeInterval: 0.1, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            let now = Date()
            if now >= deadline { return false }
            let next = min(deadline, now.addingTimeInterval(0.1))
            if !RunLoop.main.run(mode: .default, before: next) {
                usleep(10_000)
            }
        }
        return true
    }

    private static func waitPoweredOn(_ d: DiagCentral) -> Bool {
        _ = spin(10) { d.stateKnown }
        return d.manager.state == .poweredOn
    }

    /// 블루투스를 쓸 수 없을 때의 안내 (Windows 의 "[실패] BLE 오류 0x..." 자리).
    private static func emitCentralFailure(_ d: DiagCentral) {
        let st = d.manager.state
        if BLEIds.authorizationDenied || st == .unauthorized {
            emit("[실패] \(permissionText)")
        } else if st == .unsupported || !d.stateKnown {
            emit("[실패] 블루투스 어댑터를 찾을 수 없습니다.")
            emit("       블루투스가 꺼져 있거나 어댑터가 없는 PC입니다.")
        } else {
            emit("결과: 블루투스를 켠 뒤 다시 실행해 주세요.")
        }
    }

    /// 도구용 상태 글자 (Windows ProbeScan 의 StatusText).
    private static func statusText(_ e: Error?) -> String {
        guard let e = e else { return "Unreachable (연결 실패)" }
        switch BLEIds.classify(e) {
        case .unreachable: return "Unreachable (연결 실패)"
        case .protocolError: return "ProtocolError"
        case .accessDenied: return "AccessDenied (페어링 요구)"
        case .other: return "?"
        }
    }
}

// MARK: - 진단 도구 전용 CoreBluetooth 대리자 (메인 큐)

private struct DiagCand {
    let peripheral: CBPeripheral
    var rssi: Int
    var plain: Bool       // 광고에 서비스 UUID 가 그대로 실린 경우 (앱 포그라운드)
    var overflow: Bool    // Apple overflow 영역에 실린 경우 (앱 백그라운드/잠금)
    var name: String
}

/// 사건을 깃발로만 남긴다. 순서대로 쓰인 도구 코드가 spin 으로 깃발을 기다린다.
private final class DiagCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var manager: CBCentralManager!
    var onDiscover: ((CBPeripheral, [String: Any], Int) -> Void)?
    var target: UUID?
    var connected = false
    var connectFailed = false
    var connectError: Error?
    var disconnected = false
    var servicesDone = false
    var servicesError: Error?
    var charsDone = false
    var charsError: Error?
    var readDone = false
    var readError: Error?

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil, options: nil)
    }

    var stateKnown: Bool {
        let s = manager.state
        return s != .unknown && s != .resetting
    }

    func begin(_ p: CBPeripheral) {
        target = p.identifier
        connected = false
        connectFailed = false
        connectError = nil
        disconnected = false
        servicesDone = false
        servicesError = nil
        charsDone = false
        charsError = nil
        readDone = false
        readError = nil
        p.delegate = self
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        onDiscover?(peripheral, advertisementData, RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral.identifier == target { connected = true }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if peripheral.identifier == target {
            connectFailed = true
            connectError = error
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if peripheral.identifier == target && connected { disconnected = true }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == target else { return }
        servicesDone = true
        servicesError = error
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard peripheral.identifier == target else { return }
        charsDone = true
        charsError = error
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral.identifier == target else { return }
        readDone = true
        readError = error
    }
}

private final class DiagPeripheral: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil, options: nil)
    }

    var stateKnown: Bool {
        let s = manager.state
        return s != .unknown && s != .resetting
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {}
}
