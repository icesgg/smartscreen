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
///  - 스캔 관리자(CBCentralManager)가 둘이다. 잠긴 폰의 신원 UUID 는 Apple overflow 영역에만 있는데,
///    macOS 가 그것을 어떻게 보여 주는지가 실기로 확인되지 않았다. 그래서 둘 중 하나만 되어도 돌게 했다:
///      F (필터) - 신원 서비스 UUID 로 걸러 달라고 한다. iOS 는 "그 UUID 를 명시해서 찾는 스캐너" 에게
///                 overflow 광고를 맞춰 준다 - macOS 도 그러기를 기대한다. 등록, 블루투스 상태,
///                 권한 판단은 F 가 맡는다 (예전 그대로).
///      R (직접 읽기) - 거르지 않고 훑어 제조사 데이터 `4C 00 01 + 16바이트` 를 Windows 처럼 직접
///                 읽는다. 비트가 딱 하나인 광고가 후보이고 그 비트 번호를 배운다 (phoneOvfBit).
///                 토큰이 등록돼 있고 감시 중일 때만 돈다.
///    후보는 기기 식별자로 합친다. 두 쪽이 같은 패킷을 각각 알릴 수 있으므로 등록된 폰의 샘플은
///    DualSourceDedupe 를 지나야 칼만/공개 상태/판정 깨우기에 닿는다 (연속 2샘플 규칙이 샘플을 센다).
///    어느 쪽이 잠긴 폰을 실제로 주는지는 `ident: XXXX locked adverts via ...` 줄과 --probe-scan 의 요약이
///    말한다 (`ident: bound to ... via ...` 는 묶기 직전 10초의 모양일 뿐이다 - 앱이 화면에 떠 있었을
///    수도 있다).
///  - CBPeripheral 객체는 그것을 준 관리자의 것이다. 연결과 끊기는 그 관리자로만 한다 (탐색이 자기
///    관리자를 기억한다). 후보는 쪽마다 객체를 따로 들고 있다가 F 의 것이 있으면 F 로 붙는다.
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
    private var pubCentralState: CBManagerState = .unknown       // F 의 상태 (화면과 판단은 이것만 본다)
    private var pubRawCentralState: CBManagerState = .unknown    // R 의 상태 (권한 거부만 본다)
    private var pubLearnedBit = -1   // 새로 배워서 저장해야 할 overflow 비트 (Windows identBitLearned)
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

    private var central: CBCentralManager?      // F: 신원 서비스 UUID 로 거르는 스캔
    private var rawCentral: CBCentralManager?   // R: 거르지 않는 스캔 (토큰이 있을 때만 만든다)
    private var running = false
    private var targetName = ""
    private var kalman = KalmanFilter(processNoise: 1.0, measureNoise: 10.0)   // Q=초당 1.0, R=10.0
    private var dedupe = DualSourceDedupe()     // F 와 R 이 같은 패킷을 두 번 세지 않게
    private var logPath = ""
    private var csv: BLEIds.CsvLog?
    private var lastLoggedTick: [UUID: UInt64] = [:]   // 비매칭 기기는 기기별 5초에 1회만 기록 (두 쪽 공통)
    private var loggedCentralState: CBManagerState?

    // dedupe 의 source 번호
    private static let sourceFilter = 0
    private static let sourceRaw = 1

    // ---- 연결로 확인하는 신원 (IRK 대체) ----
    // 토큰은 UI 가 바꾸고(setIdentity) 광고 콜백과 프로버가 읽는다. 모두 이 큐 위에서만
    // 일어나므로, 토큰 교체와 판정/결합 초기화가 프로버에게 한 번에 보인다.
    private var identToken = ""            // 등록된 토큰(32 hex)
    private var identOn = false            // identToken 이 비어 있지 않은지 = 이 경로 켜짐
    private var identBit = -1              // 학습된 overflow 비트 (-1 = 모름). R 이 읽고 배운다
    private var probeFloor = -75           // 이보다 약하면 탐색하지 않는다
    private var boundId: UUID?             // 토큰으로 확인된 현재 기기
    private var boundSeenTick: UInt64 = 0  // 그 기기를 마지막으로 본 시각 (어느 쪽이든)
    // 묶인 기기의 잠긴 광고(일반 목록에 신원 UUID 가 없는 것)를 어느 쪽이 언제 줬는지, 그리고 마지막으로
    // 남긴 "locked adverts via ..." 의 길. 둘 다 결합이 바뀌면 지운다 (setBound).
    private var boundLocked = ScanSourceTimes()
    private var lockedLog = LockedPathLog()
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

    /// 후보 하나. 같은 기기를 두 관리자가 다 보면 한 줄로 합친다.
    private struct Cand {
        // connect 에 필요하므로 붙잡아 둔다. 객체는 그것을 준 관리자로만 연결할 수 있다.
        var viaFilter: CBPeripheral?   // F 가 준 객체
        var viaRaw: CBPeripheral?      // R 이 준 객체
        var rssi: Int                  // 마지막 원시값 (매끄럽게 하지 않은 것, 어느 쪽이든)
        var seen: UInt64
        var sure: Bool                 // 신원 UUID 를 직접 봤다 (F 가 줬다, 또는 R 광고의 UUID 목록)
        var bit: Int                   // R 이 읽은 overflow 비트 (-1 = 모름). 고르기와 배우기용 - 한 번 서면 남는다
        var times: ScanSourceTimes     // 쪽마다 마지막으로 준 시각 (bound 줄의 "via ..." 용)
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
        // 프로버: 후보를 고를 때의 원시 RSSI, overflow 비트, 찾은 경로 (bound 로그와 비트 학습용)
        case ident(rssi: Int, bit: Int, via: String)
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
        let central: CBCentralManager   // 이 객체를 준 관리자. 연결/끊기는 이것으로만 한다
        let purpose: Purpose
        let t0: UInt64
        var stage: Stage = .connecting
        var timer: DispatchSourceTimer?

        init(peripheral: CBPeripheral, central: CBCentralManager, purpose: Purpose, t0: UInt64) {
            self.peripheral = peripheral
            self.central = central
            self.purpose = purpose
            self.t0 = t0
        }
    }

    private final class Registration {
        let scanSec: Int
        var scanning = true                 // 스캔 단계 (블루투스를 기다리는 중 포함)
        var best: CBPeripheral?
        var bestRssi = -127
        var timer: DispatchSourceTimer?     // 스캔 시간. 실제로 스캔을 건 순간에 건다
        var waitTimer: DispatchSourceTimer? // 블루투스가 켜지기를 기다리는 상한
        var completions: [(RegisterOutcome) -> Void] = []

        init(scanSec: Int) {
            self.scanSec = scanSec
        }
    }

    // 블루투스가 켜지기를 (권한 질문에 답하기를) 기다리는 상한. 처음 실행하면 여기서 처음
    // CBCentralManager 를 만들어 권한 창이 뜨고, 사용자가 읽고 누를 때까지 상태가 .unknown 이다.
    private static let registerWaitCapSec = 30

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
            dedupe.reset()
            // 링버퍼는 Windows 처럼 비우지 않는다.

            // 진단 로그 (설정된 경우). 모니터링 중에도 다른 프로그램에서 읽을 수 있다.
            lastLoggedTick.removeAll()
            if !logPath.isEmpty, let f = BLEIds.CsvLog(path: logPath) {
                f.write("# session target=\(oneLine(targetName))\n")
                f.write("time,address,addrType,company,name,matched,rawRssi,smoothedRssi,mfgData,svcUuid\n")
                csv = f
            }

            running = true
            // 어느 스캔이 도는지. 직접 읽기(R)는 토큰이 있어야 돈다 (후보를 확인할 길이 토큰뿐이다).
            EventLog.write("scan: filter=on raw=\(identOn ? "on" : "off")")
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
                // 예전 폰으로 배운 비트를 새 토큰의 config 에 저장하지 않게 한다 (저장하는 쪽이 1초
                // 틱이라, 그 사이에 등록이 바뀌면 새 토큰과 함께 적힌 -1 을 덮을 수 있다).
                lock.lock()
                pubLearnedBit = -1
                lock.unlock()
                // 등록을 바꾼 직후 폰을 못 알아보는 일이 로그에서 갈리도록 남긴다.
                EventLog.write("ident: token \(identOn ? "set" : "cleared"), dropped \(dropped) past verdict(s) and the binding")
                if running {
                    EventLog.write("scan: filter=on raw=\(identOn ? "on" : "off")")
                }
            }

            // 스캔이 이미 돌고 있으면 start 를 다시 지나지 않는다. 여기서 띄우지 않으면
            // 처음 등록한 경우 프로버가 아예 없어서, "등록했습니다" 라고 말한
            // 뒤에도 폰을 끝까지 확인하지 못한다. 직접 읽기 스캔(R)도 여기서 켜고 끈다.
            if running {
                updateRawScan()
                if identOn { ensureProber() }
            }
        }
    }

    /// 프로버가 잠긴 폰을 묶으면서 overflow 비트를 새로 배웠으면 그 번호, 아니면 -1 (한 번 꺼내면
    /// 지워진다). 메인의 1초 틱이 config.ini 의 phoneOvfBit 로 저장한다 (Windows IDT_COUNTDOWN).
    func takeLearnedOverflowBit() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let v = pubLearnedBit
        pubLearnedBit = -1
        return v
    }

    // MARK: - 확인 연결 조절 (판정 쪽에서 부른다, 아무 스레드에서나)

    /// STATE 줄 꼬리. 탐색 중이면 ", probing for 1.3s", 끝난 지 3초 안이면 ", probe ended 0.4s ago",
    /// 아니면 "". Windows BleRssiScanner::ProbeTagForLog 와 같은 글자. (자리만 잡아 둔다)
    func probeTagForLog(now: UInt64) -> String { "" }

    /// 같은 기기의 연속 실패로 늘어난 재시도 간격을 처음으로 되돌린다 (깨어남 등). (자리만 잡아 둔다)
    func resetProbeBackoff() {}

    /// 재보기 중인지. 재보기 동안은 직접 읽기 스캔(R)을 켠다 - 광고 기준을 평소 광고 경로와 같은
    /// 조건에서 재야 한다. (자리만 잡아 둔다)
    func setMeasuring(_ on: Bool) {}

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
    /// 권한은 앱 단위라 두 관리자가 같은 답을 받지만, 어느 쪽이 먼저 알아채도 말하게 둘 다 본다.
    var bluetoothDenied: Bool {
        if BLEIds.authorizationDenied { return true }
        lock.lock()
        defer { lock.unlock() }
        return pubCentralState == .unauthorized || pubRawCentralState == .unauthorized
    }

    /// 등록: 앱을 화면에 띄운 폰을 찾아 토큰을 읽는다.
    /// 포그라운드에서는 iOS 가 이름과 서비스 UUID 를 광고에 그대로 실으므로 후보가
    /// 모호하지 않다. 잠긴 폰으로 등록하면 남의 폰을 집을 위험이 있어 일부러 이 조건을 쓴다.
    /// 가장 신호가 센 것 하나만 시도한다. completion 은 메인에서 불린다.
    /// "register phone: ..." 줄은 부르는 쪽(UI)이 남긴다 (Windows 와 같다).
    /// 등록은 필터 스캔(F)만 쓴다 - 포그라운드 광고의 일반 서비스 목록은 필터가 확실히 맞춘다.
    func registerPhone(scanSec: Int, completion: @escaping (RegisterOutcome) -> Void) {
        BLEIds.queue.async { [weak self] in
            guard let self = self else { return }
            if let reg = self.registration {
                // 이미 진행 중이면 같은 결과를 같이 받는다 (UI 가 버튼을 꺼 두므로 드문 일)
                reg.completions.append(completion)
                return
            }
            let reg = Registration(scanSec: max(scanSec, 3))
            reg.completions.append(completion)
            self.registration = reg
            self.ensureCentral()
            // 권한이 없거나 꺼져 있으면 기다려 봐야 소용없다. 바로 그 이유로 끝낸다
            // ("폰을 찾지 못했습니다" 로 끝나면 사용자는 폰 쪽을 의심한다).
            let st = self.central?.state ?? .unknown
            if let why = AdvScanner.registrationBlockedWhy(st) {
                EventLog.write("register: Bluetooth unavailable (\(BLEIds.stateName(st)))")
                self.finishRegistration(.failure(why: why))
                return
            }
            // 켜져 있으면 여기서 스캔과 스캔 타이머가 같이 걸린다. 아직이면 켜지는 순간
            // state 콜백이 건다 - Windows 처럼 정해진 초 전부를 실제로 스캔하는 데 쓴다.
            self.updateScan()
            if reg.timer == nil {
                let w = DispatchSource.makeTimerSource(queue: BLEIds.queue)
                w.schedule(deadline: .now() + .seconds(AdvScanner.registerWaitCapSec))
                w.setEventHandler { [weak self, weak reg] in
                    guard let self = self, let reg = reg else { return }
                    self.registrationWaitExpired(reg)
                }
                reg.waitTimer = w
                w.resume()
            }
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
        // 잠긴 광고의 길은 결합마다 새로 센다 (다시 묶으면 "locked adverts" 줄을 다시 남긴다)
        boundLocked = ScanSourceTimes()
        lockedLog.reset()
        lock.lock()
        pubBound = id != nil
        lock.unlock()
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false
        updateScan()   // 두 스캔 모두 내린다 (등록 스캔 중이면 F 는 그대로)
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

    /// 스캔이 필요하면 (모니터링 중이거나 등록 스캔 중) 걸고, 아니면 멈춘다. 직접 읽기 스캔(R)도 같이 맞춘다.
    private func updateScan() {
        updateRawScan()
        guard let c = central, c.state == .poweredOn else { return }
        let regScanning = registration?.scanning ?? false
        if running || regScanning {
            // allowDuplicates 가 없으면 기기마다 didDiscover 가 한 번뿐이라 RSSI 흐름이 없다.
            c.scanForPeripherals(withServices: [BLEIds.identService],
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            if running { setAvailable(true) }
            // 등록 스캔의 시간은 스캔을 실제로 건 지금부터 잰다. 권한 창이나 꺼진 블루투스를
            // 기다린 시간이 스캔 시간을 먹으면 앱을 띄운 폰이 있어도 "못 찾았다" 가 된다.
            if let reg = registration, reg.scanning, reg.timer == nil {
                armRegistrationScanTimer(reg)
            }
        } else if c.isScanning {
            c.stopScan()
        }
    }

    /// 직접 읽기 스캔(R): 감시 중이고 토큰이 있을 때만. 관리자는 처음 필요할 때 만든다 - 권한은 앱
    /// 단위라 두 번째 관리자가 허용 창을 다시 띄우지 않는다. 켜지기 전이면 state 콜백이 건다.
    private func updateRawScan() {
        let want = running && identOn
        if want && rawCentral == nil {
            rawCentral = CBCentralManager(delegate: self, queue: BLEIds.queue, options: nil)
            return
        }
        guard let r = rawCentral, r.state == .poweredOn else { return }
        if want {
            // 거르지 않는다: 잠긴 폰의 overflow 광고가 필터에 안 걸려도 제조사 데이터는 온다고 본다.
            r.scanForPeripherals(withServices: nil,
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if r.isScanning {
            r.stopScan()
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
        if central === rawCentral {
            rawCentralStateChanged(central.state)
            return
        }
        guard central === self.central else { return }
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
        // 등록 중에 권한이 거부됐거나(권한 창에서 "허용 안 함") 블루투스가 꺼졌다/없다: 기다려도
        // 소용없으니 바로 그 이유로 끝낸다. (.resetting 은 곧 돌아오므로 기다린다.)
        let regWhy: String? = registration != nil ? AdvScanner.registrationBlockedWhy(st) : nil
        if let pr = probe {
            if pr.purpose.isIdent || regWhy != nil {
                abortProbe()
            } else {
                finishProbe(.unreachable, token: "", why: "Unreachable")
            }
        }
        if let why = regWhy {
            EventLog.write("register: Bluetooth unavailable (\(BLEIds.stateName(st)))")
            finishRegistration(.failure(why: why))
        }
    }

    /// R 의 상태. 화면에 보이는 상태(pubCentralState)와 등록은 F 의 것이다 - 여기서는 권한 거부를
    /// 기록하고, 켜지면 스캔을 걸고, 꺼지면 R 의 객체를 버린다.
    private func rawCentralStateChanged(_ st: CBManagerState) {
        lock.lock()
        pubRawCentralState = st
        lock.unlock()
        if st == .poweredOn {
            updateRawScan()
            return
        }
        // R 이 준 기기 객체는 이제 쓸 수 없다. R 에서만 본 후보는 버리고, 함께 본 후보는 F 의 것만
        // 남긴다 (F 의 객체로 계속 붙을 수 있다). R 위에서 돌던 탐색은 결과 없이 버린다.
        var kept: [UUID: Cand] = [:]
        for (id, c) in cands where c.viaFilter != nil {
            var k = c
            k.viaRaw = nil
            kept[id] = k
        }
        cands = kept
        if let pr = probe, pr.central === rawCentral { abortProbe() }
    }

    /// 광고 하나 = 패킷 하나 (뜨거운 경로). 가볍게, 기다리지 않게.
    /// 직접 읽기(R)는 주변의 모든 광고를 받으므로 특히 그렇다 - 후보도 내 폰도 아니고 진단 로그도
    /// 꺼져 있으면 사전 몇 번 보고 돌아간다.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let fromRaw: Bool
        if central === self.central {
            fromRaw = false
        } else if central === rawCentral {
            fromRaw = true
        } else {
            return
        }
        let rssi = RSSI.intValue
        let plainList = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflowList = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let inPlain = plainList.contains(BLEIds.identService)
        let inOverflow = overflowList.contains(BLEIds.identService)
        let valid = BLEIds.validRssi(rssi)

        // 등록 스캔: 일반 서비스 목록에 신원 UUID 가 있는 것(= 앱이 화면에 떠 있는 폰)만, F 에서만.
        // 잠긴 폰은 UUID 를 overflow 로 옮기므로 여기 안 걸린다 - 의도한 것.
        if !fromRaw, let reg = registration, reg.scanning, inPlain, valid, rssi > reg.bestRssi {
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
            // 잠긴 모양의 광고(일반 목록에 신원 UUID 가 없다)를 어느 쪽이 주는지 적는다. R 은 비트 하나짜리
            // overflow 광고나 overflow 목록에 신원 UUID 가 실린 것만 친다 - 같은 기기의 다른 Apple 광고는
            // 우리 신원을 싣지 않았다. 줄은 프로버 틱이 남긴다 (lockedLog).
            if !inPlain {
                boundLocked.note(fromRaw: fromRaw, bit: fromRaw ? AdvScanner.overflowBit(advertisementData) : -1,
                                 listed: inOverflow, plain: false, now: now)
            }
        } else if identOn {
            // 아직 못 묶었으면 후보로만 쌓아 둔다. 붙는 일은 프로버가 한다.
            if fromRaw {
                // Windows 와 같다: 제조사 데이터가 overflow 모양이고 비트가 딱 하나면 후보.
                // UUID 목록에 신원 UUID 가 실려 있으면(앱이 화면에 떠 있거나 macOS 가 overflow 를 풀어
                // 줬으면) 그것도 받는다 - 토큰이 가르므로 다른 것은 바뀌지 않는다.
                let bit = AdvScanner.overflowBit(advertisementData)
                let listed = inPlain || inOverflow
                if bit >= 0 || listed {
                    noteCandidate(id, peripheral, fromRaw: true, rssi: valid ? rssi : -127, now: now,
                                  sure: listed, bit: bit, plain: inPlain)
                }
            } else {
                // 필터 스캔이 준 기기는 신원 UUID 가 맞은 것이다. UUID 목록이 비어 있어도 받는다 -
                // macOS 가 overflow 해시로 맞춰 주면서 목록에는 아무것도 안 실을 수도 있다
                // (실기 미확인. 예전에는 목록에 있는 것만 받아서 그런 경우 잠긴 폰을 영영 못 봤다).
                noteCandidate(id, peripheral, fromRaw: false, rssi: valid ? rssi : -127, now: now,
                              sure: true, bit: -1, plain: inPlain)
            }
        }

        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let matched = identMatch
            || nameMatches(advName)
            // 서비스 UUID 는 앱 설치본마다 같으므로 폰을 특정하지 못한다.
            // 토큰이 없을 때의 임시방편일 뿐이다.
            || (!identOn && (inPlain || inOverflow))

        var smoothedInt = -100
        var duplicate = false
        if matched && valid {
            // 두 관리자가 같은 패킷을 각각 알렸으면 한 번만 센다 (DualSourceDedupe 주석).
            // 판정의 연속 2샘플 규칙이 샘플 수를 세므로, 사본을 세면 페이딩 한 번이 두 샘플이 된다.
            duplicate = !dedupe.accept(source: fromRaw ? AdvScanner.sourceRaw : AdvScanner.sourceFilter,
                                       now: now)
        }
        if matched && valid && !duplicate {
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

        // 진단 로그: 들은 광고를 기록해 대상 기기가 어떤 모양으로 보이는지 확인.
        // 버린 사본은 적지 않는다 - matched 줄은 판정이 실제로 쓴 샘플과 하나씩 맞아야 한다
        // (tools/rssi-threshold.ps1 이 그 줄들로 임계값을 계산한다).
        if let f = csv, !duplicate {
            logAdv(f, id: id, adv: advertisementData, name: advName, matched: matched,
                   raw: rssi, smoothed: smoothedInt, plainList: plainList, now: now)
        }
    }

    /// 후보 표에 넣거나 합친다. sure 는 한 번 서면 후보가 사라질 때까지 남고, 비트는 R 이 새로 읽을
    /// 때만 바뀐다 (같은 기기가 overflow 가 아닌 다른 광고도 내므로 -1 로 덮지 않는다).
    /// 쪽마다의 시각(times)은 광고마다 새로 적는다 - "via ..." 는 최근에 준 쪽만 말한다.
    private func noteCandidate(_ id: UUID, _ p: CBPeripheral, fromRaw: Bool, rssi: Int, now: UInt64,
                               sure: Bool, bit: Int, plain: Bool) {
        var c = cands[id] ?? Cand(viaFilter: nil, viaRaw: nil, rssi: -127, seen: now,
                                  sure: false, bit: -1, times: ScanSourceTimes())
        if fromRaw {
            c.viaRaw = p
        } else {
            c.viaFilter = p
        }
        c.rssi = rssi
        c.seen = now
        c.sure = c.sure || sure
        if bit >= 0 { c.bit = bit }
        c.times.note(fromRaw: fromRaw, bit: bit, listed: fromRaw && sure, plain: plain, now: now)
        cands[id] = c
    }

    /// 제조사 데이터가 overflow 모양(`4C 00 01` + 16바이트)이고 비트가 딱 하나면 그 번호, 아니면 -1.
    private static func overflowBit(_ adv: [String: Any]) -> Int {
        guard let md = adv[CBAdvertisementDataManufacturerDataKey] as? Data,
              md.count == AppleOverflow.length else { return -1 }
        return AppleOverflow.singleBit([UInt8](md))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // 다른 관리자의 콜백은 우리 탐색 것이 아니다 (같은 기기라도 객체가 다르다).
        guard let pr = probe, central === pr.central, pr.peripheral.identifier == peripheral.identifier,
              pr.stage == .connecting else { return }
        pr.stage = .services
        peripheral.delegate = self
        // 전체 탐색 (Windows 의 Uncached 전체 탐색과 같게). 10초 타이머는 그대로 이어진다.
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard let pr = probe, central === pr.central,
              pr.peripheral.identifier == peripheral.identifier else { return }
        finishProbe(.unreachable, token: "", why: "Unreachable")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // 결과가 나기 전에 끊겼다. 끝난 탐색의 끊김(우리가 끊은 것)은 probe 가 이미 nil 이다.
        // 아직 연결 중 단계라면 이 끊김은 같은 기기의 이전 연결 것이므로 무시한다.
        guard let pr = probe, central === pr.central, pr.peripheral.identifier == peripheral.identifier,
              pr.stage != .connecting else { return }
        finishProbe(.unreachable, token: "", why: "Unreachable")
    }

    // MARK: - CBPeripheralDelegate (토큰 읽기)
    // 탐색 중인 그 객체의 콜백만 받는다 (===). 다른 관리자가 준 같은 기기의 객체는 다른 객체다.

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let pr = probe, pr.peripheral === peripheral, pr.stage == .services else { return }
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
        guard let pr = probe, pr.peripheral === peripheral, pr.stage == .characteristics else { return }
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
        guard let pr = probe, pr.peripheral === peripheral,
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
    /// c 는 p 를 준 관리자여야 한다 (다른 관리자의 객체로는 연결할 수 없다).
    private func startProbe(_ p: CBPeripheral, on c: CBCentralManager, purpose: Purpose) {
        if probe != nil { abortProbe() }
        let pr = Probe(peripheral: p, central: c, purpose: purpose, t0: Mono.now())
        probe = pr
        guard c.state == .poweredOn else {
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
        // 연결을 건 그 관리자로 끊는다 - 다른 관리자에게 끊으라고 하면 아무 일도 안 일어난다.
        if pr.central.state == .poweredOn {
            pr.central.cancelPeripheralConnection(pr.peripheral)
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
        case .ident(let rssi, let bit, let via):
            identProbeDone(pr.peripheral.identifier, pickRssi: rssi, pickBit: bit, via: via,
                           outcome, token: token, why: why, took: took)
        case .register:
            registerProbeDone(outcome, token: token, why: why)
        }
    }

    // MARK: - 내부: 프로버 (2초마다, 한 번에 하나)

    private func proberTick() {
        // 스캔이 꺼져 있거나 토큰이 없으면 논다. 탐색이 진행 중이면 끝날 때까지 기다린다.
        guard running, identOn, probe == nil else { return }
        let now = Mono.now()

        // 묶인 폰의 잠긴 광고를 어느 길이 주는지: 처음 보일 때와 그 묶음이 바뀔 때만 한 줄 (LockedPathLog).
        // 실기에서 어느 스캔을 살릴지는 bound 줄이 아니라 이 줄로 가른다.
        if let b = boundId, let via = lockedLog.update(boundLocked, now: now) {
            EventLog.write("ident: \(BLEIds.shortId(b)) locked adverts via \(via)")
        }

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

        // Windows 처럼 두 번 훑는다 (IdentCandidatePick): 1차는 신원 UUID 를 직접 본 후보와 배운
        // 비트가 맞는 후보, 못 찾으면 2차로 전체를 신호 순으로.
        var list: [IdentCandidate<UUID>] = []
        list.reserveCapacity(cands.count)
        for (id, c) in cands {
            list.append(IdentCandidate(id: id, rssi: c.rssi, sure: c.sure, bit: c.bit))
        }
        guard let pick = IdentCandidatePick.pick(list, learnedBit: identBit, probeFloor: probeFloor,
                                                 probedUntil: probedUntil, now: now),
              let c = cands[pick.id] else { return }
        // F 의 객체가 있으면 F 로 붙는다 (원래 경로). R 에서만 본 기기는 R 로.
        let p: CBPeripheral
        let mgr: CBCentralManager
        if let fp = c.viaFilter, let f = central {
            p = fp
            mgr = f
        } else if let rp = c.viaRaw, let r = rawCentral {
            p = rp
            mgr = r
        } else {
            return
        }
        probedUntil[pick.id] = now + AdvScanner.retryUnreachableMs   // 잠정 잠금
        // bound 줄의 "via ...": 탐색 직전 10초 안에 이 기기를 준 쪽만 (filter / raw bit N / raw list,
        // 여럿이면 " + "), 그동안 앱이 화면에 떠 있던 광고도 왔으면 ", app on screen" (ScanSourceTimes).
        // 첫 판은 후보가 생긴 뒤 한 번이라도 준 쪽을 다 적어서, 앱이 떠 있을 때 필터가 준 폰을 잠근 뒤
        // 묶어도 "via filter" 였다.
        startProbe(p, on: mgr, purpose: .ident(rssi: c.rssi, bit: c.bit, via: c.times.viaText(now: now)))
    }

    private func identProbeDone(_ id: UUID, pickRssi: Int, pickBit: Int, via: String, _ outcome: ProbeOutcome,
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
        // 앞부분("ident: bound to XXXX (") 은 Windows 와 같다 - grep 이 그대로 맞는다.
        EventLog.write("ident: bound to \(sid) (\(pickRssi) dBm, \(took)ms" + (via.isEmpty ? "" : ", via \(via)") + ")")
        if pickBit >= 0 && pickBit != identBit {
            identBit = pickBit
            lock.lock()
            pubLearnedBit = pickBit   // 설정에 저장하도록 알린다 (메인의 1초 틱이 꺼내 간다)
            lock.unlock()
            EventLog.write("ident: overflow bit is now \(pickBit)")
        }
    }

    // MARK: - 내부: BLE 직접 등록

    /// 등록을 기다려도 소용없는 블루투스 상태면 사용자에게 보일 이유, 아니면 nil.
    /// (권한 문장은 spec 4.8 의 것. 부르는 쪽이 "등록하지 못했습니다." 로 감싼다.)
    private static func registrationBlockedWhy(_ st: CBManagerState) -> String? {
        if BLEIds.authorizationDenied || st == .unauthorized {
            return "블루투스 권한이 없어요. 시스템 설정 > 개인정보 보호 및 보안 > 블루투스에서 SmartScreen 을 켜 주세요."
        }
        switch st {
        case .poweredOff:
            return "블루투스가 꺼져 있어요. 켠 뒤 다시 하세요."
        case .unsupported:
            return "이 Mac 에서 블루투스를 쓸 수 없어요."
        default:
            return nil
        }
    }

    /// 스캔을 실제로 건 순간에 부른다 (updateScan). 블루투스를 기다리던 상한은 여기서 끝난다.
    private func armRegistrationScanTimer(_ reg: Registration) {
        reg.waitTimer?.cancel()
        reg.waitTimer = nil
        let t = DispatchSource.makeTimerSource(queue: BLEIds.queue)
        t.schedule(deadline: .now() + .seconds(reg.scanSec))
        t.setEventHandler { [weak self] in self?.registrationScanEnded() }
        reg.timer = t
        t.resume()
    }

    /// 상한(30초) 동안 블루투스가 켜지지 않았다 (권한 창에 답하지 않았거나, 재설정이 끝나지 않았다).
    private func registrationWaitExpired(_ reg: Registration) {
        guard registration === reg, reg.scanning, reg.timer == nil else { return }
        let st = central?.state ?? .unknown
        EventLog.write("register: Bluetooth not ready after \(AdvScanner.registerWaitCapSec)s (\(BLEIds.stateName(st)))")
        let why = AdvScanner.registrationBlockedWhy(st)
            ?? "블루투스가 준비되지 않았어요. 블루투스 권한을 묻는 창이 떴다면 허용한 뒤 다시 하세요."
        finishRegistration(.failure(why: why))
    }

    private func registrationScanEnded() {
        guard let reg = registration, reg.scanning else { return }
        reg.scanning = false
        reg.timer?.cancel()
        reg.timer = nil
        updateScan()
        guard let best = reg.best, let f = central else {
            finishRegistration(.failure(why: "앱을 화면에 띄운 폰을 찾지 못했습니다"))
            return
        }
        EventLog.write("register: candidate \(BLEIds.shortId(best.identifier)) rssi=\(reg.bestRssi) dBm")
        startProbe(best, on: f, purpose: .register)   // best 는 F 가 준 객체다
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
        reg.waitTimer?.cancel()
        reg.waitTimer = nil
        if reg.scanning {
            // 스캔 단계에서 끝났다 (블루투스 없음/권한 없음/기다림 상한). 모니터링이 아니면 스캔을 내린다.
            reg.scanning = false
            updateScan()
        }
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
    /// 두 스캔의 광고가 섞여 들어온다 (어느 쪽인지는 적지 않는다 - 칸을 늘리면 그 도구가 틀린다).
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
