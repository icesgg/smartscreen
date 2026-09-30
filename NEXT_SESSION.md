SmartScreen 프로젝트를 이어서 개발한다. 저장소: C:\work\smartscreen (main 브랜치, 최신 푸시됨)

설계 배경은 docs/PROXIMITY.md, 식별 구조는 docs/IDENTIFICATION.md,
클립보드 공유는 docs/CLIPBOARD.md, 자동 업데이트는 docs/UPDATE.md 에 있다. 먼저 읽어라.

## 지금 상태

자리 비움을 감지해 화면을 가리는 Windows 앱 + iOS 컴패니언 앱(ios/SSBeacon).
BLE 신호 세기(RSSI)로 거리를 판단한다.

여기에 붙은 기능이 둘 더 있다. 둘 다 자리비움 감지와 아무 상관이 없고, 계정
로그인과 Supabase 배관이 이미 여기 있어서 같은 앱에 들어왔다.

- 같은 구글 계정으로 로그인한 PC 끼리 클립보드를 주고받는다 (docs/CLIPBOARD.md)
- 새 버전을 서버에 올리면 모든 PC 가 스스로 받아 간다 (docs/UPDATE.md)

## 직전 세션: 프로그램 자동 업데이트 + release.bat

**끝까지 돌았다.** 서버에 1.1.0 ~ 1.1.4 가 있고 두 PC 모두 1.1.4 다. 노트북(기업
등록)은 대시보드 [승인] → 자동 적용, 데스크톱은 zip 을 깔고 켠 뒤 올라갔다.
1.1.3 은 `release.bat` 한 번으로 나갔고, 1.1.4 는 사용자가 혼자 `release.bat` 으로 내놓았다 ("잘된다").

### 구조 (docs/UPDATE.md 에 근거까지)

- 버전: `client/version.h` 세 숫자. 비교는 `client/relver.h` 가 숫자로 한다
  (`1.10.0 > 1.9.0`)
- 서버: `supabase/releases.sql`. `releases`(버전·경로·**SHA-256**·메모·active) /
  `release_admins` / `org_release_approvals` + Storage `releases` 버킷. **읽기는
  anon 에 열고 쓰기만 지킨다** - device_tokens 와 정반대인데, 개인 PC 는 로그인이
  없고 그 PC 도 받아야 하기 때문이다. 믿는 것은 행의 해시 하나다
- 클라이언트: `client/update.cpp`. 켤 때 + 한 시간마다 확인. 받은 파일의 해시가
  행과 다르면 버린다. 자기 exe 를 `%APPDATA%\SmartScreen\update\updater.exe` 로
  복사해 `--apply-update <pid> <src> <dst> --sha <hex> --ver <v>` 로 띄우고 정상
  종료한다. 복사본은 원래 프로세스가 끝나기를 기다린 뒤(120초, 그 뒤 강제 종료)
  해시를 한 번 더 재고 바꾼다. 예전 exe 는 `.bak` 으로 남기고 새 exe 가 무사히
  뜨면 지운다. src 는 update 폴더 안, dst 이름은 `SmartScreen.exe` 여야 받는다
- **실패는 기억한다.** `%APPDATA%\SmartScreen\update\failed-<버전>.txt`. 없으면
  기업 PC 가 같은 버전을 끝없이 다시 받아 다시 종료한다 (검토에서 잡힘). [다시
  시도] 나 더 새 버전이 나올 때까지 저절로 다시 하지 않는다
- **화면을 가리는 중에는 다시 시작하지 않는다.** `main.cpp` 의 `UpdateTick` 이
  1분마다 다시 본다. **UAC 승격은 없다** - Program Files 면 "사용자 폴더로 옮기라"
  로 끝난다. 기다리는 동안 화면을 아무도 안 지키기 때문이다
- 개인 PC: 간단 창 아래 띠 + [업데이트]/[나중에]. 새 버전(또는 지난 적용 실패)마다
  한 번, 초점을 빼앗지 않고 숨은 창을 띄운다. 기업 PC: 승인된 버전을 묻지 않고
  받고, 승인 안 된 새 버전은 "관리자 승인을 기다려요" 로만 보인다
- 간단 창: 머리에 `버전 x.y.z · 업데이트 확인` 단추가 늘 있고, 띠가 보일 때만 창이
  100 자란다 (750 → 850). 상시로 늘릴 자리가 없어서다
- 대시보드(`docs/dashboard.html`, GitHub Pages): "프로그램 업데이트" 칸. admin 만
  [승인]/[승인됨]. `web/` 의 사본은 4월 것이라 낡았다 - 배포되는 것은 `docs/`
- config: `updateCheck`(기본 1), `updateChannel`(stable|beta)
- `Publish.exe`(tools/publish.cpp): 로그인 → 해시 → 업로드 → **anon 으로 다시
  내려받아 대조** → 행 upsert. 같은 버전에 다른 파일은 거절(`--force` 로만).
  **저장소의 version.h 와 자기 빌드 버전이 다르면 거절한다** (낡은 빌드가 옛
  번호로 다시 올라간 적이 있다). `--list` / `--deactivate` / `--version` / `--selftest`

### 검토

첫 판을 독립 검토(5 차원 → 반박 3표)로 훑어 16건, 고친 것을 다시 검토해 회귀 14건
(7가지), 세 번째에 1건 - 전부 확정·수정, 반박된 것 없음. 목록은 docs/UPDATE.md
"검토에서 나온 것". 셋이 컸다: 기업 PC 무한 재시작 루프, 긴 배포 메모로
`swprintf_s` 가 프로세스를 죽임, 복사본이 원래 프로세스가 끝나기 전에 예전 exe
를 띄워 뮤텍스에 걸려 아무것도 안 남음.

### release.bat (더블클릭 한 번)

`tools/release.ps1` 이 한다: version.h 패치 +1 → 메모 묻기 → 앱 정상 종료(오버레이
[종료] 와 같은 길) → `do_build.bat` → **exe 가 version.h 보다 새것인지와
`Publish.exe --version` 을 직접 확인** → `Publish.exe` → make_dist + zip → `git commit
"Release x.y.z"` + push → 닫았던 앱 다시 띄우기. `release.bat 1.2.0` 은 그 번호로
(게시 실패 뒤 같은 번호 재시도도 이걸로), `-NoGit`, `-DryRun`. 빌드 실패면 번호를
되돌리고, 어디서 멈추든 앱은 다시 띄운다.

만들면서 세 번 실패했고 셋 다 스크립트 쪽이었다 (아래 함정): PowerShell 이 `$null`
을 `""` 로 넘겨 창을 못 찾음, cmd 에 넘긴 따옴표가 `\"` 로 바뀌어 빌드가 안 돌았는데
**옛 로그를 읽어 "성공"**, 헤더 의존성 파일이 비어 있어 `version.h` 만 바꿔서는 exe 가
안 바뀜. 교훈은 하나다 - **빌드 스크립트의 보고를 믿지 말고 결과물을 봐라.**

## 그 앞 세션: PC 사이 클립보드 공유

A 에서 스크린캡처하면 B 에서 Ctrl+V 로 붙는다. 연결고리는 같은 구글 계정 하나뿐
(같은 네트워크일 필요 없음). 설계와 정한 이유는 **docs/CLIPBOARD.md** 에 있다.

**두 대 사이 실기 확인됨 (2026-09-30).** 데스크톱에서 캡처 → 노트북에서 Ctrl+V.
글과 그림 모두.

- 서버: `supabase/clipboard.sql`. `clip_items` + Storage `clip` 버킷. `device_tokens`
  와 같은 방침으로 anon 정책 없음 - 클립보드에는 붙여넣으려던 비밀번호까지 지나간다
- 세션: `client/enterprise/session.cpp`. **여기까지 앱에는 살아 있는 세션이 없었다** -
  `RefreshSession` 은 `tools/authtest.cpp` 만 부르고 있었다. 갱신하면 refresh 토큰이
  회전하는데, 저장 안 하면 **다음 실행에서 로그인이 풀린다** (증상이 하루 뒤에
  나온다). 회전은 콜백으로 알리고 저장은 UI 스레드가 한다
- 클라이언트: `client/clipsync.cpp`. 텍스트(`CF_UNICODETEXT`)와 그림(`CF_BITMAP` +
  등록 형식 `PNG`)만, 파일은 안 넘긴다. 둘이 같이 있으면 텍스트를 고른다
- 되울림은 세 겹으로 막는다: 클립보드 순번 + 내용 해시 + 행에 박힌 PC 이름.
  하나라도 새면 두 PC 가 같은 그림을 영원히 되던진다
- 시작할 때 서버의 가장 새 id 를 **기준선으로만** 적고 아무것도 붙이지 않는다.
  안 그러면 앱을 켤 때마다 어제 것이 지금 클립보드를 지운다
- 그림 경로는 기기마다 하나(`<user_id>/<device>.png`)로 고정하고 덮어쓴다. Storage
  정책에 `update` 가 있어야 하고, 없으면 **첫 장만 올라가고 그 뒤 전부 403** 이 된다
- **실기에서 걸린 것: 클립보드 형식이 모자랐다.** `CF_BITMAP` 만 올렸는데
  Chromium/Electron 앱은 등록 형식 `"PNG"` 를 먼저 찾는다. 알파를 의심했는데 틀렸다 -
  양쪽 클립보드를 나란히 열거해 본 것이 답이었다 (docs/CLIPBOARD.md "형식이
  모자랐던 일")

## 그 앞 세션: 등록이 도중에 바뀌어도 반영되게

`adoptToken` (아래 남은 작업 1) 을 읽다가, 그게 성공하든 실패하든 **PC 쪽이 등록
변경을 제대로 못 받는다**는 걸 찾았다. 실기 시험은 아직 안 했고(Mac·아이폰이
필요하다), 코드만 고쳤다.

- **`SetIdentity` 가 `std::wstring` 을 잠금 없이 갈아치우고 있었다.** 광고 콜백
  스레드와 프로버 스레드가 같은 문자열을 읽는다. `identMutex` + 잠금 없이 읽는
  `identOn` 사본으로 갈랐다
- **계정 등록이 돌고 있는 스캐너에 전달되지 않았다.** `WM_LOGIN_RESULT` 가 config 에만
  쓰고 `SetIdentity` 를 부르지 않았고, 처음 등록하는 PC 에서는 프로버 스레드가 아예
  없었다. 이제 `SetIdentity` 가 필요하면 스레드를 띄운다
- **`probedUntil` 과 `boundAddr` 이 예전 토큰의 판정을 그대로 들고 있었다.** 토큰이
  실제로 바뀌었을 때만 지우고 개수를 events.log 에 남긴다
  (`ident: token set, dropped N past verdict(s)`)
- iOS 는 `adoptToken` 의 **실패가 안 보이는 것**만 고쳤다 (컴파일 검증 못 했음):
  `tokenText` 를 서비스 재등록 전에 쓰던 것, 라디오 꺼진 채 계정 등록하면 조용히
  아무 일도 안 하던 것, `didAdd` 실패에도 초록 등이 켜져 있던 것

## 그 앞 세션들: 네 가지

### 1. 연속 2샘플 규칙 (client/main.cpp ScanThread)

스무딩 값 하나가 임계값 아래로 내려가면 바로 FAR 였다. 이제 **새 샘플이 연속 둘**
미만일 때만 잠근다. 시간이 아니라 샘플을 센다 - 샘플 식별은 `LastReceivedTick()` /
`LastReportTick()`. 상한 `BELOW_SAMPLE_CAP_MS = 6000` (client/common.h). `rssi <= -100`
은 부재이므로 즉시 잠근다. 실측: 광고 경로 잠금의 31%, GATT 17% 가 단발 패킷이었다.

### 2. 계정(구글)으로 폰 등록 - 완료, 실기 검증됨

폰과 PC 가 같은 구글 계정으로 로그인해 서버에서 같은 토큰을 받는다. BLE 등록도
그대로 남아 있다. 서버: `device_tokens` (supabase/device_tokens.sql), anon 정책 없음.
`claim_device_token()` 은 행이 있으면 그 값을 돌려준다 = 앱 재설치 복구. PC:
`client/enterprise/auth.cpp` - PKCE + 루프백(127.0.0.1) + DPAPI. `tools/authtest.cpp`
가 자체 점검과 `--login` / `--claim` / `--unclaim`. iOS: `ASWebAuthenticationSession`.

### 3. 잠금 화면

원격 세션(RDP)에서는 자동으로 안 잠근다 (`SM_REMOTESESSION` 이라 TeamViewer·AnyDesk
는 안 걸린다). 사용자가 직접 누른 잠금은 자동 해제되지 않는다 (`g_bManualLock`).
듀얼 모니터는 콘텐츠·[해제]·배너를 모니터마다. 영상은 MFPlay 플레이어가 하나라
주 모니터에만.

### 4. 설정 화면 분리 - 간단 창 + 고급 창

기본 창은 `SmartScreenSimple`. 기존 설정 창(`SmartScreenBT`)은 숨긴 채 [고급 설정]
으로 연다 - **자동 시작·기업 동기화·기기 목록이 그 창의 WM_CREATE 에 있어서 안
만들면 프로그램이 안 뜬다.** 오너드로. 명령은 고급 창으로 넘긴다. 트레이 아이콘이
없다 - **오버레이 위젯의 [설정]** 이 앱으로 돌아오는 유일한 길. 거리 3단계는
`measuredBaseRssi` 의 오프셋(+6/0/-6). 재보기 마법사(착석 60초 → 폰 두고 오기 →
비움 45초)가 어댑터도 판정한다.

## 남은 작업

### 1. iOS 재설치 시험 (다시 우선)

`adoptToken` 의 몸통은 **아직 한 번도 실행된 적이 없다.** Mac + 아이폰이 있어야 한다.
왜 안 돌았나: 서버에 행을 만든 게 그 폰이라 `claim_device_token` 이 같은 값을
돌려줬고 `guard d != token` 에서 빠져나갔다. 특성 값은 `add()` 시점에 박히므로
토큰을 바꾸려면 서비스를 통째로 다시 올려야 한다 (`removeAllServices` →
`addIdentService`).

**절차** — 서버 행을 지우면 안 된다. 이 시험의 요점이 "서버가 옛 값을 들고 있다"다.

1. 지금 토큰의 앞 4바이트를 적어 둔다 (폰 화면의 `기기 토큰`, 또는 PC 고급 창) = T1
2. 아이폰에서 앱을 **삭제**하고 Xcode 로 다시 설치한다 (새 토큰 T2). 화면의 토큰이
   T1 과 달라진 것을 확인한다
3. 앱에서 `구글 계정으로 연결` → 같은 계정으로 로그인
4. **폰**: 화면의 `기기 토큰` 이 **T1 로 돌아와야 한다.** "토큰 적용 중" 에서 멈춰
   있거나 등록 실패 문구가 뜨면 거기가 고장난 곳이다
5. **PC**: 등록을 다시 하지 않는다. 감시를 `중지 → 시작` 하고 events.log 에 `ident:
   bound to ...` 가 뜨는지 본다. **중지→시작이 필수다**: 2~3단계 사이에 PC 가 T2 를
   읽어 "남의 기기" 로 10분간 접어 두는데(`kRetryNotOursMs`) `Stop()` 이 그걸 비운다

폰이 T1 을 내주는지 PC 없이 직접 보려면 `ProbeScan.exe` 를 쓴다.

### 2. App Store 심사 4.8

구글 로그인만 넣고 제출하면 Sign in with Apple 도 요구될 수 있다. Supabase 가 Apple
provider 를 지원한다. 사내 배포(TestFlight 내부)면 해당 없다.

### 3. 검토해 볼 것

- **`contents` 가 로그인 없이 읽히는 것을 실제로 확인했다 (2026-09-30).** anon key
  만으로 `contents` 전 행(전 org)이 나오고, `content` 버킷의 **파일 바이트도 나오고
  목록도 열린다** (HTTP 206 / list 200). 버킷이 public 이어서가 아니라
  `storage.objects` 의 anon 정책 때문이다. 대조군 `device_tokens`·`clip_items`·`orgs`·
  `org_members`·`clip` 버킷은 전부 막혀 있다. 그 anon key 는 배포 zip 의 exe 에 박혀
  있다. **`supabase/schema.sql` 이 라이브와 어긋나 있다**: 라이브에는 `active` 열과
  anon 정책이 있고 schema.sql 에는 둘 다 없다 - schema.sql 로 새 프로젝트를 세우면
  `FetchManifest` 의 `active=eq.true` 가 400 을 받는다. 조이려면 기업 PC 마다 구글
  로그인이 필요해진다 (`org_release_approvals` 도 같은 이유로 anon 읽기다) - 그 대가를
  받아들일지는 정해지지 않았다. anon 이 `contents` 에 **쓸** 수 있는지는 확인 못 했다
  (쓰기 시험은 하지 않았다). 쓸 수 있다면 잠금 화면에 아무 그림이나 밀어 넣을 수
  있으므로 먼저 볼 것
- 자동 업데이트에서 안 해 본 것: 실패 기록 뒤 [다시 시도], 화면이 가려진 채로 Ready
  가 됐을 때 풀리면 적용되는지, `updateChannel=beta`, 세 대 이상. 검토에서 저위험으로
  남긴 것: 복사본이 pid 만으로 원래 프로세스를 찾는 것(실제로는 살아 있을 때
  시작되므로 닿기 어렵다), 두 번째 인스턴스가 뮤텍스를 10초 기다리는 것
- 영상을 양쪽 모니터에 띄우려면 `client/video/player.cpp` 가 플레이어를 여러 개
  지원해야 한다 (지금 `s_player` 가 하나뿐)
- 간단 창이 430x750 (띠가 보이면 850). 또 늘릴 일이 생기면 접기나 스크롤
- 클립보드에서 아직 안 해 본 것: 4 MB 상한 근처의 큰 그림, 세션이 실제로 만료된 뒤의
  자동 갱신(한 시간 뒤), 세 대 이상. 파일(`CF_HDROP`)은 안 넘긴다

## 작업 환경

- **새 버전 내놓기: `release.bat` 더블클릭** (위 "release.bat"). 낱개로는
  `cmd.exe /c do_build.bat` → `publish.bat --notes "..."` (`--list`, `--deactivate 1.2.3`,
  `--channel beta`, `--force`). `.env` 를 읽는다. `build\Publish.exe --selftest` 는
  서버 없이 해시·버전 비교를 점검한다
- 빌드: `cmd.exe /c do_build.bat` (MSVC x64 + CMake + nmake). **SmartScreen.exe 가 실행
  중이면 링크가 실패한다** - 그리고 그러면 `Publish.exe` 가 낡은 빌드라고 거절한다.
  별도 타깃만 필요하면 `nmake AuthTest` 처럼 지정. 앱을 건드리지 않고 컴파일만
  확인하려면 다른 빌드 디렉터리(`build-*` 는 .gitignore)에 cmake 를 돌린다
- **앱을 정상 종료하는 길은 오버레이 위젯의 [종료] 하나뿐이다.** 창의 X 는 숨기기만
  한다. 스크립트에서는 `SmartScreenOverlay` 창에 `WM_COMMAND`/`401`(`ID_OVL_EXIT`).
  PowerShell 에서는 `tools/release.ps1` 의 앱 종료 블록을 그대로 쓰면 된다
  (`FindWindow` 의 둘째 인자는 `IntPtr` 로 - 아래 함정)
- 배포 묶음: `make_dist.bat` → `dist\` → `SmartScreen-desktop.zip` (release.bat 이 만든다).
  README.txt 는 저장소가 추적하는 원본이라 make_dist 가 건드리지 않는다. 새로 까는
  PC 만 zip 이 필요하다 - 깔린 PC 는 서버에서 받는다
- 진단: `%APPDATA%\SmartScreen\` 의 events.log(기본 켜짐; `update:` 줄이 업데이트
  단계마다 남는다), ble_scan_log.csv, gatt_rssi_log.csv (뒤 둘은 `bleDebugLog=1` 일 때만)
- 업데이트 적용 경로 시험: `SmartScreen.exe --apply-update 0 <src> <dst> --sha <hex>
  --ver 9.9.9 --no-relaunch` (pid 0 = 기다리지 않음). src 는 `%APPDATA%\SmartScreen\update\`
  안에, dst 이름은 `SmartScreen.exe` 여야 받는다
- 클립보드 점검: `SmartScreen.exe --clip-test` (앱이 떠 있어도 된다). 결과는 창과
  `%APPDATA%\SmartScreen\clip-test.txt`
- 임계값 분석: `tools\rssi-threshold.ps1`. 구글 로그인 점검: `build\AuthTest.exe`
- 서버 스키마는 `supabase/*.sql` 을 대시보드 SQL Editor 에 붙여 넣어 적용한다
  (`schema.sql` / `device_tokens.sql` / `clipboard.sql` / `releases.sql`). 넷 다 적용돼 있다
- `.env` 에 Supabase URL/anon key 가 있다 (커밋 안 됨, `.env.example` 이 형식)
- config.ini 편집은 앱을 완전히 종료한 뒤에. 안 그러면 앱이 덮어쓴다
- iOS 는 Mac + Xcode 로만 빌드된다. **Swift 를 고치면 "컴파일 검증 못 했음"을 분명히
  말할 것** (저장소에 .xcodeproj 가 없어서 SSBeaconApp.swift 한 파일만 고쳐 왔다)
- Git Bash 에서 `cmd.exe /c x.bat` 은 `/c` 가 `C:/` 로 바뀌어 **배너만 찍고 끝난다.**
  `MSYS_NO_PATHCONV=1 cmd.exe /c ...`. `publish.bat --notes "한글"` 도 Git Bash 에서는
  따옴표가 깨진다 - cmd 에서 돌리거나 `build\Publish.exe` 를 직접 부를 것

## 함정

### 빌드 스크립트의 보고를 믿지 말 것 (release.ps1 에서 세 번)

- PowerShell 은 `$null` 을 .NET `string` 매개변수에 `""` 로 넘긴다. `FindWindow(cls,
  $null)` 은 "제목이 빈 창" 을 찾아 아무것도 못 찾는다. 둘째 인자를 `IntPtr` 로 선언
- PowerShell 이 네이티브 명령에 넘기는 인자 안의 `"` 는 `\"` 로 바뀐다. `cmd /c "call
  ""x.bat"" > ""log"""` 는 아무것도 못 하고 끝난다. 그리고 스크립트가 **지난번 로그
  파일**을 읽어 `BUILD_SUCCESS` 를 봤다 - 옛 로그는 먼저 지우고, 빌드 뒤 exe 시각과
  `Publish.exe --version` 을 직접 본다
- 네이티브 명령의 stderr 는 오류 레코드가 되고 `ErrorActionPreference=Stop` 이면
  vcvarsall 의 잡음 한 줄에도 스크립트가 죽는다. `Continue` 로 두고 `$LASTEXITCODE`

### 헤더만 바꾸면 다시 빌드되지 않을 수 있다 (do_build.bat 의 VSLANG)

CMake 의 NMake 생성기는 cl.exe 의 `/showIncludes` 출력에서 헤더 의존성을 읽는데, 그
접두어("참고: 포함 파일:")를 **글자로** 맞춘다. 콘솔 코드페이지가 처음 설정할 때와
다르면 접두어가 안 맞아 `.obj.d` 가 0 바이트로 남고, 그 뒤로는 `version.h` 만 바꿔서는
아무것도 다시 컴파일되지 않는다 - 빌드는 "성공" 하고 exe 는 낡은 채다. 실제로 그렇게
1.1.0 이 다시 올라갔다. `do_build.bat` 이 `VSLANG=1033` 으로 영어 접두어를 강제한다.
의심되면 `build\CMakeFiles\SmartScreen.dir\client\main.cpp.obj.d` 가 비어 있는지 보고,
비어 있으면 `build\CMakeCache.txt` 와 `build\CMakeFiles` 를 지우고 다시.

### 인라인 파이썬에 윈도 경로를 넣지 말 것

`python - <<'PY'` 안의 문자열에 `\build`, `\vcvarsall` 이 들어가면 `\b`(백스페이스),
`\v`(세로 탭)로 바뀌어 앵커가 조용히 안 맞는다. 이번에 두 번 밟았다. Write 로 스크립트
파일을 만들고 raw 문자열(r'...')을 쓸 것. `re.sub` 의 치환 문자열에 `\n` 을 넣으면
줄바꿈이 된다. bash heredoc 도 백슬래시를 먹는다 - 문자열 리터럴이 들어가는 수정은
Write 로 스크립트 파일을 만들어 실행하거나 Edit 도구를 쓸 것.

### 줄바꿈이 파일마다 다르다

LF: `client/main.cpp`, `ble_rssi.cpp`, `config.cpp`, `enterprise/auth.cpp`, `update.cpp`,
    `dist/README.txt`, `supabase/*.sql`, `tools/*.ps1`, `tools/publish.cpp`, `NEXT_SESSION.md`,
    `docs/dashboard.html`, `release.bat`, `publish.bat`, `make_dist.bat`
CRLF: `client/blackscreen.cpp`, `ble_gatt.cpp`, `common.h`, `enterprise/supabase.cpp`,
      `docs/*.md`, `ios/SSBeacon/SSBeaconApp.swift`, `do_build.bat`

`core.autocrlf=true` 라서 `git ls-files --eol` 의 `w/` 열이 작업본의 실제 상태다.
`tr -cd '\r' < 파일 | wc -c` 로 CR 바이트를 직접 세고 LF 개수와 같은지 본다. python 으로
일괄 치환하면 파일 전체가 뒤집힌다 - **수정 전후로 CR/LF 개수를 세서 확인할 것.**

### 인코딩

- `.bat` 는 ASCII 로만. cmd.exe 가 시스템 코드페이지(CP949)로 읽는다
- **`.ps1` 에 한글을 쓰면 UTF-8 BOM 이 필요하다.** 없으면 PowerShell 5.1 이 CP949 로
  읽어 파싱 에러가 난다. `release.ps1` 은 BOM 이 있다 - Write 로 다시 쓰면 BOM 이
  빠지므로 덧붙일 것
- `.cpp` 는 UTF-8 (BOM 없음), CMake 가 `/utf-8` 을 준다
- `Publish.exe` 가 콘솔 코드페이지를 UTF-8 로 바꾸는데 그건 콘솔 전체 설정이다. 같은
  콘솔에서 뒤에 CP949 로 쓰면 깨진다 - release.ps1 이 처음부터 UTF-8 로 쓰는 이유

### swprintf_s 는 잘라 쓰지 않는다

넘치면 CRT 의 invalid-parameter 핸들러가 프로세스를 끝낸다 (릴리스 빌드). 서버에서
오는 문자열을 고정 버퍼에 쓸 때는 `_snwprintf_s(buf, _countof(buf), _TRUNCATE, ...)`
를 쓰고 길이도 잘라라. 관리자가 370자 메모를 올리면 그 채널의 모든 PC 가 1초마다
죽는 모양이었다.

### 로그에 날짜가 없다

events.log, ble_scan_log.csv, gatt_rssi_log.csv 모두 **날짜 없이 계속 이어 붙는다.**
시각으로 자르지 말고 세션 경계(`# session`, `START thr=`, `start: SmartScreen x.y.z`)를
기준으로 볼 것.

### Supabase 가 조용히 다른 곳으로 보낸다

허용 목록(Redirect URLs)에 없는 `redirect_to` 를 **오류로 만들지 않고 Site URL 로
바꿔치기한다.** 폰 로그인이 엉뚱한 페이지에서 멈추고 앱에는 성공도 실패도 안 뜬다.
client_id 와 secret 이 짝이 안 맞으면 **authorize 는 통과하고 토큰 교환에서만** 거절한다
(`Unable to exchange external code`).

### 서버에 행이 있으면 폰이 고장나도 PC 는 성공한다

`device_tokens` 에 행이 남아 있으면 PC 가 그걸 읽어 성공한다. 폰 쪽 등록 경로를
확인하려면 **먼저 행을 지워야 한다** (`AuthTest.exe --unclaim <url> <key>`).

### 블루투스 컨트롤러가 먹통이 될 수 있다

스캔은 멀쩡한데 연결 개시만 전부 Unreachable 이 되는 상태. 라디오 껐다 켜기로는 안
풀리고 재부팅이 필요했다. (폰이 실제로 멀리 있을 때도 같은 로그가 나온다.)
`ConnectionStatus` / `GattSession` 으로 판정하지 말 것 - 서비스 탐색에 성공한 기기도
Disconnected / Closed 로 보고됐다. `GattDeviceService` 는 반드시 `Close()` 할 것.

### "쓰인 적 없는 코드는 틀린 줄 모른다"

매 세션 나온다. `g_bManualLock` 은 세팅만 되고 아무도 안 읽고 있었고, `RefreshSession`
은 앱에서 불린 적이 없었고, 자동 업데이트의 실패 경로 셋은 검토에서만 잡혔다. 오래
잠자던 경로를 켤 때는 그 경로가 의존하는 값들을 먼저 의심할 것.

**변종: "한 번만 불리던 함수".** `SetIdentity` 는 스캔 시작 직전에 딱 한 번 불렸고, 그
전제 위에 세 가지가 얹혀 있었다. "한 번만 불린다"는 가정을 찾았을 때는 셋을 따로
물어야 한다. 정말 한 번만 불리나(스레드가 살아 있으면 아니다), 두 번째로 불려야 하는데
안 불리고 있는 건 아닌가, 두 번째 호출에서만 드러날 상태가 남아 있나.

### 증상이 어느 쪽 것인지 먼저 가를 것

클립보드 첫 실기에서 전송은 다 됐고 실패한 것은 **받는 앱**이었다. 알파를 의심했고
틀렸다. **양쪽을 나란히 열거해 보는 것이 먼저다** - 그럴듯한 원인을 코드로 고치기 전에
실제로 무엇이 있는지 본다 (docs/CLIPBOARD.md "형식이 모자랐던 일").

### UI 작업 확인 방법

`PrintWindow` 로 창을 직접 캡처해서 볼 수 있다. 단 **숨겨진 창은 검게 나온다** -
`ShowWindow(h, SW_SHOW)` 를 먼저. 오너드로 버튼을 쓰면 `WM_CTLCOLORSTATIC` 을 반드시
처리할 것.

## 현재 기기 상태

- 노트북(LG gram 14Z990, Intel 내장): **1.1.4**, 기업 등록(`enterpriseRegistered=1`,
  orgId `0dca070f-…`), `measuredBaseRssi=-61`, `nearRssiThreshold=-67` (거리 3단계의
  [멀리]), `gattRssiThreshold=-61`, `bleDebugLog=0`. IRK 와 폰 토큰 둘 다 설정돼 있다.
  앱은 `C:\work\smartscreen\dist\SmartScreen.exe` 로 돌고 있다 (release.bat 이 그걸
  닫았다 다시 띄운다)
- 데스크톱: **1.1.4**, 듀얼 모니터. 기업 등록인지 개인인지는 이 세션에서 확인 못 했다
- 두 대 모두 클립보드 공유 켜짐, 같은 구글 계정(icesgg@gmail.com)
- Supabase: 네 스키마(`schema`/`device_tokens`/`clipboard`/`releases`) 적용됨.
  `releases` 에 1.1.0·1.1.1·1.1.2·1.1.3·1.1.4 (1.1.0 은 낡은 빌드가 실수로 다시 올라간 것 -
  해는 없음). `release_admins` 에 icesgg@gmail.com. 대시보드(GitHub Pages)에 승인 칸이
  올라가 있고 [승인] 단추로 1.1.3 을 승인해 노트북이 받았다 (사용자 보고)
- `client/version.h` = 1.1.4 = 서버의 마지막 = `build\` = `dist\` = `SmartScreen-desktop.zip`
