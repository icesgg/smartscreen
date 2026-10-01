import XCTest
import Foundation
import SmartScreenCore

/// 클립보드 공유의 순수 로직 (spec clipsync §4.1, §4.10, §7.5, §9, §11.1).
/// 서버의 행과 PNG 는 Windows 와 바이트 단위로 같아야 하므로, Windows 코드가 만드는 바이트를
/// 그대로 기대값으로 적는다.
final class ClipTests: XCTestCase {

    // MARK: - 해시 (§4.1 시험 벡터, 표준이 아닌 시작값)

    func testFnvVectors() {
        XCTAssertEqual(ClipLogic.fnvOffsetBasis, 0x14650FB0739D0383)
        XCTAssertEqual(ClipLogic.fnv1a64(Data()), 0x14650fb0739d0383)
        XCTAssertEqual(ClipLogic.fnv1a64(Data("a".utf8)), 0x44bd8ad473cd9906)
        XCTAssertEqual(ClipLogic.fnv1a64(Data("가".utf8)), 0xc98ae74ebc46b093)
        XCTAssertEqual(ClipLogic.fnv1a64(Data("hello\r\nworld".utf8)), 0xc2a059f7c553c2d6)
        XCTAssertEqual(ClipLogic.fnv1a64(Data("hello\nworld".utf8)), 0xe5704721c0b22967)
        XCTAssertEqual(ClipLogic.fnv1a64(ClipLogic.pngSignature), 0xf166451aeef3555e)
        XCTAssertEqual(ClipLogic.clipTestText.count, 38)
        XCTAssertEqual(ClipLogic.fnv1a64(ClipLogic.clipTestText), 0xd2b2dcd7888b9112)
    }

    func testFnvOnDataSlice() {
        let whole = Data([0x00, 0x61])
        let slice = whole[1...]            // 시작 인덱스가 0 이 아닌 Data
        XCTAssertEqual(ClipLogic.fnv1a64(slice), 0x44bd8ad473cd9906)
    }

    func testClipTestTextBytes() {
        var expect = [UInt8]("SmartScreen \"clip\" test".utf8)
        expect += [0x5C, 0x31, 0x0A, 0x09, 0xEA, 0xB0, 0x80, 0xEB, 0x82, 0x98, 0xEB, 0x8B, 0xA4, 0x20, 0x01]
        XCTAssertEqual(ClipLogic.clipTestText, Data(expect))
    }

    // MARK: - 기기 이름과 경로 (§4.10, §9.4)

    func testSlug() {
        XCTAssertEqual(ClipLogic.slug("DESKTOP-4F2K9QA"), "DESKTOP-4F2K9QA")
        // 한글 넷 + 공백 하나 = 밑줄 다섯
        XCTAssertEqual(ClipLogic.slug("홍길동의 MacBook Pro"), "_____MacBook_Pro")
        XCTAssertEqual(ClipLogic.slug(""), "pc")
        XCTAssertEqual(ClipLogic.slug(String(repeating: "a", count: 60)), String(repeating: "a", count: 48))
        XCTAssertEqual(ClipLogic.slug("x.y_z"), "x_y_z")
        // 서러게이트 쌍은 UTF-16 단위 둘 = 밑줄 둘 (Windows wchar_t 단위와 같다)
        XCTAssertEqual(ClipLogic.slug("a\u{1F600}b"), "a__b")
    }

    func testDeviceName() {
        // SHA-256("ABC") = b5d4045c...
        XCTAssertEqual(ClipLogic.deviceName(host: "Hongs-MacBook-Pro", machineId: "ABC"),
                       "Hongs-MacBook-Pro-mac-b5d404")
        XCTAssertEqual(ClipLogic.deviceName(host: "Hongs-MacBook-Pro",
                                            machineId: "00000000-1111-2222-3333-444444444444"),
                       "Hongs-MacBook-Pro-mac-d16fe3")
        XCTAssertEqual(ClipLogic.deviceName(host: nil, machineId: nil), "Mac-mac")
        XCTAssertEqual(ClipLogic.deviceName(host: "  ", machineId: " "), "Mac-mac")
        XCTAssertEqual(ClipLogic.deviceName(host: "a\tb", machineId: nil), "ab-mac")

        // 서버 제약 64 자: 호스트 쪽을 자른다
        let long = ClipLogic.deviceName(host: String(repeating: "h", count: 80), machineId: "ABC")
        XCTAssertEqual(long.unicodeScalars.count, ClipLogic.deviceMaxLength)
        XCTAssertTrue(long.hasSuffix("-mac-b5d404"))

        // LocalHostName 꼴이면 slug == 이름 (경로와 행의 이름이 같다)
        let n = ClipLogic.deviceName(host: "Hongs-MacBook-Pro", machineId: "ABC")
        XCTAssertEqual(ClipLogic.slug(n), n)
        // Windows NetBIOS 이름(대문자)과 같을 수 없다
        XCTAssertNotEqual(ClipLogic.deviceName(host: "DESKTOP-4F2K9QA", machineId: "ABC"), "DESKTOP-4F2K9QA")
    }

    func testStoragePath() {
        XCTAssertEqual(ClipLogic.storagePath(userId: "0f1e2d3c-aaaa-bbbb-cccc-111122223333", slug: "DESKTOP-4F2K9QA"),
                       "0f1e2d3c-aaaa-bbbb-cccc-111122223333/DESKTOP-4F2K9QA.png")
    }

    // MARK: - 텍스트 (§4.3, §7.5)

    func testCutAtNul() {
        XCTAssertEqual(ClipLogic.cutAtNul("abc\u{0}def"), "abc")
        XCTAssertEqual(ClipLogic.cutAtNul("\u{0}x"), "")
        XCTAssertEqual(ClipLogic.cutAtNul("plain 가"), "plain 가")
    }

    func testWireTextFromPasteboard() {
        XCTAssertEqual(ClipLogic.wireText(fromPasteboard: "a\nb"), Data("a\r\nb".utf8))
        XCTAssertEqual(ClipLogic.wireText(fromPasteboard: "a\r\nb"), Data("a\r\nb".utf8))     // 두 겹이 되지 않는다
        XCTAssertEqual(ClipLogic.wireText(fromPasteboard: "a\rb"), Data("a\rb".utf8))         // 홀로 선 CR 은 그대로
        XCTAssertEqual(ClipLogic.wireText(fromPasteboard: "a\r\r\nb"), Data("a\r\r\nb".utf8))
        XCTAssertEqual(ClipLogic.wireText(fromPasteboard: "\n\n"), Data("\r\n\r\n".utf8))
        XCTAssertEqual(ClipLogic.wireText(fromPasteboard: "가\n"), Data("가\r\n".utf8))
        XCTAssertEqual(ClipLogic.wireText(fromPasteboard: "a\u{2028}b"), Data("a\u{2028}b".utf8))
        XCTAssertEqual(ClipLogic.wireText(fromPasteboard: ""), Data())
    }

    func testPasteboardTextFromWire() {
        XCTAssertEqual(ClipLogic.pasteboardText(fromWire: Data("a\r\nb".utf8)), "a\nb")
        XCTAssertEqual(ClipLogic.pasteboardText(fromWire: Data("a\rb".utf8)), "a\rb")
        XCTAssertEqual(ClipLogic.pasteboardText(fromWire: Data("a\nb".utf8)), "a\nb")
        XCTAssertEqual(ClipLogic.pasteboardText(fromWire: Data("a\r\r\nb".utf8)), "a\r\nb")
        XCTAssertEqual(ClipLogic.pasteboardText(fromWire: Data("x\r".utf8)), "x\r")
        // 잘못된 UTF-8 은 U+FFFD
        XCTAssertEqual(ClipLogic.pasteboardText(fromWire: Data([0x61, 0xFF])), "a\u{FFFD}")
        // Mac -> 선 -> Mac 은 LF 글에서 손실이 없다
        let s = "줄 하나\n줄 둘\n\t탭"
        XCTAssertEqual(ClipLogic.pasteboardText(fromWire: ClipLogic.wireText(fromPasteboard: s)), s)
    }

    func testEchoHashUsesPasteboardForm() throws {
        let local = try XCTUnwrap(ClipLogic.localText("line1\nline2"))
        XCTAssertEqual(local.wire, Data("line1\r\nline2".utf8))
        XCTAssertEqual(local.localHash, ClipLogic.fnv1a64(Data("line1\nline2".utf8)))

        // 받는 Mac 은 LF 꼴로 붙이고 그 꼴의 해시를 든다 - 다시 읽으면 같은 해시가 나온다
        let recv = ClipLogic.receivedText(local.wire)
        XCTAssertEqual(recv.text, "line1\nline2")
        XCTAssertEqual(recv.localHash, local.localHash)
        XCTAssertEqual(ClipLogic.localText(recv.text)?.localHash, recv.localHash)

        // Windows 가 보낸 CRLF 글
        let fromWin = ClipLogic.receivedText(Data("a\r\nb".utf8))
        XCTAssertEqual(fromWin.text, "a\nb")
        XCTAssertEqual(fromWin.localHash, ClipLogic.fnv1a64(Data("a\nb".utf8)))

        XCTAssertNil(ClipLogic.localText(""))
        XCTAssertNil(ClipLogic.localText("\u{0}abc"))
        XCTAssertNotNil(ClipLogic.localText("   "))      // 공백뿐인 글도 글이다
        XCTAssertEqual(ClipLogic.localText("ab\u{0}cd")?.wire, Data("ab".utf8))
    }

    // MARK: - 붙여넣기판 형식 (§7.3)

    func testOptOutAndFileTypes() {
        XCTAssertTrue(ClipLogic.isOptedOut(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipLogic.isOptedOut(types: ["org.nspasteboard.TransientType"]))
        XCTAssertTrue(ClipLogic.isOptedOut(types: ["org.nspasteboard.AutoGeneratedType"]))
        XCTAssertTrue(ClipLogic.isOptedOut(types: ["com.agilebits.onepassword", "public.utf8-plain-text"]))
        XCTAssertTrue(ClipLogic.isOptedOut(types: ["Pasteboard generator type"]))
        XCTAssertFalse(ClipLogic.isOptedOut(types: ["public.utf8-plain-text", "public.png"]))
        XCTAssertFalse(ClipLogic.isOptedOut(types: []))

        XCTAssertTrue(ClipLogic.isFileCopy(types: ["public.file-url", "public.utf8-plain-text"]))
        XCTAssertTrue(ClipLogic.isFileCopy(types: ["NSFilenamesPboardType"]))
        XCTAssertFalse(ClipLogic.isFileCopy(types: ["public.png", "public.tiff"]))
    }

    // MARK: - JSON (§2.4)

    func testJsonEscapeMatchesWindows() {
        let esc = String(decoding: ClipLogic.jsonEscape(ClipLogic.clipTestText), as: UTF8.self)
        XCTAssertEqual(esc, "SmartScreen \\\"clip\\\" test\\\\1\\n\\t가나다 \\u0001")
        // \b \f 짧은 꼴은 쓰지 않는다 (대문자 hex), 0x7F 는 그대로
        let ctl = String(decoding: ClipLogic.jsonEscape(Data([0x08, 0x0C, 0x1F, 0x0D, 0x7F])), as: UTF8.self)
        XCTAssertEqual(ctl, "\\u0008\\u000C\\u001F\\r\u{7F}")
    }

    func testRowBodiesExact() {
        let text = ClipLogic.textRowBody(device: "DESKTOP-4F2K9QA", wire: Data("hi\r\n".utf8))
        XCTAssertEqual(String(decoding: text, as: UTF8.self),
                       "{\"device\":\"DESKTOP-4F2K9QA\",\"kind\":\"text\",\"body\":\"hi\\r\\n\",\"bytes\":4}")
        let img = ClipLogic.imageRowBody(device: "D", storagePath: "u/s.png", bytes: 10)
        XCTAssertEqual(String(decoding: img, as: UTF8.self),
                       "{\"device\":\"D\",\"kind\":\"image\",\"storage_path\":\"u/s.png\",\"bytes\":10}")
        XCTAssertEqual(String(decoding: ClipLogic.pruneBody(keepId: 123), as: UTF8.self), "{\"p_keep_id\":123}")
    }

    func testTextRowIsValidJsonAndRoundTrips() throws {
        let row = ClipLogic.textRowBody(device: "Mac \"q\" \\", wire: ClipLogic.clipTestText)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: row) as? [String: Any])
        XCTAssertEqual(obj["device"] as? String, "Mac \"q\" \\")
        XCTAssertEqual(obj["kind"] as? String, "text")
        XCTAssertEqual((obj["body"] as? String).map { Data($0.utf8) }, ClipLogic.clipTestText)
        XCTAssertEqual((obj["bytes"] as? NSNumber)?.intValue, 38)
        XCTAssertNil(obj["user_id"])          // 클라이언트는 user_id 를 보내지 않는다
    }

    func testParseBody() {
        // 서버가 돌려줄 모양: [{"body":"<escaped>"}]
        var resp = Data("[{\"body\":\"".utf8)
        resp.append(ClipLogic.jsonEscape(ClipLogic.clipTestText))
        resp.append(Data("\"}]".utf8))
        XCTAssertEqual(ClipLogic.parseBody(resp), ClipLogic.clipTestText)

        // Postgres 의 짧은 꼴 \b \f, \/ , \u 와 서러게이트 쌍
        let pg = Data("[{\"body\":\"a\\bb\\fc\\/d\\u00e9\\ud83d\\ude00\"}]".utf8)
        XCTAssertEqual(ClipLogic.parseBody(pg), Data("a\u{08}b\u{0C}c/d\u{E9}\u{1F600}".utf8))

        // 그 사이에 행이 정리됐다 / null / 잘린 응답 -> 빈 값
        XCTAssertEqual(ClipLogic.parseBody(Data("[]".utf8)), Data())
        XCTAssertEqual(ClipLogic.parseBody(Data("[{\"body\":null}]".utf8)), Data())
        XCTAssertEqual(ClipLogic.parseBody(Data("null".utf8)), Data())
        XCTAssertEqual(ClipLogic.parseBody(Data("[{\"body\":\"abc".utf8)), Data())
        XCTAssertEqual(ClipLogic.parseBody(Data()), Data())
    }

    func testParseNewest() {
        XCTAssertEqual(ClipLogic.parseNewest(Data("[]".utf8)), ClipLogic.RemoteItem())
        XCTAssertEqual(ClipLogic.parseNewest(Data("[]".utf8)).id, 0)

        let t = ClipLogic.parseNewest(Data(
            "[{\"id\":42,\"device\":\"DESKTOP-4F2K9QA\",\"kind\":\"text\",\"storage_path\":null,\"bytes\":38}]".utf8))
        XCTAssertEqual(t, ClipLogic.RemoteItem(id: 42, device: "DESKTOP-4F2K9QA", isImage: false, path: "", bytes: 38))

        let i = ClipLogic.parseNewest(Data(
            "[{\"id\":43,\"device\":\"Hongs-MacBook-Pro-mac-b5d404\",\"kind\":\"image\",\"storage_path\":\"u/x.png\",\"bytes\":1234}]".utf8))
        XCTAssertEqual(i, ClipLogic.RemoteItem(id: 43, device: "Hongs-MacBook-Pro-mac-b5d404", isImage: true,
                                               path: "u/x.png", bytes: 1234))

        // bytes 가 없으면 0, kind 가 image 가 아니면 글
        XCTAssertEqual(ClipLogic.parseNewest(Data("[{\"id\":44,\"device\":\"X\",\"kind\":\"text\"}]".utf8)).bytes, 0)
        XCTAssertFalse(ClipLogic.parseNewest(Data("[{\"id\":45,\"device\":\"X\",\"kind\":\"weird\"}]".utf8)).isImage)
        // 글 행의 storage_path 는 읽지 않는다
        XCTAssertEqual(ClipLogic.parseNewest(Data("[{\"id\":46,\"kind\":\"text\",\"storage_path\":\"p\"}]".utf8)).path, "")

        // id 가 없거나 0 이하 = 행 없음
        XCTAssertEqual(ClipLogic.parseNewest(Data("[{\"id\":0}]".utf8)).id, 0)
        XCTAssertEqual(ClipLogic.parseNewest(Data("[{\"id\":-5}]".utf8)).id, 0)
        XCTAssertEqual(ClipLogic.parseNewest(Data("{\"message\":\"x\"}".utf8)).id, 0)
        XCTAssertEqual(ClipLogic.parseNewest(Data("not json".utf8)).id, 0)
    }

    func testParseInsertedId() {
        XCTAssertEqual(ClipLogic.parseInsertedId(Data("[{\"id\":7}]".utf8)), 7)
        XCTAssertEqual(ClipLogic.parseInsertedId(Data("{\"id\":9}".utf8)), 9)
        XCTAssertEqual(ClipLogic.parseInsertedId(Data("[{\"id\":123456789012}]".utf8)), 123_456_789_012)
        XCTAssertEqual(ClipLogic.parseInsertedId(Data("[]".utf8)), 0)
        XCTAssertEqual(ClipLogic.parseInsertedId(Data("[{\"id\":0}]".utf8)), 0)
        XCTAssertEqual(ClipLogic.parseInsertedId(Data("garbage".utf8)), 0)
    }

    // MARK: - HTTP 문구

    func testRefusalAndExcerpt() {
        XCTAssertEqual(ClipLogic.refusal("조회 거절", status: 401, body: Data("{\"code\":\"PGRST301\"}".utf8)),
                       "조회 거절 [401] {\"code\":\"PGRST301\"}")
        XCTAssertEqual(ClipLogic.refusal("업로드 거절", status: 403, body: Data()), "업로드 거절 [403] ")
        let long = Data(String(repeating: "a", count: 200).utf8)
        XCTAssertEqual(ClipLogic.errorExcerpt(long), String(repeating: "a", count: 160))
        // 160 바이트 경계에서 잘린 UTF-8 은 U+FFFD
        var cut = Data(String(repeating: "a", count: 159).utf8)
        cut.append(Data("가".utf8))
        XCTAssertEqual(ClipLogic.errorExcerpt(cut), String(repeating: "a", count: 159) + "\u{FFFD}")
        XCTAssertTrue(ClipLogic.is2xx(200))
        XCTAssertTrue(ClipLogic.is2xx(204))
        XCTAssertFalse(ClipLogic.is2xx(304))
        XCTAssertFalse(ClipLogic.is2xx(0))
    }

    // MARK: - 크기 상한

    func testCaps() {
        XCTAssertFalse(ClipLogic.isOverCap(10_000_000, cap: 0))
        XCTAssertTrue(ClipLogic.isOverCap(11, cap: 10))
        XCTAssertFalse(ClipLogic.isOverCap(10, cap: 10))
        XCTAssertEqual(ClipLogic.bodyFetchCap(0), 0)
        XCTAssertEqual(ClipLogic.bodyFetchCap(4096 * 1024), 4096 * 1024 * 6 + 4096)
        XCTAssertEqual(ClipLogic.overCapSendText(size: 5_000_000, cap: 4096 * 1024), "4882 KB 라 건너뜀 (상한 4096 KB)")
        XCTAssertEqual(ClipLogic.overCapReceiveText(size: 6_291_456, cap: 4096 * 1024), "6144 KB 라 받지 않음 (상한 4096 KB)")
    }

    // MARK: - PNG (§4.7)

    private func pngHeader(_ w: UInt32, _ h: UInt32) -> Data {
        var d = ClipLogic.pngSignature
        d.append(contentsOf: [0, 0, 0, 13])
        d.append(contentsOf: Array("IHDR".utf8))
        for v in [w, h] {
            d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
        }
        d.append(contentsOf: [8, 6, 0, 0, 0, 0, 0, 0, 0])
        return d
    }

    func testPngChecks() {
        let ok = pngHeader(64, 64)
        XCTAssertTrue(ClipLogic.hasPngSignature(ok))
        XCTAssertEqual(ClipLogic.pngDimensions(ok)?.width, 64)
        XCTAssertEqual(ClipLogic.pngDimensions(ok)?.height, 64)
        XCTAssertNil(ClipLogic.receivedPngProblem(ok))

        let notPng = "받은 것이 PNG 가 아니다"
        let pixels = "그림의 화소 수가 너무 많거나 0 이라 풀지 않았다"
        XCTAssertEqual(ClipLogic.receivedPngProblem(Data("GIF89a-----------------------".utf8)), notPng)
        XCTAssertEqual(ClipLogic.receivedPngProblem(Data()), notPng)
        XCTAssertEqual(ClipLogic.receivedPngProblem(ClipLogic.pngSignature.prefix(7)), notPng)
        XCTAssertEqual(ClipLogic.receivedPngProblem(pngHeader(0, 10)), pixels)
        XCTAssertNil(ClipLogic.receivedPngProblem(pngHeader(8000, 8000)))          // 정확히 64,000,000
        XCTAssertEqual(ClipLogic.receivedPngProblem(pngHeader(8001, 8000)), pixels)
        XCTAssertEqual(ClipLogic.receivedPngProblem(pngHeader(20000, 20000)), pixels)
        XCTAssertEqual(ClipLogic.receivedPngProblem(pngHeader(UInt32.max, UInt32.max)), pixels)

        // 서명 뒤가 IHDR 이 아니다
        var noIhdr = ClipLogic.pngSignature
        noIhdr.append(Data(repeating: 0x41, count: 30))
        XCTAssertEqual(ClipLogic.receivedPngProblem(noIhdr), "PNG 를 그림으로 풀지 못했다")

        // Data 조각(시작 인덱스가 0 이 아님)에서도 맞게 읽는다
        var shifted = Data([0x00])
        shifted.append(pngHeader(3, 5))
        let slice = shifted[1...]
        XCTAssertTrue(ClipLogic.hasPngSignature(slice))
        XCTAssertEqual(ClipLogic.pngDimensions(slice)?.width, 3)
        XCTAssertEqual(ClipLogic.pngDimensions(slice)?.height, 5)
    }

    // MARK: - 조회 간격 (§4.4)

    func testPollInterval() {
        func iv(_ idle: UInt64, _ fails: Int, _ refused: Bool) -> UInt64 {
            return ClipLogic.pollIntervalMs(idleMs: idle, pollFails: fails, pollRefused: refused)
        }
        XCTAssertEqual(iv(0, 0, false), 5_000)
        XCTAssertEqual(iv(120_000, 0, false), 5_000)        // "2분 넘게" 라야 자리 비움
        XCTAssertEqual(iv(120_001, 0, false), 30_000)
        XCTAssertEqual(iv(0, 1, true), 5_000)               // 첫 실패 뒤에는 평소대로
        XCTAssertEqual(iv(0, 2, false), 30_000)
        XCTAssertEqual(iv(0, 2, true), 30_000)
        XCTAssertEqual(iv(0, 3, false), 30_000)             // 네트워크 실패는 30초에서 멈춘다
        XCTAssertEqual(iv(0, 3, true), 120_000)             // 서버가 거절하는 동안만 2분
        XCTAssertEqual(iv(200_000, 3, false), 30_000)
        XCTAssertEqual(iv(200_000, 1_000_000, true), 120_000)
    }

    // MARK: - 상태 줄 (§3.1)

    func testStatusLine() {
        XCTAssertEqual(ClipLogic.statusLine(running: false, hasAccount: true, lastOk: true, lastMsg: "x",
                                            sent: 1, received: 1), "꺼져 있어요")
        XCTAssertEqual(ClipLogic.statusLine(running: false, hasAccount: false, lastOk: true, lastMsg: "",
                                            sent: 0, received: 0), "계정으로 로그인하면 쓸 수 있어요")
        XCTAssertEqual(ClipLogic.statusLine(running: true, hasAccount: true, lastOk: false, lastMsg: "",
                                            sent: 2, received: 3), "기다리는 중  \u{00B7}  보냄 2 / 받음 3")
        XCTAssertEqual(ClipLogic.statusLine(running: true, hasAccount: true, lastOk: false, lastMsg: "조회 요청이 실패했다",
                                            sent: 0, received: 0), "안 됨: 조회 요청이 실패했다  \u{00B7}  보냄 0 / 받음 0")
        XCTAssertEqual(ClipLogic.statusLine(running: true, hasAccount: true, lastOk: true, lastMsg: "텍스트를 보냈습니다",
                                            sent: 1, received: 0), "텍스트를 보냈습니다  \u{00B7}  보냄 1 / 받음 0")
    }

    func testCapStatus() {
        XCTAssertEqual(ClipLogic.capStatus(String(repeating: "가", count: 300)).utf16.count, 200)
        // 서러게이트 쌍을 반으로 자르지 않는다
        let s = String(repeating: "a", count: 199) + "\u{1F600}"
        XCTAssertEqual(ClipLogic.capStatus(s), String(repeating: "a", count: 199))
        XCTAssertEqual(ClipLogic.capStatus("짧다"), "짧다")
    }

    func testConstants() {
        XCTAssertEqual(ClipLogic.maxPixels, 64_000_000)
        XCTAssertEqual(ClipLogic.pollBusyMs, 5_000)
        XCTAssertEqual(ClipLogic.pollIdleMs, 30_000)
        XCTAssertEqual(ClipLogic.idleAfterMs, 120_000)
        XCTAssertEqual(ClipLogic.sessionDownWaitMs, 30_000)
        XCTAssertEqual(ClipLogic.pngSignature, Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }
}
