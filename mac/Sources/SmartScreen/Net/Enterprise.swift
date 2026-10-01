import Foundation
import Darwin
import SmartScreenCore

// 기업용 콘텐츠 동기화 (Windows client/enterprise/supabase.cpp).
//
// 기업 PC 는 로그인 없이 (anon key 로) 조직의 contents 행을 읽고, 그 행이 가리키는 파일을
// 받아 잠금 화면에 띄운다. 행을 쓸 수 있는 사람은 그 조직의 멤버 전부이므로 (관리자만이
// 아니다) 행의 글자는 믿는 값이 아니다. 그래서
//   - 행은 정해진 모양과 글자 그대로 맞을 때만 받고 (Core ContentManifest),
//   - 로컬 파일 이름은 검증된 조각으로만 만들고 (ContentRow.localName),
//   - 받은 파일은 크기와 SHA-256 이 행과 같을 때만 제자리에 놓는다 (여기).
// 2026-09-30 검토 전까지는 셋 다 없었다: storage_path 의 마지막 '/' 뒤가 그대로 파일 이름이
// 됐고, HTTP 상태를 보지 않아 서버의 오류 본문이 콘텐츠 파일로 저장됐고, file_hash 는 읽기만
// 하고 쓰지 않았다.

/// 동기화 한 번의 결과. bool 하나로는 "서버에 못 닿았다" 와 "닿았는데 송출 중인 것이 없다" 가
/// 같은 false 였고, 그래서 관리자가 송출을 멈춰도 PC 는 실패로 알고 옛 그림을 계속 띄웠다.
enum EnterpriseOutcome {
    case requestFailed   // 서버에 묻지 못했다 (오프라인, HTTP 오류, 내려받기 도중 끊김). 아무것도 바꾸지 말 것 - "없다" 가 아니라 "모른다"
    case noContent       // 물어봤고, 쓸 수 있는 active 콘텐츠가 없다
    case ready           // 적어도 한 자리의 파일이 검증까지 끝나 있다
}

enum Enterprise {
    /// 받기를 거절하는 크기. 서버의 contents_file_size_range 제약, 'content' 버킷의
    /// file_size_limit 과 같은 값이다 (supabase/hardening.sql).
    private static let maxContentBytes: Int64 = 200 * 1024 * 1024
    /// 목록 응답의 상한. 행 하나가 300 바이트쯤이라 1 MB 면 수천 행이다.
    private static let maxManifestBytes = 1024 * 1024
    /// org_exists 의 답은 true/false 한 낱말이다.
    private static let maxOrgExistsBytes = 4096

    // 동기화는 한 번에 하나. 켤 때의 작업 스레드와 등록 창의 단추가 겹칠 수 있고, 둘이 같은
    // 임시 파일에 쓰면 안 된다.
    private static let syncLock = NSLock()

    /// Blocking and serialized (one at a time). Returns the outcome and synced center/banner POSIX paths.
    ///
    /// 서버의 active 콘텐츠를 받아 둔다. 자리마다 받은 파일의 경로를 돌려주고, 그 자리에 쓸 것이
    /// 없으면 빈 문자열이다. requestFailed 면 둘 다 빈 값이다. 받은 파일은 지우지 않는다 (쌓인다).
    /// 네트워크를 타고 파일 해시를 재므로 오래 걸릴 수 있다 - 메인에서 부르지 말 것.
    static func sync(url: String, key: String, org: String) -> (outcome: EnterpriseOutcome, center: String, banner: String) {
        syncLock.lock()
        defer { syncLock.unlock() }

        guard let rows = fetchManifest(url: url, key: key, org: org) else {
            return (.requestFailed, "", "")
        }

        let dir = Paths.enterpriseContentDir
        var center = ""
        var banner = ""

        // 새 것부터 (created_at desc). 한 자리에 active 가 둘이면 (대시보드는 하나만 켜 두지만
        // 스키마는 막지 않는다) 새 쪽을 쓴다.
        for item in rows {
            let isCenter = item.position == "center"
            let filled = isCenter ? !center.isEmpty : !banner.isEmpty
            if filled {
                continue    // 이 자리는 더 새 행이 이미 채웠다
            }

            let local = dir.appendingPathComponent(item.localName, isDirectory: false)

            // 이미 받아 둔 파일은 크기와 SHA-256 이 둘 다 맞을 때만 다시 쓴다. 예전에는 크기만
            // 봤고, 그래서 오류 본문이나 잘린 파일이 한 번 저장되면 크기가 우연히 맞는 한 계속 쓰였다.
            var path = ""
            if FileManager.default.fileExists(atPath: local.path) &&
                fileMatches(local, hash: item.hash, expectSize: item.size) {
                path = local.path
            } else {
                let got = fetchVerified(url: url, key: key, storagePath: item.storagePath,
                                        hash: item.hash, expectSize: item.size, local: local)
                if got == 1 {
                    path = local.path
                } else if got < 0 {
                    // 목록은 받았는데 파일을 받다가 서버에 닿지 못했다. 이걸 "그 자리에 쓸 것이
                    // 없다" 로 읽으면 회선이 잠깐 끊긴 PC 가 잠금 화면을 비운다. 전체를 실패로
                    // 돌려 부르는 쪽이 아무것도 바꾸지 않게 한다.
                    return (.requestFailed, "", "")
                }
                // got == 0: 파일이 없거나 행과 다르다. 그 자리는 비워 둔다 (이유는 이미 기록했다).
            }
            if path.isEmpty { continue }
            if isCenter { center = path } else { banner = path }
        }

        let outcome: EnterpriseOutcome = (center.isEmpty && banner.isEmpty) ? .noContent : .ready
        return (outcome, center, banner)
    }

    /// 서버에 그 조직이 있는가 (public.org_exists, supabase/hardening.sql). 1 / 0 / -1
    ///   1 = 있다,  0 = 없다,  -1 = 알 수 없다
    /// -1 은 서버에 닿지 못했을 때와 **함수가 아직 서버에 없을 때** (HTTP 404, PGRST202) 둘 다다.
    /// 뒤쪽을 "없다" 로 읽으면 SQL 을 돌리기 전의 서버에서는 어떤 조직도 등록할 수 없게 된다.
    static func orgExists(url: String, key: String, org: String) -> Int {
        // uuid 가 아닌 조직 id 는 없다 - 묻지도 않는다.
        guard let orgN = OrgId.normalize(org) else { return 0 }

        let headers = [
            "apikey": key,
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
        ]
        // orgN 은 hex 와 '-' 만 남았으므로 JSON 에 그대로 넣어도 된다.
        let body = "{\"p_org\":\"" + orgN + "\"}"
        let r = Http.request("POST", url + "/rest/v1/rpc/org_exists", headers: headers,
                             body: Data(body.utf8), maxBodyBytes: maxOrgExistsBytes)
        if !r.ok {
            EventLog.write("enterprise: org_exists - request failed (HTTP \(r.status))")
            return -1
        }
        if r.status < 200 || r.status >= 300 {
            // 404 (PGRST202) 는 함수가 아직 서버에 없다는 뜻이다. "조직이 없다" 가 아니다.
            EventLog.write("enterprise: org_exists - HTTP \(r.status), cannot tell")
            return -1
        }
        // 본문은 true 또는 false 한 낱말이다 (앞뒤 " \t\r\n" 은 무시).
        let word = trimmedWord(r.body)
        if word == Array("true".utf8) { return 1 }
        if word == Array("false".utf8) { return 0 }
        EventLog.write("enterprise: org_exists - unexpected answer, cannot tell")
        return -1
    }

    /// 그 경로가 enterprise_content 폴더 안의 파일인가 (대소문자 무시, 접두어 비교).
    /// 화면 이미지 경로의 주인을 가르는 기준이다: 이 안을 가리키면 동기화가 넣은 것이고 (동기화마다
    /// 바뀌거나 비워진다), 밖이면 사용자가 고른 것이다 (사용자의 그림이 이긴다).
    static func isEnterpriseContentPath(_ p: String) -> Bool {
        return EnterprisePaths.isEnterpriseContentPath(p, dir: Paths.enterpriseContentDir)
    }

    // ---- private ----

    /// contents 목록 (Windows FetchManifest). nil = 요청이 실패했다 (이유는 기록했다).
    /// 빈 배열 = "송출 중인 것이 없다".
    private static func fetchManifest(url: String, key: String, org: String) -> [ContentRow]? {
        // 조직 id 는 URL 에 그대로 들어간다. uuid 모양이 아니면 아예 묻지 않는다.
        guard let orgN = OrgId.normalize(org) else {
            EventLog.write("enterprise: org id '\(TextSanitize.oneLine(org))' is not a uuid - nothing requested")
            return nil
        }

        // active 인 행만 받는다. 예전에는 active 가 하나도 없으면 "가장 새 두 행" 을 active 와
        // 무관하게 받아 띄웠다 - 관리자가 송출을 전부 멈춰도 새로 등록한 PC 는 멈춘 콘텐츠를 보여
        // 줬다. active 가 없다는 것은 "띄울 것이 없다" 는 뜻이다.
        //
        // 쓰는 열만 달라고 한다. filename 은 사람이 읽는 이름일 뿐 PC 가 쓸 데가 없고, 아무 글자나
        // 들어오는 유일한 열이라 가져올 이유가 없다.
        let headers = [
            "apikey": key,
            "Authorization": "Bearer " + key,
        ]
        let q = url + "/rest/v1/contents?org_id=eq." + orgN
            + "&active=eq.true"
            + "&select=id,org_id,storage_path,file_hash,file_size,content_type,display_position"
            + "&order=created_at.desc"
        let r = Http.request("GET", q, headers: headers, maxBodyBytes: maxManifestBytes)
        if !r.ok {
            EventLog.write("enterprise: contents request failed (HTTP \(r.status))")
            return nil
        }
        if r.status < 200 || r.status >= 300 {
            EventLog.write("enterprise: contents request answered HTTP \(r.status)")
            return nil
        }
        // 2xx 인데 배열이 아니면 PostgREST 의 답이 아니다. "행이 없다" 로 읽지 않는다.
        guard let rows = ContentManifest.validate(r.body, org: orgN, log: { line in EventLog.write(line) }) else {
            EventLog.write("enterprise: contents answer is not a JSON array")
            return nil
        }
        return rows
    }

    /// 받아서, 확인하고, 맞을 때만 local 에 놓는다 (Windows FetchVerified). 돌려주는 값은
    /// Http.download 와 같다 (확인에서 떨어지면 0).
    /// storagePath 는 모양 검사를 통과한 값이어야 한다 - URL 에 그대로 붙인다.
    private static func fetchVerified(url: String, key: String, storagePath: String, hash: String,
                                      expectSize: Int64, local: URL) -> Int {
        let src = url + "/storage/v1/object/authenticated/content/" + storagePath
        let tmp = URL(fileURLWithPath: local.path + ".tmp", isDirectory: false)
        // 'content' 버킷은 비공개지만 anon 에 읽기 정책이 있다. 그래서 /object/authenticated/
        // 에 anon key 를 bearer 로 싣는다 (/object/public/ 은 안 된다).
        let headers = [
            "apikey": key,
            "Authorization": "Bearer " + key,
        ]
        let cap = expectSize > 0 ? expectSize : maxContentBytes
        let dl = Http.download(src, headers: headers, to: tmp, maxBytes: cap)
        if dl.result != 1 {
            let what = dl.result == 0 ? "refused" : "did not complete"
            EventLog.write("enterprise: download \(what) (HTTP \(dl.status)) - \(TextSanitize.oneLine(storagePath, max: 110))")
            return dl.result
        }
        if !fileMatches(tmp, hash: hash, expectSize: expectSize) {
            _ = unlink(tmp.path)
            EventLog.write("enterprise: downloaded file does not match file_size/file_hash - discarded (\(TextSanitize.oneLine(storagePath, max: 110)))")
            return 0
        }
        // 같은 폴더 안의 rename 은 원자적이다 - 잠금 화면이 반쯤 쓴 파일을 읽을 틈이 없다.
        if rename(tmp.path, local.path) != 0 {
            let e = errno
            _ = unlink(tmp.path)
            EventLog.write("enterprise: could not move the verified file into place (error \(e))")
            return 0
        }
        return 1
    }

    /// 파일의 SHA-256 이 (expectSize 가 0 이 아니면 크기도) 기대와 같은가.
    /// SHA-256 은 받은 바이트 그대로 잰다 (대시보드가 올릴 때 재는 값, 소문자 hex).
    private static func fileMatches(_ file: URL, hash: String, expectSize: Int64) -> Bool {
        if expectSize != 0 {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attrs[.size] as? NSNumber,
                  size.int64Value == expectSize else { return false }
        }
        guard let hex = SHA256Hex.ofFile(file) else { return false }
        return hex.lowercased() == hash.lowercased()
    }

    /// 앞뒤의 ' ' '\t' '\r' '\n' 을 뗀 바이트.
    private static func trimmedWord(_ d: Data) -> [UInt8] {
        let b = [UInt8](d)
        func isSpace(_ c: UInt8) -> Bool { return c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A }
        guard let first = b.firstIndex(where: { !isSpace($0) }),
              let last = b.lastIndex(where: { !isSpace($0) }) else { return [] }
        return Array(b[first...last])
    }
}
