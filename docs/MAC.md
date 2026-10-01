# SmartScreen for macOS

Windows 판(`client/`)과 같은 일을 하는 Mac 앱의 구조와, Windows 와 다르게 한 곳마다
그 이유. 코드는 `mac/`, 빌드는 GitHub Actions(`.github/workflows/mac.yml`)의 macOS
러너에서만 된다 - 이 저장소를 쓰는 사람은 Windows 에서 일하고 Mac 은 가까이 없다.

관련 파일: `mac/Package.swift`, `mac/Sources/SmartScreenCore/*` (판단 로직, 시험 가능),
`mac/Sources/SmartScreen/*` (앱), `mac/build_app.sh`, `mac/README.txt` (사용자 설명서,
zip 안의 `설치 안내.txt`), `supabase/mac_releases.sql`, `tools/release.ps1` 의 Mac 단계.

---

## 무엇이 같아야 하나

사용자가 보기에 Windows 판과 같아야 한다. 그래서 아래는 **글자 하나까지** 같게 옮겼다.

- 화면의 한국어 문구, 두 설정 창(간단 창 + 고급 창)의 배치, 오버레이 위젯, 검은 화면
- `config.ini` 의 키 33개 (이름, 기본값, 파일 형식: UTF-8 BOM + CRLF + 정렬). 위치만
  `~/Library/Application Support/SmartScreen/` 이다
- `events.log` 의 줄 모양 (`HH:MM:SS 메시지`, 날짜 없음). 두 판의 로그를 나란히 놓고 읽을 수
  있어야 한다
- 판단 규칙: 칼만 필터(광고 Q=1, 연결 Q=4, R=10), 히스테리시스 +4 dB, 연속 2샘플 규칙과
  6초 상한, `-100` = 즉시 FAR, 입력 5초 보호, 유휴 카운트다운, 잠금 해제 지연
- 서버와 주고받는 모든 것: 로그인(PKCE + 127.0.0.1 루프백), `device_tokens`, 기업 콘텐츠
  검증(`<org>/<sha256>.<ext>`), 클립보드 행과 버킷 경로, 되울림 방지 해시
- 폰과의 BLE 규약: UUID 다섯 개, TICK 1바이트, RSSI 2바이트, 토큰 16바이트 = 대문자 hex 32자

맥북(M1)에서 직접 빌드할 수도 있다. Xcode 명령줄 도구가 있으면:

```
git clone https://github.com/icesgg/smartscreen.git && cd smartscreen
bash mac/build_app.sh --native     # mac/dist/SmartScreen.app, mac/dist/SmartScreen-mac.zip
cd mac && swift test               # 판단 로직 시험
```

판단 로직은 `SmartScreenCore` 에 AppKit/CoreBluetooth 없이 두었다. CI 가 `swift test` 로
PROXIMITY.md 의 시간표(2샘플, 6초 상한, 히스테리시스, 입력 보호...)를 그대로 돌려 본다 -
Mac 이 없는 곳에서 행동을 확인하는 유일한 방법이다.

---

## Windows 와 다르게 한 것과 그 이유

### 옮길 수 없는 것

| Windows | Mac | 이유 |
|---|---|---|
| IRK 로 랜덤 주소 풀기, [기기 키] | 없음. 단추는 설명만 띄운다 | CoreBluetooth 는 BLE 주소도 본딩 키도 앱에 주지 않는다 |
| 필터 없이 스캔해 제조사 데이터 `4C 00 01` + 16바이트의 overflow 비트를 읽고 배운다 (`phoneOvfBit`) | 스캔 관리자 둘: 신원 서비스 UUID 로 거르는 F + 거르지 않는 R. R 은 Windows 와 같이 비트를 읽고 배우고, 후보는 둘을 합친다 (아래 "잠긴 폰 찾기") | macOS 가 잠긴 폰의 overflow 광고를 어느 쪽으로 보여 주는지 실기로 확인되지 않았다 - 하나만 되어도 돌게 했다. 비트 번호는 Windows 와 같게 세므로 config.ini 를 같이 쓴다 (이 노트북의 Windows 는 31 을 배웠다) |
| 페어링된 Classic 기기 목록, RFCOMM 지연 측정, [재연결] | 없음 (등록된 폰만 대상) | 지연 측정은 30~50 m 까지 닿아 자리 판단에 쓸 수 없다는 것이 이미 PROXIMITY.md 의 결론이다. Windows 도 등록된 폰에는 쓰지 않는다 |
| 전역 입력 훅 (`WH_MOUSE_LL`) | `CGEventSource` 유휴 시간을 100 ms 마다 본다 | 권한 없이 모든 입력을 보는 방법이 이것뿐이다. 이벤트 탭은 "입력 모니터링" 권한을 묻는다 |
| `SM_REMOTESESSION` (RDP) | `kCGSSessionOnConsoleKey == false` | 가장 가까운 뜻. 같은 세션을 보는 화면 공유는 Windows 의 TeamViewer 처럼 못 알아챈다 |
| 가상 화면 전체를 덮는 창 하나 | 모니터마다 창 하나 | "디스플레이마다 별도의 Space" 가 켜진 Mac 에서는 창이 모니터를 넘지 못한다. Windows 도 내용은 모니터마다 따로 그린다 |
| MFPlay (avi/wmv/mkv/webm 포함) | AVFoundation (mp4/mov) | macOS 는 앞의 넷을 기본으로 재생하지 못한다. 확장자 목록은 서버·대시보드와 같이 두고, 재생에 실패하면 그림이 없을 때의 어두운 상자로 넘어간다 (`lock: video could not be played` 줄) |

### 잠긴 폰 찾기: 광고 스캔이 둘이다 (`AdvScanner`)

잠긴 아이폰의 신원 UUID 는 광고에서 빠지고 Apple overflow 영역(제조사 데이터의 비트 하나)에만
남는다. iOS 는 "그 UUID 를 명시해서 찾는 스캐너" 에게 그것을 맞춰 준다고 문서에 적혀 있지만 macOS 는
확인되지 않았고, 필터 없는 스캔에 Apple 제조사 데이터를 그대로 주는지도 확인되지 않았다. 맥북 시험
한 번이 비싸서 둘 다 돌린다 - 하나만 되어도 폰을 찾는다.

- **F (필터)**: `scanForPeripherals(withServices: [7A1C0020-...])`. 등록, 화면의 블루투스 상태,
  권한 판단은 예전처럼 F 가 맡는다. F 가 준 기기는 UUID 목록이 비어 있어도 후보다 - 필터가 맞춘
  것이고, macOS 가 해시로 맞추면서 목록에는 아무것도 안 실을 수도 있다 (첫 판은 목록에 있는 것만 받았다)
- **R (직접 읽기)**: `withServices: nil`, 토큰이 있고 감시 중일 때만. CoreBluetooth 의 제조사 데이터는
  회사 id 2바이트를 **포함해** 정확히 19바이트(`4C 00 01` + 16)다 (Windows 는 17바이트로 받는다).
  비트가 딱 하나인 광고가 후보이고, 번호는 Windows 와 같게 b*8+k (`AppleOverflow`). UUID 목록에 신원
  UUID 가 실린 R 광고도 "확실한" 후보로 친다
- **고르기**: Windows ProberLoop 의 두 번 훑기 (`IdentCandidatePick`). 1차 = 신원 UUID 를 직접 본
  후보(F 가 준 것, R 의 UUID 목록) 또는 배운 비트와 같은 후보, 2차 = 전체. 둘 다 하한(임계값 -10 dB)과
  재시도 금지를 건너뛰고 가장 센 것
- **연결**: CBPeripheral 은 그것을 준 관리자의 것이다. 후보는 쪽마다 객체를 따로 들고, F 의 것이 있으면
  F 로, 없으면 R 로 붙는다. 탐색이 자기 관리자를 기억해서 연결과 끊기를 그것으로 하고, 다른 관리자의
  콜백은 버린다. R 이 꺼지면 R 에서만 본 후보와 R 위의 탐색을 버린다
- **사본 거르기** (`DualSourceDedupe`): 등록된 폰의 패킷 하나가 두 관리자에 다 걸리면 같은 샘플이 두 번
  온다. 판정의 연속 2샘플 규칙은 샘플 수를 세므로 페이딩 한 번이 두 샘플이 되어 화면이 꺼진다. 같은
  쪽의 샘플은 언제나 받고, 다른 쪽은 마지막으로 받은 샘플에서 400 ms 가 지났을 때만 받는다. 잠긴 폰의
  광고 간격은 1초 남짓 이상(Windows 실측 중앙값 1.7초)이라 400 ms 안의 다른 쪽 샘플은 사본이다.
  `ble_scan_log.csv` 의 matched 줄도 받은 샘플만 적는다 (칸 배치는 그대로 - `rssi-threshold.ps1`)
- **배우기**: 묶은 후보의 비트가 지금 값과 다르면 `ident: overflow bit is now N` 을 적고, 1초 틱이
  config.ini 의 `phoneOvfBit` 에 저장한다 (Windows IDT_COUNTDOWN 과 같다)
- **로그**: 시작에 `scan: filter=on raw=on|off`, 묶을 때 `ident: bound to XXXX (-55 dBm, 1234ms, via
  filter + raw bit 31)`. 앞부분은 Windows 와 같아서 grep 이 그대로 맞는다. `via` 는 **묶는 순간**을 말한다:
  탐색 직전 10초 안에 그 기기를 준 스캔만 적고 (`filter`, `raw bit N`, `raw list`), 그 10초 안에 앱이 화면에
  떠 있던 광고(일반 목록에 신원 UUID)도 왔으면 `, app on screen` 을 붙인다. 10초 안에 아무 스캔도 주지
  않았으면 가장 최근 것과 `, last seen Ns ago`. 첫 판은 후보가 생긴 뒤 한 번이라도 준 스캔을 다 적어서,
  앱이 떠 있을 때 필터가 준 폰을 잠근 뒤 묶으면 필터가 잠긴 폰을 한 번도 주지 않았어도 `via filter` 였다
- **잠긴 폰을 어느 길이 주는지**는 따로 남긴다: 묶인 폰의 잠긴 광고(일반 목록에 신원 UUID 가 없는 것 - F 가
  준 것, R 의 비트 하나짜리 overflow 광고, R 의 overflow 목록)를 처음 받을 때 `ident: XXXX locked adverts via
  raw bit 31` 한 줄, 그 묶음이 바뀔 때만 다시 (`filter + raw bit 31` 등). 길은 최근 10초 안에 주면 들어오고
  60초 동안 주지 않아야 빠진다 - 광고 간격이 들쭉날쭉해서 2초 틱마다 줄이 바뀌지 않게 (`LockedPathLog`).
  다시 묶으면 처음부터 센다. 실기에서 어느 스캔을 살릴지는 bound 줄이 아니라 이 줄과 `--probe-scan` 의
  요약으로 가른다
- 실기 결과에 따라 한쪽을 끌 수 있다 (`--probe-scan` 의 요약, 아래 "확인하지 못한 것" 1). R 은 주변의
  모든 광고를 받으므로 필터만으로 된다면 끄는 편이 가볍다

### 일부러 바꾼 것

- **refresh 토큰을 봉하는 방법.** DPAPI 대신 AES-GCM 으로 봉하고, 열쇠는 이 Mac 의
  하드웨어 UUID + 사용자 id + `seal.salt`(0600) 에서 만든다. 키체인을 쓰지 않은 이유:
  이 앱은 개발자 인증서 없이 임시(ad-hoc) 서명이라 **업데이트할 때마다 코드 해시가
  바뀌고, 키체인은 그때마다 로그인 암호를 묻는다.** 기업 PC 는 업데이트를 묻지 않고
  적용하므로 아무도 모르는 사이에 로그인이 풀린다. 봉한 값은 Windows 와 같이 `config.ini`
  의 `authRefresh` 에 들어가고, 다른 Mac 에 복사하면 열리지 않는다 (DPAPI 와 같은 성질).
  개발자 인증서로 서명하게 되면 키체인으로 옮길 것.
- **서명의 designated requirement 를 식별자로 둔다** (`build_app.sh`). 임시 서명의 기본
  요건은 코드 해시라서, 업데이트할 때마다 macOS 가 블루투스 허용을 다시 물을 수 있다.
  식별자(`com.icesgg.smartscreen`)로 두면 같은 앱으로 본다. 실기로 확인할 것.
- Windows 검토에서 나온 작은 결함 중 Mac 에서는 고쳐서 옮긴 것 (lockscreen 명세의 Q 번호):
  오버레이의 "Lock hh:mm" 이 UTC 오프셋만큼 틀리던 것(Q1), 잠금 해제 지연 타이머가 다음
  수동 잠금을 풀던 것(Q2), [중지] 뒤에 오버레이가 예전 상태로 남던 것(Q4), 고른 그림이
  다음 [시작] 까지 저장되지 않던 것(Q5), [중지] 직후 도착한 결과가 화면을 잠그던 것(Q6).
  **Windows 판은 그대로다** - 고치려면 `client/` 에서 같이 고칠 것.
- **폰 앱이 GATT 로 막 붙은 순간의 거짓 NEAR** (검토에서 나온 Windows 결함). 구독이 생기면
  판정 스레드가 바로 깨는데, 그때는 폴링 간격이 아직 0 이라 "입력 중 = 자리에 있음" 으로
  읽혀 NEAR 가 한 번 나온다 - 잠긴 화면이 한 샘플 동안 풀릴 수 있다. Mac 은 구독을 알리기
  전에 간격을 먼저 계산해 둔다. Windows(`client/ble_gatt.cpp` 의 SubscribedClientsChanged)는
  아직 그대로다.
- `--clip-test` 는 SmartScreen 이 켜져 있으면 거절하고, 받은 새 refresh 토큰을 저장한다.
  Windows 판은 점검이 토큰을 회전시키고 버린다 (clipsync 명세 10-1). 그것만으로는 로그인이 끊기지
  않는다 - Supabase(GoTrue)는 바로 앞 세대의 refresh 토큰을 받아 준다 (v1: 살아 있는 토큰의 부모인
  폐기된 토큰이 오면 폐기하지 않고 살아 있는 토큰을 돌려준다. v2: 세대 차이 1 의 재사용은 허용).
  그래서 버린 회전 하나는 다음 갱신에서 아문다. 끊기는 것은 두 세대 이상 뒤처진 토큰이 올 때(버린
  회전이 연달아 둘)뿐이다. Mac 이 켜져 있는 앱 옆에서 점검하지 않는 이유는 그래서 토큰 자체가 아니라
  `config.ini` 다: 점검이 회전한 토큰을 저장하므로, 앱과 나란히 돌면 파일 전체를 다시 쓰는 프로세스가
  둘이 되어 한쪽의 낡은 사본이 다른 쪽의 새 토큰(이나 다른 설정)을 덮을 수 있다. 그 위에 앱이 한 번 더
  회전하면 "연달아 둘" 이 된다. Windows 는 그대로다 (저장하지 않으므로 쓰는 쪽이 둘이 되지 않는다).
- **로그인 결과를 브라우저 뒤에 숨기지 않는다.** macOS 14 부터 `activate()` 는 부탁일 뿐이라, 사용자가
  로그인하던 브라우저를 쓰는 중이면 거절된다. 이 앱은 LSUIElement 라 Dock 에도 Cmd-Tab 에도 없어서
  결과 상자가 브라우저 뒤에 열리면 찾을 길이 없다. 그래서 알림을 부를 때 앱이 이미 활성이 아니면 알림
  창을 `.floating` 층에 올려 `orderFrontRegardless` 한다 (`Alerts.present`). `activate()` 는 런 루프가
  활성화 사건을 처리한 뒤에야 반영되므로 그 자리에서는 거절과 "아직 안 됨" 을 가릴 수 없다 - macOS 13 이나
  받아들여진 경우에도 올리고, 활성화가 나중에 되어도 되돌리지 않는다 (되돌리면 사용자가 브라우저로
  돌아가는 순간 다시 그 뒤에 깔린다). 닫을 때까지 다른 앱 위에 떠 있는 것이 의도다. 잠긴 동안 열린 알림은
  커튼이 앱을 활성화해 둔 동안 열려 층이 그대로이므로, 커튼을 걷으며 활성화를 잠그기 전의 앱에 돌려줄 때
  같은 층으로 올린다 (`LockScreen.restoreFrontmost`). 등록·로그인 결과 상자 직전에 간단 창도 초점 없이
  앞에 놓는다 (바뀐 "내 폰" 줄이 보이게. 재보기 창이 열려 있으면 그것을 다시 그 위로). 브라우저에
  남는 페이지는 "이 탭을 닫으세요. 결과 창이 안 보이면 화면 오른쪽 위 작은 상자의 [설정] 을 누르세요."
  라고 돌아가는 길을 적는다. Windows 는 작업 표시줄이 있어서 "이 창을 닫고 SmartScreen 으로 돌아가세요" 그대로다.
- **[중지] 는 GATT 서비스를 내리지 않는다.** CBPeripheralManager 는 붙어 있는 central 을 끊을 수 없어서,
  서비스를 지우면 아이폰은 무효가 된 핸들을 든 채 붙어 있고 다시 구독하지 않는다 - 첫 판은 [중지] ->
  [시작] 한 번에 그 세션의 GATT 경로가 죽었다. 지금은 광고와 TICK 만 멈추고, 구독 기록은 멈춘 동안에도
  고치며, [시작] 이 남은 구독자를 새 구독과 같은 길로 받아들인다 (`GATT client subscribed (kept across
  restart)`). 서비스를 지우고 다시 올리는 것은 블루투스가 꺼졌다 켜졌을 때와 `bleGattEncrypt` 가 바뀌었을
  때뿐이다. 폰 앱이 서비스 변경을 알아채고 다시 구독하게 되더라도 Mac 은 그것에 기대지 않는다.
- **유니버설 클립보드로 넘어온 것은 보내지 않는다.** 아이폰·아이패드에서 복사한 것은 macOS 가 이 Mac 의
  붙여넣기판에 올리는데(`com.apple.is-remote-clipboard` 형식이 붙는다), 그대로 두면 서버를 지나 Windows
  PC 에 붙는다 - 폰의 인증 문자나 암호 관리자 값까지. 형식 목록만 보고 내용을 읽기 전에 거른다 (폰에서
  끌어오지도 않는다). 상태 줄은 그대로 두고 로그에 실행마다 한 번 `clip: not sent - copied on another
  Apple device (Universal Clipboard)` 를 남긴다. Windows 판에는 이런 길이 없다.
- **잠자기와 화면 꺼짐을 기록한다** (`SLEEP`, `WAKE`, `DISPLAY OFF`, `DISPLAY ON`). 행동은 바꾸지 않는다.
  맥북은 배터리로 2분쯤(전원 10분) 뒤 화면을 끄고 잠든다. 그 뒤에는 이 앱도 멎어 돌아와도 풀 수 없고
  macOS 가 Touch ID / 암호를 묻는다 - 사용자는 "안 풀렸다" 고 알려 온다. 이 줄들이 그때를 가른다.
  Windows 에는 없는 줄이다.
- 잠금 화면은 자기 창만 앞으로 올린다. 앱 전체를 활성화하면 열어 둔 설정 창까지 다른 앱
  창들 위로 올라온다 (Windows 의 SetForegroundWindow 는 잠금 창 하나만 올린다). 풀 때는 잠그기
  전에 다른 앱 창 **아래** 있던 우리 창만 그 창 아래로 되돌린다 - 처음 판은 우리 창을 전부 맨
  뒤로 보내서, 업데이트를 알리려고 일부러 앞에 띄운 간단 창까지 묻었다 (회귀 검토)
- 블루투스 권한이 없으면 감시 중에 처음 알아챈 때 한 번 (macOS 의 허용 창에서 "허용 안 함" 을
  누른 직후 포함), BLE 직접 등록에서는 매번 그렇게 말한다. Windows 에는 권한이라는 것이 없어서
  대응하는 문구가 없다. 터미널에서 돌리는 점검 도구(`--probe-scan`, `--adv-scan`, `--bt-check`)는 권한을
  그 터미널 앱이 받으므로(TCC 의 책임 프로세스) 따로 말한다: 허용 창이 떠 있는 동안(권한 notDetermined)은
  그렇다고 한 번 찍고 60초까지 기다리고, 거부면 터미널 앱 이름을 대며 SmartScreen 항목이 아니라고 말한다.
  이름은 `__CFBundleIdentifier`(LaunchServices 가 넣고 셸과 tmux 가 물려받는 그 앱의 번들 id - TCC 의 책임
  프로세스와 같다)로 찾은 앱의 화면 이름이 먼저다. 없으면 `TERM_PROGRAM` 중 앱 하나만 뜻하는 값(터미널, iTerm,
  Warp, WezTerm, Ghostty)만 쓴다 - tmux 안에서는 "tmux", Cursor/VSCodium 은 "vscode" 라서 첫 판은 엉뚱한 앱을
  켜라고 했다. 그것도 없으면 "이 명령을 실행한 터미널 앱 (터미널, iTerm 등)". "어댑터를 찾을 수 없습니다" 는 `.unsupported` 일 때만이다 - 첫 판은 허용 창에 아직
  답하지 않은 것까지 그렇게 말했다. 세 도구가 같은 갈래와 글자를 쓴다 (`BLEDiagnostics.failureLines`).
  `--bt-check` 는 주변장치 관리자의 상태가 10초 안에 안 오면 주변장치 역할 지원을 "모름" 이라 하고 다시
  실행하라고 한다 (그것까지 "아니오 - 빠른 모드를 쓸 수 없습니다" 로 말하던 것을 고쳤다).
- 그림을 고르지 않았을 때의 기본 그림 자리: Windows 는 exe 옆의 `images\`, Mac 은 설정 폴더의
  `images/` (앱 묶음 안은 서명돼 있고 업데이트마다 바뀐다).
- 앱을 다시 열면(Finder, Launchpad) 간단 창이 나온다. Windows 는 두 번째 실행이 "이미
  실행 중" 으로 끝나지만, macOS 는 같은 앱을 다시 띄우지 않고 떠 있는 앱을 깨운다.
  오버레이 [설정] 말고도 돌아오는 길이 하나 더 생긴 것뿐이다.

---

## 업데이트는 표를 따로 쓴다

`releases.version` 이 기본키이고, 지금 나가 있는 Windows 1.1.x 는 자기 채널의 켜진 행을
**전부 SmartScreen.exe 로 받아 해시만 보고 실행한다.** 같은 표에 Mac 행을 넣으면 Windows
PC 들이 Mac zip 을 받아 자기 exe 자리에 놓으려 든다. 그래서 Mac 은 표 둘을 새로 쓴다
(`supabase/mac_releases.sql`):

| 표 / 버킷 | Mac |
|---|---|
| `mac_releases` | `releases` 와 같은 열·정책. 경로는 `mac/<버전>/SmartScreen-mac.zip` |
| `org_mac_release_approvals` | 조직 admin 의 Mac 버전 승인 |
| Storage `releases` | 같은 버킷, `mac/` 아래 (버킷 정책은 이미 관리자에게 모든 경로를 연다) |

마이그레이션은 덤으로 `releases.storage_path` 에 `<버전>/SmartScreen.exe` 모양의 제약을 건다.
SQL Editor 에서 Mac 행을 `releases` 에 잘못 넣는 길까지 서버가 막는다 - 위의 사고는 행 하나로
난다. 2026-10-01 에 라이브의 켜진 행 8개(1.1.0 ~ 1.1.7)를 anon key 로 읽어 전부 그 모양인 것을
확인했다. `Publish.exe` 도 Windows 모드에서 `MZ` 로 시작하지 않는 파일을 거절한다.

### 내놓는 길

버전 번호는 Windows 와 같다 (`client/version.h`). `release.bat` 한 번이 둘 다 한다:

1. 지금까지와 같이 Windows 판을 빌드·게시·커밋·푸시하고 앱을 다시 띄운다
2. 푸시한 커밋의 CI 실행(`mac.yml`)을 `gh` 로 찾아 끝나기를 기다린다
3. artifact `SmartScreen-mac` 을 받아 `VERSION` 과 zip 안의 Info.plist 버전이 새 번호인지 본다
4. 저장소 맨 위에 `SmartScreen-mac.zip` 으로 복사하고 (새로 까는 Mac 용)
5. `Publish.exe --platform mac --file <zip>` - 브라우저 로그인을 한 번 더 한다. Publish.exe 도
   zip 안의 번들 id 와 버전을 직접 읽어 대조하고, 올린 뒤 anon 으로 다시 받아 해시를 본다

Windows 의 요약(기업 PC 는 대시보드에서 [승인] 하라는 줄 포함)은 Mac 단계보다 **먼저** 찍는다 -
Mac 단계는 CI 를 기다리느라 10~20분 걸릴 수 있고, 그 사이 창을 닫아도 Windows 쪽 안내는 이미
보였다. Mac 단계를 시작하기 전에 anon 으로 `mac_releases` 를 한 번 읽어 **표가 없으면 기다리지
않고 건너뛴다** (노란 안내, 종료 코드 0 - Windows 릴리스는 성공이다). Mac 단계가 실패하면 Windows
릴리스는 그대로이고, 다시 할 명령(`release-mac.bat <버전>`)을 찍는다. 필요한 것: `gh` 와
`gh auth login` 한 번. `-NoMac` 으로 Mac 단계만 건너뛰고, `-NoGit` / `-DryRun` 이면 Mac 단계도
건너뛴다 (푸시한 커밋이 없으면 CI 가 만들 것도 없다).

배포 메모는 임시 파일로 `git commit -F` 에 넘긴다. PowerShell 5.1 은 네이티브 명령의 인자 안
따옴표를 이스케이프하지 않아서, `"폰 등록" 버튼 고침` 같은 메모가 Windows 게시 **뒤에** 커밋에서
깨졌다 (검토에서 나온 것 - 예전에는 Publish.exe 에서 먼저 깨져 게시조차 안 됐다).

### 적용

받은 zip 의 해시를 행과 대조 → `ditto` 로 풀기 → 풀린 앱의 번들 id 와 버전 확인 (여기까지
받는 단계에서 한다 - 잘못된 zip 을 앱이 꺼지기 전에 알아채고 실패로 기록한다) → 자기 실행
파일을 `update/updater` 로 복사해 `--apply-update` 로 띄우고 정상 종료 → 복사본이 원래
프로세스가 끝나기를 기다렸다가 zip 의 해시를 **다시 재고 다시 풀어** 그것을 놓는다 (풀어 둔
폴더가 그 사이에 바뀌었으면 해시 검사가 무의미하다) → 새 앱을 먼저 **옛 앱 옆**
(`.SmartScreen.app.incoming`, 같은 볼륨)에 놓고 확인한 뒤 `RENAME_SWAP` 으로 맞바꾼다 → 옛 앱은
`.bak` 이 된다 → 다시 띄운다. 어느 순간에도 `SmartScreen.app` 이나 `.bak` 중 하나는 온전한 앱이다
(앱이 외장 볼륨에 있으면 처음 판은 복사하는 몇 초 동안 앱이 없었다). 실패는 Windows 와 같이
`failed-<버전>.txt` 로 기억한다. 다시 띄우기 전에 "새 버전이 뜨지 않았다" 는 기록을 미리 써 두고 새
버전이 무사히 뜨면 지운다 - 새 버전이 뜨자마자 죽어서 `.bak` 으로 되돌렸을 때 같은 버전을 곧바로
다시 받지 않게.

더 높은 macOS 가 필요한 버전은 받지 않는다: 행의 `min_macos` 와 받은 앱의 `LSMinimumSystemVersion`
을 둘 다 본다. **첫 Mac 판부터 들어 있어야 했다** - 깔린 클라이언트의 조회는 나중에 못 바꾼다
(Windows `releases` 가 그 함정이다). macOS 를 올리면 그 기록은 다음 확인에서 저절로 풀린다.

Windows 와 다른 실패 사유가 셋 있다. 앱 이름이 `SmartScreen.app` 이 아닐 때, 다운로드 폴더에서
바로 실행 중일 때(macOS 가 읽기 전용 임시 위치로 옮겨 실행한다 - App Translocation), 그리고
macOS 의 "앱 관리" 보호가 바꾸기를 막을 때(EPERM). 셋 다 띠에 이유가 뜨고, 같은 버전을
저절로 다시 시도하지 않는다.

---

## 경고창이 판정을 멈추면 안 된다 (검토에서 나온 것)

Windows 의 MessageBox 는 떠 있는 동안에도 메시지를 돌린다 - 로그인 결과 창이 떠 있어도
`WM_SCAN_RESULT` 가 와서 FAR 이면 바로 잠근다. macOS 에서 같은 일을 하려면 조심해야 한다:
`DispatchQueue.main.async` 블록 **안에서** `NSAlert.runModal()` 을 띄우면, 창이 닫힐 때까지 메인
큐의 다른 블록이 하나도 돌지 않는다 (메인 큐는 직렬이고 중첩 런 루프는 그것을 다시 비우지
않는다). 판정 결과가 메인 큐로 오던 첫 판에서는, 계정 로그인 결과 창을 띄워 둔 채 자리를
떠도 화면이 바로 가려지지 않았고 폰이 돌아와도 풀리지 않았다. 검토자 다섯이 따로 찾았다.

그래서 두 겹으로 막는다:
- 판정 결과는 `MainLoop.perform` (CFRunLoopPerformBlock, common modes) 으로 보낸다. 이건 모달
  런 루프 안에서도 돈다
- 다른 스레드의 결과로 경고창을 띄울 때는 `MainTimer.once(after: 0)` 로 한 번 건너서, 경고창이
  메인 큐 블록 밖(타이머 콜백)에서 뜨게 한다

타이머(1초 카운트다운, 100 ms 입력 감시)는 `.common` 모드라 모달 중에도 원래 돈다.

---

## 확인하지 못한 것 (Mac 실기가 필요하다)

CI 는 컴파일, 판단 로직 시험(200개 남짓), 유니버설 빌드, 서명, zip 까지 한다. 아래는 Mac 과
아이폰이 있어야 알 수 있다. 중요한 순서다.

1. **macOS 가 잠긴 아이폰을 어느 길로 보여 주는가.** 이 포팅 전체가 여기에 걸려 있다. 폰을 잠근
   채 터미널에서 `SmartScreen --probe-scan` (블루투스 허용 창은 "터미널" 이름으로 뜬다 - 터미널에서
   실행하면 macOS 는 권한을 그 앱에 묻는다). 세 단계 - 필터 스캔 20초, 직접 읽기 스캔 20초(광고 수,
   Apple 광고 수, overflow 모양 기기와 켜진 비트, Apple 광고에 실린 키 이름과 공개되지 않은 키의 값 예),
   둘 다 동시에 10초 - 뒤에 후보(많아야 6대, 확실한 것 먼저)에 붙어 토큰을 읽고, 끝에 `요약` 블록을
   찍는다. `>>> 토큰` 줄은 예전 모양 그대로다. 요약의 `결과:` 줄로 가른다 (`ProbeScanResult` - 판정은
   SmartScreenCore 에 있고 시험이 있다). 길은 **등록된 토큰과 같은 토큰을 준 후보**가 어느 스캔에서
   왔는지로만 정한다 (등록된 토큰이 없으면 아무 토큰이나):
   - `필터 경로` - macOS 의 서비스 필터가 overflow 를 맞춰 준다. 앱은 F 로 찾는다. R 은 주변 광고를
     전부 받으므로 끌지 정한다. 끝에 `(직접 읽기는 시험하지 못했습니다)` 가 붙으면 두 번째 스캔 관리자가
     켜지지 않았던 것이니 다시 실행해서 R 도 볼 것
   - `직접 읽기 경로` - 필터는 못 찾고 제조사 데이터는 온다. 앱은 R 로 찾고 비트를 배운다 (Windows 와
     같은 길). F 는 등록(앱이 화면에 떠 있는 폰)에 계속 쓴다. `UUID 목록으로 찾았습니다 (비트는 배우지
     않음)` 이면 macOS 가 overflow 를 서비스 UUID 목록으로 풀어 준 것이다 (비트 학습은 쓰이지 않는다)
   - `둘 다` - 그대로 둔다 (사본은 DualSourceDedupe 가 거른다)
   - `판정 못 함` - **결론 내지 말고 다시 실행할 것.** 스캔이 폰을 봤는데 토큰을 못 읽었다 (`광고로 폰을
     찾았지만 (필터 / UUID 목록) 토큰을 못 읽었습니다` - 연결 실패는 흔하다: 이 Mac 이 직전 연결을 아직
     물고 있으면 Unreachable), 비트 하나짜리 기기만 있었다 (다른 iOS 앱의 overflow 도 비트 하나를 켠다),
     또는 등록된 것과 다른 토큰만 읽었다 (옆 사람의 폰, 또는 앱을 다시 설치해 토큰이 바뀌었다 - 그때는
     다시 등록). 시도 상한(6대)에 걸린 후보가 있으면 그 수도 말한다
   - `둘 다 안 됨` - 두 스캔을 다 돌렸는데 **어느 스캔도 폰을 보지 못했다** (후보 0대). macOS 가 잠긴
     폰의 overflow 광고를 앱에 주지 않는다 - 폰 앱이 광고 중이었다면 광고 경로는 죽었고 GATT 경로(폰 앱이
     Mac 에 붙어 RSSI 를 써 주는 것, 고급 창 아래 `GATT: linked`)만 남는다. 2단계의 `Apple 광고 키` 와
     공개되지 않은 키의 값이 다음 수단의 단서다 (macOS 가 overflow 를 다른 키로 풀어 주는지)
   - `필터로는 못 찾음, 직접 읽기는 시험하지 못함` - 두 번째 스캔 관리자가 켜지지 않았다. 다시 실행
     (`Apple 광고 키: 시험 못 함` 도 같은 뜻)
   `주의:` 줄이 있으면 결과를 그대로 믿지 말 것 - 토큰을 준 폰의 앱이 화면에 떠 있었다, 둘을 함께
   돌리면 한쪽이 끊긴다. 앱에서는 events.log 의 `ident: XXXX locked adverts via ...` 가 잠긴 폰을 실제로
   준 길을 말한다 (`ident: bound to ... via ...` 는 묶는 순간의 모양일 뿐이다 - 위 "로그")
2. 검은 화면을 띄우는 것 자체가 입력 유휴 시간을 되돌리지 않는가 (그러면 화면이 스스로 풀린다)
3. 업데이트 뒤 블루투스 허용을 다시 묻는가 (위 "designated requirement"). 물으면 기업 Mac 의
   자동 적용은 서명을 바꾸기 전까지 끄는 것이 맞다
4. 자기 업데이트가 "앱 관리" 보호(macOS 13+)에 막히는가. 막히면 띠에 그 설정을 안내한다
5. Mac 의 광고 수신 간격 (Windows 실측 중앙값 1.7초, p90 5.8초). 6초 상한이 그 p90 에 맞춘
   값이다. `bleDebugLog=1` 로 한 번 잴 것
6. 잠긴 아이폰이 Mac 의 GATT 서비스에 붙는가 (고급 창 아래 `GATT: linked`). [중지] -> [시작] 뒤에도
   `linked` 가 이어지는가 (events.log 의 `GATT client subscribed (kept across restart)`)
7. 클립보드: "다른 앱에서 붙여넣기" 를 묻도록 설정된 Mac 에서 확인 창이 뜨는가, Chrome/Slack/미리보기에
   받은 그림이 붙는가, 1Password 에서 복사한 것이 안 넘어가는가, 아이폰에서 복사한 것이 안 넘어가는가
   (`com.apple.is-remote-clipboard` 가 실제로 붙는가)
8. 루프백 로그인이 Supabase 허용 목록을 통과하는가 (Windows 와 같은 주소라 통과해야 한다)
9. 잠금 화면이 다른 앱의 전체 화면 Space 와 메뉴 막대까지 덮는가, mp4 가 도는가
10. 로그인 결과 상자가 브라우저 앞에 뜨는가 (macOS 14+, 브라우저를 쓰는 중에 결과가 올 때). 상자가 떠 있는
    채 브라우저를 눌러도 상자가 위에 남는가. 로그인 도중 자리를 비워 잠긴 채 3분이 지나 실패 상자가 열린
    뒤, 돌아와 풀었을 때도 상자가 브라우저 앞에 보이는가
