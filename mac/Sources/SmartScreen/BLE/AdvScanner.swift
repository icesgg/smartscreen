import Foundation
import CoreBluetooth
import SmartScreenCore

/// BLE 직접 등록의 결과. why 는 사용자에게 그대로 보이는 한국어 문장이다.
enum RegisterOutcome {
    case success(token: String)
    case failure(why: String)
}

/// 광고 스캐너 + 연결로 신원 확인 (client/ble_rssi.cpp, client/ble_ident.cpp 를 옮긴 것).
///
/// 아이폰 컴패니언 앱(SSBeacon)의 광고마다 RSSI 를 받아 칼만 필터로 매끄럽게 하고, 판정 스레드가
/// 읽을 사본을 내놓는다. 잠긴 아이폰의 광고에는 이름도 서비스 UUID 도 실리지 않고 주기적으로
/// 바뀌는 랜덤 주소만 남으므로, 후보에 한 번 붙어 신원 토큰을 읽고 그 기기(identifier)를 묶는다.
/// 그 뒤로는 그 기기가 조용해질 때까지 identifier 로 추적한다.
///
/// Mac 에서 다른 점 (spec ble §8):
///  - 스캔은 신원 서비스 UUID 로 필터한다. 잠긴 폰의 UUID 는 Apple overflow 영역에만 있고,
///    그것은 "그 UUID 를 명시해서 찾는 스캐너" 에게만 보인다. 필터 없이 훑으면 잠긴 폰을 못 본다.
///  - overflow 비트 번호는 CoreBluetooth 가 보여 주지 않으므로 배울 수 없다 (phoneOvfBit 는 늘 -1).
///    후보 = overflow 또는 일반 서비스 목록에 신원 UUID 가 있는 기기. 남의 폰은 토큰이 걸러 낸다.
///  - Windows 의 블로킹 프로버 스레드 대신 BLEIds.queue 위의 비동기 상태 기계로 돈다.
///    한 번에 탐색 하나, 단계마다 자체 시간 제한, 끝나면 반드시 연결을 끊는다.
final class AdvScanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = AdvScanner()

    // MARK: - 잠금으로 보호되는 공개 상태 (판정 스레드와 UI 가 snapshot 으로 읽는다)

    // RSSI 와 틱은 한 잠금 안에서 같이 바꾼다. 판정은 틱 값이 바뀌었는지로 "새 샘플" 을
    // 세므로, 틱만 바뀌고 RSSI 가 예전 값이면 낡은 값을 새 샘플로 셀 수 있다 (spec ble §6).
    private let lock = NSLock()
    private var pubAvailable = false
    private var pubLastReceivedTick: UInt64 = 0   // 샘플의 정체성. 0 = 이번 세션에 아직 없음
    private var pubRaw = -100
    private var pubSmoothed = -100
    // 이 시간 동안 수신 없으면 "끊김" (iOS 백그라운드 광고는 간격이 수십 초까지 벌어짐)
    private var pubTimeoutMs: UInt64 = 90_000
    private var pubBound = false
    private var pubCentralState: CBManagerState = .unknown
    // 최근 수신 시각 링버퍼 (초당 수신 건수 계산용)
    private static let rateSlots = 256
    private var rateTicks = [UInt64](repeating: 0, count: AdvScanner.rateSlots)
    private var rateHead = 0
    private var sampleHandler: (() -> Void)?

    /// 짝이 맞은 패킷마다 (BLE 큐에서) 불린다 - 판정 스레드를 바로 깨운다.
    var onSample: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return sampleHandler
        }
        set {
            lock.lock()
            sampleHandler = newValue
            lock.unlock()
        }
    }

    // MARK: - BLEIds.queue 전용 상태

    private var central: CBCentralManager?
    private var running = false
    private var targetName = ""
    private var kalman = KalmanFilter(processNoise: 1.0, measureNoise: 10.0)   // Q=초당 1.0, R=10.0
    private var logPath = ""
    private var csv: BLEIds.CsvLog?
    private var lastLoggedTick: [UUID: UInt64] = [:]   // 비매칭 기기는 기기별 5초에 1회만 기록
    private var loggedCentralState: CBManagerState?

    // ---- 연결로 확인하는 신원 (IRK 대체) ----
    // 토큰은 UI 가 바꾸고(setIdentity) 광고 콜백과 프로버가 읽는다. 모두 이 큐 위에서만
    // 일어나므로, 토큰 교체와 판정/결합 초기화가 프로버에게 한 번에 보인다.
    private var identToken = ""            // 등록된 토큰(32 hex)
    private var identOn = false            // identToken 이 비어 있지 않은지 = 이 경로 켜짐
    private var identBit = -1              // Mac 에서는 배울 수 없다 (보관만 한다)
    private var probeFloor = -75           // 이보다 약하면 탐색하지 않는다
    private var boundId: UUID?             // 토큰으로 확인된 현재 기기
    private var boundSeenTick: UInt64 = 0  // 그 기기를 마지막으로 본 시각
    private var cands: [UUID: Cand] = [:]
    // 기기별 재시도 금지 시각. 실패 종류에 따라 길이가 다르다 -
    // 남의 기기로 확인된 기기를 계속 다시 찌르면 맞는 기기에 쓸 시도를 낭비한다.
    private var probedUntil: [UUID: UInt64] = [:]
    private var proberTimer: DispatchSourceTimer?
    private var probe: Probe?
    private var registration: Registration?

    // 못 붙은 것은 금방 다시 해 본다. 실측에서 맞는 주소인데도 Unreachable 이
    // 다섯 번 연달아 났고, 60초 간격이라 4분에 다섯 번밖에 시도하지 못했다.
    private static let retryUnreachableMs: UInt64 = 15_000
    // 붙었는데 우리 서비스가 없던 기기는 다시 볼 이유가 없다. 주소가 바뀌면
    // 어차피 새 후보로 들어온다.
    private static let retryNotOursMs: UInt64 = 600_000

    private struct Cand {
        let peripheral: CBPeripheral   // connect 에 필요하므로 붙잡아 둔다
        var rssi: Int                  // 마지막 원시값 (매끄럽게 하지 않은 것)
        var seen: UInt64
    }

    // 탐색 결과. 실패를 둘로 가르는 것이 핵심이다 -
    // "붙었는데 우리 서비스가 없다"는 확정이고, "못 붙었다"는 다시 해볼 일이다.
    // 둘을 같이 취급하면 아닌 게 확실한 기기를 계속 다시 찌르면서
    // 정작 맞는 기기에 쓸 시도를 낭비한다.
    private enum ProbeOutcome {
        case token        // 토큰을 읽었다 (우리 것인지는 호출자가 대조한다)
        case notOurs      // 붙었지만 신원 서비스가 없다 - 남의 기기
        case unreachable  // 붙지 못했다 - 일시적일 수 있다
    }

    private enum Purpose {
        case ident(rssi: Int)   // 프로버: 후보를 고를 때의 원시 RSSI (bound 로그용)
        case register           // BLE 직접 등록

        var isIdent: Bool {
            if case .ident = self { return true }
            return false
        }
    }

    private enum Stage { case connecting, services, characteristics, reading }

    /// ReadPhoneToken 하나. 단계마다 타이머를 다시 건다.
    private final class Probe {
        let peripheral: CBPeripheral
        let purpose: Purpose
        let t0: UInt64
        var stage: Stage = .connecting
        var timer: DispatchSourceTimer?

        init(peripheral: CBPeripheral, purpose: Purpose, t0: UInt64) {
            self.peripheral = peripheral
            self.purpose = purpose
            self.t0 = t0
        }
    }

    private final class Registration {
        var scanning = true
        var best: CBPeripheral?
        var bestRssi = -127
        var timer: DispatchSourceTimer?
        var completions: [(RegisterOutcome) -> Void] = []
    }

    private override init() {
        super.init()
    }

    // MARK: - 공개 API

    /// 스캔을 시작한다. 블루투스가 켜져 있으면 바로, 아니면 켜지는 순간 (state 콜백) 스캔한다.
    /// Mac 의 Start 는 비동기라서 available 은 실제로 스캔을 건 뒤에야 true 가 된다.
    func start(targetName: String) {
        // 판정 스레드가 곧바로 첫 판정을 하므로 지난 세션의 값은 여기서 먼저 지운다.
        resetPublished()
        BLEIds.sync {
            if running { stopOnQueue() }
            self.targetName = targetName
            resetPublished()
            kalman.reset()            // 칼만은 Start 에서만 초기화한다 (결합이 바뀌어도 그대로)
            // 링버퍼는 Windows 처럼 비우지 않는다.

            // 진단 로그 (설정된 경우). 모니터링 중에도 다른 프로그램에서 읽을 수 있다.
            lastLoggedTick.removeAll()
            if !logPath.isEmpty, let f = BLEIds.CsvLog(path: logPath) {
                f.write("# session target=\(oneLine(targetName))\n")
                f.write("time,address,addrType,company,name,matched,rawRssi,smoothedRssi,mfgData,svcUuid\n")
                csv = f
            }

            running = true
            ensureCentral()
            updateScan()
            if identOn { ensureProber() }
        }
    }

    func stop() {
        BLEIds.sync { stopOnQueue() }
    }

    /// 등록된 폰이 바뀌었을 수도 있다는 전제로 쓴다. 감시를 시작할 때만 불리는 게
    /// 아니라 계정으로 등록을 마친 직후에도 불리므로, 스캔이 도는 중에 바뀔 수 있다.
    func setIdentity(tokenHex: String, ovfBit: Int, probeFloor: Int) {
        BLEIds.sync {
            let changed = identToken.uppercased() != tokenHex.uppercased()
            identToken = tokenHex
            identOn = !tokenHex.isEmpty
            identBit = ovfBit
            self.probeFloor = probeFloor

            if changed {
                // 지금까지의 판정은 모두 예전 토큰에 대한 것이다. "남의 기기" 라는
                // 결론은 10분을 버티므로 그대로 두면 새로 등록한 폰을 그만큼 무시한다.
                // 묶여 있던 기기도 더는 확인된 기기가 아니다 - 다른 폰을 등록했는데
                // 예전 폰이 계속 묶여 있으면 그게 화면을 열어둔다.
                // (후보는 지우지 않는다 - 있던 후보를 곧바로 탐색할 수 있다)
                let dropped = probedUntil.count
                probedUntil.removeAll()
                setBound(nil)
                // 등록을 바꾼 직후 폰을 못 알아보는 일이 로그에서 갈리도록 남긴다.
                EventLog.write("ident: token \(identOn ? "set" : "cleared"), dropped \(dropped) past verdict(s) and the binding")
            }

            // 스캔이 이미 돌고 있으면 start 를 다시 지나지 않는다. 여기서 띄우지 않으면
            // 처음 등록한 경우 프로버가 아예 없어서, "등록했습니다" 라고 말한
            // 뒤에도 폰을 끝까지 확인하지 못한다.
            if running && identOn { ensureProber() }
        }
    }

    /// 수신 끊김 판정 시간(초). 5..600 으로 자른다.
    func setTimeoutSec(_ s: UInt32) {
        let sec = UInt64(min(max(s, 5), 600))
        lock.lock()
        pubTimeoutMs = sec * 1000
        lock.unlock()
    }

    /// 진단 로그(ble_scan_log.csv) 경로. 다음 start 부터 쓴다. nil 또는 "" = 끔.
    func setDebugLog(path: String?) {
        BLEIds.sync { logPath = path ?? "" }
    }

    func snapshot(now: UInt64) -> ScannerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var s = ScannerSnapshot()
        s.available = pubAvailable
        let last = pubLastReceivedTick
        s.lastReceivedTick = last
        // 수신 이력이 있는데 끊긴 경우 = 범위 이탈로 본다 (판정 쪽)
        s.hasEverReceived = last != 0
        if last != 0 {
            let age = BLEIds.elapsed(now, since: last)
            // 마지막 수신으로부터 타임아웃(기본 90초) 넘게 지나면 -100 (엄격한 >)
            if age <= pubTimeoutMs {
                s.smoothedRssi = pubSmoothed
                s.rawRssi = pubRaw
            }
            s.receiving = age < pubTimeoutMs
        }
        var n = 0
        for t in rateTicks where t != 0 && BLEIds.elapsed(now, since: t) <= 10_000 {
            n += 1
        }
        s.packetRate = Double(n) / 10.0
        s.bound = pubBound
        return s
    }

    /// 블루투스 권한이 거부됐다 (시스템 설정 > 개인정보 보호 및 보안 > 블루투스).
    var bluetoothDenied: Bool {
        if BLEIds.authorizationDenied { return true }
        lock.lock()
        defer { lock.unlock() }
        return pubCentralState == .unauthorized
    }

    /// 등록: 앱을 화면에 띄운 폰을 찾아 토큰을 읽는다.
    /// 포그라운드에서는 iOS 가 이름과 서비스 UUID 를 광고에 그대로 실으므로 후보가
    /// 모호하지 않다. 잠긴 폰으로 등록하면 남의 폰을 집을 위험이 있어 일부러 이 조건을 쓴다.
    /// 가장 신호가 센 것 하나만 시도한다. completion 은 메인에서 불린다.
    /// "register phone: ..." 줄은 부르는 쪽(UI)이 남긴다 (Windows 와 같다).
    func registerPhone(scanSec: Int, completion: @escaping (RegisterOutcome) -> Void) {
        BLEIds.queue.async { [weak self] in
            guard let self = self else { return }
            if let reg = self.registration {
                // 이미 진행 중이면 같은 결과를 같이 받는다 (UI 가 버튼을 꺼 두므로 드문 일)
                reg.completions.append(completion)
                return
            }
            let sec = max(scanSec, 3)
            let reg = Registration()
            reg.completions.append(completion)
            self.registration = reg
            self.ensureCentral()
            self.updateScan()   // 블루투스가 아직 안 켜졌으면 켜지는 순간 state 콜백이 건다
            let t = DispatchSource.makeTimerSource(queue: BLEIds.queue)
            t.schedule(deadline: .now() + .seconds(sec))
            t.setEventHandler { [weak self] in self?.registrationScanEnded() }
            reg.timer = t
            t.resume()
        }
    }

    // MARK: - 내부: 시작/정지/스캔

    private func resetPublished() {
        lock.lock()
        pubRaw = -100
        pubSmoothed = -100
        pubLastReceivedTick = 0
        pubAvailable = false
        lock.unlock()
    }

    private func setAvailable(_ v: Bool) {
        lock.lock()
        pubAvailable = v
        lock.unlock()
    }

    private func setBound(_ id: UUID?) {
        boundId = id
        lock.lock()
        pubBound = id != nil
        lock.unlock()
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false
        updateScan()
        csv?.close()
        csv = nil
        // 프로버 타이머는 그대로 두고(놀게 된다) 묶인 기기만 버린다.
        // 다시 시작하면 처음부터 후보를 모아 다시 확인한다.
        // probedUntil 도 지운다 - 폰을 다시 설치해 토큰이 바뀐 경우 중지->시작이 해법이다.
        setBound(nil)
        cands.removeAll()
        probedUntil.removeAll()
        if let pr = probe, pr.purpose.isIdent { abortProbe() }
    }

    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: BLEIds.queue, options: nil)
        }
    }

    /// 스캔이 필요하면 (모니터링 중이거나 등록 스캔 중) 걸고, 아니면 멈춘다.
    private func updateScan() {
        guard let c = central, c.state == .poweredOn else { return }
        let regScanning = registration?.scanning ?? false
        if running || regScanning {
            // allowDuplicates 가 없으면 기기마다 didDiscover 가 한 번뿐이라 RSSI 흐름이 없다.
            c.scanForPeripherals(withServices: [BLEIds.identService],
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            if running { setAvailable(true) }
        } else if c.isScanning {
            c.stopScan()
        }
    }

    private func ensureProber() {
        if proberTimer != nil { return }
        // 타이머를 스캐너 수명 내내 살려 둔다 (Windows 는 Stop 에서 조인하면 UI 가 최악 10초
        // 멈추므로 스레드를 살려 뒀다). 꺼져 있으면 틱마다 바로 돌아간다.
        let t = DispatchSource.makeTimerSource(queue: BLEIds.queue)
        t.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.proberTick() }
        t.resume()
        proberTimer = t
    }

    private func oneLine(_ s: String) -> String {
        return s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let st = central.state
        lock.lock()
        pubCentralState = st
        lock.unlock()
        // Mac 전용 진단 줄: 잠자기/깨기, 블루투스 끄고 켜기가 로그에서 보이게 한다.
        if (running || registration != nil) && loggedCentralState != st {
            EventLog.write("BLE central state: \(BLEIds.stateName(st))")
        }
        loggedCentralState = st

        if st == .poweredOn {
            // 켜지면 (다시) 스캔을 건다. Windows 는 라디오가 꺼졌다 켜지면 다시 Start 를
            // 눌러야 했지만 여기서는 저절로 이어진다.
            updateScan()
            return
        }
        // 꺼짐/권한 없음/재설정: 스캔이 멈췄다. 식별자도 무효가 되므로 후보와 결합을 버린다.
        // RSSI 와 틱은 그대로 둔다 - 시간이 지나면 판정이 알아서 끊김으로 본다.
        setAvailable(false)
        cands.removeAll()
        if boundId != nil { setBound(nil) }
        if let pr = probe {
            if pr.purpose.isIdent {
                abortProbe()
            } else {
                finishProbe(.unreachable, token: "", why: "Unreachable")
            }
        }
    }

    /// 광고 하나 = 패킷 하나 (뜨거운 경로). 가볍게, 기다리지 않게.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        let plainList = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflowList = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let inPlain = plainList.contains(BLEIds.identService)
        let inOverflow = overflowList.contains(BLEIds.identService)
        let valid = BLEIds.validRssi(rssi)

        // 등록 스캔: 일반 서비스 목록에 신원 UUID 가 있는 것(= 앱이 화면에 떠 있는 폰)만.
        // 잠긴 폰은 UUID 를 overflow 로 옮기므로 여기 안 걸린다 - 의도한 것.
        if let reg = registration, reg.scanning, inPlain, valid, rssi > reg.bestRssi {
            reg.best = peripheral
            reg.bestRssi = rssi
        }

        guard running else { return }
        let now = Mono.now()
        let id = peripheral.identifier

        // 이 광고가 "내 폰" 인지
        let identMatch = boundId != nil && boundId == id
        if identMatch {
            boundSeenTick = now
        } else if identOn && (inOverflow || inPlain) {
            // 아직 못 묶었으면 후보로만 쌓아 둔다. 붙는 일은 프로버가 한다.
            // (Windows 는 overflow 모양만 후보로 삼는다. Mac 은 앱이 화면에 떠 있는 폰도 받는다 -
            //  토큰이 가르므로 다른 것은 바뀌지 않는다.)
            cands[id] = Cand(peripheral: peripheral, rssi: valid ? rssi : -127, seen: now)
        }

        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let matched = identMatch
            || nameMatches(advName)
            // 서비스 UUID 는 앱 설치본마다 같으므로 폰을 특정하지 못한다.
            // 토큰이 없을 때의 임시방편일 뿐이다.
            || (!identOn && (inPlain || inOverflow))

        var smoothedInt = -100
        if matched && valid {
            // 칼만 필터로 매끄럽게 한 뒤 공개 상태를 한 번에 바꾼다.
            // dt 는 같은 경로의 직전 틱에서 잰다 (덮어쓰기 전에).
            lock.lock()
            let prev = pubLastReceivedTick
            lock.unlock()
            let dt = prev != 0 ? Double(BLEIds.elapsed(now, since: prev)) / 1000.0 : 1.0
            smoothedInt = Int(kalman.update(Double(rssi), dtSec: dt).rounded())
            lock.lock()
            pubRaw = rssi
            pubSmoothed = smoothedInt
            pubLastReceivedTick = now     // 판정이 쓰는 샘플의 정체성
            rateTicks[rateHead] = now
            rateHead = (rateHead + 1) % AdvScanner.rateSlots
            let wake = sampleHandler
            lock.unlock()
            wake?()
        }

        // 진단 로그: 들은 광고를 기록해 대상 기기가 어떤 모양으로 보이는지 확인
        if let f = csv {
            logAdv(f, id: id, adv: advertisementData, name: advName, matched: matched,
                   raw: rssi, smoothed: smoothedInt, plainList: plainList, now: now)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let pr = probe, pr.peripheral.identifier == peripheral.identifier,
              pr.stage == .connecting else { return }
        pr.stage = .services
        peripheral.delegate = self
        // 전체 탐색 (Windows 의 Uncached 전체 탐색과 같게). 10초 타이머는 그대로 이어진다.
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard let pr = probe, pr.peripheral.identifier == peripheral.identifier else { return }
        finishProbe(.unreachable, token: "", why: "Unreachable")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // 결과가 나기 전에 끊겼다. 끝난 탐색의 끊김(우리가 끊은 것)은 probe 가 이미 nil 이다.
        // 아직 연결 중 단계라면 이 끊김은 같은 기기의 이전 연결 것이므로 무시한다.
        guard let pr = probe, pr.peripheral.identifier == peripheral.identifier,
              pr.stage != .connecting else { return }
        finishProbe(.unreachable, token: "", why: "Unreachable")
    }

    // MARK: - CBPeripheralDelegate (토큰 읽기)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let pr = probe, pr.peripheral.identifier == peripheral.identifier,
              pr.stage == .services else { return }
        if let e = error {
            finishProbe(.unreachable, token: "", why: AdvScanner.statusText(e))
            return
        }
        guard let svc = (peripheral.services ?? []).first(where: { $0.uuid == BLEIds.identService }) else {
            // 붙었는데 우리 서비스가 없다 = 확정
            finishProbe(.notOurs, token: "", why: "ident service absent")
            return
        }
        pr.stage = .characteristics
        armProbeTimer(5.0)
        peripheral.discoverCharacteristics([BLEIds.identToken], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let pr = probe, pr.peripheral.identifier == peripheral.identifier,
              pr.stage == .characteristics else { return }
        if let e = error {
            finishProbe(.unreachable, token: "", why: AdvScanner.statusText(e))
            return
        }
        guard let ch = (service.characteristics ?? []).first(where: { $0.uuid == BLEIds.identToken }) else {
            // 신원 서비스는 있는데 토큰 특성이 없다: Windows 처럼 사유 없이 Unreachable
            // (로그에는 "token mismatch" 로 남는다)
            finishProbe(.unreachable, token: "", why: "")
            return
        }
        pr.stage = .reading
        armProbeTimer(5.0)
        peripheral.readValue(for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let pr = probe, pr.peripheral.identifier == peripheral.identifier,
              pr.stage == .reading, characteristic.uuid == BLEIds.identToken else { return }
        if let e = error {
            finishProbe(.unreachable, token: "", why: AdvScanner.statusText(e))
            return
        }
        // 길이는 따지지 않는다: 온 바이트를 그대로 "%02X" 로 (대문자 32자가 정상)
        let hex = Hex.upper(characteristic.value ?? Data())
        if hex.isEmpty {
            finishProbe(.unreachable, token: "", why: "token empty")
        } else {
            finishProbe(.token, token: hex, why: "")
        }
    }

    // MARK: - 내부: 탐색 (ReadPhoneToken 의 비동기판)

    /// Windows GattCommunicationStatus 의 글자 (이벤트 로그용, 영어).
    private static func statusText(_ e: Error) -> String {
        switch BLEIds.classify(e) {
        case .unreachable: return "Unreachable"
        case .protocolError: return "ProtocolError"
        case .accessDenied: return "AccessDenied"
        case .other: return "?"
        }
    }

    /// 한 기기에 붙어 신원 토큰을 읽는다. 보통 1~3초, 최악 20초 (연결+서비스 10, 특성 5, 읽기 5).
    /// CoreBluetooth 의 connect 는 스스로 시간 제한이 없으므로 타이머로 끊는다.
    private func startProbe(_ p: CBPeripheral, purpose: Purpose) {
        if probe != nil { abortProbe() }
        let pr = Probe(peripheral: p, purpose: purpose, t0: Mono.now())
        probe = pr
        guard let c = central, c.state == .poweredOn else {
            finishProbe(.unreachable, token: "", why: "Unreachable")
            return
        }
        p.delegate = self
        armProbeTimer(10.0)   // 연결 + 서비스 탐색 (Windows: 기기 객체 5초 + 서비스 탐색 10초 자리)
        c.connect(p, options: nil)
    }

    private func armProbeTimer(_ seconds: Double) {
        guard let pr = probe else { return }
        pr.timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: BLEIds.queue)
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [weak self, weak pr] in
            guard let self = self, let pr = pr, self.probe === pr else { return }
            self.probeTimedOut(pr)
        }
        pr.timer = t
        t.resume()
    }

    private func probeTimedOut(_ pr: Probe) {
        switch pr.stage {
        case .connecting, .services:
            finishProbe(.unreachable, token: "", why: "service discovery timeout")
        case .characteristics:
            finishProbe(.unreachable, token: "", why: "characteristic discovery timeout")
        case .reading:
            finishProbe(.unreachable, token: "", why: "token read timeout")
        }
    }

    /// 탐색을 끝낸다: 언제나 연결을 놓는다.
    private func releaseProbe(_ pr: Probe) {
        probe = nil
        pr.timer?.cancel()
        pr.timer = nil
        // 연결을 붙잡고 있으면 폰이 광고를 멈출 수 있으니 반드시 놓아준다. 성공했든
        // 실패했든 시간이 다 됐든 (Windows: 서비스 핸들을 쥐고 있으면 LE 연결을 놓지 않아
        // 몇 대만 훑어도 연결 슬롯이 말라 이후가 전부 Unreachable 이 됐다).
        if let c = central, c.state == .poweredOn {
            c.cancelPeripheralConnection(pr.peripheral)
        }
        pr.peripheral.delegate = nil
    }

    /// 결과 없이 버린다 (중지, 블루투스 꺼짐, 등록이 끼어듦).
    private func abortProbe() {
        if let pr = probe { releaseProbe(pr) }
    }

    private func finishProbe(_ outcome: ProbeOutcome, token: String, why: String) {
        guard let pr = probe else { return }
        releaseProbe(pr)
        let took = BLEIds.elapsed(Mono.now(), since: pr.t0)
        switch pr.purpose {
        case .ident(let rssi):
            identProbeDone(pr.peripheral.identifier, pickRssi: rssi, outcome, token: token, why: why, took: took)
        case .register:
            registerProbeDone(outcome, token: token, why: why)
        }
    }

    // MARK: - 내부: 프로버 (2초마다, 한 번에 하나)

    private func proberTick() {
        // 스캔이 꺼져 있거나 토큰이 없으면 논다. 탐색이 진행 중이면 끝날 때까지 기다린다.
        guard running, identOn, probe == nil else { return }
        let now = Mono.now()

        // 묶인 기기가 아직 광고 중이면 할 일이 없다.
        // 30초로 잡은 이유: 실측 광고 간격의 최대가 19.9초였다. 20초로 두면
        // 정상적인 공백에도 결합이 풀려 헛된 탐색이 돈다. 늦게 풀어도 손해가
        // 적은 쪽인데, 결합이 풀려도 RSSI 는 bleTimeoutSec(90초)까지 살아 있다.
        if let b = boundId {
            if BLEIds.elapsed(now, since: boundSeenTick) < 30_000 { return }
            EventLog.write("ident: \(BLEIds.shortId(b)) went quiet, looking again")
            setBound(nil)
        }

        cands = cands.filter { BLEIds.elapsed(now, since: $0.value.seen) <= 30_000 }
        // 식별자는 주기적으로 바뀌므로 그냥 두면 계속 쌓인다
        probedUntil = probedUntil.filter { !(now > $0.value + 300_000) }

        // Windows 는 1차로 학습한 overflow 비트와 맞는 후보만 본다. Mac 은 비트를 볼 수 없어
        // (CoreBluetooth 가 UUID 로만 알려 준다) 바로 2차 - 전체를 신호 순으로 - 를 한다.
        var pickId: UUID?
        var pickPeripheral: CBPeripheral?
        var pickRssi = -127
        for (id, c) in cands {
            if c.rssi < probeFloor { continue }   // 자리 판정에 쓸 수 없는 거리는 건드리지 않는다
            if let until = probedUntil[id], now < until { continue }
            if c.rssi > pickRssi {
                pickId = id
                pickPeripheral = c.peripheral
                pickRssi = c.rssi
            }
        }
        guard let id = pickId, let p = pickPeripheral else { return }
        probedUntil[id] = now + AdvScanner.retryUnreachableMs   // 잠정 잠금
        startProbe(p, purpose: .ident(rssi: pickRssi))
    }

    private func identProbeDone(_ id: UUID, pickRssi: Int, _ outcome: ProbeOutcome,
                                token: String, why: String, took: UInt64) {
        guard running else { return }
        // 연결에 수 초가 걸리므로 등록된 값은 붙잡고 있지 않고 지금 다시 읽는다.
        // 탐색 중에 등록이 바뀌었으면 새 값으로 판정하는 편이 맞다.
        let ours = outcome == .token && token.uppercased() == identToken.uppercased()
        let sid = BLEIds.shortId(id)
        if !ours {
            // 붙었는데 아닌 것으로 확인된 기기는 한동안 접어 둔다 (토큰이 다른 것도 확정이다).
            // 못 붙은 것은 일시적일 수 있으니 금방 다시 해 본다.
            let settled = outcome != .unreachable
            probedUntil[id] = Mono.now() + (settled ? AdvScanner.retryNotOursMs : AdvScanner.retryUnreachableMs)
            let what = settled ? "is not our phone" : "probe failed"
            let reason = why.isEmpty ? "token mismatch" : why
            EventLog.write("ident: \(sid) \(what) (\(reason), \(took)ms)")
            return
        }
        setBound(id)
        boundSeenTick = Mono.now()
        EventLog.write("ident: bound to \(sid) (\(pickRssi) dBm, \(took)ms)")
    }

    // MARK: - 내부: BLE 직접 등록

    private func registrationScanEnded() {
        guard let reg = registration, reg.scanning else { return }
        reg.scanning = false
        reg.timer?.cancel()
        reg.timer = nil
        updateScan()
        guard let best = reg.best else {
            finishRegistration(.failure(why: "앱을 화면에 띄운 폰을 찾지 못했습니다"))
            return
        }
        EventLog.write("register: candidate \(BLEIds.shortId(best.identifier)) rssi=\(reg.bestRssi) dBm")
        startProbe(best, purpose: .register)
    }

    private func registerProbeDone(_ outcome: ProbeOutcome, token: String, why: String) {
        if outcome == .token {
            finishRegistration(.success(token: token))
        } else {
            finishRegistration(.failure(why: "연결은 했지만 토큰을 읽지 못했습니다 (\(why))"))
        }
    }

    private func finishRegistration(_ outcome: RegisterOutcome) {
        guard let reg = registration else { return }
        registration = nil
        reg.timer?.cancel()
        reg.timer = nil
        let callbacks = reg.completions
        DispatchQueue.main.async {
            for cb in callbacks { cb(outcome) }
        }
    }

    // MARK: - 내부: 이름 매칭, 진단 로그

    /// 기기 이름 대소문자 무시 포함 검사. "등록된 폰" 은 표시용이라 광고 이름과는 맞춰 보지 않는다
    /// (Windows 는 그래도 비교해서, 광고 이름이 정말 "등록된 폰" 인 기기가 걸릴 수 있었다).
    private func nameMatches(_ advName: String) -> Bool {
        if targetName.isEmpty || advName.isEmpty || targetName == Choices.registeredPhoneName {
            return false
        }
        return advName.lowercased().contains(targetName.lowercased())
    }

    /// ble_scan_log.csv 한 줄. 칸 위치는 Windows 와 같다 (tools/rssi-threshold.ps1 이 0, 5, 7 번 칸을 읽는다).
    /// time,address,addrType,company,name,matched,rawRssi,smoothedRssi,mfgData,svcUuid
    private func logAdv(_ f: BLEIds.CsvLog, id: UUID, adv: [String: Any], name: String, matched: Bool,
                        raw: Int, smoothed: Int, plainList: [CBUUID], now: UInt64) {
        if !matched {
            if let t = lastLoggedTick[id], BLEIds.elapsed(now, since: t) < 5000 { return }
            lastLoggedTick[id] = now
        }
        var company = ""
        var payload = ""
        if let md = adv[CBAdvertisementDataManufacturerDataKey] as? Data, md.count >= 2 {
            // 앞 2바이트 = 회사 ID (little-endian). 그 뒤 24바이트까지
            // (Apple: 첫 바이트가 메시지 종류. 0x01=앱 백그라운드 광고, 0x10=Nearby Info 등)
            let b = [UInt8](md)
            company = "0x" + BLEIds.hex4(Int(b[0]) | (Int(b[1]) << 8))
            let end = min(b.count, 2 + 24)
            payload = Hex.upper(Data(b[2..<end]))
        }
        let svc = plainList.first.map { BLEIds.braced($0) } ?? ""
        // Mac 은 주소 종류를 모른다 -> Windows 가 모를 때 쓰는 "?"
        let sm = matched ? "\(smoothed)" : ""
        let line = "\(LocalClock.hhmmssmmm()),\(BLEIds.shortId(id)),?,\(company),\(BLEIds.csvField(name)),"
            + "\(matched ? 1 : 0),\(raw),\(sm),\(payload),\(svc)\n"
        f.write(line)
    }
}
