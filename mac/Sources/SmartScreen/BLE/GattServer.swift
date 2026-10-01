import Foundation
import CoreBluetooth
import SmartScreenCore

/// BLE GATT 서버 (v2 근접 감지). client/ble_gatt.cpp 를 옮긴 것.
///
/// 역할 반전: PC 가 GATT 서버(주변장치), 아이폰 컴패니언 앱이 central 로 연결을 유지한다.
///  - PC 가 TICK 특성으로 알림을 보내면 iOS 가 (잠금 상태에서도) 앱을 깨운다
///  - 앱이 연결 RSSI 를 읽어 RSSI 특성에 써 준다 -> PC 는 ~1Hz 로 RSSI 를 받는다
/// iOS 백그라운드 "광고" 는 10~50초에 한 번뿐이지만, "연결" 은 스로틀되지 않는다.
///
/// 보안 (그대로 옮긴 미해결 항목): 이 경로는 폰을 식별하지 않는다. 연결해 오는 SSBeacon 폰은
/// 누구 것이든 믿는다. 고치려면 iOS/Windows 와 함께 프로토콜을 바꿔야 한다.
///
/// [중지] 는 광고와 TICK 만 멈추고 서비스는 내리지 않는다 (stopOnQueue). CBPeripheralManager 는 붙어
/// 있는 central 을 끊을 수 없어서, 서비스를 지우면 아이폰은 무효가 된 핸들을 든 채 계속 붙어 있고
/// 다시 구독하지 않는다 - 처음 판은 [중지] -> [시작] 한 번에 그 세션 내내 GATT 경로가 죽었다. 그래서
/// 서비스와 구독 기록을 그대로 두고, [시작] 이 남아 있는 구독자를 새 구독처럼 받아들인다. 서비스를
/// 지우고 다시 올리는 것은 블루투스가 꺼졌다 켜졌을 때(그때는 연결도 이미 끊겼다)와 암호화 설정이
/// 바뀌었을 때뿐이다. 폰 앱이 서비스 변경을 알아채고 다시 구독하게 되더라도 여기는 그것에 기대지 않는다.
final class GattServer: NSObject, CBPeripheralManagerDelegate {
    static let shared = GattServer()

    // MARK: - 잠금으로 보호되는 공개 상태

    private let lock = NSLock()
    private var pubRunning = false
    private var pubSubCount = 0
    private var pubEverSubscribed = false
    private var pubRaw = -100
    private var pubSmoothed = -100
    private var pubLastReportTick: UInt64 = 0   // GATT 경로의 샘플 정체성. 0 = 이번 구독 뒤 보고 없음
    private var pubPollStartTick: UInt64 = 0
    private var pubLostTick: UInt64 = 0          // 마지막으로 구독이 끊긴 시각 (Windows LostTick, 진단용)
    private var pubIntervalMs: UInt32 = 0        // 0 = 사용자가 입력 중이라 폴링 쉬는 중 (또는 구독자 없음)
    private var reportHandler: (() -> Void)?

    /// RSSI 보고와 구독 변화마다 (BLE 큐에서) 불린다 - 판정 스레드를 바로 깨운다.
    var onReport: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return reportHandler
        }
        set {
            lock.lock()
            reportHandler = newValue
            lock.unlock()
        }
    }

    // MARK: - BLEIds.queue 전용 상태

    private var pm: CBPeripheralManager?
    private var running = false
    private var plain = true
    private var kalman = KalmanFilter(processNoise: 4.0, measureNoise: 10.0)   // 1Hz 샘플링: v1(Q=1)보다 빠르게 반응
    private var subs = Set<UUID>()               // TICK 구독자 (central identifier). [중지] 동안에도 적는다
    private var tickChar: CBMutableCharacteristic?
    private var serviceAdded = false             // [중지] 를 넘어 남는다 (꺼짐/재설정이 지운다)
    private var addPending = false
    private var addedPlain = true                // 올렸거나 올리는 중인 서비스의 plain 값
    private var lastAddErrorCode: Int?
    private var advStartPending = false
    private var advStartTick: UInt64 = 0
    private var firstAdvLogPending = false
    private var pendingRestartLog: Int?
    private var advRetries = 0
    private var tickTimer: DispatchSourceTimer?
    private var seq: UInt8 = 0
    private var lastSent: UInt64 = 0
    private var lastAdvCheck: UInt64 = 0
    private var csv: BLEIds.CsvLog?
    private var stateSem: DispatchSemaphore?
    private var loggedState: CBManagerState?

    private override init() {
        super.init()
    }

    // MARK: - 공개 API

    /// plain=true 면 암호화 요구 없이 동작한다 (기본. bleGattEncrypt=1 이면 false:
    /// 본딩은 PC 마다 따로 맺어야 해서 폰을 다른 PC 로 옮기면 조용히 끊겼다).
    /// logPath 가 비어 있지 않으면 RSSI 보고를 CSV 로 기록한다.
    /// 주변장치 역할을 못 쓰거나 권한이 없을 때만 false. 그 밖에는 true 이고, 블루투스가
    /// 켜지는 대로 서비스를 올리고 광고한다.
    @discardableResult
    func start(plain: Bool, logPath: String?) -> Bool {
        if BLEIds.authorizationDenied {
            EventLog.write("GATT start failed: Bluetooth permission denied")
            return false
        }

        var waitSem: DispatchSemaphore?
        BLEIds.sync {
            if running { stopOnQueue() }
            resetState()   // 구독 기록(subs)은 남긴다 - 아래에서 이어받는다
            self.plain = plain
            if pm == nil {
                pm = CBPeripheralManager(delegate: self, queue: BLEIds.queue, options: nil)
            }
            if let m = pm, m.state == .unknown || m.state == .resetting {
                let s = DispatchSemaphore(value: 0)
                stateSem = s
                waitSem = s
            }
        }
        // 관리자를 처음 만들면 상태가 비동기로 온다. 주변장치 역할 지원 여부를 Windows 처럼
        // Start 의 결과로 돌려주려고 잠깐(최대 1초) 기다린다. 콜백은 BLE 큐로 오므로 메인이
        // 기다려도 교착되지 않는다. (처음 실행 때 권한을 묻는 중이면 그냥 지나간다)
        if let s = waitSem {
            _ = s.wait(timeout: .now() + 1.0)
        }

        var ok = false
        BLEIds.sync {
            stateSem = nil
            guard let m = pm else { return }
            switch m.state {
            case .unsupported:
                EventLog.write("GATT start failed: adapter has no peripheral role")
            case .unauthorized:
                EventLog.write("GATT start failed: Bluetooth permission denied")
            default:
                if let p = logPath, !p.isEmpty, let f = BLEIds.CsvLog(path: p) {
                    f.write("# session\ntime,seq,rawRssi,smoothedRssi,pollIntervalMs\n")
                    csv = f
                }
                running = true
                lock.lock()
                pubRunning = true
                lock.unlock()
                if m.state == .poweredOn {
                    resumeService()
                } else {
                    // 켜지는 순간 state 콜백이 서비스를 올린다. 꺼져 있거나 재설정 중이면 연결도 남아 있을 수
                    // 없다 - 그 콜백이 아직 큐에 있어도 이어받지 않게 여기서 비운다.
                    subs.removeAll()
                }
                EventLog.write("GATT server started (\(plain ? "plain" : "encryption required"))")
                // [중지] 동안에도 붙어 있던 폰을 새 구독처럼 받아들인 다음에 200 ms 틱을 건다. 구독자 수,
                // 첫 간격, 기준 시각이 한 번에 게시된 뒤에 틱이 간격을 이어서 고친다 (새 구독과 같은 상태).
                adoptKeptSubscribers()
                startTickTimer()
                ok = true
            }
        }
        return ok
    }

    func stop() {
        BLEIds.sync { stopOnQueue() }
    }

    func snapshot(now: UInt64) -> GattSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var s = GattSnapshot()
        s.running = pubRunning
        s.subscribed = pubSubCount > 0
        s.everSubscribed = pubEverSubscribed
        let iv = pubIntervalMs
        s.pollIntervalMs = iv
        // 연결되어 있고, 폴링 중이라면 보고가 제때 들어오고 있는지
        if pubSubCount > 0 {
            if iv == 0 {
                s.healthy = true   // 폴링 쉬는 중: 연결 유지만으로 충분
            } else {
                let ref = max(pubLastReportTick, pubPollStartTick)
                let limit = max(UInt64(iv) * 3, 8000)
                s.healthy = BLEIds.elapsed(now, since: ref) < limit
            }
        }
        if pubLastReportTick == 0 {
            s.reportAgeMs = 0xFFFF_FFFF
        } else {
            s.reportAgeMs = UInt32(min(BLEIds.elapsed(now, since: pubLastReportTick), 0xFFFF_FFFE))
        }
        s.lastReportTick = pubLastReportTick
        s.smoothedRssi = pubSmoothed
        s.rawRssi = pubRaw
        return s
    }

    // MARK: - 내부

    /// 세션마다 새로 시작하는 값. subs 는 지우지 않는다: 이어지는 연결이 있으면 start 가
    /// adoptKeptSubscribers 로 이어받고, 그때 everSubscribed 와 기준 시각을 다시 세운다.
    private func resetState() {
        lock.lock()
        pubSubCount = 0
        pubRaw = -100
        pubSmoothed = -100
        pubLastReportTick = 0
        pubPollStartTick = 0
        pubLostTick = 0
        pubEverSubscribed = false
        pubIntervalMs = 0
        lock.unlock()
        kalman.reset()
        seq = 0
        lastSent = 0
        lastAdvCheck = 0
        advRetries = 0
        pendingRestartLog = nil
        lastAddErrorCode = nil
        firstAdvLogPending = true
    }

    /// 프로세스 안의 [중지]. 광고와 TICK 틱만 멈춘다.
    /// 서비스(tickChar, serviceAdded)와 구독 기록(subs)은 그대로 둔다 - 클래스 머리말. 처음 판은 여기서
    /// removeAllServices 하고 subs 를 비웠는데, 아이폰은 끊기지 않은 채 무효가 된 핸들을 들고 남아서
    /// 다음 [시작] 의 새 서비스에 다시 구독하지 않았다. 멈춰 있는 동안 폰이 쓰는 RSSI 는 버리고
    /// (didReceiveWrite), 구독이 끊기면 subs 에서만 뺀다 (판정에는 알리지 않는다).
    private func stopOnQueue() {
        guard running else { return }
        running = false
        tickTimer?.cancel()
        tickTimer = nil
        if let m = pm, m.state == .poweredOn {
            m.stopAdvertising()
        }
        advStartPending = false
        pendingRestartLog = nil
        // everSubscribed / lostTick 은 여기서 되돌리지 않는다 (Windows 와 같다)
        lock.lock()
        pubRunning = false
        pubSubCount = 0
        pubIntervalMs = 0
        lock.unlock()
        csv?.close()
        csv = nil
    }

    /// [시작] 의 서비스: 올라가 있고 암호화 설정이 같으면 그대로 쓰고 광고만 다시 건다. 그래야 [중지]
    /// 동안 붙어 있던 폰의 핸들이 살아 있다. 아직 없거나 설정이 바뀌었을 때만 새로 올린다.
    private func resumeService() {
        if (serviceAdded || addPending) && addedPlain == plain {
            if serviceAdded { startAdvertising() }   // 올리는 중이면 didAdd 가 건다
            return
        }
        if (serviceAdded || addPending) && !subs.isEmpty {
            // 권한이 다른 특성으로 바꿔야 한다. 붙어 있던 폰의 핸들은 무효가 되고, 폰은 다시 구독하지
            // 않을 수 있다 (끊고 다시 붙어야 한다). 이번 세션에는 이어받지 않는다.
            subs.removeAll()
            EventLog.write("GATT service re-added (encryption setting changed) - existing subscription dropped")
        }
        addService()
    }

    /// 서비스 7A1C0010 (TICK notify + RSSI write) 를 올린다. 광고는 didAdd 다음에 건다.
    /// 처음 올릴 때, 꺼졌다 켜졌을 때, 암호화 설정이 바뀌었을 때, 올리기가 실패해 다시 할 때만 온다.
    private func addService() {
        guard running, let m = pm, m.state == .poweredOn else { return }
        // 같은 UUID 서비스가 둘 생기지 않게 먼저 비운다
        if m.isAdvertising { m.stopAdvertising() }
        m.removeAllServices()
        // 지운 서비스에 걸려 있던 구독도 같이 사라진다 (위 갈래들에서는 이미 비어 있다 - 지키기만 한다)
        if !subs.isEmpty {
            let prev = subs.count
            subs.removeAll()
            subscribersChanged(from: prev, to: 0)
        }
        addedPlain = plain
        // 본딩된 기기의 암호화 연결만 허용하는 모드 (bleGattEncrypt=1, 페어링을 부른다)
        let readPerm: CBAttributePermissions = plain ? [.readable] : [.readEncryptionRequired]
        let writePerm: CBAttributePermissions = plain ? [.writeable] : [.writeEncryptionRequired]
        let tick = CBMutableCharacteristic(type: BLEIds.tick, properties: [.notify],
                                           value: nil, permissions: readPerm)
        let rssi = CBMutableCharacteristic(type: BLEIds.rssi, properties: [.write, .writeWithoutResponse],
                                           value: nil, permissions: writePerm)
        let svc = CBMutableService(type: BLEIds.pcService, primary: true)
        svc.characteristics = [tick, rssi]
        tickChar = tick
        serviceAdded = false
        addPending = true
        m.add(svc)
    }

    private func startAdvertising() {
        guard let m = pm, m.state == .poweredOn else { return }
        advStartPending = true
        advStartTick = Mono.now()
        // UUID 만 싣는다 (이름 없음): 128비트 UUID 가 1차 광고 패킷에 남아야
        // 백그라운드 아이폰의 필터 스캔(withServices: [7A1C0010])이 찾는다.
        // 7A1C0020 은 절대 광고하지 않는다 - Windows PC 들이 이 Mac 을 폰 후보로 잡는다.
        m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [BLEIds.pcService]])
    }

    /// 광고가 멈춰 있으면 다시 켠다 (구독자가 없을 때 3초마다).
    private func ensureAdvertising() {
        guard running, let m = pm, m.state == .poweredOn else { return }
        if !serviceAdded {
            // 서비스 추가가 실패했으면 다시 해 본다
            if !addPending { addService() }
            return
        }
        if m.isAdvertising {
            advRetries = 0
            return
        }
        // 방금 건 광고의 응답을 기다리는 중이면 건드리지 않는다
        if advStartPending && BLEIds.elapsed(Mono.now(), since: advStartTick) < 5000 { return }
        // 먼저 멈추고 다시 건다 (Windows: Aborted 상태에서는 Start 만 다시 불러도 살아나지 않았다)
        m.stopAdvertising()
        advRetries += 1
        pendingRestartLog = advRetries   // 결과(status)는 didStartAdvertising 에서 남긴다
        startAdvertising()
    }

    private func startTickTimer() {
        tickTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: BLEIds.queue)
        t.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200),
                   leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        tickTimer = t
    }

    /// 200 ms 마다: 광고 점검, 폴링 간격 계산, TICK 알림.
    private func onTick() {
        guard running else { return }
        let now = Mono.now()
        if subs.isEmpty && BLEIds.elapsed(now, since: lastAdvCheck) > 3000 {
            lastAdvCheck = now
            ensureAdvertising()
        }
        let want: UInt32 = subs.isEmpty ? 0 : GattServer.desiredIntervalMs(now: now)
        lock.lock()
        let prev = pubIntervalMs
        pubIntervalMs = want
        if want > 0 && prev == 0 { pubPollStartTick = now }
        lock.unlock()
        if want == 0 || BLEIds.elapsed(now, since: lastSent) < UInt64(want) { return }
        guard let m = pm, let ch = tickChar, m.state == .poweredOn else { return }
        // 보내고 잊는다. false(전송 큐가 참)면 이번 틱은 버린다 - 쌓아 두면 낡은 틱이 뒤늦게 간다.
        _ = m.updateValue(Data([seq]), for: ch, onSubscribedCentrals: nil)
        seq = seq &+ 1       // 255 다음은 0
        lastSent = now
    }

    /// 폴링 정책: RSSI 가 필요한 건 "자리를 떴을지도 모를 때" 뿐 -> 입력 중에는 폰 앱을
    /// 깨우지 않는다 (배터리).
    private static func desiredIntervalMs(now: UInt64) -> UInt32 {
        if Shared.shared.blackActive { return 2000 }        // 잠김 상태: 복귀 감시
        let idle = BLEIds.elapsed(now, since: Shared.shared.lastInputTick)
        if idle < 5000 { return 0 }                         // 입력 중 = 자리에 있음
        if idle < 120_000 { return 1000 }                   // 입력 멈춤 직후: 빠르게 확인
        return 3000                                         // 오래 가만히 있음: 느리게
    }

    /// [시작]: [중지] 동안에도 끊기지 않은 구독자가 있으면 새 구독(0 -> N)과 같은 길로 받아들인다 -
    /// everSubscribed, 폴링 기준 시각, "이번 구독 뒤 보고 없음"(lastReportTick = 0), 그리고 판정을 깨우기
    /// 전에 간격부터 정하는 순서까지 같다 (subscribersChanged). 판정 쪽 계약(gattExpected / everSubscribed /
    /// 유예)은 그대로다: 폰이 실제로는 응답하지 않으면 새 구독이 그랬을 때와 같이 보고가 늦어 healthy 가
    /// 꺼지고, 광고도 안 들리면 부재로 판정된다.
    private func adoptKeptSubscribers() {
        if subs.isEmpty { return }
        subscribersChanged(from: 0, to: subs.count, kept: true)
    }

    /// 구독자 수가 바뀌었다 (0->N, N->0 규칙). 감시 중에만 부른다.
    /// kept: [시작] 이 [중지] 를 넘어 이어진 구독을 받아들이는 것 (로그 글자만 다르다).
    private func subscribersChanged(from prev: Int, to n: Int, kept: Bool = false) {
        let now = Mono.now()
        let firstSub = n > 0 && prev == 0
        // 새 구독이면 폴링 간격을 여기서 바로 정해 구독과 한 번에 내놓는다 (200 ms 틱과 같은 규칙).
        // 그러지 않으면 아래 wake 로 깨어난 판정이 "구독자 있음, 간격 0" 을 본다: 간격 0 이면
        // healthy 는 무조건 true 이고 판정은 "간격 0 = 사용자가 입력 중" 으로 읽어 NEAR 를 낸다.
        // 잠긴 화면이 자리에 아무도 없는데 한 샘플 동안 풀릴 수 있다.
        // Windows 에는 이 경합이 아직 있다 (client/ble_gatt.cpp SubscribedClientsChanged 가
        // reportEvent 를 먼저 깨우고 intervalMs 는 틱 스레드가 나중에 정한다).
        // Shared 의 잠금은 우리 잠금 밖에서 잡는다 (두 잠금을 겹쳐 잡지 않는다).
        let firstInterval: UInt32 = firstSub ? GattServer.desiredIntervalMs(now: now) : 0
        var lostRssi: Int?
        lock.lock()
        pubSubCount = n
        if firstSub {
            pubIntervalMs = firstInterval
            // 폴링 시작 시각도 같이 찍는다. 틱은 간격이 0 에서 0 이 아닌 값으로 바뀔 때만 다시
            // 찍으므로, 여기서 간격이 0 이 아니면 틱이 덮어쓰지 않고, 0 이면 입력이 멈춰 폴링을
            // 시작하는 순간 틱이 다시 찍는다 - 어느 쪽이든 healthy 의 기준 시각이 실제 폴링 시작이다.
            pubPollStartTick = now
            // 첫 보고가 오기 전까지 판정은 상태를 그대로 둔다 (ReportAgeMs = 0xFFFFFFFF).
            // 보고를 받기 전에 0 으로 해 둬야 한다 - 보고도 이 큐에서 처리되므로 순서가 지켜진다.
            pubLastReportTick = 0
            pubEverSubscribed = true
        } else if n == 0 && prev > 0 {
            pubLostTick = now
            lostRssi = pubSmoothed
        }
        let wake = reportHandler
        lock.unlock()
        if firstSub {
            kalman.reset()
            EventLog.write(kept ? "GATT client subscribed (kept across restart)" : "GATT client subscribed")
        }
        if let r = lostRssi {
            EventLog.write("GATT client lost (last rssi=\(r) dBm)")
        }
        wake?()
    }

    /// 폰의 RSSI 보고 하나.
    private func handleReport(rssi: Int, seq: Int) {
        if rssi >= 0 || rssi <= -127 { return }   // iOS: 127 = 측정 불가
        let now = Mono.now()
        lock.lock()
        let prev = pubLastReportTick
        lock.unlock()
        let dt = prev != 0 ? Double(BLEIds.elapsed(now, since: prev)) / 1000.0 : 1.0
        let sm = Int(kalman.update(Double(rssi), dtSec: dt).rounded())
        lock.lock()
        pubRaw = rssi
        pubSmoothed = sm
        pubLastReportTick = now      // GATT 경로의 샘플 정체성
        let iv = pubIntervalMs
        let wake = reportHandler
        lock.unlock()
        wake?()
        csv?.write("\(LocalClock.hhmmssmmm()),\(seq),\(rssi),\(sm),\(iv)\n")
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let st = peripheral.state
        if let s = stateSem {
            stateSem = nil
            s.signal()
        }
        // Mac 전용 진단 줄: 잠자기/깨기, 블루투스 끄고 켜기가 로그에서 보이게 한다.
        if running && loggedState != st {
            EventLog.write("GATT peripheral state: \(BLEIds.stateName(st))")
        }
        loggedState = st

        if st == .poweredOn {
            // 다시 켜졌다: 서비스를 다시 올리고 광고한다 (멈춰 있으면 다음 [시작] 이 올린다).
            // 서비스를 지우고 다시 올리는 것은 이 길(꺼짐/재설정 뒤)과 암호화 설정이 바뀐 [시작] 뿐이다.
            if running && !serviceAdded && !addPending { addService() }
            return
        }
        // 꺼짐/재설정/권한 없음: 올린 서비스와 연결이 모두 사라진다. 멈춰 있을 때도 적어 둔다 - 안 그러면
        // 다음 [시작] 이 사라진 서비스와 끊긴 구독을 그대로 쓴다고 믿는다.
        serviceAdded = false
        addPending = false
        advStartPending = false
        if !subs.isEmpty {
            let prev = subs.count
            subs.removeAll()
            if running { subscribersChanged(from: prev, to: 0) }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        addPending = false
        if let e = error {
            guard running else { return }
            // 3초 점검이 다시 시도한다. 같은 오류는 한 번만 남긴다.
            let code = (e as NSError).code
            if lastAddErrorCode != code {
                lastAddErrorCode = code
                EventLog.write("GATT start failed: add service error \(code)")
            }
            return
        }
        lastAddErrorCode = nil
        // [중지] 사이에 끝났어도 올라간 것은 맞다 - 다음 [시작] 이 그대로 쓴다 (resumeService)
        serviceAdded = true
        if running { startAdvertising() }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        advStartPending = false
        guard running else { return }
        // Windows 의 광고 상태 번호: 2=Started, 3=Aborted
        let st = error == nil ? 2 : 3
        EventLog.write("GATT advertisement status: \(error == nil ? "Started" : "Aborted")")
        if firstAdvLogPending {
            firstAdvLogPending = false
            EventLog.write("GATT advertising: status=\(st) (2=Started, 3=Aborted)")
        }
        if let n = pendingRestartLog {
            pendingRestartLog = nil
            EventLog.write("GATT advertisement restart #\(n) -> status=\(st)")
        }
    }

    // 구독 기록은 [중지] 동안에도 고친다 - 다음 [시작] 이 끊긴 구독을 이어받으면 안 되고, 남은 구독은
    // 이어받아야 한다 (adoptKeptSubscribers). 판정에 알리는 것(subscribersChanged)은 감시 중에만 한다.
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == BLEIds.tick else { return }
        let prev = subs.count
        subs.insert(central.identifier)
        if running {
            subscribersChanged(from: prev, to: subs.count)
        } else if prev == 0 && !subs.isEmpty {
            EventLog.write("GATT client subscribed while stopped")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == BLEIds.tick else { return }
        let prev = subs.count
        subs.remove(central.identifier)
        if running {
            subscribersChanged(from: prev, to: subs.count)
        } else if prev > 0 && subs.isEmpty {
            EventLog.write("GATT client lost while stopped")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == BLEIds.rssi {
            guard running, let v = r.value, v.count >= 1 else { continue }
            let b = [UInt8](v)
            let rssi = Int(Int8(bitPattern: b[0]))      // int8 (2의 보수)
            let s = b.count >= 2 ? Int(b[1]) : -1        // 폰이 마지막으로 받은 TICK 의 seq
            handleReport(rssi: rssi, seq: s)
        }
        // 응답이 필요한 쓰기(write-with-response)에 한 번 답한다
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // TICK 은 알림 전용이고 RSSI 는 쓰기 전용이다
        peripheral.respond(to: request, withResult: .readNotPermitted)
    }
}
