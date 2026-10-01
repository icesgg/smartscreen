import Foundation

/// Apple 백그라운드 광고의 overflow 영역 읽기 (client/ble_rssi.cpp 의 SingleOverflowBit).
///
/// iOS 앱이 백그라운드/잠금 상태에서 서비스 UUID 를 광고하면 UUID 는 광고에서 빠지고, 제조사
/// 데이터(회사 0x004C)에 `01` + 16바이트 비트필드로 남는다. UUID 마다 정해진 한 비트가 켜진다 -
/// 비트 번호는 UUID 의 해시라서 어느 폰이든 같다 (이 노트북의 Windows 는 우리 신원 서비스
/// 7A1C0020-... 에 대해 31 을 배웠다). 비트는 폰을 특정하지 못한다. 후보를 좁힐 뿐이고, 신원은
/// 붙어서 읽는 토큰이 정한다.
///
/// CoreBluetooth 의 CBAdvertisementDataManufacturerDataKey 는 앞에 회사 id 2바이트(little-endian)를
/// **포함한다** (Windows 의 ManufacturerData.Data() 는 뺀다). 그래서 모양은 정확히 19바이트:
/// `4C 00 01` + 16바이트. 비트 번호는 Windows 와 같게 센다 (16바이트 중 b 번째 바이트의 k 번째
/// 비트, 아래 비트부터 = b*8+k) - 두 판이 config.ini 의 phoneOvfBit 를 같은 뜻으로 읽어야 한다.
public enum AppleOverflow {
    /// 제조사 데이터 길이: 회사 id 2 + 종류 1 + 비트필드 16.
    public static let length = 19

    /// overflow 모양이면 켜진 비트 번호 전부 (작은 것부터. 하나도 없으면 빈 배열), 아니면 nil.
    /// 진단용 (--probe-scan 이 기기마다 켜진 비트를 보인다).
    /// 주변에 훨씬 흔한 24바이트짜리 `01 09 20 22 ...` 메시지는 길이에서 걸러진다
    /// (Windows 실측: 주소 4048개 중 이 모양은 13개뿐이었다).
    public static func bits(_ manufacturerData: [UInt8]) -> [Int]? {
        guard isOverflowShape(manufacturerData) else { return nil }
        var out: [Int] = []
        for b in 0..<16 {
            let v = manufacturerData[3 + b]
            for k in 0..<8 where (v >> UInt8(k)) & 1 != 0 {
                out.append(b * 8 + k)
            }
        }
        return out
    }

    /// 딱 한 비트만 켜져 있으면 그 번호, 아니면 -1 (Windows SingleOverflowBit).
    /// 앱 하나가 서비스 UUID 하나를 광고하면 비트가 하나다. 광고마다 불리는 뜨거운 경로라 배열을
    /// 만들지 않는다.
    public static func singleBit(_ manufacturerData: [UInt8]) -> Int {
        guard isOverflowShape(manufacturerData) else { return -1 }
        var found = -1
        var n = 0
        for b in 0..<16 {
            let v = manufacturerData[3 + b]
            if v == 0 { continue }
            for k in 0..<8 where (v >> UInt8(k)) & 1 != 0 {
                if found < 0 { found = b * 8 + k }
                n += 1
            }
        }
        return n == 1 ? found : -1
    }

    /// 회사 id 가 Apple(0x004C)인지. 길이는 보지 않는다 (진단에서 Apple 광고를 세는 데 쓴다).
    public static func isApple(_ manufacturerData: [UInt8]) -> Bool {
        return manufacturerData.count >= 2 && manufacturerData[0] == 0x4C && manufacturerData[1] == 0x00
    }

    private static func isOverflowShape(_ d: [UInt8]) -> Bool {
        return d.count == length && d[0] == 0x4C && d[1] == 0x00 && d[2] == 0x01
    }
}
