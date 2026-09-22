# SSBeacon - SmartScreen iOS 컴패니언

PC(SmartScreen)가 사용자의 자리 비움을 빠르게 감지하도록 돕는 앱.

## 두 경로를 동시에 준비한다

PC 어댑터에 따라 쓸 수 있는 경로가 다르다. 앱은 둘 다 켜 두고, PC가 고른다.

| 경로 | PC에 필요한 것 | 갱신 | 비고 |
|---|---|---|---|
| 광고 (앱=주변장치) | BLE 스캔만 | 2~30초 | 사실상 모든 동글에서 동작 |
| 연결 (앱=central) | BLE 주변장치 역할 | 1초 | 지원하는 어댑터에서만 |

아이폰은 앱 없이 잠기면 광고를 멈춘다. 이 앱이 계속 광고해 주는 것이 광고 경로의 핵심이다.

연결 경로에서는 PC가 TICK 알림을 보내고, 앱이 깨어나 `readRSSI()` 결과를 써 준다.
연결된 BLE 링크는 광고와 달리 백그라운드 스로틀을 받지 않는다.

배터리: PC는 **사용자 입력이 멈췄을 때만** TICK을 보낸다(입력 중이면 앱을 깨우지 않음).

실측(2026-09): USB 동글 4종 중 BLE 주변장치 역할이 실제로 동작한 것은 노트북 내장 인텔뿐이었다.
BARROT 칩 동글 2종은 "지원함"이라고 보고하고도 동작하지 않았고, Microsoft 내장 드라이버로 잡힌
동글 1종은 "지원 안 함"이라고 정직하게 보고했다. 그래서 광고 경로가 기본이고 연결 경로는 보너스다.

## UUID (PC의 `client/ble_gatt.h`와 일치해야 함)

- Service: `7A1C0010-5353-4243-8E2B-9F3D5A6C7E10`
- TICK (notify, PC→폰): `7A1C0011-...`
- RSSI (write, 폰→PC): `7A1C0012-...`

## Xcode 설정

1. iOS App / SwiftUI / Swift 프로젝트에 `SSBeaconApp.swift` 하나만 사용
   (템플릿이 만든 `ContentView.swift`는 삭제)
2. Signing & Capabilities → **Background Modes** 에 둘 다 체크
   - **"Uses Bluetooth LE accessories"**      (`bluetooth-central`)
   - **"Acts as a Bluetooth LE accessory"**   (`bluetooth-peripheral`)
   → Info.plist `UIBackgroundModes` 에 두 값이 모두 있어야 한다
3. Info → `Privacy - Bluetooth Always Usage Description` 추가

## 테스트 주의

- Xcode 디버거가 붙어 있으면 백그라운드 동작이 실제와 다르다.
  설치 후 **Stop** 하고, 폰에서 아이콘을 눌러 직접 실행한 상태로 테스트할 것.
- 앱 전환 화면에서 위로 밀어 종료하면 연결이 끊긴다 (홈으로 나가기/잠금만 할 것).
- PC 쪽에서 SmartScreen "시작"을 눌러야 GATT 서버가 광고를 시작한다.
