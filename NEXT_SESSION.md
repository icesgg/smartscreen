SmartScreen 프로젝트를 이어서 개발한다. 저장소: C:\work\smartscreen (main 브랜치, 최신 푸시됨)

설계 배경은 docs/PROXIMITY.md, 식별 구조는 docs/IDENTIFICATION.md 에 있다. 먼저 읽어라.

## 지금 상태

자리 비움을 감지해 화면을 가리는 Windows 앱 + iOS 컴패니언 앱(ios/SSBeacon).
BLE 신호 세기(RSSI)로 거리를 판단한다.

직전 세션에서 네 가지를 했다.

### 1. 연속 2샘플 규칙 (client/main.cpp ScanThread)

예전에는 스무딩 값 하나가 임계값 아래로 내려가면 바로 FAR 였다. 이제 **새 샘플이
연속 둘** 미만일 때만 잠근다. 시간이 아니라 샘플을 세는 것이 요점이다 - 패킷
사이에는 새 정보가 없지만 두 번째 패킷은 실제로 새 정보다.

- 샘플 식별은 `LastReceivedTick()` / `LastReportTick()` 으로 한다. 루프 반복을
  세면 같은 값을 두 번 세게 되고, 그건 주석이 거부하는 "시간 유예"와 같아진다
- 상한 `BELOW_SAMPLE_CAP_MS = 6000` (client/common.h). 걸어나가며 신호가 끊기면
  두 번째 샘플이 영영 안 오는데 수신 타임아웃은 90초다
- `rssi <= -100` 은 약한 게 아니라 부재이므로 즉시 잠근다
- 실측: 광고 경로 잠금의 31%, GATT 17% 가 단발 패킷이었다. 양 경로 실기 검증함

### 2. 계정(구글)으로 폰 등록 - 완료, 실기 검증됨

BLE 핸드셰이크 대신 폰과 PC 가 같은 구글 계정으로 로그인해 서버에서 같은 토큰을
받는다. BLE 등록도 그대로 남아 있다 (인터넷 없을 때).

- 서버: Supabase `device_tokens` (supabase/device_tokens.sql). 계정당 한 행, RLS 로
  자기 행만. **anon 정책을 하나도 두지 않았다** - 토큰을 아는 사람은 남의 화면을
  열어둘 수 있으므로 contents 테이블과 성격이 정반대다
- `claim_device_token()` 은 행이 있으면 그 값을 돌려준다. 이게 **앱 재설치를 복구**한다
- PC: `client/enterprise/auth.cpp` - PKCE + 루프백(127.0.0.1) + DPAPI. `tools/authtest.cpp`
  가 자체 점검(RFC 7636 시험값 포함)과 `--login` / `--claim` / `--unclaim` 을 한다
- iOS: `ASWebAuthenticationSession`. Info.plist 설정 불필요 (세션이 스킴을 가로챈다)
- **행을 지운 뒤 폰만으로 다시 만들어 확인했다.** 다른 PC 에서 로그인만으로
  등록되는 것도 확인됨

### 3. 잠금 화면

- **원격 세션(RDP)에서는 자동으로 안 잠근다.** 이미 잠겨 있으면 풀어 준다.
  단 직접 누른 잠금은 원격이든 아니든 유지된다
  ※ `GetSystemMetrics(SM_REMOTESESSION)` 이라 RDP 계열만 안다. TeamViewer·AnyDesk 는
    콘솔 세션을 써서 안 걸린다
- **사용자가 직접 누른 잠금은 자동 해제되지 않는다.** `g_bManualLock` 이 예전부터
  세팅만 되고 아무도 안 읽고 있었다. [해제] 버튼으로만 풀린다
- **듀얼 모니터**: 콘텐츠를 모니터마다 따로 배치한다. 예전엔 가상 화면 한가운데에
  그려서 두 화면 경계에 걸쳤다. [해제]와 배너도 모니터마다 하나씩
  ※ 영상은 MFPlay 가 호스트 창을 채우고 플레이어가 하나뿐이라 **주 모니터에만** 나온다
- 배너는 이미지가 있을 때만 만든다

### 4. 설정 화면 분리 - 간단 창 + 고급 창

기본으로 열리는 창이 `SmartScreenSimple` 로 바뀌었다. 기존 설정 창(`SmartScreenBT`)은
만들어는 두고 숨긴 채 [고급 설정] 으로 연다 - **자동 시작·기업 동기화·기기 목록이
전부 그 창의 WM_CREATE 에 있어서 안 만들면 프로그램이 안 뜬다.**

- 윈도우 11 빠른 설정 모양. 버튼과 트랙바를 전부 오너드로로 직접 그린다
- 폰 등록·그림 고르기·지금 가리기·보호 시작/중지는 **고급 창으로 명령을 넘긴다**
  (여기서 다시 구현하면 두 벌이 된다)
- 트레이 아이콘이 없다. **오버레이 위젯의 [설정]** 이 앱으로 돌아오는 유일한 길이다
- 거리 3단계는 절대 dBm 이 아니라 `measuredBaseRssi` 의 오프셋(+6/0/-6)이다
- **재보기 마법사**: 착석 60초 → 폰만 두고 오기(버튼) → 비움 45초.
  어댑터도 같이 판정한다 (표본 부족 / 값이 안 흔들림 = 세기를 못 재는 장치 /
  구간 겹침). 값을 못 믿으면 쓰지 않는다
- `자리비움 감지` 는 고급 창에서 없앴다. `keepAliveSec` 은 latency 경로에서만
  쓰이는데 컴패니언 앱이 그 경로를 안 타게 만든다 = 조작해도 아무 일이 안 일어났다.
  값과 코드는 남아 있다

## 남은 작업

### 1. iOS 재설치 시험 (우선)

`adoptToken` 은 **한 번도 실행된 적이 없다.** 앱을 지웠다 다시 깔고 구글 로그인하면
서버에 있던 옛 토큰을 도로 받아 와야 한다. 이 저장소가 반복해서 배운 게
"쓰인 적 없는 코드는 틀린 줄 모른다" 이다.

특성 값이 `add()` 시점에 박히므로 토큰을 바꾸려면 서비스를 통째로 다시 올려야 한다
(`removeAllServices` → `addIdentService`). 그 경로가 실제로 도는지 봐야 한다.

### 2. App Store 심사 4.8

구글 로그인만 넣고 제출하면 Sign in with Apple 도 요구될 수 있다. Supabase 가 Apple
provider 를 지원한다. 사내 배포(TestFlight 내부)면 해당 없다.

### 3. 검토해 볼 것

- `contents` 테이블이 **로그인 없이 읽힌다.** 지금 기업 기능이 anon key 로만
  접근하는 구조라 그렇다. 조직이 하나뿐이라 실질 노출은 자기 콘텐츠지만, 조직이
  둘 이상이 되면 exe 에 박힌 공개 키만으로 남의 조직 콘텐츠가 읽힌다.
  이제 앱에 구글 로그인이 있으니 `device_tokens` 처럼 조일 수 있다
- 영상을 양쪽 모니터에 띄우려면 `client/video/player.cpp` 가 플레이어를 여러 개
  지원해야 한다 (지금 `s_player` 가 하나뿐)
- 간단 창이 430x654 다. 항목이 더 늘면 스크롤이나 접기가 필요하다

## 작업 환경

- 빌드: `cmd.exe /c do_build.bat` (MSVC x64 + CMake + nmake)
  **SmartScreen.exe 가 실행 중이면 링크가 실패한다.** 별도 타깃만 필요하면
  `nmake AuthTest` 처럼 지정하면 앱이 떠 있어도 빌드된다
- 배포 묶음: `make_dist.bat` → `dist\` → 압축은 손으로 `SmartScreen-desktop.zip`
  README.txt 는 저장소가 추적하는 원본이라 make_dist 가 건드리지 않는다
- 진단: `%APPDATA%\SmartScreen\` 의 events.log(기본 켜짐), ble_scan_log.csv,
  gatt_rssi_log.csv (뒤 둘은 `bleDebugLog=1` 일 때만)
- 임계값 분석: `tools\rssi-threshold.ps1` (앱 켜둔 채 돌려도 된다)
- 구글 로그인 점검: `build\AuthTest.exe` (인자 없으면 자체 점검만)
- `.env` 에 Supabase URL/anon key 가 있다 (커밋 안 됨, `.env.example` 이 형식)
- config.ini 편집은 앱을 완전히 종료한 뒤에. 안 그러면 앱이 덮어쓴다
- iOS 는 Mac + Xcode 로만 빌드된다. **Swift 를 고치면 "컴파일 검증 못 했음"을 분명히 말할 것**
  (저장소에 .xcodeproj 가 없어서 파일을 새로 만들면 사용자가 타깃에 넣어야 한다.
   그래서 SSBeaconApp.swift 한 파일만 고치는 쪽으로 해 왔다)

## 함정

### 줄바꿈이 파일마다 다르다

LF: `client/main.cpp`, `ble_rssi.cpp`, `config.cpp`, `enterprise/auth.cpp`,
    `dist/README.txt`, `supabase/*.sql`, `tools/*.ps1`
CRLF: `client/blackscreen.cpp`, `ble_gatt.cpp`, `common.h`, `docs/*.md`

python 으로 일괄 치환하면 파일 전체가 뒤집힌다. **수정 전후로 CR/LF 개수를 세서
확인할 것.** CRLF 파일을 여러 줄 고칠 때는 바이트 단위로 읽어 `\r\n` 을 유지하는
스크립트를 쓰는 편이 안전하다.

### 인코딩

- `.bat` 는 ASCII 로만. cmd.exe 가 시스템 코드페이지(CP949)로 읽는다
- **`.ps1` 에 한글을 쓰면 UTF-8 BOM 이 필요하다.** BOM 없이 저장하면 PowerShell 5.1
  이 CP949 로 읽어 한글이 깨진 채 파싱 에러가 난다 (이번에 밟았다)
- `.cpp` 는 UTF-8 (BOM 없음), CMake 가 `/utf-8` 을 준다

### bash heredoc 이 백슬래시를 먹는다

문자열 리터럴이 들어가는 수정은 Write 로 스크립트 파일을 만들어 실행하거나
Edit 도구를 쓸 것.

### 로그에 날짜가 없다

events.log, ble_scan_log.csv, gatt_rssi_log.csv 모두 **날짜 없이 계속 이어 붙는다.**
같은 `09:00:00` 이 어제치에도 있다. 시각으로 자르지 말고 세션 경계(`# session`,
`START thr=`)를 기준으로 볼 것. `rssi-threshold.ps1` 은 기본이 마지막 세션이다.

### Supabase 가 조용히 다른 곳으로 보낸다

허용 목록(Redirect URLs)에 없는 `redirect_to` 를 **오류로 만들지 않고 Site URL 로
바꿔치기한다.** 그래서 폰 로그인이 엉뚱한 페이지에서 멈추고, 앱에는 성공도 실패도
안 뜬다. 이번에 이걸로 한참 헤맸다.

또 client_id 와 secret 이 짝이 안 맞으면 **authorize 는 통과하고 토큰 교환에서만**
거절한다 (`Unable to exchange external code`). Google Cloud 쪽에서 "이 클라이언트는
사용된 적 없음" 경고가 같은 사실을 반대편에서 말해 준다.

### 서버에 행이 있으면 폰이 고장나도 PC 는 성공한다

`device_tokens` 에 행이 남아 있으면 PC 가 그걸 읽어 성공한다. 폰 쪽 등록 경로를
확인하려면 **먼저 행을 지워야 한다** (`AuthTest.exe --unclaim <url> <key>`).

### 블루투스 컨트롤러가 먹통이 될 수 있다

스캔(수신)은 멀쩡한데 연결 개시만 전부 Unreachable 이 되는 상태. 라디오 껐다 켜기로는
안 풀리고 재부팅이 필요했다. 헤드폰 경합이나 본딩을 의심하기 전에 재부팅부터.
(다만 폰이 실제로 멀리 있을 때도 같은 로그가 나온다. 폰을 가져온 뒤에도 계속 그러면
그때 의심할 것)

### ConnectionStatus / GattSession 으로 판정하지 말 것

서비스 탐색에 성공한 기기도 끝까지 Disconnected / Closed 로 보고됐다.

### GattDeviceService 는 반드시 Close() 할 것

안 닫으면 Windows 가 LE 연결을 물고 있어서 몇 대만 훑어도 이후 연결이 전부 Unreachable.

### "쓰인 적 없는 코드는 틀린 줄 모른다"

이번 세션에도 두 번 나왔다. `g_bManualLock` 은 세팅만 되고 아무도 안 읽고 있었고,
`bleDebugLog=0` 이 GATT 로그는 안 끄고 있었다(그 설정이 생긴 이래 계속). 오래 잠자던
경로를 켤 때는 그 경로가 의존하는 값들을 먼저 의심할 것.

### UI 작업 확인 방법

`PrintWindow` 로 창을 직접 캡처해서 눈으로 볼 수 있다. 단 **숨겨진 창은 검게 나온다** -
`ShowWindow(h, SW_SHOW)` 를 먼저 불러야 한다. 오너드로 버튼을 쓰면
`WM_CTLCOLORSTATIC` 을 반드시 처리할 것. 안 하면 `DefWindowProc` 이 COLOR_BTNFACE 를
돌려줘서 라벨마다 회색 상자가 얹힌다.

## 현재 기기 상태

- 노트북(LG gram 14Z990, Intel 내장): `nearRssiThreshold=-61`, `measuredBaseRssi=-61`
  (마법사로 잰 값). `bleDebugLog=0`
- 데스크톱: 듀얼 모니터. 계정 로그인만으로 등록되는 것과 재보기 마법사까지 확인됨
- Supabase 프로젝트는 복구되어 살아 있다. 기업 콘텐츠 동기화도 동작한다
