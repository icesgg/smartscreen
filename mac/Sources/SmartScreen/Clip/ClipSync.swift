import AppKit
import ImageIO
import IOKit
import SystemConfiguration
import UniformTypeIdentifiers
import SmartScreenCore

// ClipSync - 같은 계정으로 로그인한 PC 사이에서 클립보드를 넘긴다 (Windows client/clipsync.cpp).
//
// A 에서 스크린캡처하거나 무언가를 복사하면 B 에서 Cmd+V(Windows 는 Ctrl+V)로 붙는다. 연결고리는
// 구글 계정 하나뿐이다. 이 앱의 자리비움 감지와는 완전히 별개의 기능이며, 같은 앱에 있는 이유는
// 계정 로그인과 Supabase 배관이 이미 여기 있기 때문이다. 서버 쪽은 supabase/clipboard.sql,
// 설계 배경은 docs/CLIPBOARD.md, 순수 로직은 SmartScreenCore/ClipLogic.swift.
//
// ---------------------------------------------------------------------------
// 되울림을 막는 것이 이 기능의 핵심 문제다
// ---------------------------------------------------------------------------
// 받은 내용을 붙여넣기판에 올리면 그것도 "변경" 으로 보인다. 그걸 그대로 올리면 저쪽이 다시
// 받고, 끝나지 않는다. 세 겹으로 막는다.
//  1. 우리가 붙여넣기판을 바꾼 직후의 changeCount 를 적어 두고 그 번호의 변경은 무시한다.
//  2. 마지막으로 올렸거나 받은 내용의 해시를 들고 있다가 같은 것은 올리지 않는다.
//  3. 서버의 행에는 올린 기기 이름이 들어 있어, 자기가 올린 것은 받지 않는다.
// 세 겹이지만 세 겹이어야 한다 - 하나라도 새면 두 PC 가 서로에게 같은 그림을 영원히 되던지고,
// 그건 사용자 눈에는 "클립보드가 멈췄다" 로 보인다.
//
// 시작할 때 남의 것을 붙이지 않는다: 서버의 가장 새 행은 어제 것일 수도 있다. 처음 **성공한**
// 조회는 기준선(id)만 적고 아무것도 붙이지 않는다. 받아 오는 사이에 사용자가 여기서 새로 복사했으면
// 받은 것을 버린다 - 방금 복사한 자리에서 Cmd+V 가 남의 옛것을 내놓으면 안 된다.
//
// ---------------------------------------------------------------------------
// Windows 와 다른 점 (spec clipsync §7)
// ---------------------------------------------------------------------------
//  - 알림이 없다 (WM_CLIPBOARDUPDATE 없음). 전용 직렬 큐에서 300 ms 마다 changeCount 를 본다.
//    메인이 아니라 전용 큐인 이유: 약속된 데이터(Universal Clipboard, 늦은 제공자)를 읽는 데
//    몇 초가 걸릴 수 있고, 그동안 메인(잠금 화면)이 멎으면 안 된다.
//  - 받은 것을 붙이기 직전에 한 번 더 본다 (pasteboardTick). Windows 에서는 "부치기 전에 한 복사" 의
//    알림이 붙이기 메시지보다 큐 앞에 있어서 저절로 먼저 처리된다. 폴링에서는 그 복사를 아직 못 봤을
//    수 있으므로 직접 본다.
//  - 붙여넣기판은 형식 이름이 아니라 UTI 다. 상호 운용은 서버(PNG 바이트, UTF-8 글)에서만 맞춘다.
//  - 줄바꿈: 보낼 때 LF -> CRLF, 받을 때 CRLF -> LF (ClipLogic.wireText / pasteboardText).
//  - 일꾼 스레드는 Thread + NSCondition. 기다림은 벽시계 기한이라 잠자기에서 깨면 바로 조회한다.

struct ClipStatus {
    var running = false
    var lastOk = true
    /// 사람이 읽는 마지막 결과. 실패하면 상태코드가 실린다.
    var lastMsg = ""
    /// 이 세션에서 올린 개수
    var sent = 0
    /// 이 세션에서 받아 붙인 개수
    var received = 0
}

enum ClipSync {
    /// 동기화를 시작한다. 계정이 있어야 한다 (AccountSession.shared.hasAccount).
    /// maxBytes 보다 큰 항목은 건너뛴다 - 스크린샷 하나가 수십 MB 가 되는 경우가 있고(다중 모니터
    /// 전체 캡처), 그걸 매번 올리면 회선만 쓴다. 보낼 때와 받을 때 모두 본다. 0 이면 상한이 없다.
    /// 메인 스레드에서 부른다.
    static func start(url: String, key: String, maxBytes: Int) -> Bool {
        return ClipEngine.shared.start(url: url, key: key, maxBytes: maxBytes)
    }

    /// 멈춘다. 앱이 끝날 때 한 번은 늘 부른다 (켠 적이 없어도 "clip: stopped" 를 적는다).
    /// 메인 스레드에서 부른다. 일꾼이 요청 하나를 기다리는 중이면 최대 20 초(+5 초) 걸린다.
    static func stop() {
        ClipEngine.shared.stop()
    }

    static var isRunning: Bool {
        return ClipEngine.shared.isRunning
    }

    static func status() -> ClipStatus {
        return ClipEngine.shared.statusCopy()
    }

    /// --clip-test 본문: 한 대에서 왕복을 확인한다. 올리고, 다시 조회하고, 내려받아 바이트를 비교한다.
    /// 받는 쪽과 같은 길로 읽는다 (조회는 본문 없이, 글 본문은 그 행만 따로). 크기 상한을 주면
    /// 내려받기가 멈추는지도 본다. 붙여넣기판은 건드리지 않고 스레드도 띄우지 않는다. 블로킹.
    ///
    /// 이게 있어야 하는 이유: 이 기능은 PC 두 대가 있어야 끝까지 시험되는데, 안 될 때 원인이 세
    /// 갈래다 - 내 코드, 서버 설정(clipboard.sql 을 안 돌렸거나 RLS 가 막는다), 그리고 상대 PC.
    /// 한 대에서 왕복이 되는 것만 확인해 두면 남은 것은 셋째뿐이다.
    static func roundTrip(url: String, key: String, report: inout String) -> Bool {
        return ClipRoundTrip.run(url: url, key: key, report: &report)
    }
}

// MARK: - 상태 문구 (spec §3.2, 정확히)

private enum ClipText {
    static let sentText = "텍스트를 보냈습니다"
    static let sentImage = "그림을 보냈습니다"
    static let receivedText = "텍스트를 받았습니다"
    static let receivedImage = "그림을 받았습니다"
    static let reconnected = "다시 연결됐어요"
    static let optedOut = "복사한 앱이 공유하지 말라고 표시해서 보내지 않았어요"
    static let staleDropped = "여기서 방금 복사한 것이 더 새것이라 받은 것은 붙이지 않았어요"
    static let loginFirst = "먼저 구글 계정으로 로그인하세요"
    static let stopTimedOut = "멈추는 중이에요. 앱을 다시 켜면 확실히 정리됩니다"
    static let noSession = "세션이 없다"
    static let writeFailed = "클립보드에 올리지 못했다"
    static let decodeFailed = "PNG 를 그림으로 풀지 못했다"
    /// Mac 에만 있는 문구 (spec §7.6). macOS 15.4+ 에서 이 앱의 붙여넣기판 읽기가 "항상 거부" 로
    /// 막혀 있으면, 말없이 "넘길 형식이 없다" 로 두지 않고 알린다 - 안 그러면 타일은 켜져 있는데
    /// 아무것도 안 넘어간다.
    static let readDenied = "macOS 설정에서 이 앱의 클립보드 읽기가 막혀 있어요"
}

// MARK: - 넘기는 것 하나

private struct ClipPayload {
    var isImage: Bool
    /// 서버로 가는(또는 서버에서 온) 바이트. 글은 CRLF 꼴 UTF-8, 그림은 PNG.
    /// 행의 bytes, 크기 상한, 로그의 바이트 수는 이것으로 센다 (Windows 와 같다).
    var wire: Data
    /// 이 Mac 의 붙여넣기판에 있는(올릴) 꼴의 해시. 되울림 방지는 이것으로 한다 (spec §7.5).
    var localHash: UInt64
    /// 받은 글을 붙여넣기판에 쓸 LF 꼴. 그림이나 여기서 복사한 것에서는 쓰지 않는다.
    var text: String
    /// 받는 쪽에서만 쓴다: 일꾼이 이번 바퀴를 시작할 때(올리기 전)의 localGen.
    var localGen: UInt64 = 0
    /// 받는 쪽에서만 쓴다: 클립보드 큐로 넘기기 직전의 changeCount.
    var postChangeCount: Int = 0
}

// MARK: - 서버 (spec §2.4 A-F). 일꾼 스레드와 --clip-test 에서만 부른다 (동기).

private struct ClipServer {
    let url: String
    let key: String

    private func headers(_ access: String, json: Bool) -> [String: String] {
        var h = ["apikey": key, "Authorization": "Bearer \(access)"]
        if json { h["Content-Type"] = "application/json" }
        return h
    }

    /// A. 그림 올리기. nil = 성공, 아니면 사유.
    func uploadImage(access: String, png: Data, path: String) -> String? {
        var h = headers(access, json: false)
        h["Content-Type"] = "image/png"
        // 경로가 기기마다 하나로 고정이므로 두 번째 캡처부터는 덮어쓰기다.
        // 이게 없으면 첫 장만 올라가고 그 뒤는 전부 409 가 된다.
        h["x-upsert"] = "true"
        let r = Http.request("POST", "\(url)/storage/v1/object/clip/\(path)", headers: h, body: png)
        if !r.ok { return "업로드 요청이 실패했다" }
        if !ClipLogic.is2xx(r.status) { return ClipLogic.refusal("업로드 거절", status: r.status, body: r.body) }
        return nil
    }

    /// B. 행 삽입. id > 0 이면 성공, 아니면 why.
    func insertRow(access: String, body: Data) -> (id: Int64, why: String) {
        var h = headers(access, json: true)
        // 돌려받지 않으면 방금 만든 id 를 모르고, 그러면 무엇보다 오래된 것을 지워야 하는지도 모른다.
        h["Prefer"] = "return=representation"
        // select=id: 돌려받을 것은 id 하나다. 이게 없으면 방금 올린 본문이 통째로 되돌아와서,
        // 큰 텍스트는 올리는 만큼을 한 번 더 내려받는다.
        let r = Http.request("POST", "\(url)/rest/v1/clip_items?select=id", headers: h, body: body)
        if !r.ok { return (0, "행 삽입 요청이 실패했다") }
        if !ClipLogic.is2xx(r.status) { return (0, ClipLogic.refusal("행 삽입 거절", status: r.status, body: r.body)) }
        let id = ClipLogic.parseInsertedId(r.body)
        if id <= 0 { return (0, "삽입은 됐는데 id 를 읽지 못했다") }
        return (id, "")
    }

    /// C. 이 계정의 keepId 보다 오래된 행을 지운다. 결과는 보지 않는다 - 실패해도 지금 넘기는 것에는
    /// 영향이 없고, 다음에 다시 지우면 된다. PostgREST DELETE 필터가 아니라 RPC 인 이유: 필터를
    /// 잘못 쓰면 전체 삭제로 거절되거나, 더 나쁘게는 의도보다 많이 지운다.
    func prune(access: String, keepId: Int64) {
        _ = Http.request("POST", "\(url)/rest/v1/rpc/prune_clip_items",
                         headers: headers(access, json: true), body: ClipLogic.pruneBody(keepId: keepId))
    }

    /// D. 내 것 중 가장 새 행 하나. 행이 없으면 ok + id 0 (오류가 아니다).
    ///
    /// 단일 객체(Accept: vnd.pgrst.object+json)를 달라고 하지 않는다. 행이 0개일 때 그게 406 으로
    /// 돌아오는데, "아직 아무도 아무것도 복사하지 않았다" 는 오류가 아니다 - 그걸 오류로 만들면
    /// 상태창이 늘 빨갛다. body 도 여기서 받지 않는다: 받던 동안에는 누군가 1 MB 짜리 텍스트를
    /// 복사해 두면 모든 PC 가 5초마다 그 1 MB 를 다시 내려받고 다시 풀었다.
    /// status 는 401 을 가려내는 데 쓴다.
    func fetchNewest(access: String) -> (ok: Bool, item: ClipLogic.RemoteItem, why: String, status: Int) {
        let r = Http.request("GET",
                             "\(url)/rest/v1/clip_items?select=id,device,kind,storage_path,bytes&order=id.desc&limit=1",
                             headers: headers(access, json: false))
        if !r.ok { return (false, ClipLogic.RemoteItem(), "조회 요청이 실패했다", r.status) }
        if !ClipLogic.is2xx(r.status) {
            return (false, ClipLogic.RemoteItem(), ClipLogic.refusal("조회 거절", status: r.status, body: r.body), r.status)
        }
        return (true, ClipLogic.parseNewest(r.body), "", r.status)
    }

    /// E. 글 행 하나의 본문. 그 사이에 행이 없어졌으면 ok + 빈 값이다. maxBody 0 = 상한 없음.
    /// 행의 bytes 칸은 올린 쪽이 적은 값이라 실제 크기와 같다는 보장이 없으므로 응답에도 상한을 건다.
    func fetchBody(access: String, id: Int64, maxBody: Int) -> (ok: Bool, body: Data, why: String) {
        let r = Http.request("GET", "\(url)/rest/v1/clip_items?select=body&id=eq.\(id)",
                             headers: headers(access, json: false), maxBodyBytes: maxBody)
        if !r.ok {
            // 상한에 걸려 멈춘 것도 false 로 온다. 그때는 상태코드가 2xx 다.
            return (false, Data(), ClipLogic.is2xx(r.status) ? "본문이 상한을 넘거나 받다가 끊겼다" : "본문 요청이 실패했다")
        }
        if !ClipLogic.is2xx(r.status) {
            return (false, Data(), ClipLogic.refusal("본문 거절", status: r.status, body: r.body))
        }
        return (true, ClipLogic.parseBody(r.body), "")
    }

    /// F. 그림 내려받기. maxBytes 0 = 상한 없음. 이걸 주지 않으면 경로가 가리키는 것이 무엇이든
    /// 끝까지 메모리에 받는다. 2xx 인데 본문이 비면 실패이고 사유는 빈 문자열이다 (Windows 그대로 -
    /// 상태 줄이 "기다리는 중" 으로 돌아간다).
    func downloadImage(access: String, path: String, maxBytes: Int) -> (ok: Bool, data: Data, why: String) {
        let r = Http.request("GET", "\(url)/storage/v1/object/authenticated/clip/\(path)",
                             headers: headers(access, json: false), maxBodyBytes: maxBytes)
        if !r.ok {
            return (false, Data(), ClipLogic.is2xx(r.status) ? "그림이 상한을 넘거나 받다가 끊겼다" : "다운로드 요청이 실패했다")
        }
        if !ClipLogic.is2xx(r.status) {
            return (false, Data(), ClipLogic.refusal("다운로드 거절", status: r.status, body: r.body))
        }
        return (!r.body.isEmpty, r.body, "")
    }
}

// MARK: - 기기 이름 (spec §4.10, §7.1, §9.4)

private enum ClipDevice {
    /// 사람이 읽는 이 Mac 의 이름 + 기계마다 다른 꼬리 (ClipLogic.deviceName 의 주석).
    /// 시작할 때마다 한 번 읽는다.
    static func name() -> String {
        var host: String? = nil
        if let h = SCDynamicStoreCopyLocalHostName(nil) as String?, !h.isEmpty {
            host = h
        } else if let c = SCDynamicStoreCopyComputerName(nil, nil) as String?, !c.isEmpty {
            host = c
        }
        return ClipLogic.deviceName(host: host, machineId: platformUUID())
    }

    /// IOPlatformUUID (하드웨어마다 하나, 바뀌지 않는다). 읽지 못하면 nil.
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service == 0 { return nil }
        defer { IOObjectRelease(service) }
        guard let ref = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
                                                        kCFAllocatorDefault, 0) else { return nil }
        return ref.takeRetainedValue() as? String
    }
}

// MARK: - 붙여넣기판 읽기/쓰기 (클립보드 큐에서만 부른다)

private enum ClipRead {
    case payload(ClipPayload)
    /// 복사한 앱이 공유하지 말라고 표시했다 (상태 줄에 말한다).
    case optedOut
    /// macOS 가 이 앱의 읽기를 막았다 (Mac 만).
    case denied
    /// 넘길 수 있는 형식이 없다 (파일 복사, PDF 만 등). 늘 있는 일이라 말하지 않는다.
    case nothing
}

private enum ClipBoardIO {
    /// 붙여넣기판의 현재 내용을 읽는다 (Windows ReadClipboard, spec §4.3 + §7.3).
    static func read(_ pb: NSPasteboard) -> ClipRead {
        let types = pb.types ?? []
        let names = types.map { $0.rawValue }

        // 1. 무엇이든 읽기 전에 본다. 형식 목록만 보므로 내용을 읽지 않고, 해시도 남지 않는다.
        if ClipLogic.isOptedOut(types: names) { return .optedOut }
        // 2. 파일 복사는 넘기지 않는다 (Windows 의 CF_HDROP). Finder 가 같이 올리는 파일 이름 글을
        //    보내지 않게 글보다 먼저 본다.
        if ClipLogic.isFileCopy(types: names) { return .nothing }

        var advertised = false   // 읽을 수 있다고 내건 형식이 있었는지
        var gotAny = false       // 읽어서 무엇이든 돌아왔는지

        // 3. 글이 먼저다. 캡처 도구는 글을 같이 얹지 않는다. 반대로 워드 같은 데서 복사하면 그림과
        //    글이 같이 올라오는데, 그때 사람이 원하는 것은 대개 글이다. 공백뿐인 글도 글이다.
        //    RTF/HTML 만 있는 것은 바꾸지 않는다 (Windows 와 같다).
        if names.contains(NSPasteboard.PasteboardType.string.rawValue) || names.contains("public.utf16-plain-text") {
            advertised = true
        }
        if let s = pb.string(forType: .string) {
            gotAny = true
            if let t = ClipLogic.localText(s) {
                return .payload(ClipPayload(isImage: false, wire: t.wire, localHash: t.localHash, text: ""))
            }
        }

        // 4. PNG 가 있으면 그대로 쓴다. 다시 굽지 않으므로 빠르고, 알파도 원본 그대로 간다.
        //    TIFF 보다 먼저여야 한다: 우리가 붙인 것을 다시 읽으면 받은 바이트가 그대로 나와서
        //    해시가 맞는다.
        if names.contains(NSPasteboard.PasteboardType.png.rawValue) { advertised = true }
        if let png = pb.data(forType: .png) {
            gotAny = true
            if png.count > 8 { return .payload(image(png)) }
        }

        // 5. TIFF (Cocoa 앱이 흔히 올린다). 1x/2x 처럼 여러 장이면 화소가 가장 많은 것을 PNG 로.
        if names.contains(NSPasteboard.PasteboardType.tiff.rawValue) { advertised = true }
        if let tiff = pb.data(forType: .tiff) {
            gotAny = true
            if let png = tiffToPng(tiff) { return .payload(image(png)) }
        }

        // 6. 그 밖의 비트맵 (JPEG, HEIC, GIF, BMP ...). PDF 같은 벡터는 넘기지 않는다 (Windows 의 EMF).
        for t in types where t != .png && t != .tiff {
            guard let ut = UTType(t.rawValue), ut.conforms(to: .image), !ut.conforms(to: .pdf) else { continue }
            advertised = true
            guard let d = pb.data(forType: t) else { continue }
            gotAny = true
            if let png = imageDataToPng(d) { return .payload(image(png)) }
        }

        if advertised && !gotAny && readDenied(pb) { return .denied }
        return .nothing
    }

    /// 받은 것을 붙여넣기판에 쓴다 (Windows WriteClipboard, spec §7.4). nil = 성공, 아니면 사유.
    /// 판에 있던 다른 것은 모두 지운다. 받은 것에 Concealed/Transient 표시는 달지 않는다 -
    /// Windows 도 달지 않으므로 클립보드 기록 도구가 두 쪽에서 같게 기록한다.
    static func write(_ pb: NSPasteboard, _ p: ClipPayload) -> String? {
        if p.isImage {
            // 붙여넣기판을 건드리기 전에 다 만든다 (Windows 는 클립보드를 연 동안 다른 앱이 기다리므로
            // 그 안에서 풀지 않았다). 서명과 화소 수를 먼저 본다 (ClipLogic.receivedPngProblem).
            if let why = ClipLogic.receivedPngProblem(p.wire) { return why }
            let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let src = CGImageSourceCreateWithData(p.wire as CFData, nil),
                  CGImageSourceGetCount(src) > 0,
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, opts) else {
                return ClipText.decodeFailed
            }
            // TIFF 는 Cocoa 앱(미리보기, Pages, Keynote, Mail)을 위한 덤이다. 압축하는 이유: 20 MP 의
            // 압축 안 한 TIFF 는 80 MB 다. 못 만들어도 PNG 는 올린다.
            let tiff = NSBitmapImageRep(cgImage: cg).tiffRepresentation(using: .lzw, factor: 0)
            // PNG 가 먼저다. Chromium/Electron 의 Mac 클립보드는 public.png 를 먼저 찾는다 - Windows 의
            // "PNG" 등록 형식에 해당한다. 그게 없으면 "이미지 처리에 실패했습니다" 로 끝난다 (§4.9 교훈:
            // 원인은 알파가 아니라 형식의 목록이었다).
            var types: [NSPasteboard.PasteboardType] = [.png]
            if tiff != nil { types.append(.tiff) }
            _ = pb.declareTypes(types, owner: nil)
            // 받은 바이트를 그대로 올린다 - 다시 읽으면 같은 바이트가 나와 해시가 맞는다.
            if !pb.setData(p.wire, forType: .png) { return ClipText.writeFailed }
            if let t = tiff { _ = pb.setData(t, forType: .tiff) }
            return nil
        }
        _ = pb.clearContents()
        if !pb.setString(p.text, forType: .string) { return ClipText.writeFailed }
        return nil
    }

    private static func image(_ png: Data) -> ClipPayload {
        return ClipPayload(isImage: true, wire: png, localHash: ClipLogic.fnv1a64(png), text: "")
    }

    private static func tiffToPng(_ tiff: Data) -> Data? {
        var best: NSBitmapImageRep? = nil
        var bestPx = 0
        for r in NSBitmapImageRep.imageReps(with: tiff) {
            guard let b = r as? NSBitmapImageRep else { continue }
            let px = b.pixelsWide * b.pixelsHigh
            if px > bestPx {
                bestPx = px
                best = b
            }
        }
        guard let rep = best else { return nil }
        guard let png = rep.representation(using: .png, properties: [:]), png.count > 8 else { return nil }
        return png
    }

    private static func imageDataToPng(_ d: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
              png.count > 8 else { return nil }
        return png
    }

    /// macOS 15.4+ 의 NSPasteboard.accessBehavior == .alwaysDeny (원시값 3). 그 이전 macOS 에는 이
    /// 속성이 없으므로 이름으로 물어본다 (없으면 막힌 것이 아니다). 읽기가 하나도 돌아오지 않았을
    /// 때만 묻는다.
    private static func readDenied(_ pb: NSPasteboard) -> Bool {
        let sel = NSSelectorFromString("accessBehavior")
        guard pb.responds(to: sel) else { return false }
        guard let n = pb.value(forKey: "accessBehavior") as? NSNumber else { return false }
        return n.intValue == 3
    }
}

// MARK: - 한 번의 실행 (start ~ stop)

/// start 마다 새로 만든다. 옛 실행의 일꾼이 늦게 끝나거나 큐에 남은 붙이기가 늦게 돌아도, 회차가
/// 다르면 새 실행의 상태를 건드리지 않는다 (spec §7.6 "never two workers").
private final class ClipRun {
    let gen: Int
    let server: ClipServer
    let device: String
    let slug: String

    // ---- cond 가 지킨다 ----
    private let cond = NSCondition()
    private var stopRequested = false
    /// 자동 리셋 이벤트 (Windows s_workEvent): 깨면 지운다. 여러 번 울려도 한 번 깬다.
    private var workPending = false
    private var workerFinished = false
    private var clipDrained = false

    // ---- 클립보드 큐만 ----
    var lastSeenChangeCount = 0
    var timer: DispatchSourceTimer?
    var deniedLogged = false

    // ---- 일꾼만 ----
    /// 조회가 연달아 실패한 횟수.
    var pollFails = 0
    /// 마지막 조회 실패에 HTTP 상태가 있었는지 (서버가 답하고 거절했다). 서버에 닿지 못한 것과 가른다.
    var pollRefused = false

    init(gen: Int, server: ClipServer, device: String, slug: String) {
        self.gen = gen
        self.server = server
        self.device = device
        self.slug = slug
    }

    func signalWork() {
        cond.lock()
        workPending = true
        cond.broadcast()
        cond.unlock()
    }

    func requestStop() {
        cond.lock()
        stopRequested = true
        cond.broadcast()
        cond.unlock()
    }

    var isStopRequested: Bool {
        cond.lock()
        defer { cond.unlock() }
        return stopRequested
    }

    /// 멈춤이나 일감을 ms 까지 기다린다. 멈춤이면 true (둘 다면 멈춤이 이긴다 - Windows 의
    /// WaitForMultipleObjects 에서 stop 이 0 번이다). 벽시계 기한이라 잠자기 뒤에는 바로 돌아온다.
    func waitWorkOrStop(ms: UInt64) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(ms) / 1000.0)
        cond.lock()
        defer { cond.unlock() }
        while !stopRequested && !workPending {
            if !cond.wait(until: deadline) { break }
        }
        if stopRequested { return true }
        workPending = false
        return false
    }

    /// 멈춤만 기다린다 (일감 신호는 남겨 둔다). 멈춤이면 true.
    func waitStop(ms: UInt64) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(ms) / 1000.0)
        cond.lock()
        defer { cond.unlock() }
        while !stopRequested {
            if !cond.wait(until: deadline) { break }
        }
        return stopRequested
    }

    func markWorkerFinished() {
        cond.lock()
        workerFinished = true
        cond.broadcast()
        cond.unlock()
    }

    func markClipDrained() {
        cond.lock()
        clipDrained = true
        cond.broadcast()
        cond.unlock()
    }

    func waitWorkerFinished(seconds: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        cond.lock()
        defer { cond.unlock() }
        while !workerFinished {
            if !cond.wait(until: deadline) { break }
        }
        return workerFinished
    }

    func waitClipDrained(seconds: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        cond.lock()
        defer { cond.unlock() }
        while !clipDrained {
            if !cond.wait(until: deadline) { break }
        }
        return clipDrained
    }

    /// 두 스레드가 다 끝났는지 (기다리지 않는다).
    var bothDone: Bool {
        cond.lock()
        defer { cond.unlock() }
        return workerFinished && clipDrained
    }
}

// MARK: - 엔진

private final class ClipEngine {
    static let shared = ClipEngine()

    /// 붙여넣기판은 이 큐에서만 만진다. 붙여넣기판을 두 스레드에서 만지면 우리가 바꾼 것인지
    /// 판단하는 번호가 어긋난다. 일꾼이 번호만 읽을 때도 이 큐를 거친다 (sync).
    private let clipQueue = DispatchQueue(label: "com.icesgg.smartscreen.clip")

    // ---- lock 이 지킨다 (Windows s_mx 묶음) ----
    private let lock = NSLock()
    private var status = ClipStatus()
    private var maxBytes = 0
    private var device = ""
    /// 이 id 까지는 처리했다 (시작 시 기준선). 늘 오르기만 한다 - 글 재시도 한 번만 예외.
    private var seenId: Int64 = 0
    /// 기준선을 적었는지. 시작할 때의 조회가 실패하면 seenId 는 0 으로 남는데, 그 상태로 다음
    /// 조회가 성공하면 서버의 가장 새 행(어제 것일 수 있다)이 "0 보다 새 것" 이라 그대로 붙었다.
    /// 처음 성공한 조회는 언제가 되든 기준선만 적는다.
    private var haveBaseline = false
    /// 마지막으로 올렸거나 받아 붙인 내용의 해시 (붙여넣기판 꼴).
    private var lastHash: UInt64 = 0
    /// 우리가 붙여넣기판을 바꾼 직후의 changeCount. 시작할 때는 없다.
    private var ignoreChangeCount: Int? = nil
    /// 이 Mac 에서 사용자가 무언가를 새로 복사할 때마다 하나씩 오른다. 우리가 붙인 것과 그
    /// 되울림은 세지 않는다. 받아 온 것을 붙이기 전에 "가지러 간 사이에 여기서 새로 복사했나" 를
    /// 가리는 데 쓴다.
    private var localGen: UInt64 = 0
    /// 올릴 것 (최신 하나만).
    private var outgoing: ClipPayload? = nil
    /// 지금 도는 실행의 회차. 0 = 없음 (stop 이 시작되면 곧바로 0 이 된다).
    private var activeGen = 0
    private var lastGen = 0
    /// Windows s_running. stop 이 시간 안에 끝나지 못하면 true 로 남는다.
    private var runningFlag = false
    private var current: ClipRun? = nil
    /// 글 본문 재시도를 이미 한 id (Windows 의 함수 static - 실행을 넘어서 남는다, 해롭지 않다).
    private var retriedId: Int64 = 0
    /// App Nap 막기. 이 앱은 보통 창이 안 보이는 LSUIElement 라, 이게 없으면 300 ms 감시와
    /// 5 초 조회가 수십 초로 늘어진다.
    private var activity: NSObjectProtocol? = nil

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func setStatus(_ ok: Bool, _ msg: String) {
        let m = ClipLogic.capStatus(msg)
        locked {
            status.lastOk = ok
            status.lastMsg = m
        }
    }

    private func isActive(_ run: ClipRun) -> Bool {
        return locked { activeGen == run.gen }
    }

    var isRunning: Bool {
        return locked { status.running }
    }

    func statusCopy() -> ClipStatus {
        return locked { status }
    }

    /// 로그 한 줄에 실을 사유. 서버가 준 160 바이트가 실릴 수 있으므로 제어문자를 공백으로 바꾼다
    /// (한 사건 = 한 줄).
    private static func logSafe(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            out.append(u.value < 0x20 ? " " : u)
        }
        return String(out)
    }

    // MARK: start / stop

    func start(url: String, key: String, maxBytes: Int) -> Bool {
        let flag = locked { (runningFlag, status.running) }
        if flag.0 {
            if flag.1 { return true }   // 이미 돈다
            // 지난 stop 이 시간 안에 끝나지 못해 플래그가 남아 있다. Windows 는 여기서 아무것도 하지
            // 않고 true 를 돌려주어, 타일이 "꺼짐" 인 채로 "켰습니다" 가 뜨고 clipSync=1 이 저장됐다
            // (spec §10 quirk 2). Mac 은 그사이 두 스레드가 다 끝났으면 정리하고 새로 시작하고,
            // 아직 돌고 있으면 false 를 돌려준다 - 두 번째 일꾼을 같은 상태 위에 띄우지 않는다.
            guard let old = locked({ current }), old.bothDone else { return false }
            locked {
                current = nil
                runningFlag = false
            }
            EventLog.write("clip: stopped")
        }

        if !AccountSession.shared.hasAccount {
            setStatus(false, ClipText.loginFirst)
            return false
        }

        let name = ClipDevice.name()
        let cap = max(0, maxBytes)
        let run: ClipRun = locked {
            lastGen += 1
            let r = ClipRun(gen: lastGen, server: ClipServer(url: url, key: key),
                            device: name, slug: ClipLogic.slug(name))
            runningFlag = true
            current = r
            activeGen = r.gen
            self.maxBytes = cap
            device = name
            seenId = 0
            haveBaseline = false
            lastHash = 0
            ignoreChangeCount = nil
            localGen = 0
            outgoing = nil
            status = ClipStatus()
            status.running = true
            return r
        }

        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "SmartScreen clipboard sharing")
        }

        clipQueue.async {
            ClipEngine.shared.clipSetUp(run)
        }
        let t = Thread {
            ClipEngine.shared.workerMain(run)
            run.markWorkerFinished()
        }
        t.name = "SmartScreen clip worker"
        t.start()

        EventLog.write("clip: started (cap \(cap / 1024) KB)")
        return true
    }

    func stop() {
        let run: ClipRun? = locked {
            activeGen = 0   // 이 뒤로 큐에 남은 감시·붙이기는 아무것도 하지 않는다
            return current
        }

        var workDone = true
        var winDone = true
        if let r = run {
            r.requestStop()
            clipQueue.async {
                r.timer?.cancel()
                r.timer = nil
                r.markClipDrained()
            }
            // 일꾼은 요청 하나를 기다리고 있을 수 있다. Http 가 타임아웃을 걸어 두므로 보통은 금방이다.
            workDone = r.waitWorkerFinished(seconds: 20)
            winDone = r.waitClipDrained(seconds: 5)
        }

        let done = workDone && winDone
        locked {
            outgoing = nil      // 아직 못 올린 것은 버린다
            status.running = false
            if done {
                current = nil
                runningFlag = false
            }
        }
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }

        if done {
            EventLog.write("clip: stopped")
        } else {
            // 플래그를 남겨 다시 시작하지 못하게 한다. 풀어 주면 다음 [켜기] 가 두 번째 일꾼을 띄워
            // 두 벌이 같은 상태를 만지게 된다 - 꺼졌다고 표시된 채로 계속 도는 것보다 훨씬 나쁘다.
            setStatus(false, ClipText.stopTimedOut)
            EventLog.write("clip: stop timed out, threads still live (work=\(workDone ? 1 : 0) win=\(winDone ? 1 : 0))")
        }
    }

    // MARK: 클립보드 큐

    private func clipSetUp(_ run: ClipRun) {
        guard isActive(run) else { return }
        // 시작할 때 이미 판에 있던 것은 올리지 않는다 - Windows 의 리스너도 앞으로의 변경만 알린다.
        run.lastSeenChangeCount = NSPasteboard.general.changeCount
        let t = DispatchSource.makeTimerSource(queue: clipQueue)
        t.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(300), leeway: .milliseconds(50))
        t.setEventHandler {
            ClipEngine.shared.pasteboardTick(run)
        }
        run.timer = t
        t.resume()
        EventLog.write("clip: listening as '\(run.device)'")
    }

    /// 300 ms 마다, 그리고 받은 것을 붙이기 직전에도 (spec §7.2).
    private func pasteboardTick(_ run: ClipRun) {
        guard isActive(run) else { return }
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        if cc == run.lastSeenChangeCount { return }
        run.lastSeenChangeCount = cc
        let ours = locked { ignoreChangeCount == cc }
        if ours { return }   // 우리가 방금 붙인 것
        handleLocalChange(run, pb)
    }

    /// 여기서 복사한 것 (Windows WM_CLIPBOARDUPDATE, spec §4.3).
    private func handleLocalChange(_ run: ClipRun, _ pb: NSPasteboard) {
        switch ClipBoardIO.read(pb) {
        case .optedOut:
            // 넘기지 못하는 것이어도 사용자가 여기서 방금 무언가를 복사했다는 것은 적어 둔다 -
            // 가지러 간 사이에 복사한 것 위에 남의 것을 덮으면 안 되기는 마찬가지다.
            locked { localGen &+= 1 }
            // 이것만은 말해 준다. 복사했는데 저쪽에 안 붙는 이유가 어디에도 안 뜨면 고장으로 보인다.
            // 내용은 읽지 않았으므로 로그에도 없다.
            setStatus(true, ClipText.optedOut)
            EventLog.write("clip: not sent - the source app marked it as not to be shared")
        case .denied:
            locked { localGen &+= 1 }
            setStatus(false, ClipText.readDenied)
            if !run.deniedLogged {
                run.deniedLogged = true
                EventLog.write("clip: not sent - macOS does not let this app read the pasteboard")
            }
        case .nothing:
            // 넘길 형식이 없는 것은 늘 있는 일이라 상태를 흔들지 않는다 (파일 복사 등).
            locked { localGen &+= 1 }
        case .payload(let p):
            // 이 비교에는 일부러 기한을 두지 않았다.
            //
            // A 가 보낸 X 를 B 가 받지 못했을 때 사람은 A 에서 X 를 다시 복사하는데, 그것이 여기서
            // 아무 말 없이 버려진다 - 다른 것을 먼저 복사해야 넘어간다. 그 불편은 그대로 남아 있다.
            // 기한을 두지 않은 이유: 같은 내용의 변경이 "사용자가 다시 복사했다" 인지 "다른 앱이 같은
            // 것을 다시 썼다" 인지 여기서는 가릴 수 없다. 그것을 새 복사로 치면 받은 쪽에서는 받은 것을
            // 도로 올리고(되울림), 보낸 쪽에서는 오래전에 복사한 것이 가장 새 행으로 다시 올라가 그사이
            // 저쪽에서 복사한 것을 두 PC 모두에서 옛것으로 덮는다. 붙여넣을 때 이런 변경이 실제로
            // 오는지를 두 대에서 재 보기 전에는 풀지 말 것.
            let gate: (same: Bool, cap: Int) = locked { (p.localHash == lastHash, maxBytes) }
            if gate.same { return }   // 방금 올렸거나 받아 붙인 그것 (localGen 은 올리지 않는다)
            if gate.cap > 0 && p.wire.count > gate.cap {
                locked { localGen &+= 1 }   // 못 보내도 새로 복사한 것은 맞다
                setStatus(false, ClipLogic.overCapSendText(size: p.wire.count, cap: gate.cap))
                return
            }
            locked {
                outgoing = p        // 올리기 전에 또 복사했으면 새 것만
                lastHash = p.localHash
                // 넣는 것과 같은 잠금 안에서 올린다. 일꾼이 이 값을 읽었을 때 "이미 센 복사는
                // outgoing 에 들어 있다" 가 성립해야 한다.
                localGen &+= 1
            }
            run.signalWork()
        }
    }

    /// 받은 것을 붙인다 (Windows WM_CLIP_APPLY, spec §4.8 + §7.2). 클립보드 큐.
    private func apply(_ run: ClipRun, _ p: ClipPayload) {
        guard isActive(run) else { return }
        // Mac 에서는 반드시 먼저 본다. 일꾼이 넘기기 **전에** 한 복사를 폴링이 아직 못 봤을 수 있고,
        // 그 복사는 넘기기 전이라 postChangeCount 와 지금 번호가 같다. 여기서 보지 않으면 방금 복사한
        // 것을 덮고, ignoreChangeCount 가 그 복사까지 삼켜서 두 PC 어디에도 남지 않는다.
        pasteboardTick(run)
        guard isActive(run) else { return }

        let kind = p.isImage ? "image" : "text"
        let pb = NSPasteboard.general
        let cur = pb.changeCount
        // 가지러 간 사이에 사용자가 여기서 새로 복사했으면 붙이지 않는다.
        //  - localGen: 일꾼이 이번 바퀴를 시작할 때(올리기 전)의 값. 그 뒤에 새 복사가 하나라도
        //    세어졌으면 다르다.
        //  - postChangeCount: 넘기기 직전의 번호. 그 뒤에 바뀌었으면 (우리가 앞서 붙인 것 말고는) 새 복사다.
        // 번호만으로 처음부터 끝까지 보지 않는 이유: 내려받는 몇 초 사이에 다른 앱이 판을 다시 쓰면
        // 멀쩡한 것을 버리게 된다. outgoing 이 비었는지는 보지 않는다 - 일꾼이 이미 가져갔을 수 있다.
        // 버린 것은 다시 받지 않는다 (seenId 는 이미 올랐다). 여기서 복사한 것이 더 새것이고, 그것이
        // 올라가면 저쪽도 그것으로 맞춰진다.
        let stale: Bool = locked {
            let copiedMeanwhile = p.localGen != localGen
            let ours: Bool = (ignoreChangeCount == cur)
            let movedSincePost = cur != p.postChangeCount && !ours
            return copiedMeanwhile || movedSincePost
        }
        if stale {
            setStatus(true, ClipText.staleDropped)
            EventLog.write("clip: incoming \(kind) dropped - a newer local copy exists")
            return
        }

        if let why = ClipBoardIO.write(pb, p) {
            setStatus(false, why)
            EventLog.write("clip: apply failed - \(ClipEngine.logSafe(why))")
            return
        }
        // 방금 우리가 만든 변경이다. 이 번호의 변경은 무시하고, 다시 읽어도 해시로 걸러진다.
        let after = pb.changeCount
        locked {
            ignoreChangeCount = after
            lastHash = p.localHash
            status.received += 1
        }
        run.lastSeenChangeCount = after
        setStatus(true, p.isImage ? ClipText.receivedImage : ClipText.receivedText)
        EventLog.write("clip: applied \(kind) (\(p.wire.count) bytes)")
    }

    // MARK: 일꾼 스레드 - 네트워크는 전부 여기서만

    /// 시스템 전체에서 마지막 키보드·마우스 입력 뒤로 지난 ms.
    private static func idleMs() -> UInt64 {
        let s = InputWatcher.secondsSinceLastInput()
        if !(s > 0) { return 0 }
        if s >= 1.0e9 { return 1_000_000_000_000 }
        return UInt64(s * 1000.0)
    }

    private func token() -> (access: String?, why: String) {
        let t = AccountSession.shared.token()
        if let a = t.0, !a.isEmpty { return (a, "") }
        return (nil, t.1.isEmpty ? ClipText.noSession : t.1)
    }

    private func workerMain(_ run: ClipRun) {
        run.pollFails = 0
        // 세션을 못 얻는 중이었는지. 조회 실패는 doPoll 이 상태 줄을 걷어 내지만 세션 실패는 그 셈에
        // 들지 않는다. 네트워크 없이 켠 PC 는 연결이 돌아와 기준선까지 적은 뒤에도, 무언가를 주고받기
        // 전까지 타일이 "안 됨" 으로 남았다.
        var sessionDown = false

        // 켜자마자 한 번 조회한다. 처음 성공한 조회는 기준선만 적고 아무것도 붙이지 않는다 - 여기서
        // 실패해도 되는 이유가 그것이다.
        let first = token()
        if let access = first.access {
            doPoll(run, access: access, localGen: 0)
        } else {
            setStatus(false, first.why)
            sessionDown = true
        }

        while true {
            // 조회가 연달아 실패하는 중이면 간격을 벌린다. 그 사이에 사용자가 무언가를 복사하면
            // 일감 신호가 깨우므로 올리기는 늦어지지 않는다.
            let every = ClipLogic.pollIntervalMs(idleMs: ClipEngine.idleMs(),
                                                 pollFails: run.pollFails, pollRefused: run.pollRefused)
            if run.waitWorkOrStop(ms: every) { break }

            let tk = token()
            guard let access = tk.access else {
                setStatus(false, tk.why)
                sessionDown = true
                // 세션이 없으면 할 수 있는 일이 없다. 5초마다 다시 물어보면 로그가 그것만으로 가득
                // 차므로 한 박자 쉰다.
                if run.waitStop(ms: ClipLogic.sessionDownWaitMs) { break }
                continue
            }
            if sessionDown {
                // 세션이 돌아왔다. 아래의 올리기/조회보다 먼저 걷어 낸다 - 그쪽이 실패하면 그 사유가
                // 이 문구를 다시 덮어야 하기 때문이다.
                sessionDown = false
                setStatus(true, ClipText.reconnected)
            }
            // 올리기 전에 읽어 둔다. 이 값을 읽은 뒤에 여기서 복사한 것이 있으면, 이번 바퀴에서 받아
            // 온 것은 붙이지 않는다. 조회 직전이 아니라 올리기 전인 이유: 올리는 몇 초 사이에 복사한
            // 것은 아직 outgoing 에 남아 있고, 그것도 "받아 온 것보다 새것" 이다.
            let gen = locked { localGen }
            // 올릴 것이 있으면 먼저 올린다. 내가 방금 복사한 것을 넘기는 쪽이 남이 올린 것을 받는
            // 것보다 급하다.
            doUpload(run, access: access)
            if run.isStopRequested { break }
            doPoll(run, access: access, localGen: gen)
        }
    }

    private func doUpload(_ run: ClipRun, access: String) {
        let taken: ClipPayload? = locked {
            let p = outgoing
            outgoing = nil
            return p
        }
        guard let p = taken else { return }

        let path = ClipLogic.storagePath(userId: AccountSession.shared.userId, slug: run.slug)
        var why = ""
        var ok = true
        if p.isImage {
            if let w = run.server.uploadImage(access: access, png: p.wire, path: path) {
                ok = false
                why = w
            }
        }
        var id: Int64 = 0
        if ok {
            let body = p.isImage
                ? ClipLogic.imageRowBody(device: run.device, storagePath: path, bytes: p.wire.count)
                : ClipLogic.textRowBody(device: run.device, wire: p.wire)
            let r = run.server.insertRow(access: access, body: body)
            if r.id > 0 {
                id = r.id
            } else {
                ok = false
                why = r.why
            }
        }

        if ok {
            locked {
                status.sent += 1
                // 내가 올린 것을 되받지 않도록 기준선을 올린다.
                if id > seenId { seenId = id }
            }
            setStatus(true, p.isImage ? ClipText.sentImage : ClipText.sentText)
            EventLog.write("clip: sent \(p.isImage ? "image" : "text") id=\(id) (\(p.wire.count) bytes)")
            run.server.prune(access: access, keepId: id)
        } else {
            setStatus(false, why)
            EventLog.write("clip: send failed - \(ClipEngine.logSafe(why))")
            // 해시를 놓아 준다. 안 그러면 같은 것을 다시 복사해도 "방금 올린 것" 으로 걸러져서, 한 번
            // 실패한 내용은 영영 못 보낸다. 자동 재시도는 하지 않는다 - 계속 실패하는 항목이 5초마다
            // 도는 편이 더 나쁘다. 놓는 것은 그 해시가 아직 이 항목의 것일 때만이다: 올리는 몇 초 사이에
            // 남의 것을 받아 붙였으면 해시는 이미 그것의 것이고, 그걸 0 으로 만들면 받은 것의 늦은
            // 변경이 되울림 방지를 빠져나간다.
            locked {
                if lastHash == p.localHash { lastHash = 0 }
            }
        }
    }

    /// localGen: 이번 바퀴를 시작할 때의 localGen (apply 의 주석).
    private func doPoll(_ run: ClipRun, access: String, localGen gen: UInt64) {
        let r = run.server.fetchNewest(access: access)
        if !r.ok {
            // 401 은 서버가 이 토큰을 거절했다는 뜻이다. 세션 쪽은 이 Mac 에서 잰 시간으로만 만료를
            // 판단하므로, 그 판단이 서버와 어긋나면 여기서 알려 주지 않는 한 같은 토큰을 계속 받는다.
            // Storage 는 만료된 토큰을 400/403 으로 말하기도 하지만, 올리기와 조회가 같은 바퀴에서 같은
            // 토큰으로 나가므로 조회에서 잡으면 된다.
            if r.status == 401 { AccountSession.shared.invalidate() }
            setStatus(false, r.why)
            // 연달아 실패하는 동안에는 첫 번만 적는다.
            if run.pollFails == 0 {
                EventLog.write("clip: poll failed - \(ClipEngine.logSafe(r.why)) (repeats are not logged until it recovers)")
            }
            run.pollRefused = (r.status != 0)
            if run.pollFails < ClipLogic.pollFailsCap { run.pollFails += 1 }
            return
        }
        if run.pollFails > 0 {
            EventLog.write("clip: poll recovered after \(run.pollFails) failed attempt(s)")
            run.pollFails = 0
            // 실패 문구가 상태 줄에 남아 있으면 다 나은 뒤에도 "안 됨" 으로 보인다.
            setStatus(true, ClipText.reconnected)
        }

        let it = r.item
        let snap: (baseline: Bool, seen: Int64, mine: String, cap: Int) = locked {
            // 처음 성공한 조회는 기준선만 적는다. 행이 하나도 없을 때(id==0)에도 적은 것으로 친다 -
            // 그러지 않으면 빈 테이블에서 시작한 PC 가 나중에 오는 첫 항목을 기준선으로 삼켜 버린다.
            // 그래서 아래의 id==0 검사보다 앞에 있다.
            let baseline = !haveBaseline
            if baseline {
                haveBaseline = true
                // 그 전에 내가 올린 것이 있으면 seenId 가 이미 올라 있다. 내리지 않는다.
                if it.id > seenId { seenId = it.id }
            }
            return (baseline, seenId, device, maxBytes)
        }
        if snap.baseline {
            EventLog.write("clip: baseline id=\(it.id)")
            return
        }
        if it.id == 0 || it.id <= snap.seen { return }

        // 기준선을 먼저 올린다. 아래에서 실패해도 같은 항목을 5초마다 영원히 다시 시도하지 않게 한다 -
        // 실패하는 항목 하나가 그 뒤에 오는 모든 것을 막으면 기능이 통째로 멎는다.
        locked { seenId = it.id }
        // 내가 올린 것. 정확히(대소문자, 정규화 없이 바이트로) 비교한다.
        if it.device.utf8.elementsEqual(snap.mine.utf8) { return }

        let cap = snap.cap
        // 상한은 받을 때도 지킨다. 세 번 본다: 받기 전에 행의 bytes 로(거짓일 수 있지만 정직한 큰
        // 항목은 요청 없이 걸러진다), 받는 동안 Http 의 상한으로, 받은 뒤 실제 크기로. 받은 크기가
        // 행의 bytes 와 "같은지" 는 보지 않는다 - 그림 파일은 기기마다 하나를 덮어쓰므로 파일이 행보다
        // 새것일 수 있다 ("틀린 그림이 아니라 앞선 그림을 건너뛴 것이고, 다음 폴링에서 맞춰진다").
        if ClipLogic.isOverCap(it.bytes, cap: cap) {
            setStatus(false, ClipLogic.overCapReceiveText(size: it.bytes, cap: cap))
            EventLog.write("clip: incoming id=\(it.id) not fetched - \(it.bytes) bytes is over the cap")
            return
        }

        let got: (ok: Bool, data: Data, why: String)
        if it.isImage {
            got = run.server.downloadImage(access: access, path: it.path, maxBytes: cap)
        } else {
            let b = run.server.fetchBody(access: access, id: it.id, maxBody: ClipLogic.bodyFetchCap(cap))
            got = (b.ok, b.body, b.why)
        }
        if !got.ok {
            setStatus(false, got.why)
            EventLog.write("clip: download failed - \(ClipEngine.logSafe(got.why))")
            // 글의 본문을 따로 받게 된 뒤로는 그 요청 하나가 실패하면 그 글을 영영 못 받는다 (기준선은
            // 위에서 이미 올렸다). 같은 id 는 다음 조회에서 한 번만 다시 받아 본다 - 상한을 넘어서 실패한
            // 것도 한 번 더 받게 되지만 거기서 멈춘다. 그 사이에 내가 올린 것이 있어 seenId 가
            // 달라졌으면 손대지 않는다.
            if !it.isImage {
                locked {
                    if retriedId != it.id {
                        retriedId = it.id
                        if seenId == it.id { seenId = snap.seen }
                    }
                }
            }
            return
        }
        // 그 사이에 행이 정리됐다 (보낸 쪽이 더 새 것을 올렸다). 말없이 버린다.
        if got.data.isEmpty { return }
        if ClipLogic.isOverCap(Int64(got.data.count), cap: cap) {
            setStatus(false, ClipLogic.overCapReceiveText(size: Int64(got.data.count), cap: cap))
            EventLog.write("clip: incoming id=\(it.id) dropped - \(got.data.count) bytes is over the cap")
            return
        }

        var p: ClipPayload
        if it.isImage {
            p = ClipPayload(isImage: true, wire: got.data, localHash: ClipLogic.fnv1a64(got.data), text: "")
        } else {
            let t = ClipLogic.receivedText(got.data)
            p = ClipPayload(isImage: false, wire: got.data, localHash: t.localHash, text: t.text)
        }
        p.localGen = gen
        // 붙이기는 클립보드 큐가 한다. 넘기기 직전의 번호를 적는다 (apply 의 주석). 번호도 그 큐에서
        // 읽는다 - 붙여넣기판 객체를 두 스레드에서 동시에 만지지 않게. 클립보드 큐는 일꾼이나 메인을
        // 기다리는 일이 없으므로 sync 가 막히지 않는다 (붙여넣기판을 읽는 중이면 그만큼만 기다린다).
        p.postChangeCount = clipQueue.sync { NSPasteboard.general.changeCount }
        let payload = p
        guard isActive(run) else { return }
        clipQueue.async {
            ClipEngine.shared.apply(run, payload)
        }
    }
}

// MARK: - --clip-test (spec §4.12, Windows ClipSyncRoundTrip)

private enum ClipRoundTrip {
    static func run(url: String, key: String, report: inout String) -> Bool {
        var out = ""
        defer { report += out }
        func line(_ mark: String, _ text: String) {
            out += mark + " " + text + "\n"
        }

        let session = AccountSession.shared
        if !session.hasAccount {
            out += "[X] 로그인한 계정이 없다. 먼저 [폰 등록] 에서 계정으로 로그인할 것.\n"
            return false
        }
        let tk = session.token()
        guard let access = tk.0, !access.isEmpty else {
            line("[X]", "세션: \(tk.1.isEmpty ? ClipText.noSession : tk.1)")
            return false
        }
        line("[OK]", "세션 (\(session.email))")

        let name = ClipDevice.name()
        let slug = ClipLogic.slug(name)
        let server = ClipServer(url: url, key: key)
        let path = ClipLogic.storagePath(userId: session.userId, slug: slug)
        line("[..]", "이 PC: \(name)  경로: \(path)")

        var allOk = true

        // ---- 텍스트 ----
        do {
            // 서버를 거치며 깨지기 쉬운 것들을 일부러 넣는다 (ClipLogic.clipTestText).
            let text = ClipLogic.clipTestText
            let ins = server.insertRow(access: access, body: ClipLogic.textRowBody(device: name, wire: text))
            if ins.id <= 0 {
                line("[X]", "텍스트 올리기: \(ins.why)")
                allOk = false
            } else {
                // 받는 쪽(doPoll)과 같은 두 걸음으로 읽는다: 조회는 본문 없이, 본문은 그 행 하나만 따로.
                let nw = server.fetchNewest(access: access)
                if !nw.ok {
                    line("[X]", "텍스트 조회: \(nw.why)")
                    allOk = false
                } else if nw.item.id != ins.id {
                    line("[X]", "방금 올린 행이 가장 새 행이 아니다")
                    allOk = false
                } else if nw.item.isImage {
                    line("[X]", "kind 가 text 로 돌아오지 않았다")
                    allOk = false
                } else if nw.item.bytes != Int64(text.count) {
                    // 받는 쪽이 내려받기 전에 상한을 보는 데 이 칸을 쓴다.
                    line("[X]", "행의 bytes 가 올린 크기와 다르게 돌아왔다")
                    allOk = false
                } else {
                    let b = server.fetchBody(access: access, id: nw.item.id, maxBody: 0)
                    if !b.ok {
                        line("[X]", "텍스트 본문 조회: \(b.why)")
                        allOk = false
                    } else if b.body != text {
                        // 여기서 걸리면 JSON 이스케이프나 \u 풀기가 틀린 것이다.
                        line("[X]", "텍스트가 달라졌다 (보냄 \(text.count) 바이트, 받음 \(b.body.count) 바이트)")
                        allOk = false
                    } else {
                        line("[OK]", "텍스트 왕복 (제어문자\u{00B7}한글\u{00B7}따옴표 포함)")
                    }
                }
            }
        }

        // ---- 그림 ----
        let made = makeTestPng()
        if let png = made.png {
            if let w = server.uploadImage(access: access, png: png, path: path) {
                line("[X]", "그림 올리기: \(w)")
                allOk = false
            } else {
                let ins = server.insertRow(access: access,
                                           body: ClipLogic.imageRowBody(device: name, storagePath: path, bytes: png.count))
                if ins.id <= 0 {
                    line("[X]", "그림 행 삽입: \(ins.why)")
                    allOk = false
                } else {
                    let dl = server.downloadImage(access: access, path: path, maxBytes: 0)
                    if !dl.ok {
                        line("[X]", "그림 내려받기: \(dl.why)")
                        allOk = false
                    } else if dl.data != png {
                        line("[X]", "그림 바이트가 다르다 (보냄 \(png.count), 받음 \(dl.data.count))")
                        allOk = false
                    } else {
                        line("[OK]", "그림 왕복 (\(png.count) 바이트)")

                        // 받은 PNG 가 실제로 그림으로 풀리는지. 바이트가 같아도 여기서 막히면 붙여넣기가
                        // 빈 그림이 된다.
                        let dec = decode(dl.data)
                        if let size = dec.size {
                            line("[OK]", "PNG 풀기 (\(size.w)x\(size.h))")
                        } else {
                            line("[X]", "PNG 풀기: \(dec.why)")
                            allOk = false
                        }

                        // 상한을 주면 받다가 멈추는지. 받는 쪽의 크기 상한은 Http 가 이 약속을 지키는 것에
                        // 기댄다 - 상한을 무시하고 끝까지 받아 오면 평소에는 아무 증상이 없고, 여기서만
                        // 드러난다.
                        let cut = server.downloadImage(access: access, path: path, maxBytes: 16)
                        if cut.ok {
                            line("[X]", "상한(16 바이트)을 줬는데도 그림을 끝까지 받았다")
                            allOk = false
                        } else {
                            line("[OK]", "상한을 넘는 것은 받다가 멈춘다")
                        }
                    }
                    // 두 번 올려 덮어쓰기(x-upsert)가 되는지. 정책에 update 가 빠져 있으면 여기서만
                    // 걸린다 - 실기에서는 "두 번째 캡처부터 안 된다" 로 나타나고, 그건 원인을 짐작하기 어렵다.
                    if let w = server.uploadImage(access: access, png: png, path: path) {
                        line("[X]", "덮어쓰기: \(w)")
                        allOk = false
                    } else {
                        line("[OK]", "같은 경로에 덮어쓰기")
                    }
                    server.prune(access: access, keepId: ins.id)
                    line("[..]", "지난 행 정리함")
                }
            }
        } else {
            line("[X]", "시험 PNG: \(made.why)")
            allOk = false
        }

        out += allOk ? "\n전부 통과. 남은 변수는 상대 PC 뿐이다.\n"
                     : "\n실패한 줄이 있다. supabase/clipboard.sql 을 돌렸는지 먼저 볼 것.\n"
        return allOk
    }

    /// 시험용 PNG: 64x64, 화소 (x,y) = A 255, R x*4, G y*4, B 0x40. 클립보드에서 가져오지 않는다 -
    /// 왕복을 보는 것이 목적이고, 사람이 마침 무엇을 복사해 뒀는지에 결과가 달라지면 안 된다.
    private static func makeTestPng() -> (png: Data?, why: String) {
        let side = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let base = rep.bitmapData else {
            return (nil, "비트맵을 만들지 못했다")
        }
        let bpr = rep.bytesPerRow
        for y in 0..<side {
            for x in 0..<side {
                let o = y * bpr + x * 4
                base[o] = UInt8(x * 4)
                base[o + 1] = UInt8(y * 4)
                base[o + 2] = 0x40
                base[o + 3] = 0xFF
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]), !png.isEmpty else {
            return (nil, "PNG 로 굽지 못했다")
        }
        return (png, "")
    }

    /// 받은 쪽(ClipBoardIO.write)과 같은 검사와 풀기.
    private static func decode(_ d: Data) -> (size: (w: Int, h: Int)?, why: String) {
        if let why = ClipLogic.receivedPngProblem(d) { return (size: nil, why: why) }
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let src = CGImageSourceCreateWithData(d as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, opts) else {
            return (size: nil, why: ClipText.decodeFailed)
        }
        return (size: (w: cg.width, h: cg.height), why: "")
    }
}
