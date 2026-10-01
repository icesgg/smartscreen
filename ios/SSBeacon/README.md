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

**PC가 올리는 서비스** - 이 앱이 central로 붙는 쪽 (연결 경로)

- Service: `7A1C0010-5353-4243-8E2B-9F3D5A6C7E10`
- TICK (notify, PC→폰): `7A1C0011-...`
- RSSI (write, 폰→PC): `7A1C0012-...`

**이 앱이 올리는 신원 서비스** - PC가 central로 붙어 읽는 쪽

- Service: `7A1C0020-5353-4243-8E2B-9F3D5A6C7E10`  (광고하는 UUID도 이것)
- Token (read, PC←폰): `7A1C0021-...`  16바이트 임의값

두 서비스가 일부러 다른 UUID를 쓰는 이유: 같게 두면 이 앱의 central 스캔이
옆자리 폰을 PC로 착각해 붙으려 든다.

## 신원 확인 (왜 토큰이 필요한가)

잠긴 아이폰의 광고에는 이름도 서비스 UUID도 안 실리고, 주기적으로 바뀌는
랜덤 주소(RPA)만 남는다. 그래서 "이 광고가 내 폰인가"를 광고만으로는 알 수 없다.

예전에는 Windows 레지스트리에 저장된 아이폰의 IRK로 RPA를 풀었는데, 그러려면
그 PC에서 아이폰과 BLE 본딩(사실상 Phone Link 설정)이 한 번은 있어야 했다.
설치의 최대 장벽이었다.

지금은 앱이 설치마다 16바이트 임의값을 만들어 `UserDefaults`에 보관하고,
읽기 전용 특성으로 노출한다. PC는 후보에 central로 붙어 토큰을 한 번 읽어
신원을 확정하고, 그 뒤는 주소가 바뀔 때까지 주소로 추적한다.

특성에 `value:`를 주어 CoreBluetooth가 값을 캐시해 직접 응답하게 했다.
앱을 깨우지 않으므로 잠금/백그라운드에서도 응답이 확실하고 배터리도 안 쓴다.
(이 형태는 읽기 전용이어야 한다 - `properties: [.read]`, `permissions: [.readable]`)

## Xcode 설정

1. iOS App / SwiftUI / Swift 프로젝트에 `SSBeaconApp.swift` 하나만 사용
   (템플릿이 만든 `ContentView.swift`는 삭제)
2. Signing & Capabilities → **Background Modes** 에 둘 다 체크
   - **"Uses Bluetooth LE accessories"**      (`bluetooth-central`)
   - **"Acts as a Bluetooth LE accessory"**   (`bluetooth-peripheral`)
   → Info.plist `UIBackgroundModes` 에 두 값이 모두 있어야 한다
3. Info → `Privacy - Bluetooth Always Usage Description` 추가
4. General → Minimum Deployments 는 **iOS 15.0 이상** (새 프로젝트의 기본값은 그보다 높으니
   그대로 두면 된다). 코드가 쓰는 가장 새 API 가 iOS 15 이고, CI(`.github/workflows/ios.yml`)가
   이 값으로 타입 검사한다

CI 가 컴파일해 보는 Xcode (SIL 단계까지만 - 기계어·서명·실행은 하지 않는다):

- macos-15 러너의 기본 Xcode(16.4) 로 기본값
- macos-15 러너의 가장 새 Xcode 26.x (지금 26.3) 로 새 프로젝트 기본값 (기본 격리 MainActor,
  MemberImportVisibility 등)
- macos-26 러너의 기본 Xcode 로 기본값과 새 프로젝트 기본값 둘 다
- xcode-27 러너(미리보기)의 기본 Xcode 로 같은 두 가지. 미리보기라 여기서 실패해도 CI 는 초록으로
  남는다 - 실행 요약에서 따로 볼 것

실제로 쓴 버전은 실행마다 요약(Summary)에 적힌다. 여기에 없는 Xcode 는 검사되지 않은 것이다.

계정 연동(구글 로그인)에는 **추가 설정이 없다.** `ASWebAuthenticationSession`
이 콜백 스킴(`ssbeacon://`)을 직접 가로채므로 Info.plist 의 URL Types 에
등록하지 않아도 된다. 찾지 말 것.

다만 App Store 심사 지침 4.8 은 서드파티 소셜 로그인을 넣은 앱에
Sign in with Apple 도 함께 제공할 것을 요구한다. 구글만 넣은 채로
제출하면 리젝 사유가 될 수 있다 (Supabase 는 Apple provider 도 지원한다).

## 테스트 주의

- Xcode 디버거가 붙어 있으면 백그라운드 동작이 실제와 다르다.
  설치 후 **Stop** 하고, 폰에서 아이콘을 눌러 직접 실행한 상태로 테스트할 것.
- 앱 전환 화면에서 위로 밀어 종료하면 연결이 끊긴다 (홈으로 나가기/잠금만 할 것).
- PC 쪽에서 SmartScreen "시작"을 눌러야 GATT 서버가 광고를 시작한다.
- PC 앱이 GATT 서비스를 내렸다 다시 올리면 (Mac [보호 꺼짐]→[보호 켜짐], 앱 재시작·자기
  업데이트) 폰의 연결은 그대로라 앱이 스스로 다시 구독해야 한다 (PC 는 폰을 끊을 수 없다).
  - iOS 가 Service Changed 를 받으면 `didModifyServices` 가 바로 다시 찾는다. 화면:
    `PC 서비스 바뀜 - 다시 찾는 중` → `보고 중`. PC 가 서비스를 내린 채면
    `PC 서비스 꺼짐 - 다시 켜지길 기다리는 중` (연결을 쥔 채 기다린다)
  - 못 받으면 TICK 감시: TICK 이 60초 없으면 서비스를 다시 찾고(`TICK 없음 - 서비스 다시 확인 중`),
    그 뒤로도 60초 없으면 끊고 같은 PC 에 다시 붙는다 (30초 동안은 다른 PC 로 갈아타지 않는다).
    PC 는 입력 중에 TICK 을 안 보내므로 이것은 정상일 수 있다 - 그래서 TICK 없이 끊을 때마다
    기다리는 시간을 두 배로 늘린다 (최대 16분).
    **감시는 앱이 깨어 있을 때만 돈다** (앞에 띄워 두었거나 Bluetooth 이벤트로 깨어났을 때).
    Service Changed 를 못 받은 채 폰이 잠겨 있으면 앱을 깨울 이벤트가 없다 (TICK 도 끊김도 없고,
    PC 의 토큰 읽기는 CoreBluetooth 캐시가 앱 없이 답한다). 그때는 앱을 열거나 범위를 벗어났다
    돌아올 때까지 연결 경로가 멈춰 있고, PC 는 광고 경로로 동작한다.
