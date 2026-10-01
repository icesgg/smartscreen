import Foundation
import CryptoKit
import Darwin

/// 서버, 브라우저, 파일 이름에서 온 글자를 한 줄짜리 자리(상태 줄, 알림, events.log)에
/// 넣기 전에 거르는 함수들. 길이는 UTF-16 단위로 센다 - Windows(wchar_t)와 같은 곳에서
/// 잘려야 같은 글이 나온다.
public enum TextSanitize {
    /// Windows CapErrorText (auth.cpp): 160 UTF-16 단위로 자르고, 서러게이트 앞짝에서
    /// 끊기면 그것도 버리고 (반쪽 글자), 0x20 미만은 빈칸으로.
    ///
    /// 예전 Windows 는 서버가 준 문자열을 통째로 돌려줬고, 받는 쪽 하나가 고정 버퍼에 찍다가
    /// 234자쯤부터 프로세스가 끝났다. Mac 에는 그런 버퍼가 없지만 같은 글이 나와야 하므로
    /// 상한과 제어문자 처리는 그대로 둔다. 줄바꿈이 섞이면 남이 로그에 줄을 지어낼 수 있다.
    public static func capErrorText(_ s: String) -> String {
        let cut = capUTF16(s, 160)
        let space: Unicode.Scalar = " "
        var out = String.UnicodeScalarView()
        for u in cut.unicodeScalars {
            out.append(u.value < 0x20 ? space : u)
        }
        return String(out)
    }

    /// Windows OneLine (supabase.cpp): 로그 한 줄에 넣을 수 있게 max UTF-16 단위로 자르고
    /// 0x20 미만과 0x7F 를 '?' 로 바꾼다. 기본 48, 저장소 경로는 110.
    /// (Windows 는 서러게이트 쌍 가운데서 자를 수 있다. 여기서는 반쪽 글자를 버린다.)
    public static func oneLine(_ s: String, max: Int = 48) -> String {
        let cut = capUTF16(s, max)
        let q: Unicode.Scalar = "?"
        var out = String.UnicodeScalarView()
        for u in cut.unicodeScalars {
            out.append((u.value < 0x20 || u.value == 0x7F) ? q : u)
        }
        return String(out)
    }

    /// 앞에서부터 max UTF-16 단위까지만 남긴다. 서러게이트 쌍(2 단위) 하나가 경계에 걸리면
    /// 그 글자는 통째로 뺀다 - 반쪽 글자는 남기지 않는다. 다른 것은 바꾸지 않는다.
    public static func capUTF16(_ s: String, _ max: Int) -> String {
        if max <= 0 { return "" }
        if s.utf16.count <= max { return s }
        var out = String.UnicodeScalarView()
        var used = 0
        for u in s.unicodeScalars {
            let w = u.value > 0xFFFF ? 2 : 1
            if used + w > max { break }
            out.append(u)
            used += w
        }
        return String(out)
    }
}

/// SHA-256 을 소문자 hex 로 (Windows Sha256Bytes / Sha256File). 대시보드가 올릴 때 계산하는
/// 값과 같은 모양이다 - 기업 콘텐츠와 업데이트 파일 검증이 이것과 비교한다.
public enum SHA256Hex {
    /// lowercase hex of SHA-256(d)
    public static func of(_ d: Data) -> String {
        return Hex.lower(Data(SHA256.hash(data: d)))
    }

    /// 파일을 64 KiB 씩 읽으며 해시한다 (200 MB 짜리 동영상도 메모리에 다 올리지 않는다).
    /// 읽기 오류면 nil - 일부만 읽은 해시를 돌려주면 잘린 파일이 "맞다" 로 보일 수 있다.
    public static func ofFile(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return nil }
        defer { _ = close(fd) }
        var hasher = SHA256()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n: Int = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                return read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<n]))
                }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return Hex.lower(Data(hasher.finalize()))
    }
}
