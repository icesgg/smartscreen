import Foundation

/// 바이트 <-> hex 문자열.
///
/// 폰 토큰은 16바이트를 32자리 대문자 hex 로 보이고 저장한다 ("%02X" - 폰 앱의 `기기 토큰`,
/// Supabase device_tokens 의 값과 같은 모양). SHA-256 은 소문자 (대시보드가 계산하는 모양).
public enum Hex {
    private static let upperDigits: [UInt8] = Array("0123456789ABCDEF".utf8)
    private static let lowerDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// "%02X" per byte
    public static func upper(_ d: Data) -> String {
        return encode(d, upperDigits)
    }

    /// "%02x" per byte
    public static func lower(_ d: Data) -> String {
        return encode(d, lowerDigits)
    }

    /// even length, hex digits only (either case). "" -> empty Data. Anything else -> nil.
    public static func decode(_ s: String) -> Data? {
        let u = Array(s.utf8)
        if u.count % 2 != 0 { return nil }
        var out = Data(capacity: u.count / 2)
        var i = 0
        while i < u.count {
            guard let hi = nibble(u[i]), let lo = nibble(u[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func encode(_ d: Data, _ digits: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(d.count * 2)
        for b in d {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30          // 0-9
        case 0x41...0x46: return c - 0x41 + 10     // A-F
        case 0x61...0x66: return c - 0x61 + 10     // a-f
        default: return nil
        }
    }
}
