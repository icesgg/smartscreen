import Foundation
import SmartScreenCore

/// Windows 의 자동 리셋 이벤트(PacketEvent, ReportEvent)를 흉내 낸다: NSCondition + pending 깃발.
///
/// set() 이 여러 번 와도 pending 은 하나뿐이라, 기다리던 쪽은 한 번만 깨어난다. 세는 세마포어를
/// 쓰면 패킷이 몰려올 때 같은 판정이 여러 번 돌고 목록 행이 그만큼 늘어난다 - 판정은 같은 값을
/// 다시 읽을 뿐이라 깨어남을 하나로 합쳐도 결과는 같다.
/// 기다리는 스레드는 하나(판정 스레드)라고 가정한다. set() 은 어느 스레드에서 불러도 된다.
final class WakeSignal {
    private let cond = NSCondition()
    private var pending = false

    init() {}

    func set() {
        cond.lock()
        pending = true
        cond.signal()
        cond.unlock()
    }

    /// Returns true if woken by set(), false on timeout.
    /// 이미 pending 이면 기다리지 않고 바로 돌아온다. 돌아올 때 pending 을 지운다 (자동 리셋).
    func wait(timeoutMs: Int) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        if !pending {
            let deadline = Date(timeIntervalSinceNow: Double(max(timeoutMs, 0)) / 1000.0)
            // 가짜 깨어남(spurious wakeup)이 있어서 pending 을 다시 확인하며 같은 시한까지 기다린다.
            while !pending {
                if !cond.wait(until: deadline) { break }
            }
        }
        let woke = pending
        pending = false
        return woke
    }
}

/// Windows ScanThread 를 옮긴 판정 스레드. 판정 자체는 Core 의 ProximityJudge 가 하고,
/// 이 클래스는 스레드, 깨우기, 공유값 게시, 메인으로 결과 보내기만 맡는다.
///
/// GCD 큐가 아니라 전용 Thread 다: 대부분의 시간을 대기에서 막혀 보내기 때문이다.
/// 한 번 쓰고 버린다 - [시작] 마다 새 세션 번호로 새로 만든다. 세션 번호는 모든 결과에 실려서,
/// [중지] 직전에 보낸 결과가 [중지] 뒤에 도착하면 메인이 버릴 수 있다 (Windows 에서는 그 결과가
/// "정지됨" 을 덮어쓰고 FAR 전이로 화면을 잠글 수도 있었다).
final class JudgeThread {
    /// g_scanIntervalSec * 1000. StartMon 이 늘 2초로 둔다: 패킷이 안 와도 이보다 오래 판정을 쉬지 않는다.
    private static let scanIntervalMs = 2000
    /// StopMon 의 WaitForSingleObject(g_hThread, 15000).
    private static let joinTimeoutSec = 15
    private static let gattSeenLine = "companion app seen - GATT connection is now required for NEAR"

    private let session: Int
    private let onResult: (ProbeResult) -> Void
    private let onGattSeen: () -> Void
    private let wakeSignal = WakeSignal()

    // stop 깃발은 깨우기 신호와 따로 둔다: 패킷 깨우기가 stop 을 가리면 안 된다 (Windows 의
    // WaitForMultipleObjects 는 가장 낮은 번호인 stop 이 이긴다).
    private let flagLock = NSLock()
    private var started = false
    private var stopRequested = false
    private var joinPending = false
    private let finished = DispatchSemaphore(value: 0)

    /// onResult / onGattSeen are delivered on the main queue. session is copied into every result.
    init(session: Int, onResult: @escaping (ProbeResult) -> Void, onGattSeen: @escaping () -> Void) {
        self.session = session
        self.onResult = onResult
        self.onGattSeen = onGattSeen
    }

    /// 스레드를 띄운다. 첫 판정은 기다리지 않고 바로 돈다. 두 번째 호출이나 stop() 뒤의 호출은 무시한다.
    func start() {
        flagLock.lock()
        if started || stopRequested {
            flagLock.unlock()
            return
        }
        started = true
        joinPending = true
        flagLock.unlock()

        // Windows 는 스레드 첫머리에서 g_proxState = Far, g_lastNearTick = 0 으로 되돌린다
        // (StopMon 은 되돌리지 않는다). 여기서는 스레드를 띄우기 전에 한다 - 그래야 메인이
        // g_monitoring 을 켜고 1초 틱을 걸기 전에 지난 세션의 NEAR 가 남아 있지 않다.
        Shared.shared.lastNearTick = 0
        Shared.shared.proxState = .far

        // 광고 패킷이나 GATT 보고가 오면 주기를 기다리지 않고 바로 다시 판정한다
        // (Windows: WaitForMultipleObjects(stop, PacketEvent, ReportEvent, 2000)).
        // 약한 참조라서 이 판정 스레드가 끝난 뒤에 콜백이 와도 아무 일도 하지 않는다.
        AdvScanner.shared.onSample = { [weak self] in self?.wake() }
        GattServer.shared.onReport = { [weak self] in self?.wake() }

        // 스레드가 self 를 강하게 잡는다: 루프가 도는 동안 판정기가 사라지면 안 된다.
        // stop() 이 깃발을 세우고 기다리면 루프가 끝나며 놓아준다.
        let t = Thread { [self] in
            self.run()
        }
        t.name = "SmartScreen judge"
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// stop 깃발을 세우고 깨운 뒤 스레드가 끝나기를 최대 15초 기다린다. 진행 중이던 판정 한 번은
    /// 끝까지 돌고 결과도 보낸다 (Windows 와 같다; 그 결과는 세션 번호로 메인이 버린다).
    /// StopMon 은 이걸 스캐너·GATT 서버를 멈추기 **전에** 불러야 한다 - 멈춘 객체를 읽지 않게.
    func stop() {
        flagLock.lock()
        stopRequested = true
        let mustJoin = joinPending
        joinPending = false
        flagLock.unlock()

        wakeSignal.set()
        if mustJoin {
            // 시간이 지나도 그냥 간다 (Windows 도 15초 뒤에는 기다리지 않는다).
            _ = finished.wait(timeout: .now() + .seconds(JudgeThread.joinTimeoutSec))
        }
    }

    /// thread-safe; called from BLE callbacks.
    func wake() {
        wakeSignal.set()
    }

    // MARK: - 판정 스레드

    private func isStopRequested() -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return stopRequested
    }

    private func run() {
        // 판정 상태(히스테리시스용 현재 상태, 2샘플 규칙의 카운터)는 스레드마다 새로 시작한다.
        let judge = ProximityJudge()
        // stop 을 먼저 본다: 깨어난 이유가 패킷이든 시간 초과든 stop 이 서 있으면 판정하지 않는다.
        while !isStopRequested() {
            // 런 루프가 없는 스레드라 반복마다 autorelease 풀을 비운다.
            autoreleasepool {
                iterate(judge)
            }
            _ = wakeSignal.wait(timeoutMs: JudgeThread.scanIntervalMs)
        }
        finished.signal()
    }

    private func iterate(_ judge: ProximityJudge) {
        let now = Mono.now()
        let scanner = AdvScanner.shared.snapshot(now: now)
        let gatt = GattServer.shared.snapshot(now: now)
        let settings = Shared.shared.judgeSettings()
        let out = judge.step(now: now, scanner: scanner, gatt: gatt, settings: settings,
                             timeStr: LocalClock.hhmmss())

        // 앱이 처음 연결되면 config 에 기록 -> 다음부터는 미연결을 "부재" 로 취급.
        if out.becameGattSeen {
            // 다음 판정부터 다시 알리지 않도록 공유값은 여기서 바로 켠다 (Windows 도 스캔 스레드가 켠다).
            Shared.shared.gattSeen = true
            // 저장은 메인이 한다 (Windows WM_GATT_SEEN). 여기서 직접 Load -> Save 하면
            // 그 사이에 메인이 쓴 값(회전한 refresh 토큰 등)을 낡은 사본으로 덮는다.
            let seen = onGattSeen
            DispatchQueue.main.async {
                seen()
            }
            EventLog.write(JudgeThread.gattSeenLine)
        }

        // 결과를 보내기 전에 공유 상태를 먼저 쓴다: 메인의 잠금 관문은 결과의 state 가 아니라
        // 이 값을 읽는다. lastNearTick 을 먼저 쓰는 것은 Windows 의 순서와 같다.
        Shared.shared.lastNearTick = judge.lastNearTick
        Shared.shared.proxState = judge.state

        var r = out.result
        r.session = session
        let result = r
        let deliver = onResult
        // 보내기만 하고 기다리지 않는다 (PostMessage). main.async 는 NSAlert.runModal() 중에도 처리된다.
        DispatchQueue.main.async {
            deliver(result)
        }
    }
}
