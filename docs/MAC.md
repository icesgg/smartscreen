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
| overflow 비트를 배워 후보 좁히기 (`phoneOvfBit`) | 스캔 필터에 신원 서비스 UUID 를 준다 | macOS 가 overflow 영역을 직접 맞춰 준다. 비트 번호는 보이지 않으므로 키는 -1 로 둔다 |
| 페어링된 Classic 기기 목록, RFCOMM 지연 측정, [재연결] | 없음 (등록된 폰만 대상) | 지연 측정은 30~50 m 까지 닿아 자리 판단에 쓸 수 없다는 것이 이미 PROXIMITY.md 의 결론이다. Windows 도 등록된 폰에는 쓰지 않는다 |
| 전역 입력 훅 (`WH_MOUSE_LL`) | `CGEventSource` 유휴 시간을 100 ms 마다 본다 | 권한 없이 모든 입력을 보는 방법이 이것뿐이다. 이벤트 탭은 "입력 모니터링" 권한을 묻는다 |
| `SM_REMOTESESSION` (RDP) | `kCGSSessionOnConsoleKey == false` | 가장 가까운 뜻. 같은 세션을 보는 화면 공유는 Windows 의 TeamViewer 처럼 못 알아챈다 |
| 가상 화면 전체를 덮는 창 하나 | 모니터마다 창 하나 | "디스플레이마다 별도의 Space" 가 켜진 Mac 에서는 창이 모니터를 넘지 못한다. Windows 도 내용은 모니터마다 따로 그린다 |
| MFPlay (avi/wmv/mkv/webm 포함) | AVFoundation (mp4/mov) | macOS 는 앞의 넷을 기본으로 재생하지 못한다. 확장자 목록은 서버·대시보드와 같이 두고, 재생에 실패하면 그림이 없을 때의 어두운 상자로 넘어간다 (`lock: video could not be played` 줄) |

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
  Windows 판은 점검이 토큰을 회전시키고 버려서, 켜져 있는 앱의 로그인이 풀릴 수 있다
  (clipsync 명세 10-1). 역시 Windows 는 그대로다.
- 잠금 화면은 자기 창만 앞으로 올린다. 앱 전체를 활성화하면 열어 둔 설정 창까지 다른 앱
  창들 위로 올라온다 (Windows 의 SetForegroundWindow 는 잠금 창 하나만 올린다). 풀 때는 잠그기
  전에 다른 앱 창 **아래** 있던 우리 창만 그 창 아래로 되돌린다 - 처음 판은 우리 창을 전부 맨
  뒤로 보내서, 업데이트를 알리려고 일부러 앞에 띄운 간단 창까지 묻었다 (회귀 검토)
- 블루투스 권한이 없으면 감시 중에 처음 알아챈 때 한 번 (macOS 의 허용 창에서 "허용 안 함" 을
  누른 직후 포함), BLE 직접 등록에서는 매번 그렇게 말한다. Windows 에는 권한이라는 것이 없어서
  대응하는 문구가 없다.
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

CI 는 컴파일, 판단 로직 시험(180개 남짓), 유니버설 빌드, 서명, zip 까지 한다. 아래는 Mac 과
아이폰이 있어야 알 수 있다. 중요한 순서다.

1. **macOS 가 잠긴 아이폰의 overflow 광고를 서비스 필터로 찾아 주는가.** 이 포팅 전체가
   여기에 걸려 있다. `SmartScreen --probe-scan` 을 폰을 잠근 채 돌려 `>>> 토큰` 이 나오는지
   본다. 안 나오면 필터 없이 스캔해 제조사 데이터(`4C 00 01 ...`)를 Windows 처럼 직접 읽는
   쪽으로 바꿔야 한다 (ble 명세 8.3-1)
2. 검은 화면을 띄우는 것 자체가 입력 유휴 시간을 되돌리지 않는가 (그러면 화면이 스스로 풀린다)
3. 업데이트 뒤 블루투스 허용을 다시 묻는가 (위 "designated requirement"). 물으면 기업 Mac 의
   자동 적용은 서명을 바꾸기 전까지 끄는 것이 맞다
4. 자기 업데이트가 "앱 관리" 보호(macOS 13+)에 막히는가. 막히면 띠에 그 설정을 안내한다
5. Mac 의 광고 수신 간격 (Windows 실측 중앙값 1.7초, p90 5.8초). 6초 상한이 그 p90 에 맞춘
   값이다. `bleDebugLog=1` 로 한 번 잴 것
6. 잠긴 아이폰이 Mac 의 GATT 서비스에 붙는가 (고급 창 아래 `GATT: linked`)
7. 클립보드: macOS 15.4+ 의 "다른 앱에서 붙여넣기" 확인 창이 뜨는가, Chrome/Slack/미리보기에
   받은 그림이 붙는가, 1Password 에서 복사한 것이 안 넘어가는가
8. 루프백 로그인이 Supabase 허용 목록을 통과하는가 (Windows 와 같은 주소라 통과해야 한다)
9. 잠금 화면이 다른 앱의 전체 화면 Space 와 메뉴 막대까지 덮는가, mp4 가 도는가
