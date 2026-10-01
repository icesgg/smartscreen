import XCTest
import Foundation
import SmartScreenCore

/// 프로그램 자동 업데이트의 판단 (UpdateLogic.swift). Windows client/update.cpp 와 같은 결정을
/// 내리는지 본다: 후보 고르기, 기업/개인, 승인 대기, 실패 기록, [나중에], 배경 확인 실패, 진행률,
/// 정리 대상, --apply-update 인자.
final class UpdateTests: XCTestCase {
    private let sha1 = String(repeating: "a", count: 64)
    private let sha2 = String(repeating: "b", count: 64)
    /// 시험에서 "지금 도는 macOS" 로 쓰는 값 (13.5.0)
    private let os13 = OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0)

    private func body(_ s: String) -> Data { return Data(s.utf8) }

    /// minMacOS 는 JSON 조각 그대로 (예: "\"14.0\"", "null", "14"). nil 이면 열이 없다.
    private func row(_ v: String, sha: String? = nil, path: String? = nil, size: String = "123",
                     notes: String = "\"메모\"", minMacOS: String? = nil) -> String {
        let h = sha ?? sha1
        let p = path ?? "mac/\(v)/SmartScreen-mac.zip"
        let m = minMacOS.map { ",\"min_macos\":" + $0 } ?? ""
        return "{\"version\":\"\(v)\",\"storage_path\":\"\(p)\",\"sha256\":\"\(h)\",\"size\":\(size),\"notes\":\(notes)\(m)}"
    }

    // MARK: - 서버 질의

    func testQueriesAreExact() {
        XCTAssertEqual(UpdateLogic.releasesQuery(channel: "stable"),
                       "/rest/v1/mac_releases?select=version,storage_path,sha256,size,notes,min_macos&active=eq.true&channel=eq.stable&order=published_at.desc")
        XCTAssertEqual(UpdateLogic.releasesQuery(channel: "beta"),
                       "/rest/v1/mac_releases?select=version,storage_path,sha256,size,notes,min_macos&active=eq.true&channel=eq.beta&order=published_at.desc")
        // 오타·빈 값은 stable (조용히 멎으면 안 된다)
        XCTAssertTrue(UpdateLogic.releasesQuery(channel: "Beta").contains("channel=eq.stable&"))
        XCTAssertTrue(UpdateLogic.releasesQuery(channel: "").contains("channel=eq.stable&"))
        // 조직 id 는 소문자 정규형으로
        XCTAssertEqual(UpdateLogic.approvalsQuery(org: " 0A1B2C3D-0000-1111-2222-333344445555\n"),
                       "/rest/v1/org_mac_release_approvals?select=version&org_id=eq.0a1b2c3d-0000-1111-2222-333344445555")
        // 모양이 틀린 값은 URL 을 벗어나지 못하게 인코딩만
        XCTAssertEqual(UpdateLogic.approvalsQuery(org: "x&y=1"),
                       "/rest/v1/org_mac_release_approvals?select=version&org_id=eq.x%26y%3D1")
        XCTAssertEqual(UpdateLogic.downloadPath(storagePath: "mac/1.2.0/SmartScreen-mac.zip"),
                       "/storage/v1/object/authenticated/releases/mac/1.2.0/SmartScreen-mac.zip")
    }

    func testValidStoragePath() {
        XCTAssertTrue(UpdateLogic.validStoragePath("mac/1.1.8/SmartScreen-mac.zip"))
        XCTAssertTrue(UpdateLogic.validStoragePath("1.1.8/SmartScreen.exe"))
        XCTAssertTrue(UpdateLogic.validStoragePath(String(repeating: "a", count: 200)))
        XCTAssertFalse(UpdateLogic.validStoragePath(String(repeating: "a", count: 201)))
        XCTAssertFalse(UpdateLogic.validStoragePath(""))
        XCTAssertFalse(UpdateLogic.validStoragePath("/mac/x.zip"))
        XCTAssertFalse(UpdateLogic.validStoragePath("mac/../x.zip"))
        XCTAssertFalse(UpdateLogic.validStoragePath("mac/a b.zip"))
        XCTAssertFalse(UpdateLogic.validStoragePath("mac/x.zip?x=1"))
        XCTAssertFalse(UpdateLogic.validStoragePath("mac/한글.zip"))
        XCTAssertTrue(UpdateLogic.validStoragePath("a.b_c-d/E.F"))
    }

    func testErrText() {
        XCTAssertEqual(UpdateLogic.errText(body("{\"code\":\"PGRST205\",\"message\":\"Could not find the table\"}"),
                                           status: 404, rest: true), UpdateText.missingTable)
        XCTAssertEqual(UpdateLogic.errText(body("{\"code\":\"42P01\",\"message\":\"relation does not exist\"}"),
                                           status: 400, rest: true), UpdateText.missingTable)
        // REST 의 404 는 표가 없다는 뜻이다
        XCTAssertEqual(UpdateLogic.errText(Data(), status: 404, rest: true), UpdateText.missingTable)
        // 저장소의 404 는 "그런 파일 없음" 이다
        XCTAssertEqual(UpdateLogic.errText(body("{\"statusCode\":\"404\",\"error\":\"not_found\",\"message\":\"Object not found\"}"),
                                           status: 404, rest: false), "Object not found")
        // message 가 error 보다 먼저, 빈 글은 건너뛴다
        XCTAssertEqual(UpdateLogic.errText(body("{\"error\":\"e\",\"msg\":\"m\",\"message\":\"\"}"),
                                           status: 400, rest: true), "m")
        XCTAssertEqual(UpdateLogic.errText(body("{\"error\":\"e\",\"error_description\":\"d\"}"),
                                           status: 400, rest: true), "d")
        XCTAssertEqual(UpdateLogic.errText(body("<html>bad gateway</html>"), status: 502, rest: true), "HTTP 502")
        XCTAssertEqual(UpdateLogic.errText(Data(), status: 500, rest: false), "HTTP 500")
        // 서버 글은 한 줄, 160 단위까지
        let long = String(repeating: "가", count: 300)
        let t = UpdateLogic.errText(body("{\"message\":\"\(long)\\nnext\"}"), status: 400, rest: true)
        XCTAssertEqual(t.utf16.count, 160)
        XCTAssertFalse(t.contains("\n"))
    }

    func testApprovedVersions() {
        let s = UpdateLogic.approvedVersions(body("[{\"version\":\"1.2.0\"},{\"version\":5},{\"x\":1},{\"version\":\"1.3.0\"}]"))
        XCTAssertEqual(s, Set(["1.2.0", "1.3.0"]))
        XCTAssertTrue(UpdateLogic.approvedVersions(body("{\"message\":\"x\"}")).isEmpty)
        XCTAssertTrue(UpdateLogic.approvedVersions(Data()).isEmpty)
    }

    // MARK: - 후보 고르기

    func testScanPicksNumericallyNewestAndCountsEveryRow() {
        let json = "[" + [row("1.9.0"), row("1.10.0", sha: sha2), row("1.1.7"), row("1.0.0")].joined(separator: ",") + "]"
        let s = UpdateLogic.scan(body(json), enterprise: false, approved: [], current: SemVer(1, 1, 7), macOS: os13)
        XCTAssertEqual(s.rows, 4)
        XCTAssertEqual(s.best?.version, "1.10.0")           // 문자열 비교면 1.9.0 이 이긴다
        XCTAssertEqual(s.best?.sha256, sha2)
        XCTAssertEqual(s.best?.storagePath, "mac/1.10.0/SmartScreen-mac.zip")
        XCTAssertEqual(s.best?.size, 123)
        XCTAssertEqual(s.best?.notes, "메모")
        XCTAssertEqual(s.newest, s.best)
        XCTAssertTrue(s.malformed.isEmpty)
    }

    func testScanSkipsMalformedAndOld() {
        let rows = [
            row("1.2"),                                        // 버전 모양
            row("1.3.0", sha: "abc"),                          // 해시 길이
            row("1.4.0", path: "/abs/x.zip"),                  // 경로
            "{\"version\":\"1.5.0\",\"storage_path\":\"mac/x.zip\"}",   // sha256 없음: 조용히
            "{\"version\":1,\"storage_path\":\"a\",\"sha256\":\"b\"}",  // 문자열 아님: 조용히
            row("1.1.7"),                                      // 같은 버전
            row("0.9.0"),
        ]
        let s = UpdateLogic.scan(body("[" + rows.joined(separator: ",") + "]"), enterprise: false,
                                 approved: [], current: SemVer(1, 1, 7), macOS: os13)
        XCTAssertEqual(s.rows, 7)
        XCTAssertNil(s.best)
        XCTAssertNil(s.newest)
        XCTAssertEqual(s.malformed, ["1.2", "1.3.0", "1.4.0"])
    }

    func testScanNormalizesFields() {
        let upper = String(repeating: "AB", count: 32)
        let json = "[" + row("2.0.0", sha: upper, size: "-5", notes: "null") + "]"
        let s = UpdateLogic.scan(body(json), enterprise: false, approved: [], current: SemVer(1, 0, 0), macOS: os13)
        XCTAssertEqual(s.best?.sha256, String(repeating: "ab", count: 32))
        XCTAssertEqual(s.best?.size, 0)
        XCTAssertEqual(s.best?.notes, "")
        // 배열이 아니면 아무 행도 없다
        let e = UpdateLogic.scan(body("{\"message\":\"x\"}"), enterprise: false, approved: [], current: SemVer(1, 0, 0),
                                 macOS: os13)
        XCTAssertEqual(e.rows, 0)
        XCTAssertNil(e.best)
    }

    func testScanEnterpriseOnlyApproved() {
        let json = "[" + [row("1.3.0"), row("1.2.0"), row("1.4.0")].joined(separator: ",") + "]"
        let s = UpdateLogic.scan(body(json), enterprise: true, approved: ["1.2.0", "1.3.0"], current: SemVer(1, 1, 7),
                                 macOS: os13)
        XCTAssertEqual(s.best?.version, "1.3.0")
        XCTAssertEqual(s.newest?.version, "1.4.0")
        let none = UpdateLogic.scan(body(json), enterprise: true, approved: [], current: SemVer(1, 1, 7), macOS: os13)
        XCTAssertNil(none.best)
        XCTAssertEqual(none.newest?.version, "1.4.0")
        // 승인은 글자 그대로 비교한다
        let lead = UpdateLogic.scan(body("[" + row("01.2.0") + "]"), enterprise: true, approved: ["1.2.0"],
                                    current: SemVer(1, 1, 7), macOS: os13)
        XCTAssertNil(lead.best)
    }

    // MARK: - macOS 버전 (min_macos, LSMinimumSystemVersion)

    func testParseMacOSVersion() {
        func parts(_ s: String) -> [Int]? {
            guard let v = UpdateLogic.parseMacOSVersion(s) else { return nil }
            return [v.majorVersion, v.minorVersion, v.patchVersion]
        }
        XCTAssertEqual(parts("13.0"), [13, 0, 0])                 // 서버 min_macos 모양
        XCTAssertEqual(parts("14"), [14, 0, 0])                   // Info.plist 에는 한 덩이도 온다
        XCTAssertEqual(parts("10.15.7"), [10, 15, 7])
        XCTAssertEqual(parts(" 13.0\n"), [13, 0, 0])              // 앞뒤 공백만 봐준다
        for bad in ["", " ", "13.", ".0", "13..0", "13.0.1.2", "a.b", "13.0-beta", "-13.0", "+13", "13,0",
                    "1234567890.0", "１３.0"] {
            XCTAssertNil(UpdateLogic.parseMacOSVersion(bad), "'\(bad)'")
        }
    }

    func testUnmetMacOS() {
        let run = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 1)
        XCTAssertNil(UpdateLogic.unmetMacOS("13.0", running: run))
        XCTAssertNil(UpdateLogic.unmetMacOS("13.6", running: run))
        XCTAssertNil(UpdateLogic.unmetMacOS("13.6.1", running: run))           // 같으면 된다
        XCTAssertNil(UpdateLogic.unmetMacOS("12", running: run))
        XCTAssertEqual(UpdateLogic.unmetMacOS("13.6.2", running: run), "13.6.2")
        XCTAssertEqual(UpdateLogic.unmetMacOS("13.7", running: run), "13.7")
        XCTAssertEqual(UpdateLogic.unmetMacOS("14.0", running: run), "14.0")
        XCTAssertEqual(UpdateLogic.unmetMacOS("14", running: run), "14")
        XCTAssertEqual(UpdateLogic.unmetMacOS(" 15.0\n", running: run), "15.0")    // 보여 줄 때는 공백 없이
        // 없거나 못 읽는 값은 제약이 없다 (업데이트가 조용히 멎으면 안 된다)
        XCTAssertNil(UpdateLogic.unmetMacOS(nil, running: run))
        XCTAssertNil(UpdateLogic.unmetMacOS("", running: run))
        XCTAssertNil(UpdateLogic.unmetMacOS("garbage", running: run))
        XCTAssertNil(UpdateLogic.unmetMacOS("99.0-beta", running: run))
    }

    func testScanSkipsRowsNeedingNewerMacOS() {
        let rows = [
            row("1.3.0", minMacOS: "\"14.0\""),        // 이 Mac(13.5) 으로는 못 쓴다
            row("1.2.0", minMacOS: "\"13.0\""),
            row("1.2.1", minMacOS: "\"13.5\""),        // 같은 버전이면 된다
            row("1.2.2"),                              // 열 없음 = 제약 없음 (가장 새 것)
            row("1.2.3", minMacOS: "null"),            // null = 제약 없음
            row("1.2.4", minMacOS: "14"),              // 글자가 아님 = 제약 없음
            row("1.2.5", minMacOS: "\"junk\""),        // 모양이 틀림 = 제약 없음
            row("1.4.0", minMacOS: "\"13.6\""),        // 못 쓴다
            row("1.1.0", minMacOS: "\"15.0\""),        // 지금 버전 이하라 관심 없다 (로그도 없다)
        ]
        let json = body("[" + rows.joined(separator: ",") + "]")
        let s = UpdateLogic.scan(json, enterprise: false, approved: [], current: SemVer(1, 1, 8), macOS: os13)
        XCTAssertEqual(s.rows, 9)
        XCTAssertEqual(s.best?.version, "1.2.5")
        XCTAssertEqual(s.newest?.version, "1.2.5")
        XCTAssertTrue(s.malformed.isEmpty)
        XCTAssertEqual(s.osSkipped, [ReleaseOSSkip(version: "1.3.0", minMacOS: "14.0"),
                                     ReleaseOSSkip(version: "1.4.0", minMacOS: "13.6")])
        XCTAssertEqual(s.osSkipped.map { $0.logLine },
                       ["update: skipping 1.3.0 (needs macOS 14.0)", "update: skipping 1.4.0 (needs macOS 13.6)"])

        // 새 macOS 에서는 아무것도 건너뛰지 않는다
        let os14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let s14 = UpdateLogic.scan(json, enterprise: false, approved: [], current: SemVer(1, 1, 8), macOS: os14)
        XCTAssertEqual(s14.best?.version, "1.4.0")
        XCTAssertTrue(s14.osSkipped.isEmpty)

        // 기업 PC: 승인됐어도 이 macOS 로 못 쓰면 받지 않고, "승인 대기" 에도 그 버전이 보이지 않는다
        let onlyNew = body("[" + row("1.3.0", minMacOS: "\"14.0\"") + "]")
        let ent = UpdateLogic.scan(onlyNew, enterprise: true, approved: ["1.3.0"], current: SemVer(1, 1, 8), macOS: os13)
        XCTAssertNil(ent.best)
        XCTAssertNil(ent.newest)
        XCTAssertEqual(ent.osSkipped.count, 1)
        let out = UpdateLogic.outcome(ent, failedWhy: nil, enterprise: true, manual: false, running: "1.1.8")
        XCTAssertEqual(out.phase, .upToDate)
        XCTAssertFalse(out.downloadNow)
    }

    func testIncomingPlaceAndCleanup() {
        XCTAssertEqual(UpdateLogic.incomingName, ".SmartScreen.app.incoming")
        let run = SemVer(1, 2, 0)
        XCTAssertTrue(UpdateLogic.shouldRemoveIncoming(version: "1.1.7", running: run))   // 맞바꾼 뒤 남은 예전 앱
        XCTAssertTrue(UpdateLogic.shouldRemoveIncoming(version: "1.2.0", running: run))
        XCTAssertTrue(UpdateLogic.shouldRemoveIncoming(version: nil, running: run))       // 반쯤 복사된 것
        XCTAssertTrue(UpdateLogic.shouldRemoveIncoming(version: "x", running: run))
        XCTAssertFalse(UpdateLogic.shouldRemoveIncoming(version: "1.3.0", running: run))  // 다른 복사본이 놓는 중일 수 있다
    }

    func testOutcomes() {
        var scan = ReleaseScan()
        scan.rows = 3
        scan.best = ReleaseCandidate(version: "1.2.0", storagePath: "p", notes: "", sha256: sha1, size: 1)
        scan.newest = scan.best

        let failed = UpdateLogic.outcome(scan, failedWhy: "이 폴더에는 쓸 권한이 없어요", enterprise: true, manual: false,
                                         running: "1.1.7")
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.msg, "지난번 적용 실패: 이 폴더에는 쓸 권한이 없어요")
        XCTAssertTrue(failed.fromMarker)
        XCTAssertFalse(failed.downloadNow)
        XCTAssertEqual(failed.logLine,
                       "update: 1.2.0 available but a previous apply failed (이 폴더에는 쓸 권한이 없어요) - waiting for [retry]")

        let personal = UpdateLogic.outcome(scan, failedWhy: nil, enterprise: false, manual: true, running: "1.1.7")
        XCTAssertEqual(personal.phase, .available)
        XCTAssertEqual(personal.msg, "")
        XCTAssertFalse(personal.fromMarker)
        XCTAssertFalse(personal.downloadNow)
        XCTAssertEqual(personal.logLine, "update: 1.2.0 available (running 1.1.7, 3 row(s)) [manual]")

        let ent = UpdateLogic.outcome(scan, failedWhy: nil, enterprise: true, manual: false, running: "1.1.7")
        XCTAssertEqual(ent.phase, .available)
        XCTAssertTrue(ent.downloadNow)
        XCTAssertEqual(ent.logLine, "update: 1.2.0 available (running 1.1.7, 3 row(s), org-approved)")

        var pending = ReleaseScan()
        pending.rows = 1
        pending.newest = scan.best
        let p = UpdateLogic.outcome(pending, failedWhy: nil, enterprise: true, manual: false, running: "1.1.7")
        XCTAssertEqual(p.phase, .pending)
        XCTAssertEqual(p.msg, "관리자 승인을 기다려요")
        XCTAssertEqual(p.logLine, "update: 1.2.0 exists but not approved for org (running 1.1.7)")

        var none = ReleaseScan()
        none.rows = 2
        let u = UpdateLogic.outcome(none, failedWhy: nil, enterprise: false, manual: false, running: "1.1.7")
        XCTAssertEqual(u.phase, .upToDate)
        XCTAssertEqual(u.logLine, "update: up to date (1.1.7, 2 row(s))")
        let um = UpdateLogic.outcome(none, failedWhy: nil, enterprise: true, manual: true, running: "1.1.7")
        XCTAssertEqual(um.logLine, "update: up to date (1.1.7, 2 row(s)) [manual]")
    }

    // MARK: - 상태 기계

    private func scanWith(best: String?, newest: String?) -> ReleaseScan {
        var s = ReleaseScan()
        if let b = best { s.best = ReleaseCandidate(version: b, storagePath: "p", notes: "n" + b, sha256: sha1, size: 9) }
        if let n = newest { s.newest = ReleaseCandidate(version: n, storagePath: "p", notes: "n" + n, sha256: sha1, size: 9) }
        return s
    }

    func testSetPhaseKeepsProgressOnlyWhileDownloading() {
        var m = ReleaseMachine()
        m.setPhase(.downloading, msg: "1.2.0 내려받는 중")
        m.setProgress(40)
        m.setPhase(.downloading, msg: "x")
        XCTAssertEqual(m.st.progressPct, 40)
        m.setPhase(.ready, msg: "준비됨")
        XCTAssertEqual(m.st.progressPct, 0)
        m.setPhase(.failed, msg: "a", fromMarker: true)
        XCTAssertTrue(m.st.fromMarker)
        m.setPhase(.failed, msg: "b")                 // nil = 그대로
        XCTAssertTrue(m.st.fromMarker)
        XCTAssertEqual(m.st.msg, "b")
        m.setPhase(.failed, msg: "c", fromMarker: false)
        XCTAssertFalse(m.st.fromMarker)
    }

    func testBackgroundCheckKeepsVisibleBand() {
        var m = ReleaseMachine()
        // 처음(Idle)과 UpToDate 에서는 배경 확인도 Checking 을 거친다
        let first = m.beginCheck(manual: false)
        XCTAssertTrue(first.enterChecking)
        m.setPhase(.upToDate)
        let again = m.beginCheck(manual: false)
        XCTAssertTrue(again.enterChecking)
        // 띠가 보이는 단계에서는 배경 확인이 Checking 으로 바꾸지 않는다 (매시간 깜빡이지 않게)
        for p in [ReleasePhase.available, .pending, .failed] {
            m.setPhase(p)
            let b = m.beginCheck(manual: false)
            XCTAssertFalse(b.enterChecking)
            XCTAssertEqual(b.prev, p)
            // 손으로 누른 것은 언제나 Checking 을 거친다
            let byHand = m.beginCheck(manual: true)
            XCTAssertTrue(byHand.enterChecking)
        }
        // Checking 에 머물러 있던 것은 Idle 로 되돌아간다
        m.setPhase(.checking)
        let stuck = m.beginCheck(manual: false)
        XCTAssertEqual(stuck.prev, .idle)
    }

    func testBackgroundFailureRestoresPrevWithoutTouchingTickOrMarker() {
        var m = ReleaseMachine()
        m.adopt(scanWith(best: nil, newest: nil), enterprise: false, now: 1234)
        m.setPhase(.upToDate)
        let b = m.beginCheck(manual: false)
        m.setPhase(.checking)
        m.keepAfterBackgroundFailure(prev: b.prev)
        XCTAssertEqual(m.st.phase, .upToDate)
        XCTAssertEqual(m.st.checkedTick, 1234)
        // Failed(기록) 에서 배경 확인이 실패해도 fromMarker 는 남는다
        m.setPhase(.failed, msg: "지난번 적용 실패: x", fromMarker: true)
        let b2 = m.beginCheck(manual: false)
        m.keepAfterBackgroundFailure(prev: b2.prev)
        XCTAssertEqual(m.st.phase, .failed)
        XCTAssertTrue(m.st.fromMarker)
        XCTAssertEqual(m.st.msg, "지난번 적용 실패: x")
    }

    func testAdoptCandidateAndDownloadedFile() {
        var m = ReleaseMachine()
        m.adopt(scanWith(best: "1.2.0", newest: "1.2.0"), enterprise: false, now: 5)
        XCTAssertEqual(m.cand.version, "1.2.0")
        XCTAssertEqual(m.st.version, "1.2.0")
        XCTAssertEqual(m.st.notes, "n1.2.0")
        XCTAssertEqual(m.st.checkedTick, 5)
        XCTAssertFalse(m.st.autoApply)
        XCTAssertTrue(m.hasCandidate)
        m.downloaded = "/x/SmartScreen-1.2.0.zip"
        // 같은 후보면 받아 둔 파일을 그대로 쓴다
        m.adopt(scanWith(best: "1.2.0", newest: "1.2.0"), enterprise: true, now: 6)
        XCTAssertEqual(m.downloaded, "/x/SmartScreen-1.2.0.zip")
        XCTAssertTrue(m.st.autoApply)
        // 다른 버전의 파일은 쓸모없다
        m.adopt(scanWith(best: "1.3.0", newest: "1.3.0"), enterprise: true, now: 7)
        XCTAssertEqual(m.downloaded, "")
        // 승인 대기: 버전은 보이지만 후보는 없다
        m.downloaded = "/x"
        m.adopt(scanWith(best: nil, newest: "1.4.0"), enterprise: true, now: 8)
        XCTAssertEqual(m.st.version, "1.4.0")
        XCTAssertFalse(m.hasCandidate)
        XCTAssertEqual(m.downloaded, "")
        // 아무것도 없다
        m.adopt(scanWith(best: nil, newest: nil), enterprise: false, now: 9)
        XCTAssertEqual(m.st.version, "")
        XCTAssertEqual(m.st.notes, "")
        XCTAssertFalse(m.st.dismissed)
    }

    func testDismissPerVersionAndPerResult() {
        var m = ReleaseMachine()
        m.adopt(scanWith(best: "1.2.0", newest: "1.2.0"), enterprise: false, now: 1)
        m.setPhase(.available)
        m.dismiss()
        XCTAssertTrue(m.status.dismissed)
        XCTAssertEqual(m.dismissedVer, "1.2.0")
        // 배경 확인이 같은 버전을 또 찾아도 감춘 채로
        _ = m.beginCheck(manual: false)
        m.adopt(scanWith(best: "1.2.0", newest: "1.2.0"), enterprise: false, now: 2)
        XCTAssertTrue(m.status.dismissed)
        // 더 새 버전이 나오면 다시 보인다
        m.adopt(scanWith(best: "1.3.0", newest: "1.3.0"), enterprise: false, now: 3)
        XCTAssertFalse(m.status.dismissed)
        // 손으로 누른 확인은 감춘 것을 푼다
        m.dismiss()
        _ = m.beginCheck(manual: true)
        XCTAssertFalse(m.st.dismissed)
        XCTAssertEqual(m.dismissedVer, "")
        m.adopt(scanWith(best: "1.3.0", newest: "1.3.0"), enterprise: false, now: 4)
        XCTAssertFalse(m.status.dismissed)

        // 버전 없이(오프라인 실패) 감추면 다음 확인 결과까지만
        var o = ReleaseMachine()
        o.setPhase(.failed, msg: "서버에 닿지 않아요", fromMarker: false)
        o.dismiss()
        XCTAssertTrue(o.dismissedNow)
        XCTAssertTrue(o.status.dismissed)
        _ = o.beginCheck(manual: false)
        XCTAssertFalse(o.dismissedNow)
    }

    func testRetryRules() {
        var m = ReleaseMachine()
        XCTAssertFalse(m.canStartDownload)
        // 승인 대기: version 은 있어도 후보가 없다 → [다시 시도] 는 다시 묻기
        m.adopt(scanWith(best: nil, newest: "1.4.0"), enterprise: true, now: 1)
        m.setPhase(.failed, msg: "x", fromMarker: false)
        XCTAssertFalse(m.hasCandidate)
        XCTAssertFalse(m.canStartDownload)
        // 후보가 있는 Failed(기록) → 다시 받기, 시작되면 fromMarker 를 끄고 그 버전을 돌려준다
        m.adopt(scanWith(best: "1.4.0", newest: "1.4.0"), enterprise: true, now: 2)
        m.setPhase(.failed, msg: "지난번 적용 실패: y", fromMarker: true)
        XCTAssertTrue(m.canStartDownload)
        let started = m.downloadStarted()
        XCTAssertEqual(started, "1.4.0")
        XCTAssertFalse(m.st.fromMarker)
        m.setPhase(.available)
        XCTAssertTrue(m.canStartDownload)
        m.setPhase(.ready, msg: "준비됨")
        XCTAssertFalse(m.canStartDownload)
        XCTAssertTrue(m.holdsDownload)
        XCTAssertFalse(m.readyToApply)            // 확인된 파일이 없다
        m.downloaded = "/x.zip"
        XCTAssertTrue(m.readyToApply)
        m.markApplying()
        XCTAssertEqual(m.st.phase, .applying)
        XCTAssertEqual(m.st.msg, "다시 시작하는 중")
        XCTAssertTrue(m.holdsDownload)
    }

    func testPhaseNumbersMatchWindows() {
        XCTAssertEqual(ReleasePhase.idle.rawValue, 0)
        XCTAssertEqual(ReleasePhase.checking.rawValue, 1)
        XCTAssertEqual(ReleasePhase.upToDate.rawValue, 2)
        XCTAssertEqual(ReleasePhase.pending.rawValue, 3)
        XCTAssertEqual(ReleasePhase.available.rawValue, 4)
        XCTAssertEqual(ReleasePhase.downloading.rawValue, 5)
        XCTAssertEqual(ReleasePhase.ready.rawValue, 6)
        XCTAssertEqual(ReleasePhase.applying.rawValue, 7)
        XCTAssertEqual(ReleasePhase.failed.rawValue, 8)
    }

    // MARK: - 진행률

    func testProgressRule() {
        XCTAssertNil(UpdateLogic.progress(got: 10, expect: 0, lastPct: -1))       // 크기를 모르면 없다
        XCTAssertNil(UpdateLogic.progress(got: 0, expect: 100, lastPct: -1))       // -1 → 0 은 1 차이라 안 알린다
        XCTAssertEqual(UpdateLogic.progress(got: 3, expect: 100, lastPct: -1), 3)
        XCTAssertNil(UpdateLogic.progress(got: 3, expect: 100, lastPct: 0))
        XCTAssertEqual(UpdateLogic.progress(got: 4, expect: 100, lastPct: 0), 4)
        XCTAssertEqual(UpdateLogic.progress(got: 29, expect: 100, lastPct: 25), 29)   // 정수 나눗셈
        XCTAssertNil(UpdateLogic.progress(got: 99, expect: 100, lastPct: 97))
        XCTAssertEqual(UpdateLogic.progress(got: 100, expect: 100, lastPct: 97), 100)
        XCTAssertNil(UpdateLogic.progress(got: 200, expect: 100, lastPct: 100))     // 100 에서 막힌다
        // got*100 이 넘쳐도 죽지 않는다 (근삿값)
        let huge = UpdateLogic.progress(got: UInt64.max / 2, expect: UInt64.max, lastPct: 0)
        XCTAssertTrue(huge == 49 || huge == 50)
    }

    // MARK: - 실패 기록

    func testMarkerFileName() {
        XCTAssertEqual(UpdateMarker.fileName("1.2.0"), "failed-1.2.0.txt")
        XCTAssertNil(UpdateMarker.fileName(""))
        XCTAssertNil(UpdateMarker.fileName("1.2"))
        XCTAssertNil(UpdateMarker.fileName("../1.2.0"))
        XCTAssertNil(UpdateMarker.fileName("1.2.0/x"))
    }

    func testMarkerRoundTrip() {
        let why = "이 폴더에는 쓸 권한이 없어요 - 프로그램을 응용 프로그램 폴더나 사용자 폴더로 옮기면 자동 업데이트가 돼요"
        let d = UpdateMarker.encode(why)
        XCTAssertEqual(Array(d.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(d.last, 0x0A)
        XCTAssertEqual(UpdateMarker.decode(d), why)
        // Windows 가 쓴 모양 (BOM + CRLF), BOM 없는 것, 두 줄 이상, 빈 파일
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        XCTAssertEqual(UpdateMarker.decode(Data(bom + Array("abc\r\n".utf8))), "abc")
        XCTAssertEqual(UpdateMarker.decode(Data("first\nsecond\n".utf8)), "first")
        XCTAssertEqual(UpdateMarker.decode(Data("no newline".utf8)), "no newline")
        XCTAssertEqual(UpdateMarker.decode(Data()), "")
        // fgetws(512) 처럼 511 단위까지
        let long = String(repeating: "x", count: 600)
        XCTAssertEqual(UpdateMarker.decode(Data((long + "\n").utf8)).utf16.count, 511)
    }

    /// RG-0: "macOS 가 낮다" 는 기록은 macOS 를 올린 뒤 거짓이 된다. 기록에서 버전을 다시 읽어 지금
    /// macOS 와 견준다 - 쓰고 읽어도 그 버전이 그대로 나와야 한다.
    func testNeedsNewerMacOSMarkerRoundTrip() {
        for x in ["14.0", "14", "13.6.2", "15.1"] {
            let stored = UpdateMarker.decode(UpdateMarker.encode(UpdateText.needsNewerMacOS(x)))
            XCTAssertEqual(UpdateText.needsNewerMacOSMinimum(stored), x)
        }
        // 정확히 needsNewerMacOS(x) 모양만 (가운데는 공백 없는 macOS 버전). 다른 기록은 평범한 실패다.
        let others = [
            "", UpdateText.noPermission, UpdateText.appMismatch, UpdateText.newBuildDidNotStart,
            UpdateText.needsNewerMacOS(""), UpdateText.needsNewerMacOS("abc"), UpdateText.needsNewerMacOS("14.0.1.2"),
            UpdateText.needsNewerMacOS(" 14.0"), UpdateText.needsNewerMacOS("14.0") + " ",
            "x" + UpdateText.needsNewerMacOS("14.0"),
            UpdateText.applyFailedPrefix + UpdateText.needsNewerMacOS("14.0"),
            UpdateText.lastApplyFailedPrefix + UpdateText.needsNewerMacOS("14.0"),
            "이 macOS 에서는 새 버전을 쓸 수 없어요 (macOS 14.0)",
        ]
        for s in others {
            XCTAssertNil(UpdateText.needsNewerMacOSMinimum(s), "'\(s)'")
        }

        // 아직 낮은 macOS: 기록은 그대로 (nil). 그 버전에 닿았거나 넘었으면 버전을 돌려준다 = 지운다.
        let marker = UpdateMarker.decode(UpdateMarker.encode(UpdateText.needsNewerMacOS("14.0")))
        let os14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let os15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)
        XCTAssertNil(UpdateLogic.obsoleteMacOSMarker(marker, running: os13))
        XCTAssertEqual(UpdateLogic.obsoleteMacOSMarker(marker, running: os14), "14.0")
        XCTAssertEqual(UpdateLogic.obsoleteMacOSMarker(marker, running: os15), "14.0")
        // 빌드에 달린 이유는 macOS 가 바뀌어도 남는다 ([다시 시도] 나 더 새 버전을 기다린다)
        XCTAssertNil(UpdateLogic.obsoleteMacOSMarker(UpdateText.appMismatch, running: os15))
        XCTAssertNil(UpdateLogic.obsoleteMacOSMarker(UpdateText.newBuildDidNotStart, running: os15))

        // 시나리오: 기업 Mac 이 13 에서 14 로 올라갔다. 기록을 지운 확인은 승인된 버전을 바로 받는다.
        let json = body("[" + row("1.2.0", minMacOS: "\"13.0\"") + "]")
        let scan14 = UpdateLogic.scan(json, enterprise: true, approved: ["1.2.0"], current: SemVer(1, 1, 8), macOS: os14)
        XCTAssertEqual(scan14.best?.version, "1.2.0")
        let kept = UpdateLogic.outcome(scan14, failedWhy: marker, enterprise: true, manual: false, running: "1.1.8")
        XCTAssertEqual(kept.phase, .failed)                 // 지우지 않았다면 이렇게 멎어 있었다
        XCTAssertFalse(kept.downloadNow)
        XCTAssertNotNil(UpdateLogic.obsoleteMacOSMarker(marker, running: os14))
        let cleared = UpdateLogic.outcome(scan14, failedWhy: nil, enterprise: true, manual: false, running: "1.1.8")
        XCTAssertEqual(cleared.phase, .available)
        XCTAssertTrue(cleared.downloadNow)
    }

    /// RG-1: 복사본은 바꾼 뒤 새 앱을 띄우기 전에 임시 기록을 남기고, 새 빌드는 뜨면 자기 버전의
    /// 기록을 지운다. 새 빌드가 안 떠서 .bak 을 되돌린 예전 앱은 그 기록을 보고 다시 적용하지 않는다.
    func testProvisionalMarkerStopsRestoredOldAppFromReapplying() {
        XCTAssertEqual(UpdateText.newBuildDidNotStart,
                       "새 버전이 뜨지 않았어요 - 예전 앱으로 되돌렸다면 [다시 시도] 를 누르세요")
        let stored = UpdateMarker.decode(UpdateMarker.encode(UpdateText.newBuildDidNotStart))
        XCTAssertEqual(stored, UpdateText.newBuildDidNotStart)
        XCTAssertEqual(UpdateMarker.fileName("1.2.0"), "failed-1.2.0.txt")

        // 되돌린 예전 앱 (1.1.8): 1.2.0 이 승인돼 있어도 받지 않고 실패를 보인다
        let json = body("[" + row("1.2.0") + "]")
        let old = UpdateLogic.scan(json, enterprise: true, approved: ["1.2.0"], current: SemVer(1, 1, 8), macOS: os13)
        XCTAssertEqual(old.best?.version, "1.2.0")
        let out = UpdateLogic.outcome(old, failedWhy: stored, enterprise: true, manual: false, running: "1.1.8")
        XCTAssertEqual(out.phase, .failed)
        XCTAssertTrue(out.fromMarker)
        XCTAssertFalse(out.downloadNow)
        XCTAssertEqual(out.msg, "지난번 적용 실패: 새 버전이 뜨지 않았어요 - 예전 앱으로 되돌렸다면 [다시 시도] 를 누르세요")

        // 잘 뜬 새 빌드 (1.2.0): 자기 버전의 행은 후보가 아니다 - 지우기 전의 기록이 이 빌드를 막을 일은 없다
        let fresh = UpdateLogic.scan(json, enterprise: true, approved: ["1.2.0"], current: SemVer(1, 2, 0), macOS: os13)
        XCTAssertNil(fresh.best)
        XCTAssertNil(fresh.newest)
        // 디렉터리 청소는 기록을 지우지 않는다 (지금 버전의 기록은 cleanupAfterStart 가 따로 지운다)
        XCTAssertFalse(UpdateLogic.cleanupTarget("failed-1.2.0.txt", running: SemVer(1, 2, 0)))
    }

    // MARK: - 정리

    func testCleanupTargets() {
        let run = SemVer(1, 2, 0)
        XCTAssertTrue(UpdateLogic.cleanupTarget("updater", running: run))
        XCTAssertTrue(UpdateLogic.cleanupTarget("updater-4242", running: run))
        XCTAssertTrue(UpdateLogic.cleanupTarget("SmartScreen-1.3.0.zip.part", running: run))
        XCTAssertTrue(UpdateLogic.cleanupTarget("SmartScreen-1.2.0.zip", running: run))
        XCTAssertTrue(UpdateLogic.cleanupTarget("SmartScreen-1.1.9.zip", running: run))
        XCTAssertFalse(UpdateLogic.cleanupTarget("SmartScreen-1.3.0.zip", running: run))   // 적용 중일 수 있다
        XCTAssertTrue(UpdateLogic.cleanupTarget("SmartScreen-junk.zip", running: run))
        XCTAssertTrue(UpdateLogic.cleanupTarget("staged-1.2.0", running: run))
        XCTAssertFalse(UpdateLogic.cleanupTarget("staged-1.10.0", running: run))
        XCTAssertTrue(UpdateLogic.cleanupTarget("staged-", running: run))
        XCTAssertFalse(UpdateLogic.cleanupTarget("failed-1.3.0.txt", running: run))       // 기록은 둔다
        XCTAssertFalse(UpdateLogic.cleanupTarget("failed-1.1.0.txt", running: run))
        XCTAssertFalse(UpdateLogic.cleanupTarget(".DS_Store", running: run))
    }

    func testBakRemoval() {
        let run = SemVer(1, 2, 0)
        XCTAssertTrue(UpdateLogic.shouldRemoveBak(bakVersion: "1.1.7", running: run))
        XCTAssertTrue(UpdateLogic.shouldRemoveBak(bakVersion: "1.2.0", running: run))
        XCTAssertTrue(UpdateLogic.shouldRemoveBak(bakVersion: nil, running: run))
        XCTAssertTrue(UpdateLogic.shouldRemoveBak(bakVersion: "garbage", running: run))
        XCTAssertFalse(UpdateLogic.shouldRemoveBak(bakVersion: "1.3.0", running: run))
    }

    func testBundleChecks() {
        XCTAssertTrue(UpdateLogic.isAppBundleName("SmartScreen.app"))
        XCTAssertTrue(UpdateLogic.isAppBundleName("smartscreen.APP"))
        XCTAssertFalse(UpdateLogic.isAppBundleName("SmartScreen 2.app"))
        XCTAssertFalse(UpdateLogic.isAppBundleName("SmartScreen"))
        XCTAssertTrue(UpdateLogic.isTranslocated("/private/var/folders/x/T/AppTranslocation/ABC/d/SmartScreen.app"))
        XCTAssertFalse(UpdateLogic.isTranslocated("/Applications/SmartScreen.app"))
        XCTAssertEqual(UpdateLogic.zipName("1.2.0"), "SmartScreen-1.2.0.zip")
        XCTAssertEqual(UpdateLogic.stagedDirName("1.2.0"), "staged-1.2.0")
        XCTAssertEqual(UpdateLogic.bundleId, "com.icesgg.smartscreen")
    }

    // MARK: - --apply-update 인자

    func testApplyArgsRoundTrip() {
        let built = ApplyArgs.arguments(pid: 4242, src: "/u/staged-1.2.0/SmartScreen.app",
                                        dst: "/Applications/SmartScreen.app", sha: sha1, ver: "1.2.0")
        XCTAssertEqual(built, ["--apply-update", "4242", "/u/staged-1.2.0/SmartScreen.app",
                               "/Applications/SmartScreen.app", "--sha", sha1, "--ver", "1.2.0"])
        // 명령줄 전체로도, 뒤쪽만으로도
        for args in [["/u/updater"] + built, Array(built.dropFirst())] {
            guard let a = ApplyArgs.parse(args) else { return XCTFail("parse failed") }
            XCTAssertEqual(a.pid, 4242)
            XCTAssertEqual(a.src, "/u/staged-1.2.0/SmartScreen.app")
            XCTAssertEqual(a.dst, "/Applications/SmartScreen.app")
            XCTAssertEqual(a.sha, sha1)
            XCTAssertEqual(a.ver, "1.2.0")
            XCTAssertTrue(a.relaunch)
        }
    }

    func testApplyArgsEdges() {
        XCTAssertNil(ApplyArgs.parse(["x", "--apply-update", "1", "src"]))           // 인자 부족
        XCTAssertNil(ApplyArgs.parse(["--apply-update", "-5", "s", "d"]))            // 음수 pid = 프로세스 그룹
        XCTAssertNil(ApplyArgs.parse(["--apply-update", "abc", "s", "d"]))
        guard let a = ApplyArgs.parse(["--apply-update", "0", "s", "d", "--no-relaunch", "--sha",
                                       String(repeating: "AB", count: 32), "--unknown", "--ver"]) else {
            return XCTFail("parse failed")
        }
        XCTAssertEqual(a.pid, 0)
        XCTAssertFalse(a.relaunch)
        XCTAssertEqual(a.sha, String(repeating: "ab", count: 32))
        XCTAssertEqual(a.ver, "")                     // 값 없는 --ver 는 무시
    }

    // MARK: - 해시와 글

    func testHasherMatchesKnownVectors() {
        var h = UpdateHasher()
        h.update(Data("ab".utf8))
        h.update(Data("c".utf8))
        XCTAssertEqual(h.finish(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(UpdateHasher().finish(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testTextsMatchWindowsWording() {
        XCTAssertEqual(UpdateText.downloading("1.2.0"), "1.2.0 내려받는 중")
        XCTAssertEqual(UpdateText.sizeMismatch(got: 10, expect: 20), "크기가 달라요 (받음 10 / 서버 20)")
        XCTAssertEqual(UpdateText.cutOff(-1005), "내려받는 중 연결이 끊겼어요 (오류 -1005)")
        XCTAssertEqual(UpdateText.updaterCopyFailed(13), "updater 복사본을 만들지 못했어요 (오류 13)")
        XCTAssertEqual(UpdateText.updaterLaunchFailed(2), "updater 를 띄우지 못했어요 (오류 2)")
        XCTAssertEqual(UpdateText.moveOldFailed(16), "기존 파일을 옮기지 못했어요 (오류 16)")
        XCTAssertEqual(UpdateText.placeFailed(28), "새 파일을 놓지 못했어요 (오류 28)")
        XCTAssertEqual(UpdateText.needsNewerMacOS("14.0"), "이 macOS 에서는 새 버전을 쓸 수 없어요 (macOS 14.0 이상)")
        XCTAssertEqual(UpdateText.applyFailedPrefix + UpdateText.needsNewerMacOS("14.0"),
                       "적용 실패: 이 macOS 에서는 새 버전을 쓸 수 없어요 (macOS 14.0 이상)")
        XCTAssertEqual(UpdateText.applyFailedPrefix + UpdateText.wrongNameApp,
                       "적용 실패: 앱 이름이 SmartScreen.app 이 아니라 자동 업데이트를 못 해요 - 이름을 바꿔 주세요")
        XCTAssertEqual(UpdateText.rollbackFailedDialog(reason: "r", folder: "/Applications"),
                       "업데이트를 적용하지 못했고, 예전 파일을 되돌리지도 못했습니다.\n\nr\n\n이 폴더에서 SmartScreen.app 이 남아 있으면 지우고,\nSmartScreen.app.bak 의 이름을 SmartScreen.app 으로 바꿔 주세요:\n/Applications")
        XCTAssertEqual(UpdateText.relaunchOldFailedDialog(reason: "r", app: "/A/SmartScreen.app"),
                       "업데이트를 적용하지 못했고, 예전 버전도 다시 띄우지 못했습니다.\n\nr\n\n직접 실행해 주세요:\n/A/SmartScreen.app")
        XCTAssertEqual(UpdateText.relaunchNewFailedDialog(app: "/A/SmartScreen.app"),
                       "새 버전을 놓았는데 실행하지 못했습니다. 직접 실행해 주세요:\n/A/SmartScreen.app")
    }
}
