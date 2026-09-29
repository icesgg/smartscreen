// SSBeaconApp.swift - SmartScreen 컴패니언
//
// PC 쪽 어댑터에 따라 두 경로가 있고, 이 앱은 둘 다 동시에 준비해 둔다.
//
//  [광고] 이 앱이 주변장치로 서비스 UUID를 광고 → PC가 스캔해서 RSSI를 읽는다.
//         PC는 스캔만 하면 되므로 어떤 USB 동글에서도 동작한다. 갱신은 수 초 간격.
//         아이폰은 앱 없이 잠기면 광고를 멈추므로, 이 앱이 계속 광고하는 게 핵심이다.
//         잠긴 상태 광고에는 이름도 UUID도 안 실려 주소만 남고, 그 주소는 주기적으로 바뀐다.
//         그래서 이 앱은 신원 서비스(kIdentUUID)를 올려 두고, PC가 central로 붙어
//         토큰을 한 번 읽어 내 폰임을 확정한다. Windows 쪽 IRK나 Phone Link 설정이 필요 없다.
//
//  [연결] PC가 GATT 서버가 되고 이 앱이 central로 붙는다. PC가 TICK을 보내면
//         iOS가 잠금 상태에서도 앱을 깨우고, 앱이 연결 RSSI를 PC에 써 준다. 1초 갱신.
//         단, PC 어댑터가 BLE 주변장치 역할을 지원해야 한다 (못 하는 동글이 많다).
//
// PC는 연결 경로가 살아 있으면 그쪽을, 아니면 광고 경로를 쓴다.
//
// 필수 Xcode 설정 (README.md 참고):
//  - Background Modes > "Uses Bluetooth LE accessories"     (bluetooth-central)
//  - Background Modes > "Acts as a Bluetooth LE accessory"  (bluetooth-peripheral)
//  - Privacy - Bluetooth Always Usage Description

import SwiftUI
import UIKit
import CoreBluetooth
import Security
import AuthenticationServices
import CryptoKit

// PC(ble_gatt.h)와 반드시 동일해야 하는 UUID
let kServiceUUID = CBUUID(string: "7A1C0010-5353-4243-8E2B-9F3D5A6C7E10")
let kTickUUID    = CBUUID(string: "7A1C0011-5353-4243-8E2B-9F3D5A6C7E10")  // notify: PC -> 폰
let kRssiUUID    = CBUUID(string: "7A1C0012-5353-4243-8E2B-9F3D5A6C7E10")  // write : 폰 -> PC

// 이 폰이 직접 올리는 신원 서비스. PC가 central로 붙어 토큰을 읽고 "내 폰"임을 확인한다.
// 위의 kServiceUUID(PC가 올리는 것)와 일부러 다른 UUID를 쓴다 - 같게 두면
// 이 앱의 central 스캔이 옆자리 폰을 PC로 착각해 붙으려 든다.
let kIdentUUID   = CBUUID(string: "7A1C0020-5353-4243-8E2B-9F3D5A6C7E10")
let kTokenUUID   = CBUUID(string: "7A1C0021-5353-4243-8E2B-9F3D5A6C7E10")  // read  : PC <- 폰
let kTokenDefaultsKey = "ssbeacon.identity.token"
let kCentralRestoreId    = "com.smartscreen.ssbeacon.central"
let kPeripheralRestoreId = "com.smartscreen.ssbeacon.peripheral"

// 계정 연동에 쓰는 Supabase 프로젝트. PC(client/main.cpp)와 같은 값이어야 한다.
// anon key 가 앱에 박혀 있는 것은 설계대로다 - 공개되도록 만들어진 값이고,
// device_tokens 를 지키는 것은 키가 아니라 RLS 다 (supabase/device_tokens.sql).
let kSupabaseUrl     = "https://vnonoschrzbgvyeduosm.supabase.co"
let kSupabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZub25vc2NocnpiZ3Z5ZWR1b3NtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU2NzkyNjQsImV4cCI6MjA5MTI1NTI2NH0.KqkmH7UtcR4ihFDMmAMfWRH0O2P2s__Jglzr5QWIzfc"

// ASWebAuthenticationSession 이 이 스킴을 직접 가로챈다. 그래서 Info.plist 에
// URL Type 을 등록하지 않아도 되고, Xcode 설정이 늘지 않는다.
let kCallbackScheme  = "ssbeacon"
let kCallbackUrl     = "ssbeacon://login-callback"

final class LinkManager: NSObject, ObservableObject,
                         CBCentralManagerDelegate, CBPeripheralDelegate,
                         CBPeripheralManagerDelegate {
    @Published var advText = "광고 준비 중"
    @Published var linkText = "PC 찾는 중"
    @Published var isAdvertising = false
    @Published var isLinked = false
    @Published var lastRssi = 0
    @Published var reportCount = 0
    @Published var tokenText = ""

    private var central: CBCentralManager!
    private var peripheralMgr: CBPeripheralManager!
    private var pc: CBPeripheral?
    private var rssiChar: CBCharacteristic?
    private var seq: UInt8 = 0
    private var discoverTries = 0

    private var identAdded = false
    // 서버가 다른 값을 확정해 주면 갈아탄다 (adoptToken 참고) - 그래서 var 다.
    private var token = LinkManager.loadOrCreateToken()

    // 서버에 올릴 때 쓰는 32자리 hex
    var tokenHex: String { token.map { String(format: "%02X", $0) }.joined() }

    // 우리 서비스를 제공하지 않는 PC는 한동안 건너뛴다.
    // (주변장치 역할을 못 하는 어댑터에 계속 붙었다 끊었다 하면 라디오만 낭비한다)
    private var skipUntil: [UUID: Date] = [:]
    private let skipWindow: TimeInterval = 600

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: kCentralRestoreId])
        peripheralMgr = CBPeripheralManager(delegate: self, queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: kPeripheralRestoreId])
    }

    // MARK: - 광고 경로 (주변장치)

    // 설치마다 한 번 만들어 두는 16바이트 임의값. 이게 이 폰의 신원이다.
    // iOS는 기기의 IRK를 앱에 주지 않으므로, 식별자는 우리가 만들어 가지고 있어야 한다.
    private static func loadOrCreateToken() -> Data {
        if let d = UserDefaults.standard.data(forKey: kTokenDefaultsKey), d.count == 16 { return d }
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        }
        let d = Data(bytes)
        UserDefaults.standard.set(d, forKey: kTokenDefaultsKey)
        return d
    }

    // 광고보다 먼저 신원 서비스를 올린다. 광고를 보고 찾아온 PC가
    // 붙자마자 읽을 게 없으면 연결만 낭비하기 때문이다.
    private func addIdentService() {
        guard peripheralMgr.state == .poweredOn, !identAdded else { return }
        // value 를 주면 CoreBluetooth 가 값을 캐시해 직접 응답한다 (읽기 전용이어야 함).
        // 앱을 깨우지 않으므로 잠금/백그라운드에서도 응답이 확실하고 배터리도 안 쓴다.
        let ch = CBMutableCharacteristic(type: kTokenUUID,
                                         properties: [.read],
                                         value: token,
                                         permissions: [.readable])
        let svc = CBMutableService(type: kIdentUUID, primary: true)
        svc.characteristics = [ch]
        peripheralMgr.add(svc)
    }

    // 서버가 확정한 토큰이 지금 값과 다르면 그쪽으로 갈아탄다.
    //
    // 이게 재설치를 복구한다: UserDefaults 가 비면 새 토큰이 생기는데, 그대로 두면
    // 이 폰을 등록해 둔 PC 가 전부 못 알아본다. 서버가 원본을 들고 있으므로 옛 값을
    // 도로 받아 온다.
    //
    // 특성 값은 add() 시점에 박혀 CoreBluetooth 가 캐시한다(그래서 잠긴 폰에서도
    // 앱을 안 깨우고 응답한다). 값을 바꾸려면 서비스를 통째로 다시 올리는 수밖에 없다.
    func adoptToken(_ hex: String) {
        guard hex.count == 32 else { return }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return }
            bytes.append(b)
            i = j
        }
        let d = Data(bytes)
        guard d.count == 16, d != token else { return }

        token = d
        UserDefaults.standard.set(d, forKey: kTokenDefaultsKey)
        tokenText = d.prefix(4).map { String(format: "%02X", $0) }.joined()

        if peripheralMgr.isAdvertising { peripheralMgr.stopAdvertising() }
        peripheralMgr.removeAllServices()
        identAdded = false
        addIdentService()      // didAdd 콜백이 광고를 다시 시작한다
    }

    private func startAdvertising() {
        guard peripheralMgr.state == .poweredOn, identAdded, !peripheralMgr.isAdvertising else { return }
        // 포그라운드에서는 이름과 UUID가 그대로 실리고,
        // 백그라운드/잠금에서는 iOS가 이름을 빼고 UUID를 overflow 영역으로 옮긴다.
        // overflow 에서는 UUID 하나당 비트 하나만 켜지므로 UUID 는 하나만 광고한다 -
        // PC 는 "비트 하나짜리" 모양을 1차 필터로 쓰고, 신원은 붙어서 토큰으로 확정한다.
        peripheralMgr.startAdvertising([
            CBAdvertisementDataLocalNameKey: "SSBeacon",
            CBAdvertisementDataServiceUUIDsKey: [kIdentUUID]
        ])
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        switch p.state {
        case .poweredOn:    advText = "신원 서비스 등록 중"; addIdentService(); startAdvertising()
        case .poweredOff:   advText = "Bluetooth 꺼짐"; isAdvertising = false
        case .unauthorized: advText = "Bluetooth 권한 없음"
        default:            advText = "대기 중"
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            advText = "신원 서비스 등록 실패: \(error.localizedDescription)"
            return
        }
        guard service.uuid == kIdentUUID else { return }
        identAdded = true
        tokenText = token.prefix(4).map { String(format: "%02X", $0) }.joined()
        startAdvertising()
    }

    func peripheralManager(_ p: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // 복원된 세션에는 서비스가 이미 올라와 있다. 다시 add 하면 실패한다.
        if let svcs = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
           svcs.contains(where: { $0.uuid == kIdentUUID }) {
            identAdded = true
        }
        isAdvertising = p.isAdvertising
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let error = error {
            advText = "광고 실패: \(error.localizedDescription)"
            isAdvertising = false
        } else {
            advText = "광고 중"
            isAdvertising = true
        }
    }

    // MARK: - 연결 경로 (중앙장치)

    private func startScanOrConnect() {
        guard central.state == .poweredOn else { return }
        if let p = pc, p.state == .connected { return }
        if !central.isScanning {
            // 백그라운드 스캔은 서비스 UUID를 명시해야 동작한다
            central.scanForPeripherals(withServices: [kServiceUUID], options: nil)
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:  startScanOrConnect()
        case .poweredOff: isLinked = false; linkText = "Bluetooth 꺼짐"
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let list = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = list.first {
            pc = p
            p.delegate = self
            isLinked = (p.state == .connected)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 서비스를 제공하지 않는다고 확인된 PC는 일정 시간 건너뛴다
        if let until = skipUntil[p.identifier], until > Date() { return }
        if let old = pc, old.identifier != p.identifier {
            c.cancelPeripheralConnection(old)
        }
        c.stopScan()
        pc = p
        p.delegate = self
        c.connect(p, options: nil)
        linkText = "PC에 연결 중"
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        isLinked = true
        linkText = "연결됨"
        discoverTries = 0
        p.discoverServices(nil)   // 전체 탐색: UUID 필터는 iOS 캐시 경로를 타서 놓치기도 한다
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        isLinked = false
        rssiChar = nil
        // 건너뛰기로 표시된 PC면 재연결을 걸지 않는다 (붙었다 끊었다 반복 방지)
        if let until = skipUntil[p.identifier], until > Date() {
            linkText = "이 PC는 광고 경로 사용"
        } else {
            linkText = "연결 끊김 - 재연결 대기"
            c.connect(p, options: nil)   // 타임아웃 없는 connect: 범위 안으로 오면 자동 재연결
        }
        startScanOrConnect()
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        isLinked = false
        linkText = "연결 실패 - 재시도"
        startScanOrConnect()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let svc = p.services?.first(where: { $0.uuid == kServiceUUID }) {
            discoverTries = 0
            skipUntil[p.identifier] = nil
            p.discoverCharacteristics([kTickUUID, kRssiUUID], for: svc)
            return
        }
        let n = p.services?.count ?? 0
        discoverTries += 1
        if discoverTries <= 2 {
            linkText = "서비스 찾는 중 (\(n)개, 재시도 \(discoverTries))"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard self != nil, p.state == .connected else { return }
                p.discoverServices(nil)
            }
        } else {
            // 이 PC는 GATT 서버를 제공하지 않는다. 광고 경로로 충분하므로 매달리지 않는다.
            linkText = "이 PC는 광고 경로 사용"
            discoverTries = 0
            skipUntil[p.identifier] = Date().addingTimeInterval(skipWindow)
            central.cancelPeripheralConnection(p)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == kTickUUID { p.setNotifyValue(true, for: ch) }
            if ch.uuid == kRssiUUID { rssiChar = ch }
        }
        linkText = "보고 중"
    }

    // PC가 보낸 TICK -> 앱이 깨어남 -> RSSI 측정 요청
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == kTickUUID else { return }
        if let d = ch.value, d.count >= 1 { seq = d[0] }
        p.readRSSI()
    }

    // RSSI 측정 완료 -> PC로 전송
    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, let ch = rssiChar else { return }
        let v = RSSI.intValue
        guard v < 0, v > -127 else { return }   // 127 = 측정 불가
        var bytes = [UInt8(bitPattern: Int8(clamping: v)), seq]
        let data = Data(bytes: &bytes, count: 2)
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

// ---------------------------------------------------------------------------
// 계정 연동 (구글 로그인 -> 서버가 토큰을 확정)
// ---------------------------------------------------------------------------
// 예전에는 PC 가 BLE 로 붙어 토큰을 읽어 갔다. 그러려면 앱을 화면에 띄우고 폰을
// PC 옆에 둬야 했고, PC 는 '가장 센 광고'를 고르는 수밖에 없었다. 계정을 쓰면
// 양쪽이 같은 값을 서버에서 받으므로 그 절차가 통째로 없어진다.
// BLE 등록도 그대로 남아 있다 - 인터넷이 없거나 서버가 죽어도 되게.
final class AuthManager: NSObject, ObservableObject,
                         ASWebAuthenticationPresentationContextProviding {
    @Published var statusText = ""
    @Published var email = ""
    @Published var busy = false

    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // MARK: PKCE (RFC 7636)
    // 암시적 흐름은 토큰을 URL 프래그먼트로 주는데 프래그먼트는 콜백에 안 실려 온다.
    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func makeVerifier() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, b.count, &b) != errSecSuccess {
            for i in 0..<b.count { b[i] = UInt8.random(in: 0...255) }
        }
        return base64url(Data(b))
    }
    private static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    // MARK: 로그인
    // 성공하면 서버가 확정한 토큰(32자리 hex)을 돌려준다.
    func signIn(currentTokenHex: String, completion: @escaping (String?) -> Void) {
        guard !busy else { return }
        busy = true
        statusText = "브라우저에서 로그인 중"

        let verifier = AuthManager.makeVerifier()
        let chal = AuthManager.challenge(for: verifier)

        var comps = URLComponents(string: "\(kSupabaseUrl)/auth/v1/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: kCallbackUrl),
            URLQueryItem(name: "code_challenge", value: chal),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]

        let s = ASWebAuthenticationSession(url: comps.url!,
                                          callbackURLScheme: kCallbackScheme) { [weak self] cb, err in
            guard let self = self else { return }
            guard let cb = cb,
                  let code = URLComponents(url: cb, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "code" })?.value else {
                self.finish(nil, "로그인이 취소되었습니다", completion)
                return
            }
            self.exchange(code: code, verifier: verifier,
                          currentTokenHex: currentTokenHex, completion: completion)
        }
        s.presentationContextProvider = self
        session = s
        s.start()
    }

    private func finish(_ token: String?, _ msg: String,
                        _ completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            self.busy = false
            self.statusText = msg
            completion(token)
        }
    }

    // 실패했을 때 상태코드와 본문을 같이 넘긴다. 폰은 Mac 없이 고칠 수 없으므로
    // 화면에 뜬 문장만으로 원인이 갈려야 한다. "실패했습니다" 로는 아무것도 모른다.
    private func post(_ path: String, body: [String: Any], bearer: String?,
                      done: @escaping (Any?, Int, String) -> Void) {
        var req = URLRequest(url: URL(string: kSupabaseUrl + path)!)
        req.httpMethod = "POST"
        req.setValue(kSupabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = bearer { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if let e = err {
                done(nil, code, e.localizedDescription)
                return
            }
            guard let d = data else { done(nil, code, "응답 없음"); return }
            let raw = String(data: d, encoding: .utf8) ?? ""
            // claim_device_token 은 text 를 주므로 응답이 JSON 문자열 하나다.
            // fragmentsAllowed 가 없으면 그것만 파싱에 실패한다.
            done(try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
                 code, raw)
        }.resume()
    }

    private func exchange(code: String, verifier: String, currentTokenHex: String,
                          completion: @escaping (String?) -> Void) {
        post("/auth/v1/token?grant_type=pkce",
             body: ["auth_code": code, "code_verifier": verifier],
             bearer: nil) { [weak self] obj, code, raw in
            guard let self = self else { return }
            guard let o = obj as? [String: Any],
                  let access = o["access_token"] as? String else {
                self.finish(nil, "토큰 교환 실패 [\(code)] \(raw.prefix(160))", completion)
                return
            }
            let mail = ((o["user"] as? [String: Any])?["email"] as? String) ?? ""
            DispatchQueue.main.async { self.email = mail }

            // 서버가 이 계정의 토큰을 확정한다. 이미 있으면 그 값이 돌아온다.
            self.post("/rest/v1/rpc/claim_device_token",
                      body: ["p_token": currentTokenHex, "p_platform": "ios"],
                      bearer: access) { res, code2, raw2 in
                if let hex = res as? String, hex.count == 32 {
                    self.finish(hex, "연동되었습니다", completion)
                } else {
                    self.finish(nil, "등록 실패 [\(code2)] \(raw2.prefix(160))", completion)
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var link = LinkManager()
    @StateObject private var auth = AuthManager()

    var body: some View {
        VStack(spacing: 18) {
            Text("SmartScreen Link").font(.title2).bold()

            HStack(spacing: 28) {
                VStack(spacing: 6) {
                    Circle().fill(link.isAdvertising ? Color.green : Color.gray)
                        .frame(width: 54, height: 54)
                    Text("광고").font(.caption)
                }
                VStack(spacing: 6) {
                    Circle().fill(link.isLinked ? Color.green : Color.gray)
                        .frame(width: 54, height: 54)
                    Text("연결").font(.caption)
                }
            }

            Text(link.advText).font(.subheadline)
            Text(link.linkText).font(.subheadline)

            if link.isLinked && link.reportCount > 0 {
                Text("\(link.lastRssi) dBm  ·  보고 \(link.reportCount)회")
                    .font(.system(.footnote, design: .monospaced))
            }

            if !link.tokenText.isEmpty {
                Text("기기 토큰 \(link.tokenText)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Divider()

            if auth.email.isEmpty {
                Button {
                    auth.signIn(currentTokenHex: link.tokenHex) { hex in
                        if let hex = hex { link.adoptToken(hex) }
                    }
                } label: {
                    Text(auth.busy ? "로그인 중…" : "구글 계정으로 연결")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(auth.busy)

                Text("PC 에서도 같은 계정으로 로그인하면 등록이 끝납니다.\n폰을 가까이 둘 필요가 없습니다.")
                    .font(.footnote).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("계정 \(auth.email)")
                    .font(.footnote).bold()
                    .textSelection(.enabled)
                Text("PC 의 [폰 등록] 에서 구글 계정으로 등록을 선택하세요.")
                    .font(.footnote).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !auth.statusText.isEmpty {
                Text(auth.statusText).font(.caption).foregroundColor(.secondary)
            }

            Text("광고 하나만 켜져 있어도 동작합니다.\n앱을 위로 밀어 종료하지 마세요.")
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
