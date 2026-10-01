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

판단 로직은 `SmartScreenCore` 에 AppKit/CoreBluetooth 없이 두었다. CI 가 `swift test` 로
PROXIMITY.md 의 시간표(2샘플, 6초 상한, 히스테리시스, 입력 보호...)를 그대로 돌려 본다 -
Mac 이 없는 곳에서 행동을 확인하는 유일한 방법이다.

---

## Windows 와 다르게 한 것과 그 이유

### 옮길 수 없는 것

| Windows | Mac | 이유 |
|---|---|---|
| IRK 로 랜덤 주소 풀기, [기기 키] | 없음. 단추는 설명만 띄운다 | CoreBluetooth 는 BLE 주소도 본딩 키도 앱에 주지 않는다 |
| overflow 비트를 배워 후보 좁히기 (`phoneOvfBit`) | 스캔 필터에 신원 서비스 UUID 를 준다 | macOS 가 overflow 영역을 직접 맞춰 준다. 비트 번호는 보이지 않으므로 키는 -1 로 둔다 |
| 페어링된 Classic 기기 목록, RFCOMM 지연 측정, [재연결] | 없음 (등록된 폰만 대상) | 지연 측정은 30~50 m 까지 닿아 자리 판단에 쓸 수 없다는 것이 이미 PROXIMITY.md 의 결론이다. Windows 도 등록된 폰에는 쓰지 않는다 |
| 전역 입력 훅 (`WH_MOUSE_LL`) | `CGEventSource` 유휴 시간을 100 ms 마다 본다 | 권한 없이 모든 입력을 보는 방법이 이것뿐이다. 이벤트 탭은 "입력 모니터링" 권한을 묻는다 |
| `SM_REMOTESESSION` (RDP) | `kCGSSessionOnConsoleKey == false` | 가장 가까운 뜻. 같은 세션을 보는 화면 공유는 Windows 의 TeamViewer 처럼 못 알아챈다 |
| 가상 화면 전체를 덮는 창 하나 | 모니터마다 창 하나 | "디스플레이마다 별도의 Space" 가 켜진 Mac 에서는 창이 모니터를 넘지 못한다. Windows 도 내용은 모니터마다 따로 그린다 |
| MFPlay (avi/wmv/mkv/webm 포함) | AVFoundation (mp4/mov) | macOS 는 앞의 넷을 기본으로 재생하지 못한다. 확장자 목록은 서버·대시보드와 같이 두고, 재생 실패는 그림 없는 화면으로 넘어간다 |

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

버전 번호는 Windows 와 같다 (`client/version.h`). `release.bat` 이 Windows 판을 내놓고
푸시하면 CI 가 그 커밋의 Mac 판을 만들고, `release.ps1` 이 그 artifact 를 받아
`Publish.exe --platform mac` 으로 올린다. Mac 단계가 실패해도 Windows 릴리스는 그대로이고,
다시 할 명령(`release-mac.bat <버전>`)을 알려 준다.

적용: 받은 zip 의 해시를 행과 대조 → `ditto` 로 풀기 → 풀린 앱의 번들 id 와 버전 확인 →
자기 실행 파일을 `update/updater` 로 복사해 `--apply-update` 로 띄우고 정상 종료 → 복사본이
원래 프로세스가 끝나기를 기다렸다가 `SmartScreen.app` 을 `.bak` 으로 옮기고 새 앱을 놓고
다시 띄운다. 실패는 Windows 와 같이 `failed-<버전>.txt` 로 기억한다.

---

## 확인하지 못한 것 (Mac 실기가 필요하다)

CI 는 컴파일과 판단 로직 시험까지만 한다. 아래는 Mac 과 아이폰이 있어야 알 수 있다.

1. **macOS 가 잠긴 아이폰의 overflow 광고를 서비스 필터로 찾아 주는가.** 이 포팅 전체가
   여기에 걸려 있다. `SmartScreen --probe-scan` 을 폰을 잠근 채 돌려 `>>> 토큰` 이 나오는지
   본다. 안 나오면 필터 없이 스캔해 제조사 데이터(`4C 00 01 ...`)를 Windows 처럼 직접 읽는
   쪽으로 바꿔야 한다 (ble 명세 8.3-1)
2. Mac 의 광고 수신 간격 (Windows 실측 중앙값 1.7초, p90 5.8초). 6초 상한이 그 p90 에 맞춘
   값이다. `bleDebugLog=1` 로 한 번 잴 것
3. 검은 화면을 띄우는 것 자체가 입력 유휴 시간을 되돌리지 않는가 (그러면 화면이 스스로 풀린다)
4. 업데이트 뒤 블루투스 허용을 다시 묻는가 (위 "designated requirement")
5. 루프백 로그인이 Supabase 허용 목록을 통과하는가 (Windows 와 같은 주소라 통과해야 한다)
