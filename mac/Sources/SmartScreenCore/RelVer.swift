import Foundation

/// "a.b.c" 버전. client/relver.h 와 같은 규칙이다 - SmartScreen(Windows), Publish.exe,
/// 이 앱이 같은 값을 같은 답으로 판정해야 한다. 문자열 비교가 아니라 숫자 비교라서
/// "1.10.0" 이 "1.9.0" 보다 새 버전이다.
public struct SemVer: Comparable, Equatable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// "1.2.3" 만 받는다: 숫자와 점 두 개, 각 자리 1~9 글자. 앞뒤 공백, 부호,
    /// 접미사("1.2.3-beta"), 두 자리("1.2") 는 거절한다. 서버의 check
    /// (^[0-9]+\.[0-9]+\.[0-9]+$) 와 같은 판정이어야 한다.
    public init?(_ s: String) {
        let u = Array(s.utf8)
        if u.isEmpty || u.count > 29 { return nil }
        var part = [0, 0, 0]
        var idx = 0
        var digits = 0
        for c in u {
            if c >= 48 && c <= 57 {
                digits += 1
                if digits > 9 { return nil }
                part[idx] = part[idx] * 10 + Int(c - 48)
            } else if c == 46 {  // '.'
                if digits == 0 || idx == 2 { return nil }
                idx += 1
                digits = 0
            } else {
                return nil
            }
        }
        if idx != 2 || digits == 0 { return nil }
        major = part[0]; minor = part[1]; patch = part[2]
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (x: SemVer, y: SemVer) -> Bool {
        if x.major != y.major { return x.major < y.major }
        if x.minor != y.minor { return x.minor < y.minor }
        return x.patch < y.patch
    }
}
