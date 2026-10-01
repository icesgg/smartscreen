import Foundation

// 기업용 콘텐츠의 모양 검사 (client/enterprise/supabase.cpp, client/video/player.cpp).
//
// 기업 PC 는 로그인 없이 (anon key 로) 조직의 contents 행을 읽고, 그 행이 가리키는 파일을
// 받아 잠금 화면에 띄운다. 행을 쓸 수 있는 사람은 그 조직의 멤버 전부이므로 (관리자만이
// 아니다) 행의 글자는 믿는 값이 아니다. 그래서
//   - 행은 정해진 모양과 글자 그대로 맞을 때만 받고,
//   - 로컬 파일 이름은 검증된 조각으로만 만들고,
//   - 받은 파일은 크기와 SHA-256 이 행과 같을 때만 제자리에 놓는다 (Net/Enterprise.swift).
// 이 규칙은 서버의 제약(contents_storage_path_shape 등)과 대시보드와 Windows 판이 함께
// 쓰는 것이라 한쪽만 바꾸면 안 된다.
//
// 글자 위치 검사는 Windows 와 같게 UTF-16 단위로 센다.

/// 조직 id 정규화 (Windows NormalizeOrgId).
public enum OrgId {
    /// 앞뒤의 ' ' '\t' '\r' '\n' 만 지우고, 정확히 36자, 8/13/18/23 자리는 '-', 나머지는
    /// 16진수 (A-F 는 소문자로). 소문자 정규형을 돌려준다. URL 에 들어가는 조직 id 는 모두
    /// 이걸 먼저 지난다. 사람들이 API 주소를 잘못 붙여 넣는 일이 있어 모양을 엄격히 본다.
    public static func normalize(_ s: String) -> String? {
        let u = Array(s.utf16)
        var b = 0
        var e = u.count
        while b < e && EnterpriseShape.isTrimSpace(u[b]) { b += 1 }
        while e > b && EnterpriseShape.isTrimSpace(u[e - 1]) { e -= 1 }
        if e - b != 36 { return nil }

        var out: [UInt16] = []
        out.reserveCapacity(36)
        for k in 0..<36 {
            var c = u[b + k]
            if k == 8 || k == 13 || k == 18 || k == 23 {
                if c != 0x2D { return nil }                  // '-' 만 (긴 대시 등은 거절)
            } else if c >= 0x41 && c <= 0x46 {               // 'A'...'F'
                c = c + 0x20
            } else if !EnterpriseShape.isLowerHex(c) {
                return nil
            }
            out.append(c)
        }
        return String(decoding: out, as: UTF16.self)
    }
}

public struct StoragePathParts: Equatable {
    public let org: String
    public let hash: String
    public let ext: String
}

/// "<org uuid>/<sha256>.<ext>" 를 세 조각으로 (Windows SplitStoragePath).
public enum StoragePath {
    /// 글자 그대로 그 모양일 때만 값을 돌려준다.
    /// 36(uuid) + 1('/') + 64(hash) + 1('.') = 102, 그 뒤가 확장자다 ([a-z0-9]{1,8}, 그래서 길이
    /// 103...110). 비교가 전부 "이 자리에 이 글자" 라서 "..", 역슬래시, '?', '#', 공백이 들어갈
    /// 자리가 없다. uuid 는 이미 소문자 정규형이어야 하고, hash 는 소문자 16진수 64자다.
    /// (확장자 허용 목록과 content_type 과의 짝은 서버가 지킨다. 클라이언트는 보지 않는다.)
    public static func split(_ p: String) -> StoragePathParts? {
        let u = Array(p.utf16)
        if u.count < 103 || u.count > 110 { return nil }
        if u[36] != 0x2F || u[101] != 0x2E { return nil }   // '/' , '.'

        let rawOrg = String(decoding: u[0..<36], as: UTF16.self)
        guard let org = OrgId.normalize(rawOrg),
              EnterpriseShape.same(org, rawOrg) else { return nil }   // 소문자 정규형만

        let hashU = u[37..<101]
        let extU = u[102...]
        if !hashU.allSatisfy({ EnterpriseShape.isLowerHex($0) }) { return nil }
        if extU.isEmpty || extU.count > 8 { return nil }
        if !extU.allSatisfy({ EnterpriseShape.isExtChar($0) }) { return nil }

        return StoragePathParts(org: org,
                                hash: String(decoding: hashU, as: UTF16.self),
                                ext: String(decoding: extU, as: UTF16.self))
    }
}

/// 잠금 화면에서 그림이 아니라 영상으로 다룰 파일인가 (Windows video/player.cpp IsVideoFile).
public enum MediaKind {
    public static let videoExtensions = [".mp4", ".avi", ".wmv", ".mkv", ".mov", ".webm"]

    /// 경로 전체에서 마지막 '.' 부터 끝까지를 (ASCII 만) 소문자로 바꿔 목록과 비교한다.
    /// 폴더 이름의 점도 센다: "/a.b/c" 는 ".b/c" 라서 영상이 아니다 - Windows 와 같다.
    /// avi/wmv/mkv/webm 은 AVFoundation 이 대개 못 틀지만 목록은 서버·대시보드와 같아야
    /// 하므로 그대로 둔다 (못 틀면 잠금 화면 쪽이 그림 표시로 물러난다).
    public static func isVideoFile(_ path: String) -> Bool {
        let u = Array(path.utf16)
        guard let dot = u.lastIndex(of: 0x2E) else { return false }
        let ext = u[dot...].map { c -> UInt16 in (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c }
        let s = String(decoding: ext, as: UTF16.self)
        return videoExtensions.contains { EnterpriseShape.same($0, s) }
    }
}

/// 검증을 통과한 contents 행 하나 (Windows ContentItem).
public struct ContentRow: Equatable {
    public let id: String
    public let storagePath: String
    public let hash: String
    public let ext: String
    public let size: Int64
    public let contentType: String
    public let position: String

    /// 로컬 파일 이름은 검증된 조각으로 만든다 - storage_path 를 잘라 쓰지 않는다.
    /// (≤1.1.4 는 마지막 '/' 뒤를 그대로 이름으로 써서 ..\..\ 로 폴더 밖에 쓸 수 있었다.)
    public var localName: String { hash + "." + ext }
}

/// contents 목록 응답의 검증 (Windows FetchManifest 의 본문 처리 + ParseContentRow).
public enum ContentManifest {
    /// 서버의 contents_file_size_range 제약, 'content' 버킷의 file_size_limit 과 같은 값 (200 MiB).
    private static let maxContentBytes: Int64 = 200 * 1024 * 1024

    /// 2xx 본문을 검증한다. nil = JSON 배열이 아니다 (부르는 쪽이
    /// "enterprise: contents answer is not a JSON array" 를 남긴다). 2xx 인데 배열이 아니면
    /// PostgREST 의 답이 아니므로 "행이 없다" 로 읽지 않는다.
    ///
    /// 행마다 아래 순서로 보고, 처음 걸린 이유로 그 행을 건너뛰며
    /// "enterprise: row skipped - <이유> (id <OneLine(id)>)" 를 log 로 넘긴다.
    /// 순서(= 서버가 준 created_at desc)는 그대로 둔다.
    ///
    /// 배열은 JSONSerialization 으로 읽는다. Windows 는 손으로 최상위 객체를 잘랐고, 예전에는
    /// '{' 다음 첫 '}' 에서 잘라 이름에 '}' 가 든 파일(promo}.png) 하나가 그 행을 통째로
    /// 잃게 했다 - 진짜 파서는 문자열 안의 중괄호에 흔들리지 않는다.
    public static func validate(_ body: Data, org: String, log: (String) -> Void) -> [ContentRow]? {
        // 첫 글자(공백 " \t\r\n" 다음)가 '[' 이어야 한다 - Windows 와 같은 판정.
        guard let first = body.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D && $0 != 0x0A }),
              first == 0x5B else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: body, options: []),
              let array = parsed as? [Any] else { return nil }

        // 부르는 쪽은 정규화한 조직 id 를 넘기지만, 아니어도 같은 답이 나오게 한 번 더 한다.
        let orgN = OrgId.normalize(org) ?? org

        // Windows SplitObjects 는 배열 안의 최상위 객체를 깊이와 상관없이 순서대로 모으고
        // 객체가 아닌 원소는 말없이 지나친다. 같게 한다.
        var objects: [[String: Any]] = []
        collectObjects(array, into: &objects)

        var rows: [ContentRow] = []
        for obj in objects {
            switch parseRow(obj, org: orgN) {
            case .ok(let row):
                rows.append(row)
            case .skip(let why, let id):
                log("enterprise: row skipped - \(why) (id \(TextSanitize.oneLine(id)))")
            }
        }
        return rows
    }

    private enum RowOutcome {
        case ok(ContentRow)
        case skip(String, String)   // (why, raw id)
    }

    private static func collectObjects(_ arr: [Any], into out: inout [[String: Any]]) {
        for el in arr {
            if let d = el as? [String: Any] {
                out.append(d)
            } else if let a = el as? [Any] {
                collectObjects(a, into: &out)
            }
        }
    }

    // 행 하나를 읽는다. 공유된 모양과 글자 그대로 맞을 때만 받는다. 이유 문구와 순서는
    // Windows 와 같다 (events.log 를 사람과 도구가 grep 한다).
    private static func parseRow(_ obj: [String: Any], org: String) -> RowOutcome {
        let id = obj["id"] as? String ?? ""

        guard let rowOrg = obj["org_id"] as? String, EnterpriseShape.same(rowOrg, org) else {
            return .skip("org_id is not this PC's org", id)
        }
        guard let sp = obj["storage_path"] as? String, let fileHash = obj["file_hash"] as? String else {
            return .skip("storage_path or file_hash missing", id)
        }
        // file_hash 와 정확히 같아야 하므로 file_hash 도 소문자여야 한다.
        guard let parts = StoragePath.split(sp),
              EnterpriseShape.same(parts.org, org),
              EnterpriseShape.same(parts.hash, fileHash) else {
            return .skip("storage_path is not <org_id>/<file_hash>.<ext>", id)
        }
        guard let size = fileSize(obj["file_size"]), size >= 1, size <= maxContentBytes else {
            return .skip("file_size out of range (1 .. 200 MB)", id)
        }
        guard let ctype = obj["content_type"] as? String,
              EnterpriseShape.same(ctype, "image") || EnterpriseShape.same(ctype, "video") else {
            return .skip("content_type is not image/video", id)
        }
        guard let pos = obj["display_position"] as? String,
              EnterpriseShape.same(pos, "center") || EnterpriseShape.same(pos, "banner") else {
            return .skip("display_position is not center/banner", id)
        }
        return .ok(ContentRow(id: id, storagePath: sp, hash: parts.hash, ext: parts.ext,
                              size: size, contentType: ctype, position: pos))
    }

    /// Windows 는 file_size 를 _atoi64 로 읽는다: JSON 숫자는 0 쪽으로 자른 정수,
    /// 문자열·null·true 는 0 (= 범위 밖). 범위 밖의 큰 수는 상한보다 크다고만 알면 된다.
    private static func fileSize(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let d = n.doubleValue.rounded(.towardZero)
        if d.isNaN { return nil }
        if d < 1 || d > Double(maxContentBytes) { return nil }
        return Int64(d)
    }
}

/// 기업용 콘텐츠 폴더 안의 경로인가 (Windows IsEnterpriseContentPath).
public enum EnterprisePaths {
    /// 비어 있지 않고, "<dir>/" 로 (대소문자 무시) 시작하며 그보다 길다.
    /// 소유 규칙: enterprise_content 안의 경로는 동기화의 것(동기화마다 바뀌거나 비워진다),
    /// 그 밖은 사용자의 것(사용자가 고른 그림이 이긴다). 예전에는 "비어 있을 때만 채움" 이라
    /// 처음 받은 콘텐츠가 config 에 저장된 채 영영 박혀 있었다.
    ///
    /// 대소문자 무시는 Windows 의 _wcsnicmp 와 같고 APFS 의 기본(대소문자 무시)과도 맞다.
    /// Swift 문자열 비교는 정준 동치라서, 파일 시스템이 돌려준 NFD 경로(한글 폴더 이름)와
    /// 우리가 만든 NFC 경로도 같은 것으로 본다.
    public static func isEnterpriseContentPath(_ p: String, dir: URL) -> Bool {
        if p.isEmpty { return false }
        var prefix = dir.path
        if !prefix.hasSuffix("/") { prefix += "/" }
        let pl = p.lowercased()
        let prel = prefix.lowercased()
        return pl.hasPrefix(prel) && pl.count > prel.count
    }
}

/// 이 파일 안에서만 쓰는 글자 판정.
fileprivate enum EnterpriseShape {
    static func isTrimSpace(_ c: UInt16) -> Bool {
        return c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A
    }

    static func isLowerHex(_ c: UInt16) -> Bool {
        return (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)
    }

    // 확장자: [a-z0-9]
    static func isExtChar(_ c: UInt16) -> Bool {
        return (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A)
    }

    /// 바이트 그대로 같은가. Windows 는 wchar 하나씩 비교한다 - Swift 의 == 는 정준 동치라
    /// U+037E 가 ';' 와 같다고 보는 식의 차이가 있어 여기서는 쓰지 않는다.
    static func same(_ a: String, _ b: String) -> Bool {
        return a.utf8.elementsEqual(b.utf8)
    }
}
