// SSBeaconApp.swift - SmartScreen 컴패니언 v2
//
// v1(광고 방식)의 한계: iOS는 백그라운드/잠금 상태에서 BLE '광고'를 10~50초에 한 번으로 조인다.
//   → 자리를 떠도 PC가 10~50초 뒤에야 알아챔.
// v2(연결 방식): 역할을 뒤집는다.
//   PC = GATT 서버(주변장치), 이 앱 = central.
//   PC가 TICK 알림을 보낼 때마다 iOS가 (잠금 상태에서도) 앱을 깨우고,
//   앱은 연결 RSSI를 읽어 PC에 써 준다 → PC는 ~1Hz로 RSSI를 받는다.
//   연결된 BLE 링크는 광고와 달리 백그라운드 스로틀을 받지 않는다.
//
// 배터리: PC가 "사용자 입력이 멈췄을 때"만 TICK을 보낸다(입력 중이면 앱을 아예 깨우지 않음).
//
// 필수 Xcode 설정 (README.md 참고):
//  - Background Modes > "Uses Bluetooth LE accessories"  (bluetooth-central)
//  - Privacy - Bluetooth Always Usage Description

import SwiftUI
import CoreBluetooth

// PC(ble_gatt.h)와 반드시 동일해야 하는 UUID
let kServiceUUID = CBUUID(string: "7A1C0010-5353-4243-8E2B-9F3D5A6C7E10")
let kTickUUID    = CBUUID(string: "7A1C0011-5353-4243-8E2B-9F3D5A6C7E10")  // notify: PC -> 폰
let kRssiUUID    = CBUUID(string: "7A1C0012-5353-4243-8E2B-9F3D5A6C7E10")  // write : 폰 -> PC
let kRestoreId   = "com.smartscreen.ssbeacon.central"

final class LinkManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var stateText = "초기화 중"
    @Published var isConnected = false
    @Published var lastRssi = 0
    @Published var reportCount = 0

    private var central: CBCentralManager!
    private var pc: CBPeripheral?
    private var rssiChar: CBCharacteristic?
    private var seq: UInt8 = 0
    private var discoverTries = 0

    override init() {
        super.init()
        // RestoreIdentifier: 앱이 종료돼도 iOS가 연결/알림 이벤트로 다시 깨워준다
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: kRestoreId])
    }

    private func startScanOrConnect() {
        guard central.state == .poweredOn else { return }
        if let p = pc, p.state == .connected { return }

        // 이미 연결돼 있는(다른 앱이 띄운) 기기가 있으면 재사용
        let known = central.retrieveConnectedPeripherals(withServices: [kServiceUUID])
        if let p = known.first {
            pc = p; p.delegate = self
            central.connect(p, options: nil)
            stateText = "PC에 연결 중"
        }
        // 이전 PC로의 재연결 대기와 별개로 스캔도 계속 돌린다.
        // 스캔을 멈추면 다른 PC(노트북 등)로 옮겼을 때 영영 찾지 못한다.
        // 백그라운드 스캔은 서비스 UUID를 명시해야 동작한다
        if !central.isScanning {
            central.scanForPeripherals(withServices: [kServiceUUID], options: nil)
            if pc == nil { stateText = "PC 찾는 중" }
        }
    }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:    stateText = "Bluetooth 켜짐"; startScanOrConnect()
        case .poweredOff:   stateText = "Bluetooth 꺼짐"; isConnected = false
        case .unauthorized: stateText = "Bluetooth 권한 없음 (설정에서 허용)"
        case .unsupported:  stateText = "BLE 미지원 기기"
        default:            stateText = "대기 중"
        }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS가 앱을 복원: 이전 연결을 이어받는다
        if let list = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = list.first {
            pc = p
            p.delegate = self
            isConnected = (p.state == .connected)
            stateText = isConnected ? "연결 복원됨" : "연결 복원 중"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 다른 PC를 찾았으면 이전 PC로의 대기 중인 연결은 취소하고 갈아탄다
        if let old = pc, old.identifier != p.identifier {
            c.cancelPeripheralConnection(old)
        }
        c.stopScan()
        pc = p
        p.delegate = self
        c.connect(p, options: nil)
        stateText = "PC에 연결 중"
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        isConnected = true
        stateText = "연결됨"
        discoverTries = 0
        // nil = 전체 탐색. UUID 필터를 주면 iOS 캐시 때문에 실제로 있는 서비스를 놓치기도 한다
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        isConnected = false
        rssiChar = nil
        stateText = "연결 끊김 - 재연결 대기"
        // 타임아웃 없는 connect(): 범위 안으로 돌아오면 iOS가 백그라운드에서도 자동 재연결
        c.connect(p, options: nil)
        startScanOrConnect()   // 동시에 스캔도 재개 (다른 PC로 옮겼을 수 있음)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        isConnected = false
        stateText = "연결 실패 - 재시도"
        c.connect(p, options: nil)
        startScanOrConnect()
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let svc = p.services?.first(where: { $0.uuid == kServiceUUID }) {
            discoverTries = 0
            p.discoverCharacteristics([kTickUUID, kRssiUUID], for: svc)
            return
        }
        let n = p.services?.count ?? 0
        discoverTries += 1
        if discoverTries <= 3 {
            stateText = "서비스 찾는 중 (\(n)개 발견, 재시도 \(discoverTries))"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard self != nil, p.state == .connected else { return }
                p.discoverServices(nil)
            }
        } else {
            // 끊었다 다시 붙으면 iOS가 GATT 목록을 다시 읽는다
            stateText = "서비스 없음 (\(n)개) - 재연결"
            discoverTries = 0
            central.cancelPeripheralConnection(p)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == kTickUUID { p.setNotifyValue(true, for: ch) }
            if ch.uuid == kRssiUUID { rssiChar = ch }
        }
        stateText = "보고 중"
    }

    // PC가 보낸 TICK → 앱이 깨어남 → RSSI 측정 요청
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == kTickUUID else { return }
        if let d = ch.value, d.count >= 1 { seq = d[0] }
        p.readRSSI()
    }

    // RSSI 측정 완료 → PC로 전송
    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, let ch = rssiChar else { return }
        let v = RSSI.intValue
        guard v < 0, v > -127 else { return }   // 127 = 측정 불가
        var bytes = [UInt8(bitPattern: Int8(clamping: v)), seq]
        let data = Data(bytes: &bytes, count: 2)
        // withoutResponse: 왕복 대기 없이 빠르게. 미지원이면 withResponse로 대체
        let type: CBCharacteristicWriteType =
            p.canSendWriteWithoutResponse && ch.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        p.writeValue(data, for: ch, type: type)

        DispatchQueue.main.async {
            self.lastRssi = v
            self.reportCount += 1
        }
    }
}

struct ContentView: View {
    @StateObject private var link = LinkManager()

    var body: some View {
        VStack(spacing: 20) {
            Text("SmartScreen Link").font(.title2).bold()
            Circle()
                .fill(link.isConnected ? Color.green : Color.gray)
                .frame(width: 80, height: 80)
            Text(link.stateText).font(.headline)
            if link.isConnected {
                Text("\(link.lastRssi) dBm").font(.system(.title3, design: .monospaced))
                Text("보고 \(link.reportCount)회").font(.caption).foregroundColor(.secondary)
            }
            Text("앱을 위로 밀어 종료하지 마세요.\n홈으로 나가거나 잠가도 연결은 유지됩니다.")
                .font(.footnote).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

@main
struct SSBeaconApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
