import Foundation

// 근접 판정기. Windows client/main.cpp 의 ScanThread 루프 본문을 한 줄씩 옮겼다.
//
// 스레드와 대기(WaitForMultipleObjects)는 앱 쪽 JudgeThread 가 맡고, 여기는 "한 번 판정"
// 만 한다. 입력은 그 순간의 스캐너/GATT 상태 사본과 설정값 사본이라, 같은 입력이면 같은
// 판정이 나온다 - 그래서 docs/PROXIMITY.md 의 타임라인을 그대로 단위 테스트로 돌릴 수 있다.
//
// Mac 에는 latency(RFCOMM) 경로가 없다. Windows 에서도 등록된 폰(g_targetAddr == 0)은 그
// 경로를 쓰지 않는다 - 30~50m 까지 닿아 자리 비움을 놓치고, 같은 안테나의 BLE 슬롯만
// 빼앗는다. Mac 은 늘 그 "등록된 폰" 갈래를 탄다: BLE 로 판단할 수 없으면 unreachable.

/// NEAR / FAR. Windows `ProxState` + `StateStr`.
public enum ProxState: Equatable {
    case far, near

    /// "NEAR" / "FAR" (events.log, 목록, 상태바에 그대로 찍힌다)
    public var name: String {
        switch self {
        case .near: return "NEAR"
        case .far: return "FAR"
        }
    }
}

/// 광고 스캐너 상태를 `now` 시점에 본 사본 (Windows g_bleScanner 의 접근자들).
public struct ScannerSnapshot {
    /// 스캔 시작에 성공했다 (Windows IsAvailable 처럼 한 번 켜지면 다음 Start 실패 전까지 유지)
    public var available = false
    /// 마지막으로 짝이 맞은 패킷의 시각 (0 = 이번 세션에 아직 없음)
    public var lastReceivedTick: UInt64 = 0
    /// 아무것도 못 받았거나 마지막 패킷이 timeout 보다 오래됐으면(엄격한 >) 이미 -100
    public var smoothedRssi = -100
    /// 같은 규칙의 마지막 원시값
    public var rawRssi = -100
    /// last != 0 && now - last < timeout
    public var receiving = false
    /// last != 0
    public var hasEverReceived = false
    /// 최근 10 초 동안 짝이 맞은 패킷 수 / 10
    public var packetRate = 0.0
    /// 토큰 읽기로 폰 하나가 확인(바인딩)됐다
    public var bound = false
    public init() {}
}

/// GATT 서버 상태를 `now` 시점에 본 사본 (Windows g_bleGatt 의 접근자들).
public struct GattSnapshot {
    public var running = false
    public var subscribed = false
    public var everSubscribed = false
    public var healthy = false
    /// 0 = 입력 중이라 폴링을 쉬는 중 (또는 구독자 없음)
    public var pollIntervalMs: UInt32 = 0
    /// 0xFFFFFFFF = 이번 구독 뒤로 보고가 아직 없음
    public var reportAgeMs: UInt32 = 0xFFFF_FFFF
    public var lastReportTick: UInt64 = 0
    public var smoothedRssi = -100
    public var rawRssi = -100
    public init() {}
}

/// 판정 스레드가 매 회 읽는 설정값 사본 (Windows 전역들).
public struct JudgeSettings {
    public var nearRssiThreshold = -65
    public var gattRssiThreshold = -65
    public var gattSeen = false
    public var gattGraceSec: UInt32 = 90
    public var monStartTick: UInt64 = 0
    public var bleLostMeansFar = true
    public var keepAliveSec: UInt32 = 5
    public var nearLatencyMs: UInt32 = 200
    public init() {}
}

/// 한 번의 판정 결과 (Windows ProbeResult). UI 스레드로 값 그대로 넘긴다.
public struct ProbeResult {
    public var reachable = false
    public var latencyMs: UInt32 = 0
    public var rssiDbm = -100
    /// true: 연결(GATT) 경로가 판정했다 ("absent" 규칙 포함)
    public var gatt = false
    public var bleAvailable = false
    public var wsaError = 0
    /// 이 샘플을 판정할 때 실제로 쓴 임계값. 히스테리시스 때문에 설정값과 다를 수 있어
    /// (FAR 에서 돌아올 때는 +4dB) 설정값만 찍으면 로그를 봐도 판정을 재현할 수 없다.
    public var thresholdDbm = -65
    public var timeStr = ""
    public var state: ProxState = .far
    public var prevState: ProxState = .far
    public var timerRemainMs: UInt32 = 0
    /// 모니터링 세션 번호. [중지] 뒤에 도착한 낡은 결과를 버리는 데 쓴다 (호출자가 채운다).
    public var session = 0
    public init() {}
}

/// ScanThread 의 상태 기계. 판정 스레드 하나만 부른다 (스레드 안전하지 않다).
/// 모니터링을 시작할 때마다 새로 만든다 - Windows 도 스레드 시작 때 g_proxState = Far,
/// g_lastNearTick = 0 으로 되돌린다.
public final class ProximityJudge {
    /// 두 번째 미만 샘플을 기다리는 최대 시간. 걸어나가는 폰은 두 번째 패킷을 영영 안
    /// 보낼 수 있고 수신 타임아웃은 90 초다. 6 s 는 실측 p90 패킷 간격 5.8 s 바로 위.
    private static let belowSampleCapMs: UInt64 = 6000
    /// FAR 에서 NEAR 로 돌아올 때 더하는 히스테리시스 (dB)
    private static let hysteresisDb = 4
    /// 깨어난 뒤 새 샘플을 기다리는 최대 시간 (Windows kWakeGraceMs, client/common.h).
    /// 잠든 동안 스캐너도 GATT 연결도 멎었다 - 깨어난 직후의 "신호 없음" 은 부재가 아니라 아직
    /// 아무것도 못 들은 것이다. 그대로 두면 깨자마자 수신 타임아웃(-100)이나 끊긴 연결("absent")로
    /// FAR 이 되어, 책상 앞에서 Mac 을 연 사람 앞에서 화면이 가려진다.
    /// 광고 p90 간격 5.8 s 의 두 배쯤이다. 정말 자리에 없을 때 늦어지는 것은 이 12 s 뿐이다.
    public static let wakeGraceMs: UInt64 = 12000

    /// "judge: slept 32400s - absence waits up to 12s for a fresh sample". 초는 버림.
    /// Windows 와 같은 글자 (두 플랫폼의 events.log 가 같아야 한다).
    public static func sleptLine(sleptMs: UInt64) -> String {
        return "judge: slept \(sleptMs / 1000)s - absence waits up to \(wakeGraceMs / 1000)s for a fresh sample"
    }

    /// 유예가 새 샘플 없이 끝났을 때 한 번 (Windows 와 같은 글자).
    public static let wakeGraceExpiredLine =
        "judge: no sample within \(wakeGraceMs / 1000)s of waking - absence applies"

    public private(set) var state: ProxState = .far
    public private(set) var lastNearTick: UInt64 = 0
    /// 깨어난 것을 안 판정 시각. 0 = 유예 없음. 새 샘플이 오거나 12 s 가 지나면 0 으로 돌아간다.
    public private(set) var resumeTick: UInt64 = 0

    // 임계값 미만이 연속 몇 "샘플" 이어졌는지. 시간이 아니라 샘플 수로 센다.
    private var belowCount = 0
    private var belowFirstTick: UInt64 = 0   // 이 구간의 첫 미만 샘플 시각 (상한 계산용)
    private var belowSampleTick: UInt64 = 0  // 마지막으로 센 샘플의 식별자 (같으면 다시 세지 않는다)
    // Windows 는 스캔 스레드가 g_gattSeen 을 바로 true 로 바꾼다. 여기서는 설정 사본을
    // 바꿀 수 없으므로 한 번 알린 뒤로는 스스로 true 로 친다 - 호출자가 Shared 를
    // 고치기 전에 다음 판정이 돌아도 "companion app seen" 을 두 번 알리지 않는다.
    private var gattSeenLatched = false

    public init() {}

    /// 판정 스레드가 잠들었다 깬 것을 알아챘다 (반복 사이의 잠든 시간이 5 s 이상 늘었다).
    /// 이 뒤로 새 샘플(광고 패킷이나 GATT 보고의 시각 > now)이 올 때까지, 최대 12 s 동안은
    /// 어느 갈래로도 FAR 로 가지 않는다 - 지금 상태를 그대로 둔다. NEAR 로 가는 것은 막지 않는다.
    /// 유예 중에 다시 불러도 된다 (기준 시각만 새로 잡는다).
    public func noteResume(now: UInt64) {
        resumeTick = now
    }

    /// ScanThread 루프 한 바퀴. 결과의 session 은 0 으로 두고(호출자가 채운다),
    /// becameGattSeen 이 true 면 호출자가 UI 스레드에서 gattSeen 을 저장하고
    /// "companion app seen - GATT connection is now required for NEAR" 를 남긴다.
    /// wakeGraceExpired 가 true 면 깨어난 뒤 12 s 동안 새 샘플이 없어 유예가 끝났다 - 호출자가
    /// wakeGraceExpiredLine 을 한 번 남긴다 (이번 판정부터 평소 규칙이다).
    public func step(now: UInt64, scanner: ScannerSnapshot, gatt: GattSnapshot,
                     settings: JudgeSettings, timeStr: String)
        -> (result: ProbeResult, becameGattSeen: Bool, wakeGraceExpired: Bool) {
        var reachable = false
        let latency: UInt32 = 0          // Mac: latency 경로 없음
        var isNear = false
        var bleAvail = false
        var useGatt = false
        var rssi = -100
        var effThr = settings.nearRssiThreshold   // 이 샘플을 판정한 실효 임계값 (로그용)

        let gattSeen = settings.gattSeen || gattSeenLatched

        // 컴패니언 앱이 이 PC에 붙은 적이 있으면(이번 세션 또는 과거), GATT 연결이 끊긴 것
        // 자체가 자리 비움의 단서다. 다만 단서일 뿐이라 광고가 폰을 듣고 있으면 그쪽을 쓴다.
        // (C 의 부호 없는 뺄셈 그대로: monStartTick 이 0 이면 아주 큰 값이 된다)
        let sinceStart = now &- settings.monStartTick
        let gattExpected = gatt.running &&
            (gatt.everSubscribed || (gattSeen && sinceStart > UInt64(settings.gattGraceSec) * 1000))

        if gatt.healthy {
            // v2: 폰 앱이 GATT로 연결되어 ~1Hz로 RSSI를 보고 중 → 최우선 사용
            useGatt = true; bleAvail = true; reachable = true
            rssi = gatt.smoothedRssi
            // 아래 두 갈래는 임계값을 안 본다. 그래도 effThr 은 이 경로의 설정값으로
            // 둔다 - 기본값(광고 임계값)인 채로 두면 STATE 줄이 "GATT rssi=-65 thr=-67"
            // 처럼 다른 경로의 숫자를 찍어서, 로그만 보고는 왜 NEAR 가 됐는지 알 수 없다.
            effThr = settings.gattRssiThreshold
            if gatt.pollIntervalMs == 0 {
                isNear = true                                  // 입력 중이라 폴링을 쉬는 상태 = 자리에 있음
            } else if gatt.reportAgeMs == 0xFFFF_FFFF {
                isNear = (state == .near)                      // 첫 보고 대기 중: 현재 상태 유지
            } else {
                // 히스테리시스: 잠금은 임계값 미만, 해제는 임계값+4 이상 (경계에서 깜빡임 방지)
                let thr = settings.gattRssiThreshold + (state == .near ? 0 : ProximityJudge.hysteresisDb)
                effThr = thr
                isNear = (rssi >= thr)
            }
        } else if gattExpected && !(scanner.available && scanner.receiving) {
            // 앱이 붙어 있어야 하는데 연결도 없고 광고도 안 들린다 → 부재로 판정.
            //
            // 광고가 들리면 이쪽으로 오지 않는다. 예전에는 GATT가 끊기기만 하면
            // RSSI를 보지도 않고 부재로 단정했는데, 앱이 잠깐 떨어져 나간 것만으로
            // -46dBm 으로 들리는 폰을 두고 화면을 잠갔다.
            // (effThr 은 Windows 처럼 광고 임계값 그대로 둔다. 이 갈래는 임계값을 안 보므로 판정에는
            // 영향이 없다. 다만 연결 임계값은 광고 임계값 + gattRssiOffset 이라, 차이가 0 이 아니면
            // 이 STATE 줄의 thr= 는 set=(연결 설정값) 과 다르게 찍힌다. 두 플랫폼의 로그가 같아야 해서
            // 한쪽만 바꾸지 않는다.)
            useGatt = true; bleAvail = true; reachable = true
            rssi = -100
            isNear = false
        } else {
            // v1: BLE 광고 RSSI - 컴패니언 앱을 안 쓰거나, 아직 첫 연결 대기 중
            rssi = scanner.smoothedRssi
            // BLE 끊김 처리는 기기 종류에 따라 다름:
            //  - 상시 광고 기기(비콘): 끊김 = 범위 이탈 → rssi=-100으로 Far 판정 (bleLostMeansFar=true)
            //  - 앱 없는 iPhone: 잠금 상태에서 광고를 멈추므로 끊김 ≠ 이탈 → 수신 중일 때만 RSSI 사용
            bleAvail = scanner.available &&
                (settings.bleLostMeansFar ? scanner.hasEverReceived : scanner.receiving)
            if bleAvail {
                // BLE로 판단하는 동안은 다른 프로브를 하지 않는다 (같은 라디오의 시간을 빼앗는다)
                reachable = true
                // 히스테리시스: 잠금은 임계값 미만, 해제는 임계값+4 이상.
                // GATT 경로에만 있었는데, 실측에서 착석 분포의 아래 꼬리가 임계값에
                // 닿으면 1dB 흔들림에 NEAR/FAR 이 뒤집혔다. 같은 이유로 여기에도 필요하다.
                effThr = settings.nearRssiThreshold + (state == .near ? 0 : ProximityJudge.hysteresisDb)
                isNear = (rssi >= effThr)
            } else {
                // 등록된 폰은 Classic 주소가 없다 - Windows 도 이 경우 RFCOMM 을 찌르지 않는다.
                // Mac 은 latency 경로 자체가 없으므로 BLE 로 판단할 수 없으면 늘 여기다.
                reachable = false
            }
        }

        // 앱이 처음 연결되면 config에 기록 → 다음부터는 미연결을 "부재"로 취급.
        // 저장은 UI 스레드가 한다. 여기서 직접 Load -> Save 하면 그 사이에 UI 스레드가 쓴
        // 값(회전한 refresh 토큰 등)을 낡은 사본으로 덮는다.
        var becameGattSeen = false
        if !gattSeen && gatt.everSubscribed {
            gattSeenLatched = true
            becameGattSeen = true
        }

        let t = now
        let prev = state
        if !bleAvail {
            // Windows: inWarmup = (재연결 뒤 120 s 안). Mac 에는 재연결도 latency 도 없어 늘 false.
            isNear = reachable && latency <= settings.nearLatencyMs
        }

        // 깨어난 뒤의 유예. 잠든 동안의 수신 타임아웃(-100), 끊긴 GATT 연결("absent"), 오래된
        // lastNearTick(keepAlive) 은 모두 "자는 동안 아무것도 못 들었다" 일 뿐 자리를 비웠다는 증거가
        // 아니다. 그래서 깨어난 뒤 첫 새 샘플이 올 때까지는 FAR 로 가지 않는다. 새 샘플이 오면 그
        // 판정부터 평소 규칙이다 (미만 샘플이면 2 샘플 규칙이 바로 센다). 12 s 안에 아무것도 안
        // 오면 그때는 정말 없는 것이다 - 평소 규칙으로 부재를 적용한다.
        var holdForWake = false
        var wakeGraceExpired = false
        if resumeTick != 0 {
            let fresh = scanner.lastReceivedTick > resumeTick || gatt.lastReportTick > resumeTick
            if fresh {
                resumeTick = 0
                // 미만 카운터도 여기서 처음부터 센다 (Windows 도 같다). 잠들기 전에 센 미만 샘플 하나가
                // 남아 있으면 깬 뒤 첫 미만 샘플 하나로 2 샘플 규칙이 차고, 그 첫 샘플 시각이 몇 시간 전이라
                // 6 s 상한도 이미 지나 있다 - 책상 앞에서 Mac 을 연 사람 앞에서 샘플 하나로 화면이 가려진다.
                // 유예가 샘플 없이 끝날 때는 지우지 않는다 - 그때는 평소 규칙 그대로다.
                belowCount = 0; belowFirstTick = 0; belowSampleTick = 0
            } else if t &- resumeTick < ProximityJudge.wakeGraceMs {
                holdForWake = true
            } else {
                resumeTick = 0
                wakeGraceExpired = true
            }
        }

        if isNear {
            lastNearTick = t
            belowCount = 0; belowFirstTick = 0; belowSampleTick = 0
            if state == .far { state = .near }
        } else if holdForWake {
            // 지금 상태를 그대로 둔다. 미만 카운터도 건드리지 않는다 - 잠들기 전의 낡은 샘플을
            // 새 증거로 세면 안 된다.
        } else if state == .near {
            let goFar: Bool
            if !bleAvail {
                // latency 모드였던 갈래: 측정값이 매번 흔들리므로 유예시간을 둔다.
                // Mac 에서는 BLE 를 못 쓰게 된 경우(lostMeansFar=0 에서 수신 끊김 등)가 여기 온다.
                goFar = (t &- lastNearTick) >= UInt64(settings.keepAliveSec) * 1000
            } else if rssi <= -100 {
                // 약한 게 아니라 신호가 아예 없다 (수신 타임아웃, 또는 연결도 광고도 없음).
                // 이건 페이딩이 아니라 부재이므로 기다릴 이유가 없다.
                goFar = true
            } else {
                // 패킷 사이에는 새 정보가 없다 - 그래서 시간 유예는 지연만 늘린다.
                // 하지만 두 번째 패킷은 실제로 새 정보다. 그래서 시간이 아니라 샘플을 센다:
                // 새 샘플이 연속 두 번 임계값 미만일 때만 잠근다. 단발 페이딩으로
                // 앉아 있는 사람 앞에서 화면이 꺼지던 것이 이걸로 사라진다.
                // (경로가 바뀌어도 센 수는 이어진다: 광고 미만 1 + GATT 미만 1 = 2)
                let sampleTick = useGatt ? gatt.lastReportTick : scanner.lastReceivedTick
                if sampleTick != belowSampleTick {
                    if belowCount == 0 { belowFirstTick = t }
                    belowSampleTick = sampleTick
                    belowCount += 1
                }
                // 두 번째 샘플을 무한정 기다리면 안 된다: 걸어나가면서 신호가 끊기면
                // 다음 샘플이 영영 안 오고, 수신 타임아웃은 90초다. 상한을 둔다.
                goFar = (belowCount >= 2) || (t &- belowFirstTick) >= ProximityJudge.belowSampleCapMs
            }
            if goFar { state = .far }
        }
        // (FAR 이고 isNear 가 아니면 아무것도 안 한다. 미만 카운터도 여기서는 안 지운다.)

        var r = ProbeResult()
        r.reachable = reachable
        r.latencyMs = latency
        r.wsaError = 0
        r.rssiDbm = rssi
        r.bleAvailable = bleAvail
        r.gatt = useGatt
        r.thresholdDbm = effThr
        r.state = state
        r.prevState = prev
        r.timeStr = timeStr
        if state == .near {
            // Windows 는 DWORD(32 비트)로 계산한다
            let since = UInt32(truncatingIfNeeded: t &- lastNearTick)
            let keepMs = settings.keepAliveSec &* 1000
            r.timerRemainMs = since < keepMs ? keepMs - since : 0
        } else {
            r.timerRemainMs = 0
        }
        return (r, becameGattSeen, wakeGraceExpired)
    }
}

/// 판정 반복 사이에 시스템이 잠들어 있었는지 본다 (Windows: GetTickCount64() -
/// QueryUnbiasedInterruptTime()/10000, Mac: CLOCK_MONOTONIC - CLOCK_UPTIME_RAW = Mono.asleepMs()).
/// 두 값의 차이는 부팅 뒤 잠들어 있던 시간의 합이라, 반복 사이에 그것이 늘었으면 그만큼 잤다.
///
/// 알림(NSWorkspace.didWakeNotification)을 쓰지 않는 까닭: 알림은 메인으로 오고 판정 스레드와
/// 순서가 정해져 있지 않다 - 깨어난 판정 스레드가 알림보다 먼저 낡은 스캐너 상태로 판정할 수 있다.
/// 판정 스레드가 자기 반복에서 직접 재면 깨어난 뒤 첫 판정부터 유예가 걸린다.
public struct SleepWatch {
    /// 이만큼 이상 늘어야 "잤다" 로 본다. 두 시계를 한 번에 읽지 못해 생기는 흔들림(µs)과
    /// NTP 가 CLOCK_MONOTONIC 을 미는 몫(반복 2 s 동안 ms 미만)보다 한참 크다.
    public static let minSleptMs: UInt64 = 5000

    private var lastAsleepMs: UInt64?

    public init() {}

    /// 이번 반복에서 읽은 누적 잠든 시간(ms). 지난 반복보다 5000 ms 이상 늘었으면 늘어난 만큼을
    /// 돌려준다. 첫 호출은 기준만 잡는다. 줄었으면(시계 흔들림) 새 값을 기준으로 삼을 뿐이다 -
    /// 늘 직전 반복과 비교하므로 느린 밀림이 쌓이지 않는다.
    public mutating func observe(asleepMs: UInt64) -> UInt64? {
        defer { lastAsleepMs = asleepMs }
        guard let last = lastAsleepMs, asleepMs > last else { return nil }
        let grew = asleepMs - last
        return grew >= SleepWatch.minSleptMs ? grew : nil
    }
}

/// GATT TICK 간격 정책 (Windows client/ble_gatt.cpp DesiredIntervalMs 와 같은 순서).
/// RSSI 가 필요한 건 "자리를 떴을지도 모를 때" 뿐 -> 입력 중에는 폰 앱을 깨우지 않는다 (배터리).
public enum GattPollPolicy {
    /// blackActive: 화면이 가려져 있다. measuring: 재보기 마법사가 재는 중.
    /// idleMs: 마지막 키보드/마우스 입력 뒤로 지난 시간.
    /// 0 = TICK 을 보내지 않는다 (판정은 "입력 중 = 자리에 있음" 으로 읽는다).
    public static func intervalMs(blackActive: Bool, measuring: Bool, idleMs: UInt64) -> UInt32 {
        if blackActive { return 2000 }        // 잠김 상태: 복귀 감시
        // 재보기는 입력과 무관하게 1 초마다 잰다. 입력 5 초 규칙을 그대로 두면 앉아서 재는 1 분 동안
        // 타자를 친 사람은 TICK 이 멎어 연결 표본이 0 개다 ("연결 신호 못 쟀어요"). 재는 동안은
        // 잠금이 꺼져 있으므로 판정이 연결 RSSI 를 읽어 FAR 로 가도 화면은 가려지지 않는다.
        if measuring { return 1000 }
        if idleMs < 5000 { return 0 }         // 입력 중 = 자리에 있음
        if idleMs < 120_000 { return 1000 }   // 입력 멈춤 직후: 빠르게 확인
        return 3000                           // 오래 가만히 있음: 느리게
    }
}
