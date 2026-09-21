# SSBeacon - SmartScreen iOS 컴패니언

PC(SmartScreen)가 사용자의 자리 비움을 빠르게 감지하도록 돕는 앱.

## v1 → v2 구조 변경

| | v1 (광고) | v2 (연결) |
|---|---|---|
| 역할 | 폰이 광고, PC가 수신 | **PC가 GATT 서버, 앱이 central** |
| RSSI 갱신 | 10~50초 (iOS 백그라운드 광고 스로틀) | **~1초** |
| 이탈 감지 | 10~50초 | **1~3초** |

v2에서 PC는 TICK 특성으로 알림을 보내고, 앱은 깨어나 `readRSSI()` 결과를 RSSI 특성에 쓴다.
연결된 BLE 링크는 광고와 달리 백그라운드에서 스로틀되지 않는다.

배터리: PC는 **사용자 입력이 멈췄을 때만** TICK을 보낸다(입력 중이면 앱을 깨우지 않음).

## UUID (PC의 `client/ble_gatt.h`와 일치해야 함)

- Service: `7A1C0010-5353-4243-8E2B-9F3D5A6C7E10`
- TICK (notify, PC→폰): `7A1C0011-...`
- RSSI (write, 폰→PC): `7A1C0012-...`

## Xcode 설정

1. iOS App / SwiftUI / Swift 프로젝트에 `SSBeaconApp.swift` 하나만 사용
   (템플릿이 만든 `ContentView.swift`는 삭제)
2. Signing & Capabilities → **Background Modes** → **"Uses Bluetooth LE accessories"** 체크
   → Info.plist `UIBackgroundModes` 에 `bluetooth-central` 이 들어가야 함
   (v1의 `bluetooth-peripheral` 이 아님)
3. Info → `Privacy - Bluetooth Always Usage Description` 추가

## 테스트 주의

- Xcode 디버거가 붙어 있으면 백그라운드 동작이 실제와 다르다.
  설치 후 **Stop** 하고, 폰에서 아이콘을 눌러 직접 실행한 상태로 테스트할 것.
- 앱 전환 화면에서 위로 밀어 종료하면 연결이 끊긴다 (홈으로 나가기/잠금만 할 것).
- PC 쪽에서 SmartScreen "시작"을 눌러야 GATT 서버가 광고를 시작한다.
