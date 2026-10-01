import Foundation
import CryptoKit

// ClipLogic - 클립보드 공유(Windows client/clipsync.cpp)에서 화면·네트워크·붙여넣기판 없이
// 정할 수 있는 것을 모았다. 앱 쪽(SmartScreen/Clip/ClipSync.swift)이 이걸 부르고, `swift test` 가
// 이걸 본다.
//
// 같은 구글 계정으로 로그인한 PC 사이에서 클립보드를 넘긴다. 연결고리는 계정 하나뿐이다 -
// 같은 네트워크일 필요가 없고, 블루투스도 폰도 개입하지 않는다. 서버의 행과 PNG 는 Windows 와
// 바이트 단위로 같아야 한다 (spec clipsync §9): Mac 이 올린 것을 Windows 가 받고, 그 반대도 된다.
//
// 되울림을 막는 것이 이 기능의 핵심 문제다. 세 겹(변경 번호, 내용 해시, 행의 기기 이름)이고
// 세 겹이어야 한다 - "하나라도 새면 두 PC 가 같은 그림을 영원히 되던지고, 사용자 눈에는
// '클립보드가 멈췄다' 로 보인다 - 원인이 보이지 않는 종류의 고장이다."

public enum ClipLogic {

    // MARK: - 수 (spec §2.1)

    /// 입력이 최근에 있었으면 자주, 자리를 비웠으면 드물게 확인한다. 이 앱은 자리 비움을 이미
    /// 재고 있으므로 그 값을 쓰면 공짜다. 5초 고정으로 두면 하루에 2만 번이 넘는 요청이 되고,
    /// 아무도 안 쓰는 밤에도 그대로 돈다.
    public static let pollBusyMs: UInt64 = 5_000
    public static let pollIdleMs: UInt64 = 30_000
    /// 키보드·마우스 입력이 이보다 오래 없으면 "자리 비움" 간격으로 조회한다.
    public static let idleAfterMs: UInt64 = 120_000
    /// 조회가 둘째로 연달아 실패한 뒤로는 적어도 30초.
    public static let backoffMidMs: UInt64 = 30_000
    /// 셋째부터, 그리고 서버가 **답하고 거절하는** 동안(401/5xx)만 2분. 서버에 닿지 못한 것
    /// (네트워크)은 30초에서 멈춘다 - 그것까지 2분으로 벌렸더니 Wi-Fi 가 잠깐 끊겼다 돌아온 PC 가
    /// 최대 2분 동안 아무것도 못 받았다. 기다림은 입력으로 깨지 않으므로.
    public static let backoffLongMs: UInt64 = 120_000
    /// 연속 실패 횟수의 포화값.
    public static let pollFailsCap = 1_000_000
    /// 세션을 못 얻으면 한 박자 쉰다. 5초마다 다시 물어보면 로그가 그것만으로 가득 찬다.
    public static let sessionDownWaitMs: UInt64 = 30_000
    /// 받은 그림을 풀기 전에 보는 화소 수 상한. PNG 는 몇 백 KB 로 2만x2만 짜리를 담을 수 있고
    /// (1비트 단색), 그걸 그대로 풀면 1.6 GB 짜리 비트맵을 잡게 된다. 바이트 상한(clipMaxKB)
    /// 으로는 이게 걸러지지 않는다. 8K 화면 한 장이 33 MP 다.
    public static let maxPixels: UInt64 = 64 * 1000 * 1000
    /// 상태 줄 문구의 길이 상한 (UTF-16 단위). 서버가 준 오류 문구가 그대로 실릴 수 있어서
    /// 길이를 믿지 않고 자른다.
    public static let statusMaxUTF16 = 200
    /// 거절 문구에 붙이는 응답 본문의 앞부분 (바이트).
    public static let errorExcerptBytes = 160
    /// Storage 경로의 기기 부분 최대 길이.
    public static let slugMaxLength = 48
    /// 서버 제약 char_length(device) between 1 and 64.
    public static let deviceMaxLength = 64
    /// 받은 그림 바이트는 이것으로 시작해야 한다.
    public static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    /// FNV-1a 64 의 시작값. 표준값(14695981039346656037)보다 한 자리 짧은 Windows 코드의 값을
    /// 그대로 쓴다 - 해시는 서버로 가지 않지만 같은 시험 벡터가 두 쪽에 맞게.
    public static let fnvOffsetBasis: UInt64 = 1_469_598_103_934_665_603
    public static let fnvPrime: UInt64 = 1_099_511_628_211

    /// --clip-test 의 텍스트 (38 바이트). 서버를 거치며 깨지기 쉬운 것들을 일부러 넣는다:
    /// 따옴표, 역슬래시, 줄바꿈, 탭, 한글, 그리고 \u 로 실려 오는 제어문자.
    /// C 원문: "SmartScreen \"clip\" test\\1\n\t\xEA\xB0\x80\xEB\x82\x98\xEB\x8B\xA4 \x01"
    public static let clipTestText: Data = {
        var b = [UInt8]("SmartScreen \"clip\" test".utf8)
        b += [0x5C, 0x31, 0x0A, 0x09]                                   // \ 1 LF TAB
        b += [0xEA, 0xB0, 0x80, 0xEB, 0x82, 0x98, 0xEB, 0x8B, 0xA4]     // 가나다
        b += [0x20, 0x01]
        return Data(b)
    }()

    // MARK: - 내용 식별

    /// 암호용이 아니다. "이거 방금 본 것과 같나" 만 답하면 된다. FNV-1a 64 (Windows HashBytes).
    /// 이 Mac 안에서만 쓰고 서버로 보내지 않는다.
    public static func fnv1a64(_ d: Data) -> UInt64 {
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt64 in
            var h = fnvOffsetBasis
            for b in raw {
                h ^= UInt64(b)
                h = h &* fnvPrime
            }
            return h
        }
    }

    // MARK: - 텍스트 (spec §4.3, §7.5)

    /// 첫 U+0000 앞까지. Windows 는 CF_UNICODETEXT 를 첫 NUL 까지만 읽고, Postgres text 는
    /// NUL 을 담지 못한다.
    public static func cutAtNul(_ s: String) -> String {
        guard let i = s.unicodeScalars.firstIndex(where: { $0.value == 0 }) else { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars[..<i])
        return String(out)
    }

    /// 이 Mac 의 붙여넣기판 글 -> 서버에 싣는 UTF-8 (CRLF 줄바꿈).
    ///
    /// Windows 는 어느 쪽으로도 줄바꿈을 바꾸지 않는다. Windows 앱은 CRLF 를 올리므로 실제로는
    /// 선 위에 CRLF 가 흐르고, Windows 의 받는 쪽은 온 것을 그대로 CF_UNICODETEXT 에 쓴다. LF 만
    /// 있으면 옛 Win32 편집 칸에서 줄이 붙어 버린다. 그래서 Mac 이 보낼 때 Windows 가 복사했을 때와
    /// 같은 꼴로 만든다: 홀로 선 LF 만 CRLF 로 (있던 CRLF 는 두 겹이 되지 않고, 홀로 선 CR 과
    /// U+2028/U+2029 는 그대로).
    public static func wireText(fromPasteboard s: String) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(s.utf8.count + 16)
        var prevCR = false
        for b in s.utf8 {
            if b == 0x0A && !prevCR {
                out.append(0x0D)
            }
            out.append(b)
            prevCR = (b == 0x0D)
        }
        return Data(out)
    }

    /// 서버에서 온 UTF-8 -> 이 Mac 의 붙여넣기판에 올릴 글 (CRLF -> LF, 홀로 선 CR/LF 는 그대로).
    /// 터미널/zsh, vim, 코드 편집기는 CR 을 ^M 이나 빈 줄로 보거나 소스 파일에 줄바꿈을 섞어 둔다.
    /// 잘못된 UTF-8 은 U+FFFD 가 된다 (Windows Utf8ToWide 와 같다).
    public static func pasteboardText(fromWire d: Data) -> String {
        let b = [UInt8](d)
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            if b[i] == 0x0D && i + 1 < b.count && b[i + 1] == 0x0A {
                out.append(0x0A)
                i += 2
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 이 Mac 에서 복사한 글 -> (서버에 실을 바이트, 되울림 해시). 빈 글이면 nil (넘길 것이 없다).
    ///
    /// 해시는 **붙여넣기판에 있는 꼴**(읽은 그대로)로 잡는다. 선 위의 CRLF 꼴로 잡으면, 받은 글을
    /// 붙인 뒤 변경 번호를 놓친 읽기에서 해시가 맞지 않아 받은 것을 도로 올리게 된다 (spec §7.5).
    /// 크기 상한, 행의 bytes, 로그의 바이트 수는 선 위의 꼴로 센다 - Windows 와 같다.
    public static func localText(_ read: String) -> (wire: Data, localHash: UInt64)? {
        let t = cutAtNul(read)
        if t.isEmpty { return nil }
        return (wire: wireText(fromPasteboard: t), localHash: fnv1a64(Data(t.utf8)))
    }

    /// 서버에서 받은 글 -> (붙여넣기판에 쓸 글, 되울림 해시). 해시는 붙여넣기판에 쓰는 LF 꼴로
    /// 잡는다 - 나중에 다시 읽으면 바로 그 글이 돌아오므로.
    public static func receivedText(_ wire: Data) -> (text: String, localHash: UInt64) {
        let t = pasteboardText(fromWire: wire)
        return (text: t, localHash: fnv1a64(Data(t.utf8)))
    }

    // MARK: - 붙여넣기판 형식 (spec §7.3)

    /// 복사한 앱이 "기록하지도, 다른 기기로 보내지도 말라" 고 단 표시 (nspasteboard.org 관례와
    /// 옛 관례). Windows 의 ExcludeClipboardContentFromMonitorProcessing / Clipboard Viewer Ignore /
    /// CanIncludeInClipboardHistory=0 / CanUploadToCloudClipboard=0 에 해당한다. 암호 관리자가 암호를
    /// 복사할 때 다는 표시다. 이걸 보지 않던 Windows 판에서는 "암호가 평문으로 서버에 올라가 다른
    /// PC 의 클립보드에 붙었고, 관리자가 30초 뒤에 이 PC 의 클립보드를 비워도 그쪽에는 그대로
    /// 남았다". Mac 의 표시는 값이 없다 - 있기만 하면 제외한다.
    public static let optOutTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",          // 암호 (1Password, KeePassXC ...)
        "org.nspasteboard.TransientType",          // 기록하지 말 것
        "org.nspasteboard.AutoGeneratedType",      // 사람이 아니라 프로그램이 올린 것 (글 확장 도구)
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
        "com.agilebits.onepassword",
        "net.antelle.keeweb",
    ]

    /// 내용을 읽기 전에 형식 목록만으로 본다. 내용을 읽지 않으므로 해시도 남지 않는다.
    public static func isOptedOut(types: [String]) -> Bool {
        for t in types where optOutTypes.contains(t) { return true }
        return false
    }

    /// 다른 Apple 기기(아이폰, 아이패드, 다른 Mac)에서 복사해 유니버설 클립보드로 넘어온 것. macOS 가 그
    /// 항목에 이 형식을 붙인다. 보내지 않는다: 폰에서 복사한 것(인증 문자, 폰의 암호 관리자에서 꺼낸 값)이
    /// 사용자가 모르는 사이에 서버를 지나 Windows PC 의 클립보드에까지 붙었다. 형식 목록만 보므로 폰에서
    /// 내용을 끌어오지 않는다 (약속된 데이터라 읽는 순간 가져온다).
    /// optOutTypes 에 넣지 않는다 - 거기 들면 "복사한 앱이 공유하지 말라고 표시" 라고 상태 줄에 뜨는데,
    /// 그런 표시를 단 앱은 없다. 부르는 쪽이 따로 다룬다 (말없이 건너뛰고 로그에 한 번).
    public static func isRemoteAppleCopy(types: [String]) -> Bool {
        return types.contains("com.apple.is-remote-clipboard")
    }

    /// 파일 복사. Windows 는 CF_HDROP 만 올라오므로 아무것도 보내지 않는다. Finder 는 파일 URL 옆에
    /// 파일 이름을 글로(그리고 아이콘 그림을) 같이 올리므로, 이걸 먼저 보지 않으면 Mac 만 파일
    /// 이름을 보내게 된다.
    public static func isFileCopy(types: [String]) -> Bool {
        return types.contains("public.file-url") || types.contains("NSFilenamesPboardType")
    }

    // MARK: - 기기 이름과 경로 (spec §4.10, §9.4)

    /// Storage 경로에 쓸 이름. 호스트 이름에 무엇이 들어 있을지 모르므로 좁게 받는다.
    /// UTF-16 단위마다 [A-Za-z0-9-_] 는 그대로, 나머지는 '_'. 비면 "pc", 48 자를 넘으면 앞 48 자.
    /// 기기마다 파일 하나를 덮어쓰므로 "파일 수가 기기 수로 묶여서 청소할 것이 아예 생기지 않는다".
    public static func slug(_ name: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(name.utf16.count)
        for u in name.utf16 {
            switch u {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F:
                out.append(UInt8(u))
            default:
                out.append(0x5F)
            }
        }
        if out.isEmpty { return "pc" }
        if out.count > slugMaxLength { out = Array(out[0..<slugMaxLength]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// 행의 device 칸에 들어가는 이 Mac 의 이름. 되울림 방지가 이 이름을 정확히(대소문자 구분)
    /// 비교하므로 **계정 안에서 기기마다 달라야 하고, 실행 중에는 바뀌지 않아야 한다**. 같은
    /// 이름의 두 기기는 서로의 것을 받지 않고 Storage 파일 하나를 나눠 쓴다.
    ///
    ///   host      : LocalHostName (예 "Hongs-MacBook-Pro"), 없으면 ComputerName, 그것도 없으면 "Mac"
    ///   machineId : IOPlatformUUID (없으면 nil)
    ///   결과      : "<host>-mac-<SHA-256(machineId) 앞 6 hex>" (machineId 가 없으면 "<host>-mac")
    ///
    /// 꼬리를 붙이는 이유: LocalHostName 은 같은 네트워크 안에서만 겹치지 않는다 - 집과 회사의
    /// MacBook Pro 둘이 다 "Hongs-MacBook-Pro" 인 것은 흔하다. 기계마다 다른 꼬리로 그걸 가른다.
    /// 소문자 "mac" 과 hex 꼬리는 Windows 이름(GetComputerNameW 의 NetBIOS 이름: 15 자 이하, 대문자)과도
    /// 겹치지 않게 한다. 사람이 읽는 이름이라 앞부분은 호스트 이름 그대로 둔다.
    /// 길이는 서버 제약(64 자, Postgres char_length = 코드 포인트)에 맞춰 호스트 쪽을 자른다.
    public static func deviceName(host: String?, machineId: String?) -> String {
        let trimmed = (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 제어문자는 로그 한 줄과 상태 줄을 깨므로 뺀다 (LocalHostName 에는 원래 없다).
        var cleaned = String.UnicodeScalarView()
        for u in trimmed.unicodeScalars where u.value >= 0x20 && u.value != 0x7F {
            cleaned.append(u)
        }
        var h = String(cleaned)
        if h.isEmpty { h = "Mac" }

        var suffix = "-mac"
        let m = (machineId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty {
            suffix += "-" + String(sha256Hex(Data(m.utf8)).prefix(6))
        }
        let room = deviceMaxLength - suffix.unicodeScalars.count
        if h.unicodeScalars.count > room {
            var cut = String.UnicodeScalarView()
            for u in h.unicodeScalars.prefix(max(0, room)) {
                cut.append(u)
            }
            h = String(cut)
        }
        return h + suffix
    }

    /// "<user_id>/<slug>.png" - user_id 는 Supabase 가 준 소문자 UUID 를 그대로 쓴다.
    public static func storagePath(userId: String, slug: String) -> String {
        return "\(userId)/\(slug).png"
    }

    // MARK: - JSON (spec §2.4)

    /// Windows JsonEscape 와 같은 바이트 (UTF-8 바이트 단위): " -> \", \ -> \\, LF -> \n, CR -> \r,
    /// TAB -> \t, 그 밖의 0x20 미만은 \u00XX (대문자 hex). 0x7F 와 0x80 이상은 그대로.
    /// 클립보드 텍스트는 사람이 복사한 아무 문자열이다. 제어문자를 그대로 실으면 본문이 깨진 JSON 이
    /// 되고, 서버는 그걸 "잘못된 요청" 으로만 말해 준다.
    public static func jsonEscape(_ bytes: Data) -> Data {
        let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
        var o = [UInt8]()
        o.reserveCapacity(bytes.count + 16)
        for c in bytes {
            switch c {
            case 0x22: o += [0x5C, 0x22]
            case 0x5C: o += [0x5C, 0x5C]
            case 0x0A: o += [0x5C, 0x6E]
            case 0x0D: o += [0x5C, 0x72]
            case 0x09: o += [0x5C, 0x74]
            default:
                if c < 0x20 {
                    o += [0x5C, 0x75, 0x30, 0x30, hex[Int(c >> 4)], hex[Int(c & 0x0F)]]
                } else {
                    o.append(c)
                }
            }
        }
        return Data(o)
    }

    /// B. 글 행: {"device":"<이름>","kind":"text","body":"<글>","bytes":<n>}. bytes = 선 위의 UTF-8 길이.
    /// user_id 는 보내지 않는다 - 서버가 auth.uid() 로 채운다 ("틀릴 수 있는 자리를 하나 없앤다").
    public static func textRowBody(device: String, wire: Data) -> Data {
        var d = Data("{\"device\":\"".utf8)
        d.append(jsonEscape(Data(device.utf8)))
        d.append(Data("\",\"kind\":\"text\",\"body\":\"".utf8))
        d.append(jsonEscape(wire))
        d.append(Data("\",\"bytes\":\(wire.count)}".utf8))
        return d
    }

    /// B. 그림 행: {"device":"<이름>","kind":"image","storage_path":"<uid>/<slug>.png","bytes":<n>}.
    /// 그림 파일을 행보다 먼저 올린다 - 행이 없는 파일을 가리키는 일이 없게.
    public static func imageRowBody(device: String, storagePath: String, bytes: Int) -> Data {
        var d = Data("{\"device\":\"".utf8)
        d.append(jsonEscape(Data(device.utf8)))
        d.append(Data("\",\"kind\":\"image\",\"storage_path\":\"".utf8))
        d.append(jsonEscape(Data(storagePath.utf8)))
        d.append(Data("\",\"bytes\":\(max(0, bytes))}".utf8))
        return d
    }

    /// C. {"p_keep_id":<id>} - 이 계정의 그보다 오래된 행을 지우는 RPC 의 본문.
    public static func pruneBody(keepId: Int64) -> Data {
        return Data("{\"p_keep_id\":\(keepId)}".utf8)
    }

    /// B 의 응답 [{"id":N}] 에서 N. 없거나 0 이하면 0 (= "삽입은 됐는데 id 를 읽지 못했다").
    public static func parseInsertedId(_ body: Data) -> Int64 {
        guard let o = firstObject(body), let id = int64(o["id"]), id > 0 else { return 0 }
        return id
    }

    /// D 의 응답 한 행. id == 0 이면 행이 없다 (오류가 아니다 - "아직 아무도 아무것도 복사하지 않았다").
    public struct RemoteItem: Equatable {
        public var id: Int64
        public var device: String
        public var isImage: Bool
        /// kind=image 일 때만 읽는다.
        public var path: String
        /// 올린 쪽이 적은 크기. 믿지는 않는다 - 받기 전에 거르는 데만 쓴다. 없으면 0.
        public var bytes: Int64
        public init(id: Int64 = 0, device: String = "", isImage: Bool = false, path: String = "", bytes: Int64 = 0) {
            self.id = id
            self.device = device
            self.isImage = isImage
            self.path = path
            self.bytes = bytes
        }
    }

    /// D. `[]` 또는 `[{"id":..,"device":..,"kind":..,"storage_path":..,"bytes":..}]`.
    /// id 가 없거나 0 이하면 행 없음. kind == "image" 만 그림이고 나머지는 글이다.
    public static func parseNewest(_ body: Data) -> RemoteItem {
        guard let o = firstObject(body), let id = int64(o["id"]), id > 0 else { return RemoteItem() }
        let isImage = (o["kind"] as? String) == "image"
        return RemoteItem(id: id,
                          device: (o["device"] as? String) ?? "",
                          isImage: isImage,
                          path: isImage ? ((o["storage_path"] as? String) ?? "") : "",
                          bytes: int64(o["bytes"]) ?? 0)
    }

    /// E. `[{"body":"..."}]` 의 본문 UTF-8. `[]`(그 사이에 행이 정리됐다)이나 null 이면 빈 값 -
    /// "보낸 쪽이 더 새 것을 올리고 지난 행을 정리한 것이고, 오류가 아니다". 잘린 응답은 값이 아니다.
    /// \b \f \/ \uXXXX 와 서러게이트 쌍은 JSONSerialization 이 푼다 (Postgres 는 0x08 과 0x0C 를
    /// 짧은 꼴로 적는다 - 그걸 못 풀면 쪽 나눔이 든 글이 받는 PC 에서 'f' 로 찍힌다).
    public static func parseBody(_ body: Data) -> Data {
        guard let o = firstObject(body), let s = o["body"] as? String else { return Data() }
        return Data(s.utf8)
    }

    // MARK: - HTTP 문구 (spec §2.4)

    /// 응답 본문의 앞 160 바이트를 (잘린 UTF-8 은 U+FFFD 로) 글로.
    public static func errorExcerpt(_ body: Data) -> String {
        return String(decoding: body.prefix(errorExcerptBytes), as: UTF8.self)
    }

    /// "<what> [<status>] <앞 160 바이트>" (예: "조회 거절 [401] {...}").
    public static func refusal(_ what: String, status: Int, body: Data) -> String {
        return "\(what) [\(status)] \(errorExcerpt(body))"
    }

    public static func is2xx(_ status: Int) -> Bool {
        return status >= 200 && status < 300
    }

    // MARK: - 크기 상한 (spec §2.2, §4.3, §4.6)

    /// cap 은 바이트, 0 = 상한 없음.
    public static func isOverCap(_ size: Int64, cap: Int) -> Bool {
        return cap > 0 && size > Int64(cap)
    }

    /// 글 본문 요청의 응답 상한. JSON 에 실려 오는 동안에는 본문이 원래보다 길다 - 제어문자
    /// 하나가 \u0001 여섯 글자가 되는 것이 가장 크게 불어나는 경우다.
    public static func bodyFetchCap(_ cap: Int) -> Int {
        return cap > 0 ? cap * 6 + 4096 : 0
    }

    /// 여기서 복사한 것이 상한보다 크다 (로그에는 적지 않는다).
    public static func overCapSendText(size: Int, cap: Int) -> String {
        return "\(size / 1024) KB 라 건너뜀 (상한 \(cap / 1024) KB)"
    }

    /// 받을 것이 상한보다 크다 (행의 bytes 로 받기 전에, 또는 받은 실제 크기로).
    public static func overCapReceiveText(size: Int64, cap: Int) -> String {
        return "\(size / 1024) KB 라 받지 않음 (상한 \(cap / 1024) KB)"
    }

    // MARK: - PNG (spec §4.7)

    public static func hasPngSignature(_ d: Data) -> Bool {
        return d.count >= pngSignature.count && d.prefix(pngSignature.count).elementsEqual(pngSignature)
    }

    /// IHDR 의 너비와 높이 (풀지 않고 머리말만 읽는다). 서명 뒤 첫 덩이가 IHDR 이 아니면 nil.
    public static func pngDimensions(_ d: Data) -> (width: UInt32, height: UInt32)? {
        guard d.count >= 24, hasPngSignature(d) else { return nil }
        let b = [UInt8](d.prefix(24))
        guard b[12] == 0x49, b[13] == 0x48, b[14] == 0x44, b[15] == 0x52 else { return nil }   // "IHDR"
        func be32(_ i: Int) -> UInt32 {
            var v: UInt32 = 0
            for k in 0..<4 {
                v = (v << 8) | UInt32(b[i + k])
            }
            return v
        }
        return (width: be32(16), height: be32(20))
    }

    /// 받은 그림을 풀기 전에 본다 (Windows PngToBitmap 의 앞부분). 괜찮으면 nil, 아니면 사유.
    ///
    /// 서명을 먼저 본다. 이 바이트는 서버에서 온 것이고, 서버의 행은 이 계정의 세션을 가진 누구나
    /// 쓸 수 있다. 서명을 안 보면 디코더가 아는 모든 형식(TIFF/GIF/JPEG/BMP/ICO)이 풀리고, 풀리기만
    /// 하면 PNG 가 아닌 것이 "PNG" 라는 이름으로 붙여넣기판에 올라간다.
    public static func receivedPngProblem(_ d: Data) -> String? {
        guard hasPngSignature(d) else { return "받은 것이 PNG 가 아니다" }
        guard let dim = pngDimensions(d) else { return "PNG 를 그림으로 풀지 못했다" }
        let px = UInt64(dim.width) * UInt64(dim.height)
        if px == 0 || px > maxPixels { return "그림의 화소 수가 너무 많거나 0 이라 풀지 않았다" }
        return nil
    }

    // MARK: - 조회 간격 (spec §4.4)

    /// 다음 조회까지 기다릴 ms. idleMs = 시스템 전체에서 마지막 키보드·마우스 입력 뒤로 지난 ms.
    /// 복사하면 일꾼이 바로 깨므로 올리기는 이 간격을 기다리지 않는다.
    public static func pollIntervalMs(idleMs: UInt64, pollFails: Int, pollRefused: Bool) -> UInt64 {
        var every = idleMs > idleAfterMs ? pollIdleMs : pollBusyMs
        if pollFails >= 3 && pollRefused {
            every = backoffLongMs
        } else if pollFails >= 2 && every < backoffMidMs {
            every = backoffMidMs
        }
        return every
    }

    // MARK: - 상태 줄 (spec §3.1, §3.2)

    /// lastMsg 에 넣기 전에 자른다 (200 UTF-16 단위, 서러게이트 쌍은 쪼개지 않는다).
    public static func capStatus(_ s: String) -> String {
        return TextSanitize.capUTF16(s, statusMaxUTF16)
    }

    /// 간단 창의 클립보드 타일 아래 한 줄 (Windows SimpleRefresh, 256 자 버퍼에 _TRUNCATE).
    /// 구분자는 공백 둘, U+00B7, 공백 둘이다.
    public static func statusLine(running: Bool, hasAccount: Bool, lastOk: Bool, lastMsg: String,
                                  sent: Int, received: Int) -> String {
        let s: String
        if !running {
            s = hasAccount ? "꺼져 있어요" : "계정으로 로그인하면 쓸 수 있어요"
        } else if lastMsg.isEmpty {
            s = "기다리는 중  \u{00B7}  보냄 \(sent) / 받음 \(received)"
        } else {
            s = "\(lastOk ? "" : "안 됨: ")\(lastMsg)  \u{00B7}  보냄 \(sent) / 받음 \(received)"
        }
        return TextSanitize.capUTF16(s, 255)
    }

    // MARK: - private

    /// 배열이면 첫 원소, 객체면 그 자체. 그 밖(빈 배열, null, 깨진 JSON)은 nil.
    private static func firstObject(_ body: Data) -> [String: Any]? {
        guard !body.isEmpty, let obj = try? JSONSerialization.jsonObject(with: body, options: []) else {
            return nil
        }
        if let arr = obj as? [Any] {
            return arr.first as? [String: Any]
        }
        return obj as? [String: Any]
    }

    /// JSON 수 -> Int64. 수가 아니면(문자열, null) nil.
    private static func int64(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber else { return nil }
        return n.int64Value
    }

    private static func sha256Hex(_ d: Data) -> String {
        let hex: [Character] = Array("0123456789abcdef")
        var s = ""
        for b in SHA256.hash(data: d) {
            s.append(hex[Int(b >> 4)])
            s.append(hex[Int(b & 0x0F)])
        }
        return s
    }
}
