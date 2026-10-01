import Foundation

// 화면과 로그에 나가는 파생 문자열을 한곳에 모았다. Windows client/main.cpp (OnResult,
// IDT_COUNTDOWN, UpdateOverlayState, SimpleWindow 의 WM_PAINT, PopulateCombo) 와
// client/common.h (RssiToLevel, LevelBar, RssiToDist, LatencyToDist) 의 글자를 그대로 옮겼다.
//
// 앞뒤 공백, 두 칸/세 칸 띄어쓰기가 모두 의미가 있다 (Windows 와 나란히 놓고 비교하는
// 사람이 있다). 특수 문자는 눈으로 헷갈리지 않게 escape 로 쓴다:
//   \u{2022} • (오버레이 구분점), \u{25A3} ▣ (오버레이 첫 줄), \u{2588} █ / \u{2591} ░ (신호 막대).

/// 8비트 RGB 색 (Windows RGB()/COLORREF 값 그대로).
public struct RGB: Equatable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }
}

public enum Texts {

    // MARK: - 신호 표시 (common.h)

    /// RSSI 기반 신호 레벨 (5단계, dBm)
    public static func rssiToLevel(_ rssi: Int, receiving: Bool) -> Int {
        if !receiving || rssi <= -100 { return 0 }   // 신호 없음
        if rssi >= -50 { return 5 }   // 매우 강함 (~1m 이내)
        if rssi >= -60 { return 4 }   // 강함 (~3m)
        if rssi >= -70 { return 3 }   // 보통 (~5-7m)
        if rssi >= -80 { return 2 }   // 약함 (~10m)
        return 1                      // 매우 약함 (>10m)
    }

    public static func levelBar(_ level: Int) -> String {
        switch level {
        case 5: return "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
        case 4: return "\u{2588}\u{2588}\u{2588}\u{2588}\u{2591}"
        case 3: return "\u{2588}\u{2588}\u{2588}\u{2591}\u{2591}"
        case 2: return "\u{2588}\u{2588}\u{2591}\u{2591}\u{2591}"
        case 1: return "\u{2588}\u{2591}\u{2591}\u{2591}\u{2591}"
        default: return "\u{2591}\u{2591}\u{2591}\u{2591}\u{2591}"
        }
    }

    /// RSSI 기반 거리 추정 (dBm → 거리 문자열). Log-distance path loss model 기반.
    public static func rssiToDist(_ rssi: Int) -> String {
        if rssi >= -45 { return "< 1m" }
        if rssi >= -55 { return "~1-2m" }
        if rssi >= -65 { return "~2-5m" }
        if rssi >= -75 { return "~5-10m" }
        if rssi >= -85 { return "~10-15m" }
        return "> 15m"
    }

    public static func latencyToDist(_ ms: UInt32) -> String {
        if ms < 150 { return "< 1m" }
        if ms < 300 { return "~1-2m" }
        if ms < 500 { return "~2-3m" }
        if ms < 1000 { return "~3-5m" }
        if ms < 2000 { return "~5-10m" }
        return "> 10m"
    }

    /// Windows LatencyToLevel. Mac 에는 latency 경로가 없지만 BLE 를 못 쓰는 행은 이걸로 그린다.
    private static func latencyToLevel(_ ms: UInt32, reachable: Bool, nearLatencyMs: UInt32) -> Int {
        if !reachable { return 0 }
        if ms <= nearLatencyMs { return 4 }
        return 3
    }

    /// 경로 표시용 줄임: 길면 "..." + 끝 (maxLen-3) 글자 (UTF-16 단위, Windows wstring 과 같다).
    public static func truncPath(_ p: String, maxLen: Int = 35) -> String {
        let units = Array(p.utf16)
        if units.count <= maxLen { return p }
        let keep = max(0, maxLen - 3)
        var tail = Array(units[(units.count - keep)...])
        // 잘린 자리가 서로게이트 쌍 한가운데면 짝 잃은 뒷부분을 버린다 (Windows 는 그대로 둔다)
        if let first = tail.first, UTF16.isTrailSurrogate(first) { tail.removeFirst() }
        return "..." + String(decoding: tail, as: UTF16.self)
    }

    // MARK: - 상태바 부품

    /// 상태바의 "ID:" 값. 잠긴 아이폰을 특정하는 수단이 무엇인지 드러낸다 - 둘 다 없으면
    /// 특정할 방법이 원천적으로 없고, 그래도 화면은 멀쩡해 보이므로 여기에 드러내 둔다.
    /// Mac 은 IRK 를 쓸 수 없으므로 "IRK", "IRK/토큰 대기", "토큰+IRK" 는 나오지 않는다.
    public static func idStatus(hasToken: Bool, bound: Bool) -> String {
        if !hasToken { return "없음!" }
        if !bound { return "토큰 대기" }
        return "토큰"
    }

    public static func gattStatus(running: Bool, subscribed: Bool) -> String {
        if !running { return "off" }
        return subscribed ? "linked" : "waiting"
    }

    // MARK: - 고급 창

    public static let stateLabelStopped = "  정지됨"
    public static let statusInitial = "  기기를 선택하고 시작을 누르세요"

    /// 고급 창의 큰 상태 띠 (OnResult 가 결과마다 쓴다)
    public static func stateLabel(_ r: ProbeResult, countdown: Int) -> String {
        if r.state == .near {
            return "  근처   (유휴: \(countdown)s)"
        }
        if r.bleAvailable && r.rssiDbm <= -100 {
            // 신호가 약해서가 아니라 폰 신호가 아예 끊긴 경우.
            // 앱을 위로 밀어 종료했거나 iOS가 앱을 내린 상황이라 사용자가 알아야 한다.
            return "  멀리  (폰 신호 없음 - 앱 확인)"
        }
        return "  멀리"
    }

    /// [초기화] 옆 카운트다운 줄 (1 초 틱마다). 처음 맞는 조건이 이긴다.
    public static func countdownLabel(black: Bool, unlockTimer: Int, manual: Bool, near: Bool, countdown: Int) -> String {
        if black && unlockTimer > 0 { return "  잠금 - \(unlockTimer)초 후 해제" }
        if black && manual { return "  직접 잠금 - [해제] 필요" }
        if black { return "  잠금 중" }
        if near { return "  보호 중" }
        return "  \(countdown)초 후 잠금"
    }

    /// 고급 창 상태바. targetName 은 상대 기기가 정한 이름이라 길이를 믿을 수 없다 -
    /// Windows 처럼 299 글자(UTF-16)에서 자른다.
    public static func statusBar(_ r: ProbeResult, targetName: String, packetRate: Double,
                                 nearThr: Int, gattThr: Int, idSt: String, gattSt: String, countdown: Int) -> String {
        let s: String
        if r.bleAvailable {
            // 초당 수신 건수: 신호가 얼마나 촘촘한지 보면서 임계값을 잡을 수 있다.
            // Near>= 는 그 경로가 실제로 쓰는 설정값이다 (히스테리시스 없이).
            let rate = String(format: "%.1f", packetRate)
            let thr = r.gatt ? gattThr : nearThr
            s = "  \"\(targetName)\"  |  \(r.state.name)  |  RSSI: \(r.rssiDbm) dBm\(r.gatt ? " (GATT)" : "")"
                + "  |  \(rate)/s  |  Near>=\(thr) dBm  |  ID: \(idSt)  |  GATT: \(gattSt)  |  Idle: \(countdown)s"
        } else {
            s = "  \"\(targetName)\"  |  \(r.state.name)  |  Latency: \(r.latencyMs) ms  |  BLE: N/A"
                + "  |  ID: \(idSt)  |  GATT: \(gattSt)  |  Idle: \(countdown)s"
        }
        return capUTF16(s, 299)
    }

    /// 목록(로그 표) 한 줄, 7 칸: Time, 신호 강도, Signal, Distance, State, Timer, Event.
    /// Mac 에서 fails 는 늘 0, inWarmup 은 늘 false 다 (latency 경로가 없다).
    public static func listRow(_ r: ProbeResult, nearThr: Int, nearLatencyMs: UInt32, inWarmup: Bool, fails: Int) -> [String] {
        let transition = r.state != r.prevState
        let secs = Int(r.timerRemainMs / 1000)

        var ev = ""
        if transition && r.state == .near {
            if r.bleAvailable {
                ev = ">>> ENTERED NEAR (\(r.rssiDbm) dBm\(r.gatt ? " GATT" : "")) <<<"
            } else {
                ev = ">>> ENTERED NEAR (\(r.latencyMs)ms) <<<"
            }
        } else if transition && r.state == .far {
            ev = "<<< LEFT NEAR ZONE >>>"
        } else if !r.reachable && fails >= 3 && fails % 5 == 0 {
            ev = "unreachable - reconnecting... (fail=\(fails))"
        } else if !r.reachable && fails >= 3 {
            ev = "unreachable (fail=\(fails), err=\(r.wsaError))"
        } else if !r.reachable {
            // 등록된 폰이 첫 패킷을 받기 전에 보이는 줄이다 (err=0)
            ev = "unreachable (err=\(r.wsaError))"
        } else if r.bleAvailable {
            // BLE RSSI 기반 이벤트 메시지. 기준은 광고 설정값이다 (GATT 행이어도, 히스테리시스 없이).
            if r.state == .near && r.rssiDbm >= nearThr {
                ev = "near (\(r.rssiDbm) dBm, reset \(secs)s)"
            } else if r.state == .near && inWarmup {
                ev = "near (warmup, \(r.rssiDbm) dBm)"
            } else if r.state == .near {
                ev = "near (weak \(r.rssiDbm) dBm, \(secs)s)"
            } else if r.rssiDbm <= -100 {
                ev = "far (BLE lost)"
            } else {
                ev = "far (\(r.rssiDbm) dBm)"
            }
        } else {
            // Latency fallback 이벤트 메시지
            if r.state == .near && r.latencyMs <= nearLatencyMs {
                ev = "near (reset \(secs)s, \(r.latencyMs)ms)"
            } else if r.state == .near {
                ev = "near (weak \(r.latencyMs)ms, \(secs)s)"
            } else {
                ev = "far (\(r.latencyMs)ms)"
            }
        }

        // 신호 강도 칼럼: BLE RSSI 또는 latency
        let lat: String
        if !r.reachable { lat = "timeout" }
        else if r.bleAvailable { lat = r.gatt ? "\(r.rssiDbm) dBm G" : "\(r.rssiDbm) dBm" }
        else { lat = "\(r.latencyMs) ms" }

        // Signal 레벨 바
        let lev = r.bleAvailable
            ? rssiToLevel(r.rssiDbm, receiving: r.reachable)
            : latencyToLevel(r.latencyMs, reachable: r.reachable, nearLatencyMs: nearLatencyMs)
        let sg = "\(levelBar(lev)) \(lev)"

        // Distance
        let di: String
        if !r.reachable { di = "-" }
        else if r.bleAvailable { di = rssiToDist(r.rssiDbm) }
        else { di = latencyToDist(r.latencyMs) }

        let tm = r.state == .near ? "\(secs)s" : "-"
        return [r.timeStr, lat, sg, di, r.state.name, tm, ev]
    }

    // MARK: - 오버레이 (UpdateOverlayState)

    public static func overlayLine1(monitoring: Bool, targetName: String) -> String {
        if monitoring && !targetName.isEmpty {
            // 기기 이름은 상대 기기가 정한다 (최대 248자). Windows 는 63 글자 버퍼에 잘라 쓴다 -
            // swprintf_s 가 넘치면 프로세스를 끝내서, 이름이 긴 기기를 고르면 검은 화면째 죽었다.
            return capUTF16("\u{25A3} " + targetName, 63)
        }
        return "\u{25A3} SmartScreen"
    }

    public static func overlayLine2(monitoring: Bool, black: Bool, unlockTimer: Int, manual: Bool,
                                    near: Bool, countdown: Int) -> (text: String, color: RGB) {
        if !monitoring {
            return ("정지됨", RGB(128, 128, 128))
        }
        if black {
            let red = RGB(235, 70, 70)
            if unlockTimer > 0 { return ("잠금  \u{2022}  \(unlockTimer)초 후 해제", red) }
            if manual { return ("잠금  \u{2022}  [해제] 를 눌러야 풀립니다", red) }
            return ("잠금", red)
        }
        if near {
            return ("근처  \u{2022}  보호 중", RGB(60, 210, 90))
        }
        return ("멀리  \u{2022}  \(countdown)초", RGB(240, 170, 50))
    }

    // MARK: - 간단 창 상태 카드

    public static func simpleCard(monitoring: Bool, black: Bool, manual: Bool, near: Bool)
        -> (title: String, subtitle: String, color: RGB) {
        if !monitoring {
            return ("꺼져 있어요", "아래 [보호 꺼짐] 을 누르면 시작해요", RGB(120, 120, 120))
        }
        if black {
            return ("화면을 가리는 중",
                    manual ? "검은 화면의 [해제] 를 누르면 돌아와요" : "폰이 돌아오면 저절로 풀려요",
                    RGB(200, 60, 60))
        }
        if near {
            return ("지키는 중", "자리를 비우면 화면을 가려요", RGB(46, 160, 67))
        }
        return ("폰이 안 보여요", "곧 화면을 가릴 거예요", RGB(230, 145, 40))
    }

    // MARK: - 오버레이 셋째 줄

    /// "Lock 14:02 -> Unlock 14:09 (7m03s)". lock 은 호출자가 unlock - duration 으로 준다.
    /// Windows 는 지역 시각에서 시간을 뺀 뒤 그 값을 UTC 로 여겨 다시 지역 시각으로 바꿔서
    /// 잠근 시각이 시간대만큼(KST +9h) 틀렸다 (quirk Q1). Mac 은 고친 값을 쓴다.
    public static func ovlInfo(lock: Date, unlock: Date, durationSec: UInt64) -> String {
        let cal = Calendar.current
        let l = cal.dateComponents([.hour, .minute], from: lock)
        let u = cal.dateComponents([.hour, .minute], from: unlock)
        let durMin = durationSec / 60
        let durSec = Int(durationSec % 60)
        return "Lock \(two(l.hour ?? 0)):\(two(l.minute ?? 0)) -> Unlock \(two(u.hour ?? 0)):\(two(u.minute ?? 0))"
            + " (\(durMin)m\(two(durSec))s)"
    }

    // MARK: - 입력 칸, 콤보

    /// [시작] 때 "신호 강도" 칸 읽기. C _wtoi 로 읽고, 양수면 음수로 바꾸고, [-100, -30] 으로 자른다.
    /// 숫자가 아닌 값이나 빈 칸은 0 → -30 (가장 엄격한 값)이 된다.
    /// Windows 는 칸을 16 글자 버퍼로 읽으므로 앞 15 글자(UTF-16)만 본다.
    public static func parseThresholdField(_ s: String) -> Int {
        let head = String(decoding: Array(s.utf16.prefix(15)), as: UTF16.self)
        var v = cWtoi(head)
        if v > 0 { v = -v }        // 양수 입력시 음수로 변환
        if v > -30 { v = -30 }
        if v < -100 { v = -100 }
        return v
    }

    /// ComboFindValue: |v - target| 이 가장 작은 칸. 앞에서부터 엄격한 < 로 보므로 같으면 앞 칸.
    public static func comboFindValue(_ values: [Int], _ target: Int) -> Int {
        guard let first = values.first else { return 0 }
        var best = 0
        var bestDiff = abs(first - target)
        var i = 1
        while i < values.count {
            let d = abs(values[i] - target)
            if d < bestDiff { bestDiff = d; best = i }
            i += 1
        }
        return best
    }

    /// 장치 목록의 등록된 폰 항목. `[` 앞은 두 칸.
    public static func phoneEntry(token: String) -> String {
        return "등록된 폰  [토큰 \(tokenPrefix(token))]"
    }

    /// 토큰 앞 8 글자 (폰 앱의 "기기 토큰" 표시와 같은 값)
    public static func tokenPrefix(_ token: String) -> String {
        return String(token.prefix(8))
    }

    // MARK: - private

    private static func two(_ v: Int) -> String {
        return v >= 0 && v < 10 ? "0\(v)" : "\(v)"
    }

    /// _snwprintf_s(..., _TRUNCATE) 처럼 UTF-16 단위로 자른다. 서로게이트 쌍은 쪼개지 않는다.
    private static func capUTF16(_ s: String, _ maxUnits: Int) -> String {
        let units = Array(s.utf16)
        if units.count <= maxUnits { return s }
        var cut = max(0, maxUnits)
        if cut > 0 && UTF16.isLeadSurrogate(units[cut - 1]) { cut -= 1 }
        return String(decoding: units[0..<cut], as: UTF16.self)
    }

    /// C _wtoi: 앞 공백을 건너뛰고, 부호 하나, 숫자가 끝날 때까지. 숫자가 없으면 0.
    /// 넘치면 Int32 범위로 붙인다 (MS CRT 처럼).
    private static func cWtoi(_ s: String) -> Int {
        let scalars = Array(s.unicodeScalars)
        var i = 0
        // isspace: ' ', \t, \n, \v, \f, \r
        while i < scalars.count {
            let c = scalars[i].value
            if c == 0x20 || (c >= 0x09 && c <= 0x0D) { i += 1 } else { break }
        }
        var negative = false
        if i < scalars.count {
            if scalars[i] == "-" { negative = true; i += 1 }
            else if scalars[i] == "+" { i += 1 }
        }
        var acc: Int64 = 0
        let limit: Int64 = Int64(Int32.max) + 1
        while i < scalars.count {
            let c = scalars[i].value
            guard c >= 0x30 && c <= 0x39 else { break }
            if acc <= limit { acc = acc * 10 + Int64(c - 0x30) }
            i += 1
        }
        if negative {
            let v = -acc
            return Int(v < Int64(Int32.min) ? Int64(Int32.min) : v)
        }
        return Int(acc > Int64(Int32.max) ? Int64(Int32.max) : acc)
    }
}
