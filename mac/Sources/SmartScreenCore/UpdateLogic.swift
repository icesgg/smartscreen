import Foundation
import CryptoKit

// UpdateLogic.swift - 프로그램 자동 업데이트의 판단 부분 (Windows client/update.cpp 의 CheckJob,
// ErrText, ValidStoragePath, 실패 기록, --apply-update 인자, 상태 s_st/s_cand/s_dismissed*).
//
// 화면도 파일도 네트워크도 만지지 않는다. 앱 쪽(SmartScreen/Update/Updater.swift)이 서버에 묻고
// 파일을 다루며, 여기서는 "무엇을 받을지, 어느 단계로 갈지, 띠와 로그에 무엇을 적을지" 만 정한다.
// Mac 이 없는 곳에서도 `swift test` 로 Windows 와 같은 판정인지 볼 수 있게 하려는 것이다.
//
// 왜 있나 (update.h 머리말): 프로그램을 고치는 일은 잦은데, 고칠 때마다 PC 마다 zip 을 풀어
// 덮어쓰는 것은 손으로 하는 배포다. 사람이 하는 배포는 어느 PC 가 어느 버전인지 아무도 모르게
// 되는 것으로 끝난다. 그래서 새 버전은 서버에 올리고, 모든 PC 가 스스로 알아채서 받아 간다.
//
//  개인 PC  간단 창에 "새 버전이 있어요" 띠가 뜬다. [업데이트] 를 누르기 전에는 아무것도 안 바뀐다.
//  기업 PC  조직 관리자가 대시보드에서 승인한 버전만, 묻지 않고 받아서 다시 시작한다. 승인 안 된
//           새 버전은 보이기만 한다 ("관리자 승인을 기다려요") - 배포 시점은 관리자가 정한다.
//
// 믿는 것은 해시 하나다: 행(mac_releases)은 로그인 없이 읽히고 파일도 누구나 받을 수 있다. 어느
// 파일이 진짜인지는 행에 박힌 SHA-256 으로만 정한다. 행을 쓸 수 있는 사람은 release_admins 뿐이다.
//
// Mac 은 Windows 와 다른 표를 쓴다 (mac_releases / org_mac_release_approvals). 지금 나가 있는
// Windows 1.1.x 는 releases 의 켜진 행을 전부 SmartScreen.exe 로 받아 해시만 보고 실행하므로,
// 같은 표에 Mac zip 을 넣으면 Windows PC 들이 그 zip 을 자기 exe 자리에 놓는다 (docs/MAC.md).

/// 업데이트 단계 (Windows UpdatePhase). 숫자는 로그("keeping %d")에 찍히므로 같은 번호다.
public enum ReleasePhase: Int, Equatable {
    case idle = 0          // 아직 확인한 적 없음
    case checking = 1      // 서버에 물어보는 중
    case upToDate = 2      // 이 버전이 가장 새 것
    case pending = 3       // (기업) 새 버전이 있지만 관리자가 아직 승인하지 않음
    case available = 4     // 받을 수 있는 새 버전이 있음. 개인 PC 는 여기서 사용자를 기다린다
    case downloading = 5
    case ready = 6         // 내려받고 해시까지 맞음 (Mac: 풀어서 앱도 확인함). 다시 시작만 남았다
    case applying = 7      // updater 를 띄웠고 이 프로세스는 곧 끝난다
    case failed = 8        // 확인·내려받기·적용 중 하나가 실패. msg 에 이유. [다시 시도] 로 재개
}

/// Windows UpdateStatus.
public struct ReleaseStatus: Equatable {
    public var phase: ReleasePhase = .idle
    public var version = ""            // 후보 버전. Pending/Available 이후에 채워진다
    public var notes = ""              // 배포 메모 (첫 줄만 화면에 보인다)
    public var msg = ""                // 사람이 읽는 마지막 결과. 실패하면 이유가 실린다
    public var progressPct = 0
    public var autoApply = false       // 기업 PC 에서 승인된 버전 = 묻지 않고 적용
    public var dismissed = false       // 이 상태에 [나중에] 를 눌렀다
    public var fromMarker = false      // Failed 가 실패 기록(failed-<버전>.txt)에서 왔다
    public var checkedTick: UInt64 = 0 // 마지막 확인이 끝난 Mono.now()
    public init() {}
}

/// 받을 후보 하나 (Windows Candidate).
public struct ReleaseCandidate: Equatable {
    public var version = ""
    public var storagePath = ""        // 'releases' 버킷 안의 경로
    public var notes = ""
    public var sha256 = ""             // 소문자 hex 64자
    public var size: UInt64 = 0
    public init() {}
    public init(version: String, storagePath: String, notes: String, sha256: String, size: UInt64) {
        self.version = version
        self.storagePath = storagePath
        self.notes = notes
        self.sha256 = sha256
        self.size = size
    }
}

/// 서버의 행들을 훑은 결과.
public struct ReleaseScan: Equatable {
    /// 받을 것 (기업 PC 는 승인된 것 중 가장 새 것)
    public var best: ReleaseCandidate?
    /// 있긴 한 가장 새 것 (승인과 상관없이)
    public var newest: ReleaseCandidate?
    /// 배열 안의 객체 수 (모양이 틀린 행, 지금 버전 이하인 행까지 센다 - Windows 와 같다)
    public var rows = 0
    /// 모양이 틀려 건너뛴 행의 version 값들 (차례대로). 부르는 쪽이
    /// "update: skipping malformed row (version '<v>')" 로 적는다.
    public var malformed: [String] = []
    public init() {}
}

/// 확인 한 번이 끝났을 때 갈 단계와 남길 말.
public struct CheckOutcome: Equatable {
    public let phase: ReleasePhase
    public let msg: String
    public let fromMarker: Bool
    /// events.log 에 그대로 적을 줄 (시각 없이)
    public let logLine: String
    /// 기업 PC 의 승인된 버전: 같은 일꾼에서 묻지 않고 바로 내려받는다
    public let downloadNow: Bool
}

/// 사용자에게 보이는 업데이트 글 (Windows update.cpp 의 문구 그대로). Windows 의 개념(SmartScreen.exe,
/// Program Files, releases 표)을 말하는 글만 Mac 에 맞게 가장 작게 바꿨다.
public enum UpdateText {
    // ---- 확인 ----
    public static let unreachable = "서버에 닿지 않아요"
    public static let unreachableApprovals = "서버에 닿지 않아요 (승인 목록)"
    public static let approvalsPrefix = "승인 목록: "
    /// Windows: "서버에 releases 표가 없어요 (supabase/releases.sql 을 아직 안 돌렸어요)". Mac 은 표가 따로다.
    /// 증상은 "업데이트 확인이 안 된다" 인데 원인은 SQL 을 안 돌린 것이라, 여기서 말해 주지 않으면
    /// 클라이언트 코드를 의심하게 된다.
    public static let missingTable = "서버에 mac_releases 표가 없어요 (supabase/mac_releases.sql 을 아직 안 돌렸어요)"
    public static let waitingApproval = "관리자 승인을 기다려요"
    /// 다시 켠 뒤 기록(failed-<버전>.txt)을 읽었을 때
    public static let lastApplyFailedPrefix = "지난번 적용 실패: "
    /// 지금 난 실패지만 기록으로 남기는 것 (FailMarked)
    public static let applyFailedPrefix = "적용 실패: "

    // ---- 내려받기 ----
    public static let noVersion = "받을 버전이 정해지지 않았어요"
    public static let badRowHash = "서버 행의 해시가 이상해요"
    public static func downloading(_ ver: String) -> String { return "\(ver) 내려받는 중" }
    public static let ready = "준비됨"
    public static let restarting = "다시 시작하는 중"
    public static let badAddress = "주소가 이상해요"
    public static let fileFailedPrefix = "파일을 받지 못했어요: "
    public static let cannotCreate = "파일을 만들지 못했어요"
    public static let aborted = "중단됐어요"
    public static let diskWrite = "디스크에 쓰지 못했어요"
    public static func cutOff(_ code: Int) -> String { return "내려받는 중 연결이 끊겼어요 (오류 \(code))" }
    public static let renameFailed = "파일 이름을 바꾸지 못했어요"
    public static func sizeMismatch(got: UInt64, expect: UInt64) -> String {
        return "크기가 달라요 (받음 \(got) / 서버 \(expect))"
    }
    public static let hashMismatchServer = "내려받은 파일의 해시가 서버 기록과 달라요"

    // ---- 적용 (앱 쪽) ----
    public static let nothingReady = "준비된 업데이트가 없어요"
    /// Windows: "실행 파일 이름이 SmartScreen.exe 가 아니라 자동 업데이트를 못 해요 - 이름을 바꿔 주세요"
    public static let wrongNameApp = "앱 이름이 SmartScreen.app 이 아니라 자동 업데이트를 못 해요 - 이름을 바꿔 주세요"
    /// Mac 만: 다운로드 폴더에서 바로 연 앱은 macOS 가 읽기 전용의 임시 자리(App Translocation)에서 돌린다.
    public static let translocated = "다운로드한 자리에서 바로 실행 중이라 바꿀 수 없어요 - 응용 프로그램 폴더로 옮긴 뒤 다시 켜 주세요"
    /// Windows: "... 프로그램을 사용자 폴더로 옮기면 자동 업데이트가 돼요" (Program Files 자리)
    public static let noPermission = "이 폴더에는 쓸 권한이 없어요 - 프로그램을 응용 프로그램 폴더나 사용자 폴더로 옮기면 자동 업데이트가 돼요"
    public static func updaterCopyFailed(_ code: Int) -> String { return "updater 복사본을 만들지 못했어요 (오류 \(code))" }
    public static func updaterLaunchFailed(_ code: Int) -> String { return "updater 를 띄우지 못했어요 (오류 \(code))" }

    // ---- 적용 (복사본 쪽) - 실패 기록에 들어가는 이유 ----
    public static let cannotConfirmExit = "예전 프로그램이 끝났는지 확인하지 못했어요"
    public static let wouldNotExit = "예전 프로그램이 끝나지 않아 바꾸지 못했어요"
    public static let badSourcePlace = "내려받은 파일 위치가 이상해요"
    public static let wrongNameApplier = "앱 이름이 SmartScreen.app 이 아니라 자동 업데이트를 못 해요"
    public static let noExpectedHash = "기대하는 해시가 없어요"
    public static let cannotReadDownload = "내려받은 파일을 읽지 못했어요"
    public static let hashMismatchRecord = "내려받은 파일의 해시가 기록과 달라요"
    public static let unzipFailed = "내려받은 파일을 풀지 못했어요"
    public static let noAppInZip = "내려받은 파일 안에 SmartScreen.app 이 없어요"
    public static let appMismatch = "내려받은 앱이 기록과 달라요 (버전 또는 번들 id)"
    /// macOS 13+ 의 "앱 관리" 보호가 다른 앱이 고치는 것을 막을 때 (EPERM)
    public static let appManagement = "시스템 설정 > 개인정보 보호 및 보안 > 앱 관리 에서 SmartScreen 을 허용해 주세요"
    public static func moveOldFailed(_ code: Int) -> String { return "기존 파일을 옮기지 못했어요 (오류 \(code))" }
    public static let placedButDiffers = "새 파일을 놓았는데 내용이 달라요"
    public static func placeFailed(_ code: Int) -> String { return "새 파일을 놓지 못했어요 (오류 \(code))" }

    // ---- 복사본의 대화상자 (아무것도 다시 띄울 수 없을 때만) ----
    public static let dialogTitle = "SmartScreen 업데이트"
    public static func rollbackFailedDialog(reason: String, folder: String) -> String {
        return "업데이트를 적용하지 못했고, 예전 파일을 되돌리지도 못했습니다.\n\n" + reason +
            "\n\n이 폴더에서 SmartScreen.app 이 남아 있으면 지우고,\n" +
            "SmartScreen.app.bak 의 이름을 SmartScreen.app 으로 바꿔 주세요:\n" + folder
    }
    public static func relaunchOldFailedDialog(reason: String, app: String) -> String {
        return "업데이트를 적용하지 못했고, 예전 버전도 다시 띄우지 못했습니다.\n\n" + reason +
            "\n\n직접 실행해 주세요:\n" + app
    }
    public static func relaunchNewFailedDialog(app: String) -> String {
        return "새 버전을 놓았는데 실행하지 못했습니다. 직접 실행해 주세요:\n" + app
    }
}

public enum UpdateLogic {
    // ---- 서버 ----
    public static let releasesTable = "mac_releases"
    public static let approvalsTable = "org_mac_release_approvals"
    /// 한 시간마다 묻는다. "요청은 작은 GET 이고, 새 버전이 한 시간 늦게 닿아도 아무도 곤란하지 않다."
    public static let checkEveryMs: UInt64 = 3_600_000
    /// 머리 단추가 "최신 버전이에요" 를 보여 주는 시간
    public static let upToDateFlashMs: UInt64 = 6000

    // ---- 묶음 ----
    public static let bundleId = "com.icesgg.smartscreen"
    public static let appBundleName = "SmartScreen.app"
    public static let executableName = "SmartScreen"
    public static let updaterName = "updater"

    /// config.ini 의 updateChannel: 정확히 "beta" 만 beta, 나머지는 stable.
    /// "오타 하나로 업데이트가 조용히 멎으면 안 된다." (URL 에 들어가는 값이라 다른 글자는 받지 않는다)
    public static func normalizeChannel(_ s: String) -> String {
        return s == "beta" ? "beta" : "stable"
    }

    /// 확인 질의 (Windows 의 releases 질의와 같은 모양, 표 이름만 다르다).
    public static func releasesQuery(channel: String) -> String {
        return "/rest/v1/\(releasesTable)?select=version,storage_path,sha256,size,notes" +
            "&active=eq.true&channel=eq.\(normalizeChannel(channel))&order=published_at.desc"
    }

    /// 승인 목록 질의 (기업 PC 만). 조직 id 는 소문자 정규형으로 넣는다 (등록이 그렇게 저장한다).
    /// 모양이 틀린 값은 그대로 두되 URL 을 벗어나지 못하게 인코딩만 한다 - 서버가 오류로 답하고,
    /// 그 오류가 "승인 목록: ..." 으로 보인다 (Windows 와 같은 결과).
    public static func approvalsQuery(org: String) -> String {
        let o = OrgId.normalize(org) ?? URLEnc.encode(org)
        return "/rest/v1/\(approvalsTable)?select=version&org_id=eq.\(o)"
    }

    /// 버킷 안 파일의 주소 (url 뒤에 붙인다). anon 키로 되는 "authenticated" 끝점이다 - 버킷에
    /// anon select 정책이 있다.
    public static func downloadPath(storagePath: String) -> String {
        return "/storage/v1/object/authenticated/releases/" + storagePath
    }

    /// 버킷 안의 경로로만 쓴다. 행을 쓸 수 있는 사람은 관리자뿐이지만, 그래도 URL 을 벗어나는
    /// 값은 받지 않는다 - 서버 쪽 실수 하나가 이상한 곳을 읽게 만들 이유가 없다.
    public static func validStoragePath(_ p: String) -> Bool {
        let u = Array(p.utf16)
        if u.isEmpty || u.count > 200 { return false }
        if u[0] == 0x2F { return false }                       // '/'
        var prevDot = false
        for c in u {
            let isDot = c == 0x2E
            if isDot && prevDot { return false }               // ".."
            prevDot = isDot
            let ok = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) ||
                c == 0x2E || c == 0x5F || c == 0x2D || c == 0x2F
            if !ok { return false }
        }
        return true
    }

    /// 실패 이유를 사람이 읽는 한 줄로 (Windows ErrText). 표가 아직 없는 경우를 따로 알려 준다.
    /// rest = REST 질의의 답이다 (표가 없으면 PostgREST 가 404 로 답한다). 저장소 내려받기의 404 는
    /// "그런 파일 없음" 이라 표 이야기를 하면 안 된다.
    /// 그 밖에는 message, msg, error_description, error 중 처음으로 비어 있지 않은 글자. 없으면 "HTTP <n>".
    public static func errText(_ body: Data, status: Int, rest: Bool) -> String {
        let s = String(decoding: body, as: UTF8.self)
        if s.contains("PGRST205") || s.contains("42P01") || (rest && status == 404) {
            return UpdateText.missingTable
        }
        if let obj = (try? JSONSerialization.jsonObject(with: body, options: [])) as? [String: Any] {
            for k in ["message", "msg", "error_description", "error"] {
                if let v = obj[k] as? String, !v.isEmpty {
                    // 서버 글은 띠와 로그 한 줄에 들어간다. 줄바꿈과 지나친 길이는 여기서 자른다.
                    return TextSanitize.capErrorText(v)
                }
            }
        }
        return "HTTP \(status)"
    }

    /// 승인 목록의 version 들 (문자열인 것만, 글자 그대로 비교한다 - Windows 와 같다).
    public static func approvedVersions(_ body: Data) -> Set<String> {
        var out = Set<String>()
        for o in objects(body) {
            if let v = o["version"] as? String { out.insert(v) }
        }
        return out
    }

    /// CheckJob 의 행 고르기. 서버 순서(published_at desc)와 상관없이 버전 숫자로 고른다.
    /// enterprise 면 approved 에 있는 버전만 best 가 된다.
    public static func scan(_ body: Data, enterprise: Bool, approved: Set<String>, current: SemVer) -> ReleaseScan {
        var out = ReleaseScan()
        var bestV: SemVer?
        var newestV: SemVer?
        for o in objects(body) {
            out.rows += 1
            // 셋 중 하나라도 문자열이 아니면 조용히 건너뛴다 (Windows 와 같다)
            guard let v = o["version"] as? String,
                  let sp = o["storage_path"] as? String,
                  let shaRaw = o["sha256"] as? String else { continue }
            let notes = o["notes"] as? String ?? ""
            var size: UInt64 = 0
            if let n = o["size"] as? NSNumber {
                let i = n.int64Value
                size = i > 0 ? UInt64(i) : 0
            }
            let sha = asciiLower(shaRaw)
            guard let sv = SemVer(v), sha.utf8.count == 64, validStoragePath(sp) else {
                out.malformed.append(v)
                continue
            }
            if sv <= current { continue }                     // 내 버전 이하는 관심 없다
            let c = ReleaseCandidate(version: v, storagePath: sp, notes: notes, sha256: sha, size: size)
            if newestV.map({ sv > $0 }) ?? true {
                out.newest = c
                newestV = sv
            }
            if enterprise && !approved.contains(v) { continue }
            if bestV.map({ sv > $0 }) ?? true {
                out.best = c
                bestV = sv
            }
        }
        return out
    }

    /// 확인 결과로 갈 단계 (Windows CheckJob 의 끝). failedWhy = best 의 실패 기록 (없으면 nil).
    /// running = 이 빌드의 버전 글자 (로그용).
    public static func outcome(_ scan: ReleaseScan, failedWhy: String?, enterprise: Bool, manual: Bool,
                               running: String) -> CheckOutcome {
        let manualTag = manual ? " [manual]" : ""
        if let b = scan.best, let why = failedWhy {
            // 지난번에 이 버전을 적용하다 실패했다. [다시 시도] 나 더 새 버전이 나올 때까지 저절로
            // 다시 하지 않는다 - 기업 PC 가 같은 실패를 끝없이 되풀이하게 된다.
            return CheckOutcome(phase: .failed, msg: UpdateText.lastApplyFailedPrefix + why, fromMarker: true,
                                logLine: "update: \(b.version) available but a previous apply failed (\(why)) - waiting for [retry]",
                                downloadNow: false)
        }
        if let b = scan.best {
            let org = enterprise ? ", org-approved" : ""
            return CheckOutcome(phase: .available, msg: "", fromMarker: false,
                                logLine: "update: \(b.version) available (running \(running), \(scan.rows) row(s)\(org))\(manualTag)",
                                downloadNow: enterprise)          // 승인됐으면 묻지 않는다
        }
        if let n = scan.newest, enterprise {
            return CheckOutcome(phase: .pending, msg: UpdateText.waitingApproval, fromMarker: false,
                                logLine: "update: \(n.version) exists but not approved for org (running \(running))",
                                downloadNow: false)
        }
        return CheckOutcome(phase: .upToDate, msg: "", fromMarker: false,
                            logLine: "update: up to date (\(running), \(scan.rows) row(s))\(manualTag)",
                            downloadNow: false)
    }

    /// 진행률을 알릴지 (Windows StreamToFile): 크기를 알 때만, 100 으로 막고, 4 이상 움직였거나
    /// 100 이 됐을 때만. lastPct 는 -1 에서 시작한다. 알릴 값을 돌려준다 (안 알리면 nil).
    public static func progress(got: UInt64, expect: UInt64, lastPct: Int) -> Int? {
        if expect == 0 { return nil }
        var pct = 100
        if got < expect {
            // C 처럼 정수로 나눈다 (부동소수점은 29/100 을 28 로 만든다). got*100 이 넘칠 만큼 크면
            // expect 는 그보다 더 크므로 expect/100 은 0 이 아니다.
            let m = got.multipliedReportingOverflow(by: 100)
            let q: UInt64 = m.overflow ? got / (expect / 100) : m.partialValue / expect
            pct = q > 100 ? 100 : Int(q)
        }
        if pct != lastPct && (pct - lastPct >= 4 || pct == 100) { return pct }
        return nil
    }

    // ---- update 폴더 안의 이름들 ----

    /// 내려받은 파일 (해시를 잰 그 파일)
    public static func zipName(_ ver: String) -> String { return "SmartScreen-\(ver).zip" }
    /// 받은 zip 을 푼 곳 (안에 SmartScreen.app)
    public static func stagedDirName(_ ver: String) -> String { return "staged-\(ver)" }

    /// 앱이 켜질 때 update 폴더에서 지울 것인가 (Windows UpdateCleanupAfterStart).
    /// 내려받는 중이던 *.part 와 updater 복사본은 언제나 지운다 (돌고 있는 복사본이 있어도 지우는
    /// 것은 된다). 받은 zip 과 푼 묶음은 지금 버전 이하일 때만 - 더 새 버전의 것은 예전 앱이
    /// 적용 도중에 다시 켜졌을 때 그 적용이 쓰는 중일 수 있다. failed-*.txt 는 두어야 한다: 실패한
    /// 뒤 다시 뜬 예전 앱이 그걸 봐야 한다.
    public static func cleanupTarget(_ name: String, running: SemVer) -> Bool {
        if name.hasSuffix(".part") { return true }
        if name.hasPrefix(updaterName) { return true }
        if name.hasPrefix("SmartScreen-") && name.hasSuffix(".zip") {
            let v = String(name.dropFirst("SmartScreen-".count).dropLast(".zip".count))
            guard let sv = SemVer(v) else { return true }
            return sv <= running
        }
        if name.hasPrefix("staged-") {
            let v = String(name.dropFirst("staged-".count))
            guard let sv = SemVer(v) else { return true }
            return sv <= running
        }
        return false
    }

    /// <앱>.bak 을 지울 것인가. 새 빌드가 무사히 떴으면 이전 것은 필요 없다. 다만 .bak 이 지금
    /// 것보다 새 버전이면 (사람이 손으로 되돌린 경우) 남겨 둔다. 버전을 못 읽으면 지운다.
    public static func shouldRemoveBak(bakVersion: String?, running: SemVer) -> Bool {
        guard let s = bakVersion, let v = SemVer(s) else { return true }
        return v <= running
    }

    /// 묶음 이름 검사 (Windows: 파일 이름이 smartscreen.exe). 대소문자는 가리지 않는다.
    public static func isAppBundleName(_ lastPathComponent: String) -> Bool {
        return lastPathComponent.lowercased() == "smartscreen.app"
    }

    /// 다운로드 폴더에서 바로 연 앱은 macOS 가 읽기 전용의 임의 경로에서 돌린다.
    public static func isTranslocated(_ path: String) -> Bool {
        return path.contains("/AppTranslocation/")
    }

    // ---- private ----

    /// 최상위 JSON 배열 안의 객체들. 배열이 아니면 빈 목록.
    private static func objects(_ body: Data) -> [[String: Any]] {
        guard let arr = (try? JSONSerialization.jsonObject(with: body, options: [])) as? [Any] else { return [] }
        var out: [[String: Any]] = []
        for el in arr {
            if let o = el as? [String: Any] { out.append(o) }
        }
        return out
    }

    /// Windows tolower 를 바이트마다 한 것과 같게 ASCII 만 소문자로 (다른 글자는 길이째 그대로).
    private static func asciiLower(_ s: String) -> String {
        var b = Array(s.utf8)
        for i in 0..<b.count where b[i] >= 0x41 && b[i] <= 0x5A {
            b[i] += 0x20
        }
        return String(decoding: b, as: UTF8.self)
    }
}

/// Windows update.cpp 의 s_st / s_cand / s_downloaded / s_dismissedVer / s_dismissedNow 와 그 위의
/// 동작. 잠금은 없다 - 앱 쪽이 NSLock 하나 안에서 부른다 (Windows s_mx).
public struct ReleaseMachine {
    public private(set) var st = ReleaseStatus()
    public private(set) var cand = ReleaseCandidate()
    /// 해시까지 확인한 파일의 경로 (없으면 "")
    public var downloaded = ""
    /// [나중에] 를 누른 후보 버전
    public private(set) var dismissedVer = ""
    /// 후보 없는 상태(오프라인 실패)에서 [나중에]
    public private(set) var dismissedNow = false

    public init() {}

    /// UpdateInit: Windows 처럼 상태만 처음으로 되돌린다.
    public mutating func resetStatus() {
        st = ReleaseStatus()
    }

    /// SetPhase. 단계, 글, fromMarker 를 같이 바꾼다 - 따로 바꾸면 그 사이에 UI 가 읽어 접두어가
    /// 두 번 붙거나 창이 안 뜬다. fromMarker nil = 그대로. 내려받는 중이 아니면 진행률은 0.
    public mutating func setPhase(_ p: ReleasePhase, msg: String = "", fromMarker: Bool? = nil) {
        st.phase = p
        st.msg = msg
        if let fm = fromMarker { st.fromMarker = fm }
        if p != .downloading { st.progressPct = 0 }
    }

    public mutating func setProgress(_ pct: Int) {
        st.progressPct = pct
    }

    /// 이미 받아 둔 것이 있으면 다시 묻지 않는다 - 곧 적용될 것이다.
    public var holdsDownload: Bool {
        return st.phase == .downloading || st.phase == .ready || st.phase == .applying
    }

    /// CheckJob 머리. prev = 배경 확인이 실패했을 때 되돌아갈 단계, enterChecking = Checking 으로
    /// 바꿔야 하는가 (부르는 쪽이 setPhase(.checking) 한다).
    ///
    /// 한 시간마다 도는 확인은 보이는 띠(Available/Pending/Failed)를 그대로 둔 채 묻는다. Checking
    /// 으로 바꾸면 띠가 사라지고 창이 줄었다 다시 자란다 - 매시간 깜빡이게 된다. 손으로 누른 것은
    /// 반응이 보여야 하므로 언제나 Checking 을 거친다.
    public mutating func beginCheck(manual: Bool) -> (prev: ReleasePhase, enterChecking: Bool) {
        var prev = st.phase
        dismissedNow = false              // 새 결과가 나오면 "이번만 감추기" 는 끝난다
        if manual {
            // 손으로 눌렀다 = 결과를 보여 달라는 것. 전에 [나중에] 를 눌렀어도 이번 결과는 보인다.
            st.dismissed = false
            dismissedVer = ""
        }
        let enter = manual || prev == .idle || prev == .upToDate
        if prev == .checking { prev = .idle }
        return (prev, enter)
    }

    /// CheckFailed 의 배경 확인 쪽: 아직 Checking 이면 전 단계로. checkedTick 은 그대로 둔다 -
    /// 갱신하면 머리 단추가 "최신 버전이에요" 를 6초 보여 준다. fromMarker 도 그대로 - 기록에서 온
    /// 실패가 평범한 실패로 바뀐 적이 있다.
    public mutating func keepAfterBackgroundFailure(prev: ReleasePhase) {
        if st.phase == .checking { st.phase = prev }
    }

    /// 확인이 끝났을 때 후보와 보이는 버전을 정한다 (단계는 부르는 쪽이 outcome 으로 바꾼다).
    public mutating func adopt(_ scan: ReleaseScan, enterprise: Bool, now: UInt64) {
        st.checkedTick = now
        st.autoApply = enterprise
        if let b = scan.best {
            if cand.version != b.version { downloaded = "" }   // 다른 버전의 파일은 쓸모없다
            cand = b
            st.version = b.version
            st.notes = b.notes
            st.dismissed = (dismissedVer == b.version)
        } else if let n = scan.newest {
            cand = ReleaseCandidate()
            downloaded = ""
            st.version = n.version
            st.notes = n.notes
            st.dismissed = (dismissedVer == n.version)
        } else {
            cand = ReleaseCandidate()
            downloaded = ""
            st.version = ""
            st.notes = ""
            st.dismissed = false
        }
    }

    /// [나중에]. 후보 버전이 있으면 그 버전에 대해 계속 감추고, 없으면(오프라인 실패 같은 것)
    /// 다음 확인 결과가 나올 때까지만 감춘다.
    public mutating func dismiss() {
        st.dismissed = true
        if !st.version.isEmpty {
            dismissedVer = st.version
        } else {
            dismissedNow = true
        }
    }

    /// UpdateGetStatus
    public var status: ReleaseStatus {
        var s = st
        if dismissedNow { s.dismissed = true }
        return s
    }

    /// 받을 후보(버전·경로·해시)가 정해져 있나. [다시 시도] 가 "다시 묻기" 와 "다시 받기" 중
    /// 무엇을 할지 이걸로 가른다 - version 만 보면 틀린다 (Pending 은 version 은 있고 후보는 없다).
    public var hasCandidate: Bool { return !cand.version.isEmpty }

    /// UpdateDownloadAsync 의 조건: Available 또는 Failed 이고 후보가 있다.
    public var canStartDownload: Bool {
        return (st.phase == .available || st.phase == .failed) && !cand.version.isEmpty
    }

    /// 내려받기 일이 실제로 시작된 뒤: fromMarker 를 끄고, 그 사이 배경 확인이 바꿨을 수 있는
    /// 지금 후보의 버전을 돌려준다 (부르는 쪽이 그 버전의 실패 기록을 지운다).
    public mutating func downloadStarted() -> String {
        st.fromMarker = false
        return cand.version
    }

    /// 적용할 수 있는가 (Ready 이고 확인된 파일이 있다)
    public var readyToApply: Bool { return st.phase == .ready && !downloaded.isEmpty }

    /// updater 를 띄웠다 (Windows 도 여기서는 알리지 않는다 - 곧 끝난다)
    public mutating func markApplying() {
        st.phase = .applying
        st.msg = UpdateText.restarting
    }
}

/// 실패 기록 failed-<버전>.txt (update.h "실패는 기억해야 한다").
///
/// 적용에 실패하면 복사본은 예전 앱을 다시 띄운다. 그 앱이 아무것도 모르면 같은 버전을 다시 받아
/// 다시 적용하러 종료하고, 그게 끝없이 반복된다 - 기업 PC 는 묻지 않고 적용하므로 특히 그렇다.
/// 그래서 실패한 버전과 이유를 적어 두고, 다음 확인은 그 버전을 "실패함" 으로만 보여 준다.
public enum UpdateMarker {
    /// "failed-<ver>.txt". 버전 모양(a.b.c)이 아니면 nil - 파일 이름에 아무 글자나 넣지 않는다.
    public static func fileName(_ ver: String) -> String? {
        if SemVer(ver) == nil { return nil }
        return "failed-\(ver).txt"
    }

    /// 한 줄 = 이유, 그리고 줄바꿈. Windows("w, ccs=UTF-8")처럼 BOM 을 앞에 둔다.
    public static func encode(_ reason: String) -> Data {
        var d = Data([0xEF, 0xBB, 0xBF])
        d.append(contentsOf: Array((reason + "\n").utf8))
        return d
    }

    /// 첫 줄 (BOM 은 빼고, 최대 511 UTF-16 단위, 끝의 CR/LF 는 지운다). Windows fgetws(512) 와 같다.
    public static func decode(_ data: Data) -> String {
        var bytes = Array(data)
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        let text = String(decoding: bytes, as: UTF8.self)
        var first = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u == "\n" { break }
            first.append(u)
        }
        var scalars = Array(TextSanitize.capUTF16(String(first), 511).unicodeScalars)
        while let last = scalars.last, last == "\r" || last == "\n" {
            scalars.removeLast()
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }
}

/// `SmartScreen --apply-update <pid> <src> <dst> [--sha <hex>] [--ver <v>] [--no-relaunch]`.
/// Mac: src = update/staged-<ver>/SmartScreen.app, dst = 지금 돌고 있는 SmartScreen.app,
/// --sha = 받은 zip 의 SHA-256 (복사본이 바꾸기 직전에 한 번 더 잰다).
public struct ApplyArgs: Equatable {
    public static let flag = "--apply-update"
    public var pid: Int32 = 0            // 0 = 기다리지 않는다 (시험용)
    public var src = ""
    public var dst = ""
    public var sha = ""                  // 소문자로
    public var ver = ""
    public var relaunch = true           // --no-relaunch = 끝나고 아무것도 띄우지 않는다 (시험용)
    public init() {}

    /// 명령줄 전체(CommandLine.arguments)나 "--apply-update" 뒤의 부분 어느 쪽이든 받는다.
    /// pid, src, dst 가 없으면 nil (Windows 의 종료 코드 2). 모르는 인자는 무시한다.
    /// pid 가 음수거나 숫자가 아니면 nil - kill(음수) 는 프로세스 그룹 전체를 가리킨다.
    public static func parse(_ args: [String]) -> ApplyArgs? {
        var rest = args
        if let i = args.firstIndex(of: flag) {
            rest = Array(args[(i + 1)...])
        }
        if rest.count < 3 { return nil }
        guard let pid = Int32(rest[0]), pid >= 0 else { return nil }
        var a = ApplyArgs()
        a.pid = pid
        a.src = rest[1]
        a.dst = rest[2]
        var i = 3
        while i < rest.count {
            let s = rest[i]
            if s == "--no-relaunch" {
                a.relaunch = false
            } else if s == "--sha" && i + 1 < rest.count {
                i += 1
                var b = Array(rest[i].utf8)
                for k in 0..<b.count where b[k] >= 0x41 && b[k] <= 0x5A { b[k] += 0x20 }
                a.sha = String(decoding: b, as: UTF8.self)
            } else if s == "--ver" && i + 1 < rest.count {
                i += 1
                a.ver = rest[i]
            }
            i += 1
        }
        return a
    }

    /// 앱이 복사본을 띄울 때 넘기는 인자 (실행 파일 경로는 빼고).
    public static func arguments(pid: Int32, src: String, dst: String, sha: String, ver: String) -> [String] {
        return [flag, "\(pid)", src, dst, "--sha", sha, "--ver", ver]
    }
}

/// 내려받으면서 SHA-256 을 같이 잰다 (Windows Sha256Stream). 흘려 재는 편이 한 번 덜 읽는다.
public struct UpdateHasher {
    private var h = SHA256()
    public init() {}
    public mutating func update(_ d: Data) {
        h.update(data: d)
    }
    /// 소문자 hex 64자
    public func finish() -> String {
        return Hex.lower(Data(h.finalize()))
    }
}
