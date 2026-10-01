import Foundation
import Darwin

/// config.ini 의 내용 (Windows client/config.h 의 AppConfig 와 같은 33개 키, 같은 기본값).
///
/// 파일은 이 Mac 하나의 것이다 (PC 사이에 나누지 않는다). 그래도 키 이름과 뜻은 Windows 와
/// 같아야 한다 - 문서, 지원 절차, "앱 닫고 편집" 이 두 판에서 같게.
/// Mac 이 쓰지 않는 키(bleIrk, btAddress, nearLatencyMs...)도 읽은 값을 그대로 다시 쓴다.
public struct AppConfig: Equatable {
    /// 서버 키 덮어쓰기 (비면 내장값). 1.1.4 이하에서 등록한 PC 에만 남아 있다.
    public var anonKey: String = ""
    /// 누구로 로그인했는지 보여주기 위한 것뿐
    public var authEmail: String = ""
    /// 봉한 refresh 토큰 (Windows 는 DPAPI, Mac 은 SecretSeal). 이 파일은 평문이고,
    /// refresh 토큰은 폰 토큰과 달리 계정 자체를 여는 값이라 그대로 넣지 않는다.
    public var authRefresh: String = ""
    public var authUserId: String = ""
    public var bannerImagePath: String = ""
    /// BLE 광고 진단 로그 (ble_scan_log.csv)
    public var bleDebugLog: Bool = false
    /// 링크 암호화(=LE 본딩) 요구. 기본 끔: 본딩은 PC마다 따로 맺어야 해서 PC를 옮길 때마다 막힌다.
    public var bleGattEncrypt: Bool = false
    /// v2: PC가 GATT 서버가 되어 폰 앱의 1Hz RSSI 보고를 받음
    public var bleGattServer: Bool = true
    /// Windows 전용 IRK (32자리 hex). Mac 은 읽고 그대로 되쓰기만 한다.
    public var bleIrk: String = ""
    /// BLE 끊김 = 범위 이탈. 컴패니언 앱이 상시 광고하므로 기본 켬
    public var bleLostMeansFar: Bool = true
    /// BLE 수신 끊김 판정 시간(초). 주머니 속 iPhone은 광고 간격이 70초까지 벌어짐
    public var bleTimeoutSec: UInt32 = 90
    /// Classic BT 주소 (0 = 등록된 폰). Mac 은 읽은 값을 그대로 둔다.
    public var btAddress: UInt64 = 0
    public var centerImagePath: String = ""
    /// 이보다 큰 클립보드 항목은 건너뛴다. 다중 모니터 전체 캡처가 수십 MB 가 되는데,
    /// 그걸 복사할 때마다 올리면 회선만 쓴다.
    public var clipMaxKB: UInt32 = 4096
    /// 기본 꺼짐이고 그래야 한다: 켜면 복사한 그림과 텍스트가 서버를 지나간다.
    /// 자리비움 감지와 달리 이건 사용자가 알고 켜는 일이어야 한다.
    public var clipSync: Bool = false
    public var enterpriseRegistered: Bool = false
    /// 시작 후 앱 연결을 기다리는 시간(초)
    public var gattGraceSec: UInt32 = 90
    /// [연결] 경로 (dBm). 1.1.6 부터 nearRssiThreshold 의 사본이다.
    /// -55 였는데, 실측에서 착석 분포(-62~-45) 안에 들어가 있어 자리에 앉아 있는데도 화면을 잠갔다.
    public var gattRssiThreshold: Int = -65
    /// 컴패니언 앱이 연결된 적 있음 → 이후 미연결은 "부재"로 간주
    public var gattSeen: Bool = false
    public var idleCountdownSec: Int = 20
    public var keepAliveSec: UInt32 = 5
    /// 간단 화면의 거리 3단계가 기준으로 삼는 값. 재보기로 정해진다.
    /// 0 = 아직 안 재봤음. 같은 "보통"이 자리와 어댑터에 따라 10~20 dB 달라지므로 고정값으로 둘 수 없다.
    public var measuredBaseRssi: Int = 0
    /// 지연시간 경로 (Windows 전용, 옛 값). Mac 은 되쓰기만 한다.
    public var nearLatencyMs: UInt32 = 200
    /// [광고] 경로 (dBm). 임계값 기본값은 자리마다 다시 재는 것이 전제다 - 늦게 잠기는 것이
    /// 잘못 잠기는 것보다 낫다.
    public var nearRssiThreshold: Int = -65
    /// 조직 UUID (소문자 정규형으로 저장)
    public var orgId: String = ""
    /// 폰의 Apple overflow 비트 번호. -1 = 아직 모름. 후보를 좁히는 필터일 뿐 신원이 아니다.
    public var phoneOvfBit: Int = -1
    /// 폰이 GATT 로 내주는 16바이트 신원값 (32자리 대문자 hex, 받은 그대로)
    public var phoneToken: String = ""
    public var scanIntervalSec: UInt32 = 2
    /// 서버 주소 덮어쓰기 (비면 내장값)
    public var serverUrl: String = ""
    public var unlockAuto: Bool = true
    public var unlockDelaySec: Int = 0
    /// stable 이 기본. beta 는 내 PC 에서 먼저 돌려 보는 용도다.
    public var updateChannel: String = "stable"
    /// 켤 때와 한 시간마다 서버에 묻는다. 끄면 묻지 않는다 - 서버가 없는 곳에 두는 경우.
    public var updateCheck: Bool = true

    /// Not written. true = the file existed and was read.
    public var loaded: Bool = false
    /// Not written. true = the file exists but could not be read; save() refuses such a struct.
    /// 이 표시가 선 구조체는 기본값뿐이다 - 그대로 쓰면 폰 토큰, 로그인, 조직 등록, 임계값이
    /// 전부 기본값으로 덮인다.
    public var loadFailed: Bool = false

    public init() {}
}

/// config.ini 읽기/쓰기 (Windows client/config.cpp 를 그대로 옮겼다).
///
/// 파일: UTF-8 BOM, CRLF, 한 줄에 `key=value`, 키는 서수(ASCII) 순, 아는 키는 언제나 모두 쓴다.
/// 구역, 주석, 따옴표, 이스케이프, 앞뒤 공백 자르기가 없다. 키 = 첫 `=` 앞, 값 = 그 뒤 전부
/// (base64 의 `=` 가 들어갈 수 있다). `=` 없는 줄은 버린다. 같은 키가 또 나오면 뒤엣것.
/// 모르는 키는 저장할 때 사라진다 (Windows 와 같다).
///
/// "파일이 없다" 와 "있는데 못 읽었다" 를 가른다. 예전에는 둘 다 빈 맵이었고, 부르는 쪽은
/// 둘 다 "설정이 없다" 로 읽어 기본값을 그 위에 저장했다 - 잠깐 못 읽은 것만으로 폰 토큰,
/// 로그인, 조직 등록, 임계값이 전부 기본값으로 덮였다.
///
/// 읽고-고치고-쓰기는 메인 스레드에서만 할 것. 파일 잠금은 파일이 깨지지 않게는 해 주지만,
/// 두 스레드가 서로의 변경을 덮어쓰는 것은 막지 못한다. 작업 스레드는 읽기만 한다.
public enum ConfigStore {
    /// config.ini 를 읽거나 바꿔 끼우는 동안 잡는다. 이 프로세스 안의 스레드끼리만 막아 준다 -
    /// 로그인 스레드가 읽는 순간과 메인 스레드가 새 파일을 끼우는 순간이 겹치지 않게.
    /// 다른 프로세스와 겹치는 것은 아래의 재시도가 맡는다.
    private static let fileLock = NSLock()
    /// 읽기 실패는 상태가 바뀔 때만 적는다. 간단 창이 1초에 두 번 읽으므로 읽을 때마다 적으면
    /// 못 읽는 동안 로그가 그것으로 찬다. fileLock 이 지킨다.
    private static var readFailing = false

    private enum IniRead { case loaded, absent, failed }

    // MARK: - Load

    /// LoadAppConfig. Absent file -> defaults, loaded=false, loadFailed=false.
    /// Unreadable -> defaults, loadFailed=true (logs the state change once). Thread-safe (file lock).
    public static func load() -> AppConfig {
        var cfg = AppConfig()
        let path = Paths.configFile.path
        var changed = false
        fileLock.lock()
        let rd = readIni(path)
        let failing = (rd.result == .failed)
        if failing != readFailing {
            readFailing = failing
            changed = true
        }
        fileLock.unlock()

        cfg.loadFailed = failing
        if changed {
            if failing {
                EventLog.write("config: config.ini is there but could not be read (err=\(rd.err)) - "
                               + "using defaults for now and refusing to save over it")
            } else {
                EventLog.write("config: config.ini can be read again")
            }
        }
        if rd.result != .loaded { return cfg }
        apply(rd.map, to: &cfg)
        // "읽을 설정이 있었는가". 예전(Windows)에는 btAddress != 0 을 돌려줬는데, 등록된 폰을
        // 쓰면 Classic 주소가 없어 0이라 그때 설정 전체가 무시됐다.
        cfg.loaded = true
        return cfg
    }

    private static func readIni(_ path: String) -> (result: IniRead, map: [String: String], err: Int32) {
        var fd: Int32 = -1
        var err: Int32 = 0
        // 못 열었으면 조금 기다렸다가 다시 연다. 겹치는 상대(다른 프로세스가 새 파일을 끼우는
        // 순간, 백신)는 파일을 마이크로초 단위로만 잡는다. 오래 기다리지 않는 이유: 이 함수는
        // 메인 스레드의 1초 타이머에서도 불린다.
        for attempt in 0..<5 {
            if attempt > 0 { usleep(10_000) }
            fd = open(path, O_RDONLY | O_CLOEXEC)
            if fd >= 0 { break }
            err = errno
            if err == ENOENT || err == ENOTDIR { return (.absent, [:], 0) }
        }
        if fd < 0 { return (.failed, [:], err) }
        defer { _ = close(fd) }

        var all = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n: Int = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                return read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                all.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                // 읽다가 끊겼으면 앞부분만 들고 있는 것이다. 그것을 "설정" 으로 돌려주면
                // 뒤쪽 키들이 기본값으로 저장된다.
                return (.failed, [:], errno)
            }
        }
        let m = parse(Data(all))
        // 열렸는데 키가 하나도 없는 파일은 없는 것과 같다 (잃을 것이 없다).
        return (m.isEmpty ? .absent : .loaded, m, 0)
    }

    /// 파일 바이트를 key -> value 로 나눈다 (Windows ReadIni 의 줄 처리).
    /// 앞의 UTF-8 BOM 은 건너뛴다. UTF-16LE BOM(FF FE)이면 UTF-16LE 로 읽는다 (CRT 의
    /// "r,ccs=UTF-8" 이 BOM 으로 인코딩을 고르는 것과 같게). 잘못된 UTF-8 은 U+FFFD 로 읽는다.
    /// 줄은 LF 로 나누고 끝의 CR/LF 를 모두 떼어 낸다. 그 밖에는 아무것도 자르지 않는다.
    public static func parse(_ data: Data) -> [String: String] {
        var bytes = [UInt8](data)
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            bytes.removeFirst(3)
        } else if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            var units = [UInt16]()
            units.reserveCapacity((bytes.count - 2) / 2)
            var i = 2
            while i + 1 < bytes.count {
                units.append(UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
                i += 2
            }
            bytes = Array(String(decoding: units, as: UTF16.self).utf8)
        }

        var m = [String: String]()
        let n = bytes.count
        var start = 0
        while start < n {
            var end = start
            while end < n && bytes[end] != 0x0A { end += 1 }
            var line = bytes[start..<end]
            // Windows 는 줄을 wchar_t 문자열로 받아 NUL 에서 끝난다.
            if let z = line.firstIndex(of: 0) {
                line = line[line.startIndex..<z]
            }
            while let last = line.last, last == 0x0D || last == 0x0A {
                line = line.dropLast()
            }
            // '=' 는 ASCII 라 UTF-8 의 여러 바이트 글자 안에 나타나지 않는다 - 바이트로 찾아도 된다.
            if let eq = line.firstIndex(of: 0x3D) {
                let key = String(decoding: line[line.startIndex..<eq], as: UTF8.self)
                let value = String(decoding: line[line.index(after: eq)..<line.endIndex], as: UTF8.self)
                m[key] = value
            }
            start = end + 1
        }
        return m
    }

    /// 읽은 키를 구조체에 얹는다 (config.cpp LoadAppConfig 의 키 처리와 같다).
    /// 없는 키는 cfg 에 있던 값을 그대로 둔다.
    public static func apply(_ kv: [String: String], to cfg: inout AppConfig) {
        if let v = kv["btAddress"], let a = parseU64(v) { cfg.btAddress = a }
        if let v = kv["nearLatencyMs"] { cfg.nearLatencyMs = toUInt32(v) }
        if let v = kv["nearRssiThreshold"] { cfg.nearRssiThreshold = wtoi(v) }
        if let v = kv["bleDebugLog"] { cfg.bleDebugLog = flag(v) }
        if let v = kv["bleIrk"] { cfg.bleIrk = v }
        if let v = kv["phoneToken"] { cfg.phoneToken = v }
        if let v = kv["phoneOvfBit"] { cfg.phoneOvfBit = wtoi(v) }
        if let v = kv["bleTimeoutSec"] { cfg.bleTimeoutSec = toUInt32(v) }
        if let v = kv["bleGattServer"] { cfg.bleGattServer = flag(v) }
        if let v = kv["bleGattEncrypt"] { cfg.bleGattEncrypt = flag(v) }
        if let v = kv["gattSeen"] { cfg.gattSeen = flag(v) }
        if let v = kv["gattGraceSec"] { cfg.gattGraceSec = toUInt32(v) }
        if let v = kv["gattRssiThreshold"] { cfg.gattRssiThreshold = wtoi(v) }
        if let v = kv["bleLostMeansFar"] { cfg.bleLostMeansFar = flag(v) }
        if let v = kv["keepAliveSec"] { cfg.keepAliveSec = toUInt32(v) }
        if let v = kv["scanIntervalSec"] { cfg.scanIntervalSec = toUInt32(v) }
        if let v = kv["idleCountdownSec"] { cfg.idleCountdownSec = wtoi(v) }
        if let v = kv["unlockAuto"] { cfg.unlockAuto = flag(v) }
        if let v = kv["unlockDelaySec"] { cfg.unlockDelaySec = wtoi(v) }
        if let v = kv["centerImagePath"] { cfg.centerImagePath = v }
        if let v = kv["bannerImagePath"] { cfg.bannerImagePath = v }
        if let v = kv["measuredBaseRssi"] { cfg.measuredBaseRssi = wtoi(v) }
        if let v = kv["authRefresh"] { cfg.authRefresh = v }
        if let v = kv["authUserId"] { cfg.authUserId = v }
        if let v = kv["authEmail"] { cfg.authEmail = v }
        if let v = kv["clipSync"] { cfg.clipSync = flag(v) }
        if let v = kv["clipMaxKB"] {
            // 서버가 받는 크기에 맞춘다: 텍스트 8 MiB, 그림 16 MiB (supabase/hardening.sql).
            // 그보다 크게 두면 올리기만 거절당한다. 0 은 예전에 "상한 없음" 이었는데,
            // 받는 쪽에도 상한이 생긴 지금은 "서버가 받는 만큼" 이다.
            let n = wtoi(v)
            cfg.clipMaxKB = (n <= 0 || n > 8192) ? 8192 : UInt32(n)
        }
        if let v = kv["orgId"] { cfg.orgId = v }
        if let v = kv["serverUrl"] { cfg.serverUrl = v }
        if let v = kv["anonKey"] { cfg.anonKey = v }
        if let v = kv["enterpriseRegistered"] { cfg.enterpriseRegistered = flag(v) }
        if let v = kv["updateCheck"] { cfg.updateCheck = flag(v) }
        if let v = kv["updateChannel"] {
            // 모르는 값이면 stable. 오타 하나로 업데이트가 조용히 멎으면 안 된다.
            cfg.updateChannel = (v == "beta") ? "beta" : "stable"
        }
    }

    /// C _wtoi: skip leading whitespace, optional sign, digits until non-digit; no digits -> 0. Clamps to Int32 range.
    /// ("  -67x" -> -67, "abc" -> 0, "+5" -> 5, "true" -> 0). 공백은 ASCII 공백류(0x09-0x0D, 0x20),
    /// 숫자는 ASCII 0-9 만 본다. 넘치면 UCRT 처럼 INT_MAX / INT_MIN 에 붙는다.
    public static func wtoi(_ s: String) -> Int {
        let u = Array(s.utf8)
        var i = 0
        while i < u.count && isSpace(u[i]) { i += 1 }
        var negative = false
        if i < u.count && (u[i] == 0x2B || u[i] == 0x2D) {   // '+' '-'
            negative = (u[i] == 0x2D)
            i += 1
        }
        var v: Int64 = 0
        while i < u.count && u[i] >= 0x30 && u[i] <= 0x39 {
            // 한계를 넘은 뒤에는 더 키우지 않는다 (아래에서 잘라 붙인다). 넘침 없이 계산된다.
            if v <= 2_147_483_648 { v = v * 10 + Int64(u[i] - 0x30) }
            i += 1
        }
        if negative { v = -v }
        if v > Int64(Int32.max) { v = Int64(Int32.max) }
        if v < Int64(Int32.min) { v = Int64(Int32.min) }
        return Int(v)
    }

    // MARK: - Save

    /// SaveAppConfig: refuses loadFailed; writes config.ini.tmp (BOM, "k=v\r\n", keys sorted), fsync, rename.
    /// Strips CR/LF from values. Main thread only by convention. Returns success; failures are logged.
    @discardableResult
    public static func save(_ cfg: AppConfig) -> Bool {
        // 읽지 못한 구조체는 기본값뿐이다. 그대로 쓰면 폰 토큰, 로그인, 조직 등록이 전부
        // 기본값으로 덮인다 - 파일을 잠깐 못 연 것뿐인데. 부르는 쪽 대부분이 load 의 결과를
        // 보지 않으므로 여기서 막는다.
        if cfg.loadFailed {
            EventLog.write("config: save refused - this copy came from a failed read; "
                           + "writing it would replace config.ini with defaults")
            return false
        }
        let data = serialize(cfg)
        let file = Paths.configFile
        let path = file.path
        let dir = file.deletingLastPathComponent().path
        fileLock.lock()
        let w = writeIni(path: path, dir: dir, data: data)
        fileLock.unlock()
        // 예전에는 못 써도 아무 흔적이 없었다. 저장이 사라진 것을 다음 실행에서야 알았다.
        if !w.ok {
            EventLog.write("config: save FAILED at \(w.stage) (err=\(w.err)) - config.ini is unchanged")
        }
        return w.ok
    }

    /// 파일 바이트: UTF-8 BOM + 정렬된 "k=v\r\n" 33줄.
    ///
    /// 값의 CR/LF 는 지운다: macOS 파일 이름에는 줄바꿈이 들어갈 수 있고, 값에 줄바꿈이
    /// 섞이면 다음에 읽을 때 가짜 키가 생긴다. NUL 에서는 값이 끝난다 (Windows 의 %s 가 그렇다).
    /// 줄은 1000자를 넘지 않게 하는 것이 원칙이다 (Windows 읽기는 1024 wchar_t 버퍼로 줄을
    /// 자른다) - 앱이 만드는 값은 모두 그보다 짧다. 사용자가 고른 아주 긴 경로만은 그대로
    /// 쓴다: 이 파일은 이 Mac 만 읽고, 이 쪽 읽기에는 줄 길이 제한이 없다.
    public static func serialize(_ cfg: AppConfig) -> Data {
        let pairs: [(String, String)] = [
            ("anonKey", cfg.anonKey),
            ("authEmail", cfg.authEmail),
            ("authRefresh", cfg.authRefresh),
            ("authUserId", cfg.authUserId),
            ("bannerImagePath", cfg.bannerImagePath),
            ("bleDebugLog", bit(cfg.bleDebugLog)),
            ("bleGattEncrypt", bit(cfg.bleGattEncrypt)),
            ("bleGattServer", bit(cfg.bleGattServer)),
            ("bleIrk", cfg.bleIrk),
            ("bleLostMeansFar", bit(cfg.bleLostMeansFar)),
            ("bleTimeoutSec", "\(cfg.bleTimeoutSec)"),
            ("btAddress", "\(cfg.btAddress)"),
            ("centerImagePath", cfg.centerImagePath),
            ("clipMaxKB", "\(cfg.clipMaxKB)"),
            ("clipSync", bit(cfg.clipSync)),
            ("enterpriseRegistered", bit(cfg.enterpriseRegistered)),
            ("gattGraceSec", "\(cfg.gattGraceSec)"),
            ("gattRssiThreshold", "\(cfg.gattRssiThreshold)"),
            ("gattSeen", bit(cfg.gattSeen)),
            ("idleCountdownSec", "\(cfg.idleCountdownSec)"),
            ("keepAliveSec", "\(cfg.keepAliveSec)"),
            ("measuredBaseRssi", "\(cfg.measuredBaseRssi)"),
            ("nearLatencyMs", "\(cfg.nearLatencyMs)"),
            ("nearRssiThreshold", "\(cfg.nearRssiThreshold)"),
            ("orgId", cfg.orgId),
            ("phoneOvfBit", "\(cfg.phoneOvfBit)"),
            ("phoneToken", cfg.phoneToken),
            ("scanIntervalSec", "\(cfg.scanIntervalSec)"),
            ("serverUrl", cfg.serverUrl),
            ("unlockAuto", bit(cfg.unlockAuto)),
            ("unlockDelaySec", "\(cfg.unlockDelaySec)"),
            ("updateChannel", cfg.updateChannel),
            ("updateCheck", bit(cfg.updateCheck)),
        ]
        // Windows 는 std::map<wstring> 순서(UTF-16 단위 서수)로 쓴다. 위 목록도 그 순서지만,
        // 키를 더할 때 순서를 틀려도 파일 순서가 어긋나지 않게 다시 정렬한다.
        let sorted = pairs.sorted { a, b in a.0.utf16.lexicographicallyPrecedes(b.0.utf16) }
        var out = Data([0xEF, 0xBB, 0xBF])
        for (k, v) in sorted {
            out.append(contentsOf: Array("\(k)=\(cleanValue(v))\r\n".utf8))
        }
        return out
    }

    /// config.ini.tmp 에 다 쓴 뒤 config.ini 자리에 끼운다.
    ///
    /// 예전에는 config.ini 를 그 자리에서 잘라 내고 다시 썼다. 여는 순간 파일이 비므로 닫기
    /// 전에 죽으면(전원, 크래시) 빈 파일이나 반쪽 파일이 남았고, 못 열면 아무 말 없이 돌아가서
    /// 저장이 사라진 것을 아무도 몰랐다. 지금은 이름을 바꿔 끼우기 전까지 원래 파일에 손대지 않는다.
    private static func writeIni(path: String, dir: String, data: Data) -> (ok: Bool, stage: String, err: Int32) {
        let tmp = path + ".tmp"
        // 0600: authRefresh 가 (봉한) 계정 토큰이다.
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if fd < 0 {
            return (false, "open config.ini.tmp", errno)
        }
        let bytes = [UInt8](data)
        var ok = true
        var err: Int32 = 0
        var off = 0
        while off < bytes.count {
            let n: Int = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + off, raw.count - off)
            }
            if n > 0 {
                off += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                ok = false
                err = (n < 0) ? errno : EIO
                break
            }
        }
        // 내용이 디스크에 닿은 뒤에 이름을 바꾼다. 순서가 반대면 전원이 나갔을 때 이름은
        // 바뀌었는데 내용은 없는 파일이 남을 수 있다. (Windows 처럼 결과는 보지 않는다 -
        // fsync 를 받지 않는 파일 시스템에서 저장 자체가 막히면 안 된다.)
        if ok { _ = fsync(fd) }
        if close(fd) != 0 && ok {
            ok = false
            err = errno
        }
        if !ok {
            _ = unlink(tmp)
            return (false, "write config.ini.tmp", err)
        }

        // rename(2) 는 같은 볼륨에서 원자적이다. 다시 해 보는 것은 Windows 에서 읽는 쪽이 파일을
        // 잡고 있으면 바꿔 끼우기가 거절되었기 때문이다 (Mac 에서는 거의 쓸 일이 없다).
        for attempt in 0..<10 {
            if attempt > 0 { usleep(15_000) }
            if rename(tmp, path) == 0 {
                // Windows 의 MOVEFILE_WRITE_THROUGH 자리: 바뀐 이름도 디스크에 닿게.
                let dfd = open(dir, O_RDONLY | O_CLOEXEC)
                if dfd >= 0 {
                    _ = fsync(dfd)
                    _ = close(dfd)
                }
                return (true, "", 0)
            }
            err = errno
        }
        _ = unlink(tmp)
        return (false, "replace config.ini", err)
    }

    // MARK: - Helpers

    private static func isSpace(_ c: UInt8) -> Bool {
        return c == 0x20 || (c >= 0x09 && c <= 0x0D)
    }

    /// uint 키: _wtoi 한 int 를 DWORD 에 넣는 C 와 같다 ("-1" -> 4294967295).
    private static func toUInt32(_ s: String) -> UInt32 {
        return UInt32(truncatingIfNeeded: wtoi(s))
    }

    /// bool 키: int != 0. 숫자만 센다 - "true" 는 false 로 읽힌다 (Windows 와 같다).
    private static func flag(_ s: String) -> Bool {
        return wtoi(s) != 0
    }

    private static func bit(_ b: Bool) -> String {
        return b ? "1" : "0"
    }

    /// swscanf("%llu") 와 같다: 앞 공백, 부호 하나, 숫자. 숫자가 없으면 nil (기본값 유지).
    /// strtoull 처럼 넘치면 UInt64.max, '-' 는 2의 보수로 감는다.
    private static func parseU64(_ s: String) -> UInt64? {
        let u = Array(s.utf8)
        var i = 0
        while i < u.count && isSpace(u[i]) { i += 1 }
        var negative = false
        if i < u.count && (u[i] == 0x2B || u[i] == 0x2D) {
            negative = (u[i] == 0x2D)
            i += 1
        }
        var v: UInt64 = 0
        var digits = 0
        var overflow = false
        while i < u.count && u[i] >= 0x30 && u[i] <= 0x39 {
            let d = UInt64(u[i] - 0x30)
            if !overflow {
                let (m, o1) = v.multipliedReportingOverflow(by: 10)
                let (a, o2) = m.addingReportingOverflow(d)
                if o1 || o2 { overflow = true } else { v = a }
            }
            digits += 1
            i += 1
        }
        if digits == 0 { return nil }
        if overflow { return UInt64.max }
        return negative ? (0 &- v) : v
    }

    /// 값에서 CR/LF 를 지우고 NUL 에서 끊는다.
    private static func cleanValue(_ v: String) -> String {
        var out = String.UnicodeScalarView()
        for u in v.unicodeScalars {
            if u.value == 0 { break }
            if u.value == 0x0A || u.value == 0x0D { continue }
            out.append(u)
        }
        return String(out)
    }
}
