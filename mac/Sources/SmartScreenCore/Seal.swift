import Foundation
import CryptoKit

/// DPAPI(CryptProtectData) 자리를 대신하는 순수 암호 부분. 키를 어디서 얻는지는 앱의 몫이다
/// (Net/SecretSeal.swift: IOPlatformUUID + uid + configDir/seal.salt).
///
/// config.ini 의 authRefresh 에는 Windows 처럼 "봉한 값의 표준 base64" 가 들어간다 - 그래서
/// 세션 시작(세 갈래 결과), 회전 -> 봉한 문자열 -> config 저장 흐름이 Windows 와 그대로 같다.
/// 다른 PC 에서 복사해 온 config.ini 의 값(또는 Windows 의 DPAPI 값)은 열리지 않고,
/// 그건 "저장된 로그인을 풀지 못했다" 로 이어진다 - Windows 와 같은 길이다.
///
/// Keychain 을 쓰지 않는 이유: 임시(ad-hoc) 서명 빌드는 업데이트마다 코드 해시가 바뀌고,
/// 그러면 Keychain 이 업데이트 뒤마다 묻거나 조용히 거절해 사용자가 로그아웃된다.
public enum Seal {
    /// AES-GCM 으로 UTF-8 평문을 봉하고 SealedBox.combined (nonce 12 + 암호문 + tag 16) 의
    /// 표준 base64 를 돌려준다. 빈 평문은 봉하지 않는다 (Windows ProtectSecret 도 거절한다).
    public static func seal(_ plain: String, key: Data) -> String? {
        if plain.isEmpty { return nil }
        let sk = SymmetricKey(data: key)
        guard let box = try? AES.GCM.seal(Data(plain.utf8), using: sk),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    /// seal 의 반대. 빈 값, base64 가 아닌 값, 짧거나 변조된 값, 다른 키 -> nil.
    /// base64 는 Windows Base64Decode 와 같이 읽는다: 표준 알파벳, '=' CR LF 는 어디서든
    /// 건너뛰고, 그 밖의 글자(ASCII 가 아닌 글자 포함)는 거절, 길이·패딩은 따지지 않는다.
    public static func open(_ sealed: String, key: Data) -> String? {
        if sealed.isEmpty { return nil }
        guard let raw = base64Decode(sealed), !raw.isEmpty else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: raw) else { return nil }
        guard let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// SHA-256("SmartScreen seal v1" || machineId || "|" || uid || "|" || salt) -> 32바이트 키.
    /// machineId 와 문자열 조각은 UTF-8, uid 는 10진수 글자("501"), salt 는 원래 바이트.
    /// 이 바이트 배열을 바꾸면 이미 봉해 둔 authRefresh 가 열리지 않아 모두 로그아웃된다 -
    /// 바꾸려면 "v2" 로 올리고 옛 키로도 열어 봐야 한다.
    public static func deriveKey(machineId: String, uid: UInt32, salt: Data) -> Data {
        var h = SHA256()
        h.update(data: Data("SmartScreen seal v1".utf8))
        h.update(data: Data(machineId.utf8))
        h.update(data: Data("|".utf8))
        h.update(data: Data(String(uid).utf8))
        h.update(data: Data("|".utf8))
        h.update(data: salt)
        return Data(h.finalize())
    }

    // ---- private ----

    private static func base64Decode(_ s: String) -> Data? {
        var out = Data()
        var acc: UInt32 = 0
        var bits = 0
        for c in s.utf8 {
            if c == 0x3D || c == 0x0D || c == 0x0A { continue }   // '=' CR LF
            guard let d = sextet(c) else { return nil }
            acc = (acc << 6) | UInt32(d)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    private static func sextet(_ c: UInt8) -> UInt8? {
        if c >= 0x41 && c <= 0x5A { return c - 0x41 }        // A-Z
        if c >= 0x61 && c <= 0x7A { return c - 0x61 + 26 }   // a-z
        if c >= 0x30 && c <= 0x39 { return c - 0x30 + 52 }   // 0-9
        if c == 0x2B { return 62 }                            // '+'
        if c == 0x2F { return 63 }                            // '/'
        return nil
    }
}
