import XCTest
import CryptoKit
@testable import SmartScreenCore

// PKCE, 루프백 요청 읽기, 서버 응답 읽기, 기업용 콘텐츠 검증, 봉인.
// Windows 판(client/enterprise, tools/authtest.cpp)과 같은 입력에 같은 답을 내는지 본다.
final class CoreCTests: XCTestCase {

    private static let org = "123e4567-e89b-12d3-a456-426614174000"
    private static let sha = String(repeating: "0123456789abcdef", count: 4)   // 64 lowercase hex
    private static var goodPath: String { "\(org)/\(sha).png" }

    // ------------------------------------------------------------------ PKCE

    func testPKCEAppendixB() {
        // RFC 7636 Appendix B (AuthTest 의 "Appendix B 시험값과 일치")
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierLengthAndAlphabet() {
        guard let v1 = PKCE.makeVerifier(), let v2 = PKCE.makeVerifier() else {
            return XCTFail("makeVerifier returned nil")
        }
        XCTAssertEqual(v1.utf8.count, 43)
        XCTAssertNotEqual(v1, v2)   // 부를 때마다 다른 값
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        XCTAssertTrue(v1.utf8.allSatisfy { allowed.contains($0) })   // URL 에 그대로 실린다

        let c = PKCE.challenge(for: v1)
        XCTAssertEqual(c.utf8.count, 43)
        XCTAssertFalse(c.contains("+") || c.contains("/") || c.contains("="))
        XCTAssertEqual(PKCE.challenge(for: ""), "")
    }

    func testBase64url() {
        XCTAssertEqual(PKCE.base64url(Data([0xFB, 0xFF])), "-_8")       // std "+/8="
        XCTAssertEqual(PKCE.base64url(Data([0x66, 0x6F, 0x6F])), "Zm9v")
        XCTAssertEqual(PKCE.base64url(Data()), "")
    }

    // ------------------------------------------------------------------ URLEnc

    func testURLEnc() {
        XCTAssertEqual(URLEnc.encode("http://127.0.0.1:54321"), "http%3A%2F%2F127.0.0.1%3A54321")
        XCTAssertEqual(URLEnc.encode("aZ09-._~"), "aZ09-._~")
        XCTAssertEqual(URLEnc.encode("a b,+"), "a%20b%2C%2B")
        XCTAssertEqual(URLEnc.encode("한"), "%ED%95%9C")
        // challenge 는 base64url 이라 인코딩해도 그대로다
        XCTAssertEqual(URLEnc.encode("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    // ------------------------------------------------------------------ loopback request

    func testQueryParamCode() {
        let req = "GET /?code=abc%2Ddef&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        XCTAssertEqual(LoopbackRequest.queryParam(req, "code"), "abc-def")
        XCTAssertEqual(LoopbackRequest.queryParam(req, "state"), "xyz")
        XCTAssertNil(LoopbackRequest.queryParam(req, "error"))
        XCTAssertEqual(LoopbackRequest.queryParam("GET /?code=abc%2Ddef&state=xyz HTTP/1.1", "code"), "abc-def")
    }

    func testQueryParamPrefixMatchOnly() {
        // "error_code=" 는 "error" 에 걸리지 않는다
        XCTAssertNil(LoopbackRequest.queryParam("GET /?error_code=500 HTTP/1.1", "error"))
        let req = "GET /?error_code=500&error=access_denied&error_description=Unable+to+exchange%21 HTTP/1.1"
        XCTAssertEqual(LoopbackRequest.queryParam(req, "error"), "access_denied")
        XCTAssertEqual(LoopbackRequest.queryParam(req, "error_description"), "Unable to exchange!")
        // 첫 쌍이 이긴다
        XCTAssertEqual(LoopbackRequest.queryParam("GET /?a=1&a=2 HTTP/1.1", "a"), "1")
    }

    func testQueryParamDecoding() {
        XCTAssertEqual(LoopbackRequest.queryParam("GET /?x=a+b%20c HTTP/1.1", "x"), "a b c")
        XCTAssertEqual(LoopbackRequest.queryParam("GET /?x=%zz%4 HTTP/1.1", "x"), "%zz%4")   // 잘못된 % 는 그대로
        XCTAssertEqual(LoopbackRequest.queryParam("GET /?x=%ED%95%9C HTTP/1.1", "x"), "한")
        XCTAssertEqual(LoopbackRequest.queryParam("GET /?x=%FF HTTP/1.1", "x"), "\u{FFFD}")
        XCTAssertEqual(LoopbackRequest.queryParam("GET /?code= HTTP/1.1", "code"), "")
        XCTAssertNil(LoopbackRequest.queryParam("GET / HTTP/1.1", "code"))     // '?' 없음
        XCTAssertNil(LoopbackRequest.queryParam("GET /?code=1", "code"))       // 두 번째 공백 없음
        XCTAssertNil(LoopbackRequest.queryParam("", "code"))
    }

    func testIsOnPath() {
        XCTAssertTrue(LoopbackRequest.isOnPath("GET /?code=1 HTTP/1.1"))
        XCTAssertFalse(LoopbackRequest.isOnPath("GET /favicon.ico HTTP/1.1"))
        XCTAssertFalse(LoopbackRequest.isOnPath("POST /?code=1 HTTP/1.1"))
        XCTAssertFalse(LoopbackRequest.isOnPath("get /?code=1 HTTP/1.1"))
        XCTAssertFalse(LoopbackRequest.isOnPath("GET /x?code=1 HTTP/1.1"))
        XCTAssertFalse(LoopbackRequest.isOnPath(""))
    }

    func testPlausibleCode() {
        XCTAssertTrue(LoopbackRequest.isPlausibleCode("abc-def"))
        XCTAssertTrue(LoopbackRequest.isPlausibleCode("8f14e45f-ceea-467f-a0e6-0d5b9c8a9a2e"))
        XCTAssertFalse(LoopbackRequest.isPlausibleCode(""))
        XCTAssertFalse(LoopbackRequest.isPlausibleCode("a\"b"))
        XCTAssertFalse(LoopbackRequest.isPlausibleCode("a\\b"))
        XCTAssertFalse(LoopbackRequest.isPlausibleCode("a\nb"))
        XCTAssertFalse(LoopbackRequest.isPlausibleCode("a\u{01}b"))
        // 요청 줄에 두 번째 공백이 없으면 헤더까지 값에 딸려 온다 - 제어문자로 걸러진다
        let v = LoopbackRequest.queryParam("GET /?code=abc\r\nHost: x", "code") ?? ""
        XCTAssertFalse(LoopbackRequest.isPlausibleCode(v))
    }

    func testResultPages() {
        XCTAssertEqual(LoopbackRequest.successBody,
                       "<!doctype html><meta charset=utf-8><title>SmartScreen</title><body style=\"font-family:sans-serif;text-align:center;padding-top:80px\"><h2>로그인되었습니다</h2><p>이 탭을 닫으세요. 결과 창이 안 보이면 화면 오른쪽 위 작은 상자의 [설정] 을 누르세요.</p>")
        XCTAssertEqual(LoopbackRequest.failureBody,
                       "<!doctype html><meta charset=utf-8><title>SmartScreen</title><body style=\"font-family:sans-serif;text-align:center;padding-top:80px\"><h2>로그인하지 못했습니다</h2><p>SmartScreen 에서 다시 시도하세요.</p>")

        let body = LoopbackRequest.successBody
        let resp = LoopbackRequest.response200(body: body)
        let expected = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
                       "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        XCTAssertEqual(resp, Data(expected.utf8))
        XCTAssertNotEqual(body.utf8.count, body.count)   // 길이는 글자 수가 아니라 UTF-8 바이트 수

        XCTAssertEqual(LoopbackRequest.response404,
                       Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
    }

    // ------------------------------------------------------------------ AuthParse

    func testParseSession() {
        let json = """
        {"access_token":"AT","token_type":"bearer","expires_in":3600,"expires_at":999,\
        "refresh_token":"RT","user":{"id":"uid-1","aud":"authenticated","email":"a@b.c",\
        "identities":[{"id":"other","email":"x@y.z"}]}}
        """
        guard let t = AuthParse.parseSession(Data(json.utf8), nowUnix: 1000) else {
            return XCTFail("parseSession returned nil")
        }
        XCTAssertEqual(t.access, "AT")
        XCTAssertEqual(t.refresh, "RT")
        XCTAssertEqual(t.userId, "uid-1")
        XCTAssertEqual(t.email, "a@b.c")
        XCTAssertEqual(t.expiresAtUnix, 4600)   // expires_at 은 보지 않는다
    }

    func testParseSessionDefaultsAndFailures() {
        let noExp = #"{"access_token":"AT","refresh_token":"RT"}"#
        XCTAssertEqual(AuthParse.parseSession(Data(noExp.utf8), nowUnix: 1000)?.expiresAtUnix, 4600)
        XCTAssertEqual(AuthParse.parseSession(Data(noExp.utf8), nowUnix: 1000)?.userId, "")

        let custom = #"{"access_token":"AT","refresh_token":"RT","expires_in":60}"#
        XCTAssertEqual(AuthParse.parseSession(Data(custom.utf8), nowUnix: 1000)?.expiresAtUnix, 1060)

        XCTAssertNil(AuthParse.parseSession(Data(#"{"access_token":"AT"}"#.utf8), nowUnix: 0))
        XCTAssertNil(AuthParse.parseSession(Data(#"{"access_token":"","refresh_token":"RT"}"#.utf8), nowUnix: 0))
        XCTAssertNil(AuthParse.parseSession(Data(#"{"access_token":"AT","refresh_token":null}"#.utf8), nowUnix: 0))
        XCTAssertNil(AuthParse.parseSession(Data(#"{"access_token":"AT","refresh_token":"R"#.utf8), nowUnix: 0))   // 잘린 본문
        XCTAssertNil(AuthParse.parseSession(Data("<html>".utf8), nowUnix: 0))
        XCTAssertNil(AuthParse.parseSession(Data(), nowUnix: 0))
    }

    func testPickError() {
        func pe(_ s: String, _ status: Int = 400) -> String { AuthParse.pickError(Data(s.utf8), status: status) }
        XCTAssertEqual(pe(#"{"error":"invalid_grant","error_description":"Invalid Refresh Token: Already Used"}"#),
                       "Invalid Refresh Token: Already Used")
        XCTAssertEqual(pe(#"{"code":400,"error_code":"bad_code_verifier","msg":"code verifier mismatch"}"#),
                       "code verifier mismatch")
        XCTAssertEqual(pe(#"{"code":"PGRST301","details":null,"hint":null,"message":"JWT expired"}"#), "JWT expired")
        XCTAssertEqual(pe(#"{"error":"access_denied"}"#), "access_denied")
        XCTAssertEqual(pe(#"{"error_description":"","msg":"m"}"#), "m")           // 빈 값은 다음 키로
        XCTAssertEqual(pe(#"{"msg":"m","message":"x"}"#), "m")                    // 키 순서
        XCTAssertEqual(pe("<html>Bad Gateway</html>", 502), "HTTP 502")
        XCTAssertEqual(pe("{}", 401), "HTTP 401")
        XCTAssertEqual(pe("", 500), "HTTP 500")
        XCTAssertEqual(pe(#"{"error_code":"x"}"#, 403), "HTTP 403")               // error_code 는 error 가 아니다
        // 제어문자는 빈칸 (짧은 이스케이프 \f 포함), 160 UTF-16 단위로 자른다
        XCTAssertEqual(pe(#"{"msg":"a\nb\fc"}"#), "a b c")
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(pe("{\"msg\":\"\(long)\"}").utf16.count, 160)
        XCTAssertEqual(pe(#"{"msg":"한글"}"#), "한글")
        // JSON 의 \uXXXX (서러게이트 쌍 포함). 역슬래시-u 는 실행 중에 붙인다.
        let u = "\\" + "u"
        XCTAssertEqual(pe("{\"msg\":\"" + u + "D55C" + u + "AE00\"}"), "한글")
        XCTAssertEqual(pe("{\"msg\":\"" + u + "D83D" + u + "DE00\"}"), "\u{1F600}")
    }

    func testFirstToken() {
        XCTAssertEqual(AuthParse.firstToken(Data("[]".utf8)), "")
        XCTAssertEqual(AuthParse.firstToken(Data(#"[{"token":"ABCDEF0123456789ABCDEF0123456789"}]"#.utf8)),
                       "ABCDEF0123456789ABCDEF0123456789")
        XCTAssertEqual(AuthParse.firstToken(Data(#"[{"token":""},{"token":"CD"}]"#.utf8)), "CD")
        XCTAssertEqual(AuthParse.firstToken(Data(#"[{"token":null}]"#.utf8)), "")
        XCTAssertNil(AuthParse.firstToken(Data(#"{"token":"AB"}"#.utf8)))
        XCTAssertNil(AuthParse.firstToken(Data("not json".utf8)))
        XCTAssertNil(AuthParse.firstToken(Data()))
    }

    // ------------------------------------------------------------------ OrgId / StoragePath

    func testNormalizeOrgId() {
        XCTAssertEqual(OrgId.normalize(Self.org), Self.org)
        XCTAssertEqual(OrgId.normalize("123E4567-E89B-12D3-A456-426614174000"), Self.org)
        XCTAssertEqual(OrgId.normalize(" \t123E4567-e89b-12d3-a456-426614174000\r\n"), Self.org)
        XCTAssertNil(OrgId.normalize(""))
        XCTAssertNil(OrgId.normalize("123e4567-e89b-12d3-a456-42661417400"))         // 35자
        XCTAssertNil(OrgId.normalize("123e4567-e89b-12d3-a456-4266141740000"))       // 37자
        XCTAssertNil(OrgId.normalize("123e4567e-89b-12d3-a456-426614174000"))        // 대시 자리
        XCTAssertNil(OrgId.normalize("123e4567\u{2013}e89b-12d3-a456-426614174000")) // en dash
        XCTAssertNil(OrgId.normalize("123e4567\u{2010}e89b-12d3-a456-426614174000")) // hyphen U+2010
        XCTAssertNil(OrgId.normalize("123e4567-e89b-12d3-a456-42661417400g"))
        XCTAssertNil(OrgId.normalize("123e4567-e89b 12d3-a456-426614174000"))
        XCTAssertNil(OrgId.normalize("\u{3000}123e4567-e89b-12d3-a456-426614174000"))  // 전각 공백은 지우지 않는다
        XCTAssertNil(OrgId.normalize("https://vnonoschrzbgvyeduosm.supabase.co"))
    }

    func testStoragePathShape() {
        let parts = StoragePath.split(Self.goodPath)
        XCTAssertEqual(parts, StoragePathParts(org: Self.org, hash: Self.sha, ext: "png"))
        XCTAssertNotNil(StoragePath.split("\(Self.org)/\(Self.sha).webm"))
        XCTAssertNotNil(StoragePath.split("\(Self.org)/\(Self.sha).abcdefgh"))     // 110자

        XCTAssertNil(StoragePath.split("\(Self.org)/\(Self.sha)."))                // 102자, 확장자 없음
        XCTAssertNil(StoragePath.split("\(Self.org)/\(Self.sha).abcdefghi"))       // 111자
        XCTAssertNil(StoragePath.split("\(Self.org)/\(Self.sha.dropLast()).png"))  // hash 63자
        XCTAssertNil(StoragePath.split("\(Self.org)/\(Self.sha.uppercased()).png"))
        XCTAssertNil(StoragePath.split("\(Self.org.uppercased())/\(Self.sha).png"))
        XCTAssertNil(StoragePath.split("\(Self.org)/\(Self.sha).PNG"))
        XCTAssertNil(StoragePath.split("\(Self.org)/\(Self.sha).p-g"))
        XCTAssertNil(StoragePath.split("\(Self.org)/\(Self.sha)..png"))
        XCTAssertNil(StoragePath.split("\(Self.org)/\(Self.sha).p g"))
        XCTAssertNil(StoragePath.split("\(Self.org)\\\(Self.sha).png"))
        XCTAssertNil(StoragePath.split("../\(Self.org.dropFirst(3))/\(Self.sha).png"))
        XCTAssertNil(StoragePath.split(""))
    }

    func testIsVideoFile() {
        XCTAssertFalse(MediaKind.isVideoFile("/a.b/c"))     // 마지막 점은 경로 전체에서
        XCTAssertTrue(MediaKind.isVideoFile("X.MP4"))
        XCTAssertTrue(MediaKind.isVideoFile("/Users/u/Movies/clip.webm"))
        XCTAssertTrue(MediaKind.isVideoFile("/x/.mov"))
        XCTAssertTrue(MediaKind.isVideoFile("/x/a.png.Mkv"))
        XCTAssertFalse(MediaKind.isVideoFile("/x/y.png"))
        XCTAssertFalse(MediaKind.isVideoFile("/x/y.mp4.png"))
        XCTAssertFalse(MediaKind.isVideoFile("/x/mp4"))
        XCTAssertFalse(MediaKind.isVideoFile(""))
        XCTAssertEqual(MediaKind.videoExtensions, [".mp4", ".avi", ".wmv", ".mkv", ".mov", ".webm"])
    }

    // ------------------------------------------------------------------ ContentManifest

    private func rowJSON(id: String = "r1", orgId: String? = nil, path: String? = nil,
                         fileHash: String? = nil, size: String = "1234", ctype: String = "image",
                         pos: String = "center", extra: String = "") -> String {
        let o = orgId ?? Self.org
        let p = path ?? Self.goodPath
        let h = fileHash ?? Self.sha
        return "{\"id\":\"\(id)\",\"org_id\":\"\(o)\",\"storage_path\":\"\(p)\",\"file_hash\":\"\(h)\"," +
               "\"file_size\":\(size),\"content_type\":\"\(ctype)\",\"display_position\":\"\(pos)\"\(extra)}"
    }

    private func validate(_ json: String, org: String? = nil) -> (rows: [ContentRow]?, logs: [String]) {
        var logs: [String] = []
        let rows = ContentManifest.validate(Data(json.utf8), org: org ?? Self.org, log: { logs.append($0) })
        return (rows, logs)
    }

    private func skipLine(_ why: String, _ id: String) -> String {
        return "enterprise: row skipped - \(why) (id \(id))"
    }

    func testManifestValidRow() {
        let r = validate("[\(rowJSON())]")
        XCTAssertEqual(r.logs, [])
        XCTAssertEqual(r.rows?.count, 1)
        guard let row = r.rows?.first else { return }
        XCTAssertEqual(row.id, "r1")
        XCTAssertEqual(row.storagePath, Self.goodPath)
        XCTAssertEqual(row.hash, Self.sha)
        XCTAssertEqual(row.ext, "png")
        XCTAssertEqual(row.size, 1234)
        XCTAssertEqual(row.contentType, "image")
        XCTAssertEqual(row.position, "center")
        XCTAssertEqual(row.localName, "\(Self.sha).png")
    }

    func testManifestOrderAndOrgNormalization() {
        let json = " \r\n[\(rowJSON(id: "a", pos: "banner")),\(rowJSON(id: "b", ctype: "video"))]"
        let r = validate(json, org: Self.org.uppercased())   // 정규화해서 비교한다
        XCTAssertEqual(r.rows?.map { $0.id }, ["a", "b"])
        XCTAssertEqual(r.rows?.map { $0.position }, ["banner", "center"])
        XCTAssertEqual(r.logs, [])
    }

    func testManifestWrongOrg() {
        let other = "00000000-0000-0000-0000-000000000000"
        let r = validate("[\(rowJSON(id: "r2", orgId: other)),\(rowJSON(id: "ok"))]")
        XCTAssertEqual(r.rows?.map { $0.id }, ["ok"])
        XCTAssertEqual(r.logs, [skipLine("org_id is not this PC's org", "r2")])

        // org_id 는 맞는데 경로의 조직이 다르다
        let r2 = validate("[\(rowJSON(id: "r3", path: "\(other)/\(Self.sha).png"))]")
        XCTAssertEqual(r2.rows, [])
        XCTAssertEqual(r2.logs, [skipLine("storage_path is not <org_id>/<file_hash>.<ext>", "r3")])
    }

    func testManifestMissingFields() {
        let noPath = "[{\"id\":\"m1\",\"org_id\":\"\(Self.org)\",\"file_hash\":\"\(Self.sha)\"," +
                     "\"file_size\":1,\"content_type\":\"image\",\"display_position\":\"center\"}]"
        XCTAssertEqual(validate(noPath).logs, [skipLine("storage_path or file_hash missing", "m1")])
        let nullHash = "[{\"id\":\"m2\",\"org_id\":\"\(Self.org)\",\"storage_path\":\"\(Self.goodPath)\",\"file_hash\":null}]"
        XCTAssertEqual(validate(nullHash).logs, [skipLine("storage_path or file_hash missing", "m2")])
        // id 가 없으면 빈 칸
        let noId = "[{\"org_id\":\"x\"}]"
        XCTAssertEqual(validate(noId).logs, [skipLine("org_id is not this PC's org", "")])
    }

    func testManifestHashMismatch() {
        let wrong = "f" + String(Self.sha.dropFirst())
        let why = "storage_path is not <org_id>/<file_hash>.<ext>"
        XCTAssertEqual(validate("[\(rowJSON(id: "h1", fileHash: wrong))]").logs, [skipLine(why, "h1")])
        // file_hash 도 소문자여야 한다 (정확히 같아야 하므로)
        XCTAssertEqual(validate("[\(rowJSON(id: "h2", fileHash: Self.sha.uppercased()))]").logs, [skipLine(why, "h2")])
        // 경로 모양이 틀림
        XCTAssertEqual(validate("[\(rowJSON(id: "h3", path: "\(Self.org)/../\(Self.sha).png"))]").logs, [skipLine(why, "h3")])
        XCTAssertEqual(validate("[\(rowJSON(id: "h4", path: "\(Self.org)/\(Self.sha).PNG"))]").logs, [skipLine(why, "h4")])
    }

    func testManifestSizeRange() {
        let why = "file_size out of range (1 .. 200 MB)"
        XCTAssertEqual(validate("[\(rowJSON(size: "209715200"))]").rows?.first?.size, 209_715_200)
        XCTAssertEqual(validate("[\(rowJSON(size: "1"))]").rows?.first?.size, 1)
        XCTAssertEqual(validate("[\(rowJSON(size: "12.9"))]").rows?.first?.size, 12)   // _atoi64 처럼 자른다
        for bad in ["0", "-5", "209715201", "\"12\"", "null", "true", "1e30", "0.5"] {
            let r = validate("[\(rowJSON(id: "s", size: bad))]")
            XCTAssertEqual(r.rows, [], "size \(bad)")
            XCTAssertEqual(r.logs, [skipLine(why, "s")], "size \(bad)")
        }
    }

    func testManifestTypeAndPosition() {
        XCTAssertEqual(validate("[\(rowJSON(id: "t", ctype: "audio"))]").logs,
                       [skipLine("content_type is not image/video", "t")])
        XCTAssertEqual(validate("[\(rowJSON(id: "t", ctype: "Image"))]").logs,
                       [skipLine("content_type is not image/video", "t")])
        XCTAssertEqual(validate("[\(rowJSON(id: "p", pos: "left"))]").logs,
                       [skipLine("display_position is not center/banner", "p")])
        XCTAssertEqual(validate("[\(rowJSON(id: "p", pos: "CENTER"))]").logs,
                       [skipLine("display_position is not center/banner", "p")])
    }

    func testManifestNotAnArray() {
        XCTAssertNil(validate("{\"a\":1}").rows)
        XCTAssertNil(validate("").rows)
        XCTAssertNil(validate("   ").rows)
        XCTAssertNil(validate("<html>").rows)
        XCTAssertNil(validate("[{\"id\":").rows)            // 잘린 배열
        XCTAssertEqual(validate("[]").rows, [])             // 빈 배열은 "행 없음" 이지 실패가 아니다
        XCTAssertEqual(validate(" \n[]").rows, [])
        XCTAssertEqual(validate("[1,\"x\",null]").rows, []) // 객체가 아닌 원소는 말없이 지나친다
    }

    func testManifestBracesInsideStrings() {
        // 이름에 '}' 가 든 파일(promo}.png) 하나가 그 행을 통째로 잃게 한 적이 있다
        let a = rowJSON(id: "{a}", extra: ",\"filename\":\"promo}.png\",\"note\":\"{[\\\"}\\\"]\"")
        let b = rowJSON(id: "b", pos: "banner", extra: ",\"filename\":\"{{{\"")
        let r = validate("[\(a),\(b)]")
        XCTAssertEqual(r.logs, [])
        XCTAssertEqual(r.rows?.map { $0.id }, ["{a}", "b"])
    }

    func testManifestLogIdIsOneLine() {
        // 서버에서 온 글자를 그대로 찍으면 줄바꿈 하나로 events.log 에 가짜 줄을 만들 수 있다
        let r = validate("[\(rowJSON(id: "a\\nb", ctype: "x"))]")
        XCTAssertEqual(r.logs, [skipLine("content_type is not image/video", "a?b")])
        let longId = String(repeating: "x", count: 60)
        let r2 = validate("[\(rowJSON(id: longId, ctype: "x"))]")
        XCTAssertEqual(r2.logs, [skipLine("content_type is not image/video", String(repeating: "x", count: 48))])
    }

    // ------------------------------------------------------------------ EnterprisePaths

    func testIsEnterpriseContentPath() {
        let dir = URL(fileURLWithPath: "/Users/u/Library/Application Support/SmartScreen/enterprise_content",
                      isDirectory: true)
        let base = "/Users/u/Library/Application Support/SmartScreen/enterprise_content"
        XCTAssertTrue(EnterprisePaths.isEnterpriseContentPath("\(base)/\(Self.sha).png", dir: dir))
        XCTAssertTrue(EnterprisePaths.isEnterpriseContentPath("\(base.uppercased())/A.PNG", dir: dir))
        XCTAssertFalse(EnterprisePaths.isEnterpriseContentPath("\(base)/", dir: dir))    // 더 길어야 한다
        XCTAssertFalse(EnterprisePaths.isEnterpriseContentPath(base, dir: dir))
        XCTAssertFalse(EnterprisePaths.isEnterpriseContentPath("\(base)2/a.png", dir: dir))
        XCTAssertFalse(EnterprisePaths.isEnterpriseContentPath("/Users/u/Pictures/a.png", dir: dir))
        XCTAssertFalse(EnterprisePaths.isEnterpriseContentPath("", dir: dir))
    }

    // ------------------------------------------------------------------ Seal

    private let sealKey = Data(repeating: 7, count: 32)

    func testSealRoundTrip() {
        let plain = "v1.refresh-token-abc"
        guard let sealed = Seal.seal(plain, key: sealKey) else { return XCTFail("seal returned nil") }
        XCTAssertFalse(sealed.contains(plain))                       // 결과에 평문이 남지 않음
        XCTAssertEqual(Data(base64Encoded: sealed)?.count, 12 + plain.utf8.count + 16)   // 표준 base64
        XCTAssertEqual(Seal.open(sealed, key: sealKey), plain)
        XCTAssertNotEqual(Seal.seal(plain, key: sealKey), sealed)   // nonce 가 매번 다르다
        XCTAssertEqual(Seal.open(Seal.seal("한글 토큰", key: sealKey) ?? "", key: sealKey), "한글 토큰")
        // Windows Base64Decode 처럼 CR/LF 는 건너뛴다
        var withCRLF = sealed
        withCRLF.insert(contentsOf: "\r\n", at: withCRLF.index(withCRLF.startIndex, offsetBy: 20))
        XCTAssertEqual(Seal.open(withCRLF, key: sealKey), plain)
        XCTAssertNil(Seal.seal("", key: sealKey))
    }

    func testSealTamperAndWrongKey() {
        guard let sealed = Seal.seal("refresh-token", key: sealKey) else { return XCTFail("seal returned nil") }
        var chars = Array(sealed)
        XCTAssertGreaterThan(chars.count, 40)
        chars[40] = chars[40] == "A" ? "B" : "A"                     // AuthTest 처럼 40번째 글자를 바꾼다
        XCTAssertNil(Seal.open(String(chars), key: sealKey))
        XCTAssertNil(Seal.open(sealed, key: Data(repeating: 8, count: 32)))
        XCTAssertNil(Seal.open(sealed, key: Data(repeating: 7, count: 5)))   // 키 길이가 틀려도 죽지 않는다
        XCTAssertNil(Seal.open("!!!not base64!!!", key: sealKey))
        XCTAssertNil(Seal.open("", key: sealKey))
        XCTAssertNil(Seal.open("QUJD", key: sealKey))                    // 너무 짧다
        XCTAssertNil(Seal.open("AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAA", key: sealKey))   // Windows DPAPI 머리
        XCTAssertNil(Seal.seal("x", key: Data(repeating: 1, count: 5)))
    }

    func testDeriveKeyLayout() {
        let salt = Data((0..<32).map { UInt8($0) })
        let k = Seal.deriveKey(machineId: "MACHINE-UUID", uid: 501, salt: salt)
        XCTAssertEqual(k.count, 32)

        // 바이트 배열을 고정한다: 바뀌면 이미 봉해 둔 authRefresh 가 열리지 않는다
        var expected = Data("SmartScreen seal v1MACHINE-UUID|501|".utf8)
        expected.append(salt)
        XCTAssertEqual(k, Data(SHA256.hash(data: expected)))

        XCTAssertEqual(Seal.deriveKey(machineId: "MACHINE-UUID", uid: 501, salt: salt), k)
        XCTAssertNotEqual(Seal.deriveKey(machineId: "MACHINE-UUID", uid: 502, salt: salt), k)
        XCTAssertNotEqual(Seal.deriveKey(machineId: "OTHER", uid: 501, salt: salt), k)
        XCTAssertNotEqual(Seal.deriveKey(machineId: "MACHINE-UUID", uid: 501, salt: Data([1])), k)

        // 다른 키로 봉한 값은 열리지 않는다 (복사해 온 config.ini)
        let other = Seal.deriveKey(machineId: "OTHER", uid: 501, salt: salt)
        let sealed = Seal.seal("rt", key: k) ?? ""
        XCTAssertNil(Seal.open(sealed, key: other))
        XCTAssertEqual(Seal.open(sealed, key: k), "rt")
    }
}
