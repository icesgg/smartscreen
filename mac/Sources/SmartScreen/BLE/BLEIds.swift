import Foundation
import CoreBluetooth
import SmartScreenCore

/// SmartScreen 의 BLE UUID 와 BLE 파일들이 같이 쓰는 작은 도구들.
///
/// UUID 는 iOS 앱(ios/SSBeacon 의 kServiceUUID ... kTokenUUID)과 Windows 판(client/ble_gatt.h)과
/// 바이트 단위로 같아야 한다. 하나라도 어긋나면 폰과 PC 가 서로를 못 찾는다.
enum BLEIds {
    // ---- PC 가 올리는 GATT 서비스 (v2 근접 감지) ----
    // Mac 은 이 UUID 만 광고한다. 7A1C0020 을 광고하면 Windows PC 들이 Mac 을 폰 후보로 잡는다.
    static let pcService = CBUUID(string: "7A1C0010-5353-4243-8E2B-9F3D5A6C7E10")
    /// notify: PC -> 폰 (seq 1바이트)
    static let tick = CBUUID(string: "7A1C0011-5353-4243-8E2B-9F3D5A6C7E10")
    /// write : 폰 -> PC (int8 rssi, uint8 seq)
    static let rssi = CBUUID(string: "7A1C0012-5353-4243-8E2B-9F3D5A6C7E10")

    // ---- 폰이 올리는 신원 서비스 ----
    // 위의 서비스는 PC가, 이쪽은 폰이 올린다 - 일부러 다른 UUID를 쓴다.
    // 같은 값이면 폰 앱의 central 스캔이 옆자리 폰을 PC로 착각해 붙으려 든다.
    // 잠금 상태 광고에서는 이 UUID 가 Apple overflow 영역으로만 남는다.
    static let identService = CBUUID(string: "7A1C0020-5353-4243-8E2B-9F3D5A6C7E10")
    /// read : PC <- 폰 (16바이트 토큰)
    static let identToken = CBUUID(string: "7A1C0021-5353-4243-8E2B-9F3D5A6C7E10")

    // ---- 이 아래는 BLE 파일들끼리만 쓰는 것 ----

    private static let queueKey = DispatchSpecificKey<Int>()

    /// 광고 스캐너(CBCentralManager)와 GATT 서버(CBPeripheralManager)가 같이 쓰는 직렬 큐.
    /// 두 관리자의 상태는 이 큐 안에서만 바뀐다. 판정 스레드와 UI 는 잠금으로 보호된
    /// 사본(snapshot)만 읽는다. 이 큐에서는 절대 기다리지 않는다 - 연결 한 번이 최악 10초라
    /// 기다리면 그동안 광고 콜백이 멈춘다 (Windows: "스캔 콜백 스레드에서 하면 안 된다").
    static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "com.icesgg.smartscreen.ble", qos: .userInitiated)
        q.setSpecific(key: queueKey, value: 1)
        return q
    }()

    /// 큐 위에서 동기로 실행한다 (이미 큐 위라면 그 자리에서). 메인이 부르는 start/stop 처럼
    /// Windows 에서 동기였던 호출을 같은 의미로 유지하려고 쓴다.
    /// 이 큐는 메인을 기다리는 일이 없으므로 메인에서 불러도 교착되지 않는다.
    static func sync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
            return
        }
        queue.sync(execute: work)
    }

    /// 로그에 쓰는 기기 표시. CoreBluetooth 는 48비트 주소를 주지 않으므로
    /// CBPeripheral.identifier 의 앞 12 hex (대문자, 대시 없음) 를 쓴다 -
    /// Windows 의 "%012llX" 와 줄 모양과 grep 패턴이 같게 남는다.
    static func shortId(_ id: UUID) -> String {
        let s = id.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        return String(s.prefix(12))
    }

    /// winrt::to_hstring(guid) 모양: "{7a1c0020-5353-4243-8e2b-9f3d5a6c7e10}" (소문자, 중괄호).
    /// 16/32비트 UUID 는 Bluetooth 기본 UUID 로 늘려서 쓴다 (Windows 는 늘 128비트로 보여 준다).
    static func braced(_ u: CBUUID) -> String {
        let d = [UInt8](u.data)
        let base: [UInt8] = [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB]
        let full: [UInt8]
        switch d.count {
        case 2: full = [0x00, 0x00, d[0], d[1]] + base
        case 4: full = d + base
        case 16: full = d
        default: return "{" + u.uuidString.lowercased() + "}"
        }
        let h = Array(Hex.lower(Data(full)))
        guard h.count == 32 else { return "{" + u.uuidString.lowercased() + "}" }
        return "{" + String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-"
            + String(h[16..<20]) + "-" + String(h[20..<32]) + "}"
    }

    /// "%04X"
    static func hex4(_ v: Int) -> String {
        let s = String(v & 0xFFFF, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - s.count)) + s
    }

    /// RSSI 가 실제 측정값인지. Apple 은 127 을 "측정 불가" 로 주고 (Windows 는 -127),
    /// 0 이상은 물리적으로 나올 수 없다. 둘 다 필터에 넣지 않는다.
    static func validRssi(_ v: Int) -> Bool {
        return v < 0 && v > -127
    }

    /// now - then (ms). 다른 스레드가 now 를 잰 직후에 더 새 틱을 써 넣을 수 있으므로
    /// then > now 이면 0 이다 (UInt64 뺄셈이 음수가 되면 Swift 는 죽는다).
    static func elapsed(_ now: UInt64, since then: UInt64) -> UInt64 {
        return now > then ? now - then : 0
    }

    /// CSV 칸에 넣을 글자: 쉼표와 줄바꿈은 칸/줄을 깨므로 공백으로 바꾼다
    /// (tools/rssi-threshold.ps1 이 ',' 로 자르고 칸 번호로 읽는다).
    static func csvField(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        let space: Unicode.Scalar = " "
        for u in s.unicodeScalars {
            out.append((u == "," || u == "\n" || u == "\r") ? space : u)
        }
        return String(out)
    }

    static func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "?"
        }
    }

    /// 이 앱이 블루투스 권한을 거부당했는지 (시스템 설정에서 끔 / 관리 정책).
    static var authorizationDenied: Bool {
        let a = CBManager.authorization
        return a == .denied || a == .restricted
    }

    /// Windows GattCommunicationStatus 에 해당하는 분류 (로그의 why 문자열용).
    enum GattStatus {
        case unreachable      // 붙지 못했다 / 끊겼다
        case protocolError    // 그 밖의 ATT 오류
        case accessDenied     // 페어링(암호화) 요구
        case other            // Windows 의 "?"
    }

    static func classify(_ error: Error) -> GattStatus {
        if let e = error as? CBATTError {
            switch e.code {
            case .insufficientAuthentication, .insufficientEncryption,
                 .insufficientAuthorization, .insufficientEncryptionKeySize:
                return .accessDenied
            default:
                return .protocolError
            }
        }
        if let e = error as? CBError {
            switch e.code {
            case .connectionTimeout, .peripheralDisconnected, .connectionFailed,
                 .notConnected, .connectionLimitReached, .operationCancelled:
                return .unreachable
            case .encryptionTimedOut, .peerRemovedPairingInformation:
                return .accessDenied
            default:
                return .other
            }
        }
        return .other
    }

    /// ble_scan_log.csv / gatt_rssi_log.csv 를 붙여 쓰는 파일.
    /// Windows 는 "a,ccs=UTF-8" 로 열어 새 파일에만 BOM 을 쓴다 - 같게 한다.
    /// 줄마다 fflush 해서 다른 프로그램이 모니터링 중에도 읽을 수 있다.
    final class CsvLog {
        private var fp: UnsafeMutablePointer<FILE>?

        init?(path: String) {
            guard let f = fopen(path, "a") else { return nil }
            fp = f
            if fseeko(f, 0, SEEK_END) == 0 && ftello(f) == 0 {
                fputs("\u{FEFF}", f)
            }
        }

        func write(_ s: String) {
            guard let f = fp else { return }
            fputs(s, f)
            fflush(f)
        }

        func close() {
            if let f = fp {
                fclose(f)
                fp = nil
            }
        }

        deinit { close() }
    }
}
