import XCTest
import Foundation
import SmartScreenCore

/// Clock, Paths, EventLog, config.ini, ServerDefaults, TextSanitize, Hex, SHA256Hex.
///
/// 모든 시험은 $SMARTSCREEN_HOME 을 시험마다 새 임시 폴더로 돌려 놓고 파일을 만진다 -
/// 사용자의 진짜 config.ini / events.log 를 건드리지 않게.
final class CoreATests: XCTestCase {
    private var home: URL!
    private var previousHome: String?

    override func setUp() {
        super.setUp()
        previousHome = getenv("SMARTSCREEN_HOME").map { String(cString: $0) }
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartScreenCoreA-\(UUID().uuidString)", isDirectory: true)
        setenv("SMARTSCREEN_HOME", home.path, 1)
    }

    override func tearDown() {
        if let p = previousHome {
            setenv("SMARTSCREEN_HOME", p, 1)
        } else {
            unsetenv("SMARTSCREEN_HOME")
        }
        if let h = home {
            try? FileManager.default.removeItem(at: h)
        }
        super.tearDown()
    }

    // MARK: - helpers

    /// 지금 config.ini 가 있을 자리에 바이트를 그대로 쓴다.
    private func writeConfigBytes(_ bytes: [UInt8]) throws {
        try Data(bytes).write(to: Paths.configFile)
    }

    private func readLog() -> String {
        guard let d = try? Data(contentsOf: Paths.eventsLog) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    private func occurrences(_ needle: String, in hay: String) -> Int {
        return hay.components(separatedBy: needle).count - 1
    }

    /// "HH:MM:SS <msg>"
    private func isTimePrefixed(_ line: String, _ msg: String) -> Bool {
        let u = Array(line.utf8)
        guard u.count >= 9 else { return false }
        for i in 0..<8 {
            let c = u[i]
            if i == 2 || i == 5 {
                if c != 0x3A { return false }
            } else if !(c >= 0x30 && c <= 0x39) {
                return false
            }
        }
        return u[8] == 0x20 && String(decoding: u[9...], as: UTF8.self) == msg
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Windows 의 live config.ini 에 적힌 순서 (spec enterprise-auth §3.1).
    private let windowsKeyOrder = [
        "anonKey", "authEmail", "authRefresh", "authUserId", "bannerImagePath", "bleDebugLog",
        "bleGattEncrypt", "bleGattServer", "bleIrk", "bleLostMeansFar", "bleTimeoutSec", "btAddress",
        "centerImagePath", "clipMaxKB", "clipSync", "enterpriseRegistered", "gattGraceSec",
        "gattRssiThreshold", "gattSeen", "idleCountdownSec", "keepAliveSec", "measuredBaseRssi",
        "nearLatencyMs", "nearRssiThreshold", "orgId", "phoneOvfBit", "phoneToken", "scanIntervalSec",
        "serverUrl", "unlockAuto", "unlockDelaySec", "updateChannel", "updateCheck",
    ]

    // MARK: - Clock

    func testMonoIsNonZeroAndAdvances() {
        let a = Mono.now()
        XCTAssertGreaterThan(a, 0)
        Thread.sleep(forTimeInterval: 0.03)
        let b = Mono.now()
        XCTAssertGreaterThanOrEqual(b, a + 20)
    }

    func testPad2() {
        XCTAssertEqual(pad2(0), "00")
        XCTAssertEqual(pad2(7), "07")
        XCTAssertEqual(pad2(12), "12")
        XCTAssertEqual(pad2(123), "123")
        XCTAssertEqual(pad2(-5), "-5")
    }

    func testLocalClockFormats() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let d = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 9, minute: 5,
                                                             second: 3, nanosecond: 42_500_000)))
        XCTAssertEqual(LocalClock.hhmmss(d), "09:05:03")
        XCTAssertEqual(LocalClock.hhmmssmmm(d), "09:05:03.042")
        XCTAssertEqual(LocalClock.hhmm(d), "09:05")

        // 밀리초는 버림 (GetLocalTime): 999.9 ms 가 다음 초로 넘어가지 않는다.
        let late = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 23, minute: 59,
                                                                second: 58, nanosecond: 999_900_000)))
        XCTAssertEqual(LocalClock.hhmmssmmm(late), "23:59:58.999")
        XCTAssertEqual(LocalClock.hhmmss(late), "23:59:58")
    }

    func testMainTimerOnceFires() {
        let exp = expectation(description: "once")
        MainTimer.once(after: 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    func testMainTimerEveryRepeats() {
        let exp = expectation(description: "every")
        var n = 0
        let t = MainTimer.every(0.02) {
            n += 1
            if n == 2 { exp.fulfill() }
        }
        wait(for: [exp], timeout: 5)
        t.invalidate()
        XCTAssertGreaterThanOrEqual(n, 2)
    }

    // MARK: - Paths

    func testPathsHonorEnvironmentOnEveryAccess() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertEqual(Paths.configDir.path, home.path)
        XCTAssertTrue(isDirectory(home), "configDir is created on first use")
        XCTAssertEqual(Paths.configFile.lastPathComponent, "config.ini")
        XCTAssertEqual(Paths.configFile.deletingLastPathComponent().path, home.path)
        XCTAssertEqual(Paths.eventsLog.lastPathComponent, "events.log")
        XCTAssertEqual(Paths.eventsLog.deletingLastPathComponent().path, home.path)

        let ec = Paths.enterpriseContentDir
        XCTAssertEqual(ec.lastPathComponent, "enterprise_content")
        XCTAssertTrue(isDirectory(ec))
        let up = Paths.updateDir
        XCTAssertEqual(up.lastPathComponent, "update")
        XCTAssertTrue(isDirectory(up))

        // 환경 변수는 접근할 때마다 다시 읽는다.
        let other = home.appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("again", isDirectory: true)
        setenv("SMARTSCREEN_HOME", other.path, 1)
        XCTAssertEqual(Paths.configDir.path, other.path)
        XCTAssertTrue(isDirectory(other))
        setenv("SMARTSCREEN_HOME", home.path, 1)
        XCTAssertEqual(Paths.configDir.path, home.path)

        let made = home.appendingPathComponent("a/b/c", isDirectory: true)
        Paths.ensureDir(made)
        XCTAssertTrue(isDirectory(made))
        Paths.ensureDir(made)   // 이미 있어도 괜찮다
        XCTAssertTrue(isDirectory(made))
    }

    // MARK: - EventLog

    func testEventLogLineFormatAndSingleBOM() throws {
        EventLog.write("hello\nworld\r!")
        EventLog.write("second 한글")
        let bytes = [UInt8](try Data(contentsOf: Paths.eventsLog))
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: bytes.dropFirst(3), as: UTF8.self)
        XCTAssertFalse(text.unicodeScalars.contains("\u{FEFF}"), "BOM only when the file is created")
        XCTAssertFalse(text.unicodeScalars.contains("\r"))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.last, "")
        XCTAssertTrue(isTimePrefixed(lines[0], "hello world !"), lines[0])
        XCTAssertTrue(isTimePrefixed(lines[1], "second 한글"), lines[1])
    }

    func testEventLogFromManyThreads() throws {
        let group = DispatchGroup()
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for j in 0..<25 { EventLog.write("t\(i) n\(j)") }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        let text = String(decoding: [UInt8](try Data(contentsOf: Paths.eventsLog)).dropFirst(3), as: UTF8.self)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 200)
        for l in lines {
            let u = Array(l.utf8)
            XCTAssertTrue(u.count > 9 && u[2] == 0x3A && u[5] == 0x3A && u[8] == 0x20, l)
        }
    }

    // MARK: - config.ini: _wtoi

    func testWtoiMatchesC() {
        XCTAssertEqual(ConfigStore.wtoi("  -67x"), -67)
        XCTAssertEqual(ConfigStore.wtoi("abc"), 0)
        XCTAssertEqual(ConfigStore.wtoi("+5"), 5)
        XCTAssertEqual(ConfigStore.wtoi(""), 0)
        XCTAssertEqual(ConfigStore.wtoi("-"), 0)
        XCTAssertEqual(ConfigStore.wtoi("- 5"), 0)
        XCTAssertEqual(ConfigStore.wtoi("\t\r\n 12"), 12)
        XCTAssertEqual(ConfigStore.wtoi("0x10"), 0)
        XCTAssertEqual(ConfigStore.wtoi("007"), 7)
        XCTAssertEqual(ConfigStore.wtoi("true"), 0)
        XCTAssertEqual(ConfigStore.wtoi("1 2"), 1)
        XCTAssertEqual(ConfigStore.wtoi("2147483647"), 2147483647)
        XCTAssertEqual(ConfigStore.wtoi("2147483648"), 2147483647)
        XCTAssertEqual(ConfigStore.wtoi("-2147483648"), -2147483648)
        XCTAssertEqual(ConfigStore.wtoi("-99999999999999999999999"), -2147483648)
        XCTAssertEqual(ConfigStore.wtoi("99999999999999999999999"), 2147483647)
    }

    // MARK: - config.ini: parse

    func testParseBOMAndLineEndings() {
        let withBOM = Data([0xEF, 0xBB, 0xBF] + Array("a=1\r\nb=2\nc=3".utf8))
        let m = ConfigStore.parse(withBOM)
        XCTAssertEqual(m, ["a": "1", "b": "2", "c": "3"])

        let noBOM = Data(Array("a=1\r\nb=2\r\n".utf8))
        XCTAssertEqual(ConfigStore.parse(noBOM), ["a": "1", "b": "2"])

        // 끝의 CR 은 몇 개든 뗀다. 가운데 CR 은 값이다.
        XCTAssertEqual(ConfigStore.parse(Data(Array("a=1\r\r\n".utf8))), ["a": "1"])
        XCTAssertEqual(ConfigStore.parse(Data(Array("a=x\ry\n".utf8))), ["a": "x\ry"])
        XCTAssertEqual(ConfigStore.parse(Data()), [:])
    }

    func testParseHasNoTrimmingAndLastDuplicateWins() {
        let text = " k = v \r\nk=v=w==\r\ndup=1\r\nnoequals\r\n\r\n=empty\r\ndup=2\r\n한글=값\r\n"
        let m = ConfigStore.parse(Data(Array(text.utf8)))
        XCTAssertEqual(m[" k "], " v ")
        XCTAssertEqual(m["k"], "v=w==")
        XCTAssertEqual(m["dup"], "2")
        XCTAssertNil(m["noequals"])
        XCTAssertEqual(m[""], "empty")
        XCTAssertEqual(m["한글"], "값")
        XCTAssertEqual(m.count, 5)
    }

    func testParseUTF16LEWithBOM() {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for u in "a=1\r\nb=한\r\n".utf16 {
            bytes.append(UInt8(u & 0xFF))
            bytes.append(UInt8(u >> 8))
        }
        XCTAssertEqual(ConfigStore.parse(Data(bytes)), ["a": "1", "b": "한"])
    }

    // MARK: - config.ini: apply

    func testApplyNumericAndBoolSemantics() {
        var c = AppConfig()
        ConfigStore.apply([
            "bleTimeoutSec": "-1",
            "gattGraceSec": "abc",
            "keepAliveSec": " 9s",
            "nearRssiThreshold": "  -67x",
            "phoneOvfBit": "+31",
            "bleDebugLog": "true",
            "gattSeen": "2",
            "unlockAuto": "0",
            "bleGattServer": "",
            "btAddress": "abc",
        ], to: &c)
        XCTAssertEqual(c.bleTimeoutSec, 4294967295)     // uint: C 처럼 비트 그대로
        XCTAssertEqual(c.gattGraceSec, 0)
        XCTAssertEqual(c.keepAliveSec, 9)
        XCTAssertEqual(c.nearRssiThreshold, -67)
        XCTAssertEqual(c.phoneOvfBit, 31)
        XCTAssertFalse(c.bleDebugLog)                   // "true" 는 숫자가 아니라 false
        XCTAssertTrue(c.gattSeen)
        XCTAssertFalse(c.unlockAuto)
        XCTAssertFalse(c.bleGattServer)
        XCTAssertEqual(c.btAddress, 0)                  // 읽지 못하면 원래 값

        var d = AppConfig()
        d.btAddress = 77
        ConfigStore.apply(["btAddress": "abc"], to: &d)
        XCTAssertEqual(d.btAddress, 77)
        ConfigStore.apply(["btAddress": " 123456789012345"], to: &d)
        XCTAssertEqual(d.btAddress, 123456789012345)
        ConfigStore.apply(["btAddress": "18446744073709551615"], to: &d)
        XCTAssertEqual(d.btAddress, UInt64.max)
        ConfigStore.apply(["btAddress": "99999999999999999999999"], to: &d)
        XCTAssertEqual(d.btAddress, UInt64.max)
        ConfigStore.apply(["btAddress": "-1"], to: &d)
        XCTAssertEqual(d.btAddress, UInt64.max)

        // 없는 키는 건드리지 않는다.
        var e = AppConfig()
        e.phoneToken = "KEEP"
        e.updateChannel = "beta"
        ConfigStore.apply(["orgId": "x"], to: &e)
        XCTAssertEqual(e.phoneToken, "KEEP")
        XCTAssertEqual(e.updateChannel, "beta")
        XCTAssertEqual(e.orgId, "x")
    }

    func testUpdateChannelIsBetaOnlyWhenExactlyBeta() {
        let cases: [(String, String)] = [
            ("beta", "beta"), ("Beta", "stable"), ("beta ", "stable"), (" beta", "stable"),
            ("", "stable"), ("stable", "stable"), ("nightly", "stable"),
        ]
        for (raw, want) in cases {
            var c = AppConfig()
            ConfigStore.apply(["updateChannel": raw], to: &c)
            XCTAssertEqual(c.updateChannel, want, "updateChannel=\(raw)")
        }
    }

    func testClipMaxKBReadClamp() {
        XCTAssertEqual(AppConfig().clipMaxKB, 4096)
        let cases: [(String, UInt32)] = [
            ("0", 8192), ("-5", 8192), ("8193", 8192), ("8192", 8192), ("100", 100), ("1", 1),
            ("abc", 8192), ("99999999999", 8192),
        ]
        for (raw, want) in cases {
            var c = AppConfig()
            ConfigStore.apply(["clipMaxKB": raw], to: &c)
            XCTAssertEqual(c.clipMaxKB, want, "clipMaxKB=\(raw)")
        }
    }

    // MARK: - config.ini: serialize

    func testSerializeDefaultsIsByteExact() {
        let expected = [
            "anonKey=", "authEmail=", "authRefresh=", "authUserId=", "bannerImagePath=", "bleDebugLog=0",
            "bleGattEncrypt=0", "bleGattServer=1", "bleIrk=", "bleLostMeansFar=1", "bleTimeoutSec=90",
            "btAddress=0", "centerImagePath=", "clipMaxKB=4096", "clipSync=0", "enterpriseRegistered=0",
            "gattGraceSec=90", "gattRssiThreshold=-65", "gattSeen=0", "idleCountdownSec=20",
            "keepAliveSec=5", "measuredBaseRssi=0", "nearLatencyMs=200", "nearRssiThreshold=-65",
            "orgId=", "phoneOvfBit=-1", "phoneToken=", "scanIntervalSec=2", "serverUrl=",
            "unlockAuto=1", "unlockDelaySec=0", "updateChannel=stable", "updateCheck=1",
        ]
        var want: [UInt8] = [0xEF, 0xBB, 0xBF]
        for line in expected { want += Array("\(line)\r\n".utf8) }
        XCTAssertEqual([UInt8](ConfigStore.serialize(AppConfig())), want)
    }

    func testSerializeWritesAll33KeysInOrdinalOrder() {
        XCTAssertEqual(windowsKeyOrder.count, 33)
        let ordinal = windowsKeyOrder.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        XCTAssertEqual(ordinal, windowsKeyOrder)

        let bytes = [UInt8](ConfigStore.serialize(AppConfig()))
        let text = String(decoding: bytes.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\r\n"))
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 33)
        let keys = lines.map { line -> String in
            if let r = line.range(of: "=") { return String(line[line.startIndex..<r.lowerBound]) }
            return line
        }
        XCTAssertEqual(keys, windowsKeyOrder)
        // LF 는 언제나 CR 뒤에만 온다.
        for (i, b) in bytes.enumerated() where b == 0x0A {
            XCTAssertEqual(bytes[i - 1], 0x0D)
        }
    }

    func testSerializeStripsLineBreaksFromValues() {
        var c = AppConfig()
        c.centerImagePath = "/a\nb\r\nc.png"
        c.bannerImagePath = "/x\ry.png"
        c.authEmail = "me@example.com\u{0}junk"
        let data = ConfigStore.serialize(c)
        let m = ConfigStore.parse(data)
        XCTAssertEqual(m.count, 33)
        XCTAssertEqual(m["centerImagePath"], "/abc.png")
        XCTAssertEqual(m["bannerImagePath"], "/xy.png")
        XCTAssertEqual(m["authEmail"], "me@example.com")
        let text = String(decoding: [UInt8](data).dropFirst(3), as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 33)
    }

    // MARK: - config.ini: load / save

    func testRoundTripThroughFile() throws {
        var c = AppConfig()
        c.anonKey = "key=="
        c.authEmail = "user@example.com"
        c.authRefresh = "AAAA/BBBB+CCCC=="
        c.authUserId = "0b6f6c1e-1111-2222-3333-444455556666"
        c.bannerImagePath = "/Users/me/그림/배너 1.png"
        c.bleDebugLog = true
        c.bleGattEncrypt = true
        c.bleGattServer = false
        c.bleIrk = "00112233445566778899AABBCCDDEEFF"
        c.bleLostMeansFar = false
        c.bleTimeoutSec = 120
        c.btAddress = 0xFFFF_FFFF_FFFF
        c.centerImagePath = "/Users/me/Movies/promo.mov"
        c.clipMaxKB = 1024
        c.clipSync = true
        c.enterpriseRegistered = true
        c.gattGraceSec = 30
        c.gattRssiThreshold = -70
        c.gattSeen = true
        c.idleCountdownSec = 60
        c.keepAliveSec = 7
        c.measuredBaseRssi = -58
        c.nearLatencyMs = 250
        c.nearRssiThreshold = -71
        c.orgId = "4f1c2b3a-0000-4000-8000-1234567890ab"
        c.phoneOvfBit = 31
        c.phoneToken = "0123456789ABCDEF0123456789ABCDEF"
        c.scanIntervalSec = 3
        c.serverUrl = "https://example.supabase.co"
        c.unlockAuto = false
        c.unlockDelaySec = 10
        c.updateChannel = "beta"
        c.updateCheck = false

        XCTAssertTrue(ConfigStore.save(c))
        let bytes = [UInt8](try Data(contentsOf: Paths.configFile))
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.configFile.path + ".tmp"))

        let back = ConfigStore.load()
        var want = c
        want.loaded = true
        XCTAssertEqual(back, want)
        XCTAssertFalse(back.loadFailed)

        // 두 번째 저장도 같은 바이트 (rename 으로 바꿔 끼운다).
        XCTAssertTrue(ConfigStore.save(back))
        XCTAssertEqual([UInt8](try Data(contentsOf: Paths.configFile)), bytes)
    }

    func testAbsentFileGivesDefaults() {
        let c = ConfigStore.load()
        XCTAssertFalse(c.loaded)
        XCTAssertFalse(c.loadFailed)
        XCTAssertEqual(c, AppConfig())
        // 처음 실행: 기본값에 자기 값을 얹어 저장해도 잃을 것이 없다.
        var first = c
        first.phoneToken = "AB"
        XCTAssertTrue(ConfigStore.save(first))
        XCTAssertEqual(ConfigStore.load().phoneToken, "AB")
    }

    func testFileWithoutKeysIsAbsent() throws {
        try writeConfigBytes([])
        var c = ConfigStore.load()
        XCTAssertFalse(c.loaded)
        XCTAssertFalse(c.loadFailed)

        try writeConfigBytes([0xEF, 0xBB, 0xBF] + Array("\r\nhello\r\n\r\n".utf8))
        c = ConfigStore.load()
        XCTAssertFalse(c.loaded)
        XCTAssertFalse(c.loadFailed)
        XCTAssertEqual(c, AppConfig())
    }

    func testLoadPartialFileWithBOMAndCRLF() throws {
        try writeConfigBytes([0xEF, 0xBB, 0xBF] + Array("nearRssiThreshold=  -67x\r\nphoneToken=AB\r\nfoo=bar\r\n".utf8))
        let c = ConfigStore.load()
        XCTAssertTrue(c.loaded)
        XCTAssertFalse(c.loadFailed)
        XCTAssertEqual(c.nearRssiThreshold, -67)
        XCTAssertEqual(c.phoneToken, "AB")
        XCTAssertEqual(c.gattRssiThreshold, -65)
        XCTAssertEqual(c.clipMaxKB, 4096)

        // LF 만 쓴 파일, BOM 없는 파일도 같다.
        try writeConfigBytes(Array("nearRssiThreshold=-60\nphoneToken=CD".utf8))
        let d = ConfigStore.load()
        XCTAssertTrue(d.loaded)
        XCTAssertEqual(d.nearRssiThreshold, -60)
        XCTAssertEqual(d.phoneToken, "CD")
    }

    func testUnknownKeysAreDroppedOnSave() throws {
        try writeConfigBytes(Array("foo=bar\r\nphoneToken=X\r\n".utf8))
        let c = ConfigStore.load()
        XCTAssertTrue(ConfigStore.save(c))
        let text = String(decoding: try Data(contentsOf: Paths.configFile), as: UTF8.self)
        XCTAssertFalse(text.contains("foo="))
        XCTAssertTrue(text.contains("\r\nphoneToken=X\r\n"))
    }

    func testUnreadableFileSetsLoadFailedAndSaveRefuses() throws {
        // 디렉터리는 열리지만 읽으면 EISDIR - "있는데 못 읽었다" 를 만든다.
        let path = Paths.configFile
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        let c = ConfigStore.load()
        XCTAssertTrue(c.loadFailed)
        XCTAssertFalse(c.loaded)
        var defaults = AppConfig()
        defaults.loadFailed = true
        XCTAssertEqual(c, defaults)

        // 상태가 바뀔 때만 적는다.
        _ = ConfigStore.load()
        var log = readLog()
        XCTAssertEqual(occurrences("config: config.ini is there but could not be read (err=", in: log), 1)
        XCTAssertTrue(log.contains("- using defaults for now and refusing to save over it"))

        XCTAssertFalse(ConfigStore.save(c))
        log = readLog()
        XCTAssertTrue(log.contains("config: save refused - this copy came from a failed read; "
                                   + "writing it would replace config.ini with defaults"))
        XCTAssertTrue(isDirectory(path), "a refused save must not touch config.ini")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path + ".tmp"))

        // 다시 읽히게 되면 한 번 적는다 (없는 파일도 "읽힌다" 쪽이다).
        try FileManager.default.removeItem(at: path)
        let again = ConfigStore.load()
        XCTAssertFalse(again.loadFailed)
        log = readLog()
        XCTAssertEqual(occurrences("config: config.ini can be read again", in: log), 1)
        _ = ConfigStore.load()
        XCTAssertEqual(occurrences("config: config.ini can be read again", in: readLog()), 1)
    }

    func testSaveFailureIsLoggedAndLeavesNoTmp() throws {
        // config.ini 자리에 디렉터리가 있으면 rename 이 끝내 실패한다.
        let path = Paths.configFile
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertFalse(ConfigStore.save(AppConfig()))
        let log = readLog()
        XCTAssertTrue(log.contains("config: save FAILED at replace config.ini (err="), log)
        XCTAssertTrue(log.contains(") - config.ini is unchanged"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path + ".tmp"))
        XCTAssertTrue(isDirectory(path))
        try FileManager.default.removeItem(at: path)
    }

    // MARK: - ServerDefaults

    func testServerDefaultsOverrideRule() {
        var c = AppConfig()
        XCTAssertEqual(ServerDefaults.url(c), "https://vnonoschrzbgvyeduosm.supabase.co")
        XCTAssertEqual(ServerDefaults.key(c), ServerDefaults.anonKey)
        XCTAssertTrue(ServerDefaults.anonKey.hasPrefix("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."))
        XCTAssertTrue(ServerDefaults.anonKey.hasSuffix(".KqkmH7UtcR4ihFDMmAMfWRH0O2P2s__Jglzr5QWIzfc"))
        XCTAssertEqual(ServerDefaults.dashboardUrl, "https://icesgg.github.io/smartscreen/dashboard.html")
        c.serverUrl = "https://other.example"
        c.anonKey = "k"
        XCTAssertEqual(ServerDefaults.url(c), "https://other.example")
        XCTAssertEqual(ServerDefaults.key(c), "k")
    }

    // MARK: - TextSanitize

    func testCapErrorText() {
        XCTAssertEqual(TextSanitize.capErrorText("short"), "short")
        XCTAssertEqual(TextSanitize.capErrorText("한글 오류"), "한글 오류")
        XCTAssertEqual(TextSanitize.capErrorText("line1\nline2\ttab\r"), "line1 line2 tab ")
        XCTAssertEqual(TextSanitize.capErrorText("del\u{7F}kept"), "del\u{7F}kept")
        XCTAssertEqual(TextSanitize.capErrorText(String(repeating: "a", count: 200)).utf16.count, 160)
        XCTAssertEqual(TextSanitize.capErrorText(String(repeating: "a", count: 160)), String(repeating: "a", count: 160))
        // 160번째 단위가 서러게이트 앞짝이면 그 글자를 통째로 버린다.
        let a159 = String(repeating: "a", count: 159)
        XCTAssertEqual(TextSanitize.capErrorText(a159 + "😀b"), a159)
        let a158 = String(repeating: "a", count: 158)
        XCTAssertEqual(TextSanitize.capErrorText(a158 + "😀b"), a158 + "😀")
    }

    func testOneLine() {
        XCTAssertEqual(TextSanitize.oneLine("a\nb\u{7F}c\u{1}"), "a?b?c?")
        XCTAssertEqual(TextSanitize.oneLine(String(repeating: "x", count: 60)), String(repeating: "x", count: 48))
        XCTAssertEqual(TextSanitize.oneLine(String(repeating: "y", count: 120), max: 110).utf16.count, 110)
        XCTAssertEqual(TextSanitize.oneLine("tab\there", max: 3), "tab")
        XCTAssertEqual(TextSanitize.oneLine("한글은 그대로"), "한글은 그대로")
    }

    func testCapUTF16() {
        XCTAssertEqual(TextSanitize.capUTF16("abc", 0), "")
        XCTAssertEqual(TextSanitize.capUTF16("abc", 5), "abc")
        XCTAssertEqual(TextSanitize.capUTF16("abc", 2), "ab")
        XCTAssertEqual(TextSanitize.capUTF16("a😀", 2), "a")
        XCTAssertEqual(TextSanitize.capUTF16("a😀", 3), "a😀")
        XCTAssertEqual(TextSanitize.capUTF16("a\nb", 2), "a\n")
    }

    // MARK: - Hex / SHA256Hex

    func testHex() {
        let d = Data([0x00, 0x0F, 0xAB, 0xFF])
        XCTAssertEqual(Hex.upper(d), "000FABFF")
        XCTAssertEqual(Hex.lower(d), "000fabff")
        XCTAssertEqual(Hex.upper(Data()), "")
        XCTAssertEqual(Hex.decode("000fABff"), d)
        XCTAssertEqual(Hex.decode(""), Data())
        XCTAssertNil(Hex.decode("abc"))
        XCTAssertNil(Hex.decode("0g"))
        XCTAssertNil(Hex.decode(" 00"))
        XCTAssertNil(Hex.decode("0x00"))
        let all = Data((0...255).map { UInt8($0) })
        XCTAssertEqual(Hex.decode(Hex.upper(all)), all)
        XCTAssertEqual(Hex.decode(Hex.lower(all)), all)
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Hex.of(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Hex.of(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSHA256OfFile() throws {
        Paths.ensureDir(home)
        let small = home.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: small)
        XCTAssertEqual(SHA256Hex.ofFile(small), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // 64 KiB 조각 여러 개에 걸치는 파일
        let big = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let bigURL = home.appendingPathComponent("big.bin")
        try big.write(to: bigURL)
        XCTAssertEqual(SHA256Hex.ofFile(bigURL), SHA256Hex.of(big))

        let empty = home.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        XCTAssertEqual(SHA256Hex.ofFile(empty), SHA256Hex.of(Data()))

        XCTAssertNil(SHA256Hex.ofFile(home.appendingPathComponent("missing.bin")))
        XCTAssertNil(SHA256Hex.ofFile(home), "a directory is a read error")
    }
}
