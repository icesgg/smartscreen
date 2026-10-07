SmartScreen 프로젝트를 이어서 개발한다. 저장소: C:\work\smartscreen (main 브랜치, 최신 푸시됨)

설계 배경은 docs/PROXIMITY.md, 식별 구조는 docs/IDENTIFICATION.md,
클립보드 공유는 docs/CLIPBOARD.md, 자동 업데이트는 docs/UPDATE.md, Mac 판은 docs/MAC.md 에
있다. 먼저 읽어라.

## 지금 상태

자리 비움을 감지해 화면을 가리는 Windows 앱 + **Mac 앱(mac/, 2026-10-01 새로)** + iOS
컴패니언 앱(ios/SSBeacon). BLE 신호 세기(RSSI)로 거리를 판단한다.

여기에 붙은 기능이 둘 더 있다. 둘 다 자리비움 감지와 아무 상관이 없고, 계정
로그인과 Supabase 배관이 이미 여기 있어서 같은 앱에 들어왔다.

- 같은 구글 계정으로 로그인한 PC 끼리 클립보드를 주고받는다 (docs/CLIPBOARD.md)
- 새 버전을 서버에 올리면 모든 PC 가 스스로 받아 간다 (docs/UPDATE.md)

## 직전 세션 (뒤쪽): 폰 등록 창에 [등록 내역 삭제] (2026-10-06, main, 아직 안 내놓음 = 다음 release.bat 이 1.1.12)

사용자 요청 ("폰 등록 팝업창에 등록내역삭제 버튼도"). 사용자가 정한 것: **이 PC 의 폰 토큰 + 기기 키(IRK) 를 지우고 구글
로그인(클립보드 공유)은 그대로**, 서버 `device_tokens` 와 다른 PC 는 건드리지 않음, **보호가 켜져 있으면 함께 끈다**. Mac 은
기기 키 기능이 없어 토큰만 (설정 키 `bleIrk` 는 같은 이름이라 같이 비운다).

- 단추는 등록된 것(토큰 또는 기기 키, 아직 저장 못 한 로그인 토큰 포함)이 있을 때만 보인다. 창 본문에 한 단락이 붙는다:
  `[등록 내역 삭제]  이 PC 에서 폰 등록을 지웁니다` / `구글 로그인과 클립보드 공유는 그대로입니다.` (두 판 같은 글자)
- 흐름: 로그인 중이면 거절 → 확인 창(기본 아니요, "지울 것: 폰 토큰, 기기 키", 보호 중이면 "함께 끕니다") → config 를 새로
  읽어 `phoneToken`="" / `phoneOvfBit`=-1 / `bleIrk`="" 저장 (실패하면 아무것도 안 바꾸고 알림) → 저장 대기 중인 로그인
  토큰(`g_authSave.phoneToken`)도 비움 → 보호 끄기 → 스캐너의 신원·IRK 지우기, 배운 overflow 비트 버리기 → 목록과 간단 창
  ("아직 등록하지 않았어요" / [등록하기]) → 완료 창
- 로그 (두 판 같음): `register phone: registration deleted (token=1 irk=1, protection stopped)`,
  `register phone: delete NOT saved - registration kept`, `register phone: delete - nothing registered on this PC`
- **Windows 는 표준 MessageBox 로 단추 넷을 못 만든다** - 앱에 comctl32 v6 매니페스트가 없어 TaskDialog 도 못 쓴다 (부르면
  로드가 깨진다). 그래서 `client/choicebox.cpp/.h` (메모리 DLGTEMPLATE + DialogBoxIndirectParamW, 배치는 WM_INITDIALOG
  에서 픽셀로)를 새로 만들었다. 치수는 이 PC 에서 실제 MessageBoxW 를 찍어 잰 값이다 (아이콘 21,23 / 글 62,23 / 42px 회색 띠 /
  단추 75x23). [등록 내역 삭제(D)] 는 왼쪽 끝, [예(Y)] [아니요(N)] [취소] 는 예전 자리. 저장소 밖 하네스로 PrintWindow 캡처와
  키보드 11가지(Esc/Enter/Alt+D/Tab/X 등)를 확인했다. 띄우지 못하면 예전 3단추 MessageBoxW 로 물러난다
- Mac: `SmartScreenCore/PhoneRegistration.swift` (문구·지울 것·로그 줄, 시험 14개), `Alerts.yesNoCancel(_:title:destructive:)`
  4단추 (넷째는 빨간 글씨, 키 없음). Mac CI 337개 통과. 실기(지우기를 끝까지 누르기)는 두 판 모두 아직 안 했다 - 사용자의
  등록이 지워지므로 사용자가 직접 한다 (아래 "남은 작업")
- 설명서 두 개(`dist/README.txt` 2-(3), `mac/README.txt` (6))에 한 단락씩

## 직전 세션: 노트북 로그로 진단 + 1.1.11 준비 (2026-10-02 오전)

사용자가 결과 틀을 **하나도 채우지 않은 채** 왔다. 그래서 이 노트북의 events.log(1.1.10, 10-01 18:32 ~
10-02 07:35)를 직접 읽어 진단하고, 정할 것을 장단점과 함께 물어 사용자가 고른 것만 넣었다. **전부 main 에 있고
1.1.11 로 나갔다** (2026-10-02 11:21, 사용자 release.bat - 재보기 문구 c00e63c 도 함께). 아래 "현재 기기 상태". 맥북 로그는 없었다.

### 노트북 로그에서 나온 것

- **앉은 채 짧게 가려짐 4번** (19:53:53, 19:58:58, 19:59:23, 20:38:08). 모두 광고 경로, -68 ~ -72 (기준 -67),
  12~15초 뒤 풀림. 그때 폰은 노트북에 GATT 로 붙어 있지 않았다. 원인 후보가 둘이다:
  - 기준 -67 은 손으로 정한 값이고 1.1.10 에서 다시 재지 않았다 (`gattRssiOffset=0`). 1.1.9 때 GATT 경로도 같은
    -67 로 짧은 FAR 를 6번 냈다 → 주머니에 넣은 채 다시 재기는 어쨌든 필요하다
  - **노트북 자신의 토큰 프로버가 폰에 연결을 시작한 순간과 겹친다.** 4번 모두 프로브 시작 ±1.5초 안이었고, 로그 전체에서
    30초 이하 광고 FAR 의 43% 가 그 창에 있었다 (우연이면 16%). 이 노트북은 IRK 로 폰을 이미 알아보는데도 프로버가 20초마다
    연결을 시도해 거의 다 실패했다 (`probe failed` 3,106줄 = 로그의 53%). 같은 안테나라 광고를 놓치는 것으로 본다 - **원시값이
    없어(bleDebugLog=0) 메커니즘은 미증명**. 1.1.11 의 STATE 꼬리(`, probing for 1.3s`)로 다음 로그에서 바로 갈린다
- **노트북 → 폰 새 연결은 상태와 상관없이 거의 늘 실패한다** (약 99.5%). 성공은 폰이 막 이 PC 에 GATT 로 붙은 직후(그 링크를
  탐, ~1.1초)나 노트북이 깨어나거나 앱이 막 시작한 직후(3.4~4.1초)뿐이다. 맥북은 브리프상 주소가 바뀐 뒤 1~3초에 다시 묶었다.
  노트북은 IRK 덕에 판정에는 지장이 없었다
- **깨자마자 14초 가려짐** (06:40:19, 9시간 잠 뒤). GetTickCount64 는 잠든 시간을 센다 → 깨어난 첫 판정이 "90초 넘게 못 들음 =
  부재" 로 읽었다 (`GATT rssi=-100` 은 부재 갈래가 붙인 이름). Windows 잠금 화면 뒤에서 끝나 눈에는 안 보였을 것이다
- **클립보드 3건 사라짐** (06:46:53 ~ 06:49:24, id 252~254). 다른 기기에서 온 것을 받았는데 Windows 가 잠겨 있어
  (Winlogon 21:20:38 잠금 ~ 06:55:19 해제) 클립보드를 열지 못하고 버렸다. 다시 받을 길이 없다 (`s_seenId` 가 먼저 올라감)
- **재보기 함정**: 재보기 1단계 동안 키보드·마우스를 쓰면 PC 가 TICK 을 안 보내 연결 신호를 못 잰다 (두 판 같음)

### 사용자가 고른 것 (AskUserQuestion) 과 들어간 것

- 확인 연결(프로버): **네 가지 다** - IRK 로 알아보는 동안 쉬기(Windows), 시도 시작·끝 로그 + 실패 줄 요약(둘 다), 연속 실패 시
  간격 늘리기 15→30→60→120초(둘 다), GATT 로 붙은 지 60초 뒤 쉬기(Windows)
- 결함: **네 가지 다** - 재보기 중 TICK 1초(둘 다), 잠긴 동안 온 클립보드 보관 뒤 붙이기(Windows), 깨어난 직후 12초 유예 +
  Windows SLEEP/WAKE 줄(둘 다)
- 맥북 직접 읽기 스캔(R): **"GATT 가 붙어 있을 때만 끄기"** (+ 필터가 멎으면 다시 걸기)
- 남은 작업: **정지 결함만** (StopMon 15초 조인 + 같은 꼴의 GATT TickThread 3초 조인). keepalive TICK, ProbeScan 문구,
  대시보드 supabase-js 고정은 고르지 않았다

새 로그 줄 (두 판 글자 같음, 표시 없는 것은 둘 다):
- STATE 꼬리 `, probing for 1.3s` / `, probe ended 0.4s ago` (프로브가 돌고 있거나 끝난 지 3초 안)
- `ident: <id> probe failed x<N> since <HH:MM:SS> (last: <why>, <ms>ms)` - 첫 실패는 예전 줄 그대로, 그 뒤는 10번째마다와
  연속이 끝날 때만 (첫 실패 순으로)
- Windows: `ident: probes paused - IRK recognises the phone` / `ident: probes resumed - IRK has not matched for 30s` /
  `ident: probes held - GATT linked for 60s` / `ident: probes resumed - GATT link ended` / `ident: probes resumed - measuring` /
  `ident: <addr> back, bound again`
- `judge: slept <S>s - absence waits up to 12s for a fresh sample` / `judge: no sample within 12s of waking - absence applies`
- Windows: `SLEEP` / `WAKE` (WM_POWERBROADCAST, Mac 과 같은 글자), `scan thread did not stop in 15s - left to finish`,
  `GATT tick thread did not stop in 3s - left to finish`, `scan thread could not start (err=<n>)` (그때 상태 `시작 실패`)
- Mac: `scan: raw=off (GATT linked)` / `scan: raw=on (GATT not linked)` / `scan: raw=on (measuring)` /
  `scan: raw=on (filter quiet)` / `scan: filter restarted (no phone via filter for 30s)`
- Windows 클립보드: `clip: apply deferred - 클립보드를 열지 못했다 (err=, holder=, locked=)`, `clip: applied text (N bytes) after Ns`,
  `clip: deferred item replaced by a newer one`, `clip: deferred item dropped - newer local copy`,
  `clip: deferred item discarded - sync stopped`, `clip: read failed - ...`. 상태 글 `잠금이 풀리면 붙여요` / `클립보드가 비면 붙여요`.
  둘 다: `clip: text body gone before download (id=<n>)`

규칙 요점:
- 깨어남은 판정 스레드가 직접 잰다 (Windows `GetTickCount64 - QueryUnbiasedInterruptTime/10000`, Mac `CLOCK_MONOTONIC -
  CLOCK_UPTIME_RAW`, 반복 사이 5초 넘게 늘면). 새 광고·GATT 보고가 올 때까지 최대 12초 어느 갈래로도 FAR 로 안 간다. 새 샘플이
  유예를 끝내면 미만 카운터도 처음부터 센다 (잠들기 전 샘플과 짝짓지 않게)
- Mac R: GATT 가 10초 넘게 건강하고 **필터(F)가 묶인 폰을 30초 안에 줬을 때만** 끈다. 재보기 중엔 늘 켠다. F 다시 걸기는 120초에
  한 번까지 - R 이 10초 안에 묶인 폰을 줬으면 F 가 그 폰을, 근거가 GATT 뿐이면 F 가 신원 후보를 하나도 30초 못 줄 때 (주소가
  바뀐 폰은 새 식별자로 오므로)
- Windows GATT 쉼 중에도 조용해진 결합은 푼다 (`went quiet`). 찾지는 않지만 같은 주소가 다시 들리면 탐색 없이 다시 묶는다.
  재보기 중에는 쉬지 않는다
- 정지 결함: 판정·틱 스레드가 `DuplicateHandle` 로 자기 정지 이벤트를 쥐고 세대 번호(`g_scanGen`)를 본다. 브리프의 "이벤트를
  닫지 않기만" 으로는 모자랐다 - 스레드가 전역을 다시 읽어 다음 [시작] 의 이벤트를 이어받기 때문. [시작] 은 실패하면 닫힌 쪽으로
  (`시작 실패`, 감시 안 켬)

### 검토에서 바뀐 것, 남긴 것

워크플로 넷: (1) 진단 8갈래 + 반박 검증(갈래마다 1~2) (2) 구현 5갈래(각자 worktree·브랜치, Mac 은 갈래마다 CI) + 통합
(3) 검토 7관점 → 지적 30건, 건마다 반박 검증 둘 (4) 고치기 2갈래 + 통합 + 고친 것만 다시 검토. 마지막 세 건은 메인이 직접 고쳤다.
Mac CI 시험 248 → 323+. Windows 는 별도 폴더(`build-s11`, `build_in.bat`) 빌드만. **실기 확인은 하나도 없다.**

- **GATT 쉼이 묶은 주소를 얼려 두던 것** (검토, fail-open): 쉼 중에 폰이 주소를 바꾸면 옛 주소에 묶인 채 남아, GATT 가 끊기는
  순간 그 주소의 마지막 착석 RSSI 로 최대 bleTimeoutSec 까지 NEAR 가 날 수 있었다 (토큰만 쓰는 PC). 쉼 중에도 조용해지면 풀게
  고쳤다. 실측상 링크 중 재결합은 예전에도 1/22 만 성공했으므로 남은 차이는 작다
- **남긴 것 (판정 쪽, 이번 변경 전부터 있던 것 - 고치면 잠그는 시점이 바뀌므로 사용자가 정할 일)**:
  - 토큰만 쓰는 Windows PC(IRK 없음)에서 긴 GATT 링크 중 폰이 주소를 바꾸면 광고 경로가 눈이 먼다. 그 뒤 GATT 가 1초만 끊겨도
    `GATT rssi=-100` 으로 바로 가려진다 (main.cpp 의 `gattExpected && !IsReceiving` 갈래). 후보: GATT 를 막 잃었고 직전이 NEAR 면
    몇 초 다시 붙기를 기다리기 (두 판 같은 줄로)
  - GATT 가 끊긴 뒤 광고 경로가 마지막 광고 샘플을 bleTimeoutSec(90초)까지 쓴다 - 그 사이 주소가 바뀌었으면 묵은 착석 값이다
  - Mac 깨어남: 첫 프로버 틱이 묵은 결합을 풀어, 다시 묶기 전에는 광고로 유예를 끝낼 수 없다 (맥북은 다시 묶기가 1~3초라 낮음)
  - 틱 스레드가 3초 조인을 넘기면 Stop 이 비우는 provider 를 건드릴 수 있다 (드묾), 클립보드 바로 붙이기 경로의 `expectSeq=0`
    (예전부터), 엉뚱한 IRK(본딩된 마우스 등)면 IRK 쉼이 토큰 결합을 영영 막는다

## 그 앞 세션: Mac 실기 준비, iOS 컴파일 CI, Windows 결함 6건 (2026-10-01 오후)

사용자가 맥북 결과 칸을 **하나도 채우지 않은 채** 왔다 (`mac_releases` 를 anon 으로 읽어 보니 404 = SQL 도
아직). 결과를 기다리지 않고, **맥북 시험 한 번으로 최대한 많이 갈리게** 준비했다. 전부 main 에 있다.
Mac 은 세션 끝 무렵 사용자가 맥북에 깔아 **GATT 연결까지는 실기로 됐다** (아래 "현재 기기 상태" - 나머지
항목은 아직 결과를 못 받았다). 아이폰 새 소스는 아직 폰에 안 들어갔다. Windows 6건은 사용자가 "모두 넣기" 로 정해 main 에
합쳤고, 세션 끝에 사용자가 직접 release.bat 으로 **1.1.8** 을 내놓았다 - 그런데 Windows exe 의 업데이트
코드가 1.1.7 인 채로 나갔다 (함정 "헤더만 바꾸면"). 빌드를 고쳐 사용자가 바로 **1.1.9** 를 내놓았고,
노트북에서 `running`/`up to date (1.1.9` 까지 확인했다 (아래 "현재 기기 상태").

### Mac: 스캔을 둘로 (필터 + 직접 읽기)

- 포팅 전체의 전제(macOS 서비스 필터가 잠긴 폰의 overflow 광고를 맞춰 준다)가 미확인이라, 필터 없는 두 번째
  CBCentralManager 를 같이 돌린다. 제조사 데이터 `4C 00 01` + 16바이트에서 비트 하나짜리를 후보로 삼고, 번호는
  Windows `SingleOverflowBit` 와 같다 (b*8+k). 어느 쪽이 되든 앱은 폰을 찾는다
- 비트는 Windows 처럼 배워 `phoneOvfBit` 에 저장한다. **노트북 Windows 가 배운 값은 31** - 서비스 UUID 의
  해시라 폰마다 같을 것이지만 박아 넣지는 않았다
- 묶인 폰의 샘플은 400 ms 사본 제거(`DualSourceDedupe`)를 거친다. 두 스캔이 같은 패킷을 주면 2샘플 규칙이
  샘플을 두 번 센다
- events.log: `scan: filter=on raw=on`, `ident: bound to X (..., via raw bit 31[, app on screen])`
  (via = 묶기 직전 10초 안에 그 폰을 준 스캔만), `ident: X locked adverts via filter + raw bit 31`
  (잠긴 폰을 실제로 주는 스캔 - 처음과 바뀔 때만), `ident: overflow bit is now N`
- `--probe-scan` 은 세 단계(필터만 20초 / 직접 읽기만 20초 / 둘 다 10초) 뒤 후보 최대 6대에 붙어 토큰을
  읽고, 붙여 넣을 `요약` 블록을 찍는다. 판정은 SmartScreenCore `ProbeScanResult` (시험 있음). 결과 줄:
  - `둘 다` / `필터 경로` / `직접 읽기 경로` - 그 길로 잠긴 폰의 토큰을 읽었다
  - `판정 못 함` - 폰은 봤는데 토큰을 못 읽었다 (연결 실패, 남의 토큰뿐). **결론 내지 말고 1~2분 뒤 다시**
  - `둘 다 안 됨` - 어느 스캔도 후보를 못 봤다. 그때만 GATT 경로뿐이다. `Apple 광고 키:` 줄에 비공개 키
    (`HashedServiceUUIDs` 따위)가 있으면 macOS 가 overflow 를 다른 키로 주는 것일 수 있다 - 그것부터 볼 것
- 결과가 `필터 경로` 만이면 직접 읽기 스캔은 주변 광고를 전부 받아 CPU 를 쓰므로 끌지 정할 것 (지금은 늘 켠다)

### Mac: 첫 실행에 걸릴 것들 (검토 → 반박 검증 둘로 확정한 것만 고쳤다)

- 터미널에서 돌린 진단은 블루투스 권한을 **터미널** 이 받는다. 허용 창을 60초 기다리고, 거부되면 그 터미널
  앱 이름을 댄다 (`__CFBundleIdentifier`). "어댑터 없음" 은 정말 `.unsupported` 일 때만
- 로그인 결과 창이 macOS 14+ 에서 브라우저 뒤에 숨는다 (`activate()` 는 요청일 뿐이고, Dock 도 Cmd-Tab 도
  없는 앱이다) → 앱이 비활성이면 `.floating` + `orderFrontRegardless`, 잠금 중에 뜬 창은 풀릴 때 올린다.
  로그인 성공 페이지가 "[설정] 을 누르라" 고 말한다 (Mac 만)
- [중지]→[시작] 이 GATT 서비스를 지웠다 다시 올려서, 붙어 있던 폰이 다시 구독하지 않았다 → 서비스와
  구독자를 그대로 둔다 (`GATT client subscribed (kept across restart)`)
- `SLEEP` / `WAKE` / `DISPLAY OFF` / `DISPLAY ON` 줄. 배터리의 맥북은 2분 뒤 화면을 끄고 잠든다 -
  그 뒤에 돌아오면 저절로 안 풀리는 것이 정상이다 (설명서에도 적었다)
- ~~유니버설 클립보드(아이폰에서 복사한 것)는 다른 PC 로 보내지 않는다~~ → **되돌렸다.** 첫 실기에서 아이폰 →
  Mac → Windows 로 넘어가는 것을 보고 사용자가 "이게 내가 원한거다". 거르는 갈래를 뺐다 (main, 다음 릴리스)
- 반박된 것: macOS 15.4 "붙여넣기 허용" 창 (개발자 미리보기로만 켜진다), 잠금 그림의 폴더 권한 창 (열기
  패널로 고른 파일은 `com.apple.macl` 로 다음 실행에도 열린다)

### iOS: 처음으로 컴파일 확인 (`.github/workflows/ios.yml`)

- `ios/**` 를 main / mac / ios 에 푸시하면 iOS SDK 로 typecheck + SIL 까지 (최소 iOS 15.0, Xcode 16.4,
  Xcode 26 새 프로젝트 설정, 26.6, 27 미리보기). iOS 16 API 를 넣은 카나리아가 거절되는지도 본다
- 기준선: "컴파일 검증 못 했음" 이던 코드(adoptToken 등)는 Xcode 16.4 에서 그대로 컴파일됐다. Xcode 26 새
  프로젝트 설정(MemberImportVisibility)에서만 `import Combine` 이 빠져 있었다 (고침)
- **PC 가 GATT 서비스를 지웠다 다시 올리면 폰이 다시 구독하지 않던 것.** Windows 에서도 보인다: 노트북
  events.log 의 08:15 / 08:19 재시작 뒤 08:47 (폰이 범위를 나갔다 올 때)까지 `GATT client subscribed` 가
  없고, 그동안 프로버는 같은 후보 `4E33E1C031B2` 에 18초마다 Unreachable 이었다. 주변장치는 central 을
  끊을 API 가 없어 폰이 묵은 연결을 쥐고 있던 것으로 본다
  → `didModifyServices` 로 다시 찾기 + TICK 감시 (60초 TICK 이 없으면 서비스를 다시 찾고, 그래도 없으면
  끊고 다시 붙는다. PC 는 입력 중에 TICK 을 안 보내므로 끊는 간격은 점점 늘린다). **잠긴 채 정지된 앱은
  깨울 사건이 없어 감시가 못 돈다** - 앱을 열거나 링크가 끊길 때 풀린다
- 런타임은 미확인이다. 사용자가 Xcode 로 다시 설치해야 폰에 들어간다

### Windows: Mac 에서만 고쳤던 결함 6건 (1.1.8 로 나감, 제대로 된 빌드는 1.1.9)

- **GATT 거짓 NEAR**: 구독 콜백이 폴링 간격을 정하기 전에 판정을 깨워서 간격 0 = "입력 중" 으로 읽혔다 →
  잠긴 화면이 0~9초 풀린다. 노트북 events.log 에 BLACK ON 중 **12번** (`GATT client subscribed` 바로 뒤
  `STATE FAR -> NEAR (GATT ... thr=X set=X)`). 잠금 해제 지연 10초라 가려졌을 뿐, 기본값 "즉시" 면 실제로
  풀린다. 이제 `pollMutex` 아래 간격·시각을 구독자 수보다 먼저 쓰고, 판정은 간격 → 보고 나이 → RSSI 순으로
  읽는다 (새 연결의 첫 보고가 지난 연결의 RSSI 와 짝지어지지 않게)
- Q1 오버레이 잠근 시각 (9시간 어긋남), Q2 남은 해제 카운트다운이 수동 잠금을 풂 (`ManualLockNow` 하나로),
  Q4 [중지] 뒤 오버레이, Q5 고른 그림 즉시 저장, Q6 [중지] 뒤 결과 무시
- **`--clip-test` 토큰 회전은 반박됐다.** Supabase(GoTrue)는 바로 전 세대 refresh 토큰을 받아 준다 (v1:
  활성 토큰의 부모면 그 활성 토큰을 돌려줌, v2: `counterDifference == 1` 허용). 한 번 버린 회전은 다음
  갱신에 저절로 낫는다. Windows 동작은 그대로 두고, Mac 의 거절(앱이 떠 있으면)은 "config.ini 를 쓰는
  쪽은 하나" 로 이유를 고쳤다 (아래 함정)
- 확인은 MSVC 로컬 빌드(실행 중인 앱을 건드리지 않는 별도 폴더)까지. 실기 시험은 "남은 작업 0"

### 어떻게 했나

워크플로 셋, 반박 검증은 건마다 둘. (1) Mac 이중 스캔 구현(CI 반복) + Windows 결함 7건 분석·반박 + Mac
첫 실행 검토 4갈래 (9건 → 확정 7) (2) 이중 스캔 검토 3갈래 (9건 → 확정 8) + Mac 첫 실행 수정 + iOS + Windows
수정 (3) 확정 건 적용 + 세 변경을 다시 검토 (13건 → 확정 12) + 적용. Mac 시험 180 → 237개.

## 그 앞 세션: Mac 판 (2026-10-01 오전)

"이 프로그램을 맥북에서도 동일하게" 를 한 세션에 했다. `mac/` 에 Swift 네이티브 앱
(AppKit + CoreBluetooth, macOS 13+, 유니버설)이 있고, **Windows 판과 같은 화면 문구·설정 키·로그
줄·서버 규약·폰 규약**으로 돈다. 설계와 Windows 와 다르게 한 곳마다의 이유는 **docs/MAC.md**,
사용자 설명서는 `mac/README.txt` (zip 안의 `설치 안내.txt`).

**이 PC 에는 Mac 이 없다. 컴파일러는 GitHub Actions 의 macOS 러너 하나뿐이다**
(`.github/workflows/mac.yml`, `mac` / `main` 에 푸시하면 돈다). 단계를 나눠 두었다: Core 빌드 →
앱 빌드 → `swift test` (판단 로직 시험) → `mac/build_app.sh` (유니버설 빌드, 아이콘, 서명, zip,
실행 파일의 `--version` 대조). 결과물은 artifact `SmartScreen-mac` (`SmartScreen-mac.zip` +
`VERSION`). **Mac 실기에서는 아직 한 번도 돌지 않았다** - 아래 "남은 작업 Mac".

### 어떻게 만들었나

- Windows 소스를 8 갈래로 읽어 명세를 쓰고(문구·상수·알고리즘·로그 줄 전부), 모듈 계약을 정한
  뒤 13 갈래로 나눠 짰다. 첫 전체 빌드가 컴파일 오류 0 이었다
- `SmartScreenCore` 에 AppKit 없이 판단 로직을 모았다 - Windows ScanThread 를 한 줄씩 옮긴
  `ProximityJudge`, 잠금/해제 상태 기계 `GuardEngine`, config.ini, 문구, 재보기 판정, PKCE, 기업 콘텐츠
  검증, 클립보드 해시·줄바꿈, 업데이트 후보 고르기. **PROXIMITY.md 의 시간표(2샘플, 6초 상한,
  히스테리시스, 입력 5초 보호, 유휴 "바로")가 그대로 단위 시험이다** - 180개, CI 에서 통과
- 검토를 세 번 돌렸다 (모듈별 검토자 → 발견마다 반박 검증자 둘). 1차 10건 중 확정 3, 2차 22건 중
  확정 10 (같은 문제 다섯 개 포함), 3차 7건 중 확정 5. 전부 고친 뒤 고친 것만 다시 검토해
  회귀 7건 중 확정 5 (창 순서 되돌리기가 업데이트 띠까지 묻던 것 등) - 그것도 고쳤다.
  가장 큰 것은 "경고창이 떠 있으면 판정이 멈춘다" (아래 함정 첫 항목)
- 완결성 점검: Windows 설명서의 장마다, 창의 단추마다 Mac 쪽을 찾아 대조했다. 빠진 기능은 없었고
  빈틈은 Mac 설명서 쪽이었다 (고쳤다)

### Windows 와 다르게 한 것 (이유는 docs/MAC.md)

- 없는 것: IRK·[기기 키], 페어링된 Classic 기기 목록, RFCOMM 지연 경로, [재연결]. 스캔은 신원 서비스
  UUID 로 필터를 걸고 macOS 가 overflow 를 맞춘다고 봤다 (→ 오후: 필터 없는 스캔도 같이 돌리고 overflow
  비트도 Windows 처럼 배운다 - 위)
- 입력 감시는 `CGEventSource` 유휴 시간을 100 ms 마다 (권한 창이 없는 유일한 길). 원격 세션은
  `kCGSSessionOnConsoleKey`. 잠금 창은 모니터마다 하나 (`CGShieldingWindowLevel`)
- refresh 토큰은 키체인이 아니라 AES-GCM + 이 Mac 의 하드웨어 UUID 로 봉해 `authRefresh` 에 넣는다
  (`seal.salt`). 임시 서명이라 업데이트마다 키체인이 암호를 묻기 때문이다
- 서명의 designated requirement 를 `identifier "com.icesgg.smartscreen"` 로 둔다 (업데이트 뒤
  블루투스 허용을 다시 묻지 않게 - **실기 미확인**)
- Windows 결함 중 Mac 에서는 고쳐서 옮긴 것: 오버레이 잠금 시각(Q1), 지연 해제 타이머 잔여(Q2),
  [중지] 뒤 오버레이(Q4), 고른 그림 즉시 저장(Q5), [중지] 직후 결과(Q6), **GATT 구독 순간의 거짓
  NEAR**, **`--clip-test` 의 토큰 회전**. (→ 오후: 앞의 여섯은 Windows 도 고쳐 main 에 있다. 토큰 회전은
  반박됐다 - 위)

### 서버: Mac 은 표가 따로다 (`supabase/mac_releases.sql`, **아직 적용 안 됨**)

깔린 Windows 1.1.x 는 `releases` 의 켜진 행을 플랫폼을 묻지 않고 받아 해시만 보고 exe 자리에
놓는다. 그 표에 Mac zip 을 넣으면 모든 Windows PC 가 망가진다. 그래서 `mac_releases` /
`org_mac_release_approvals` 를 새로 만들고(같은 정책, 같은 `releases` 버킷의 `mac/<버전>/`),
덤으로 `releases.storage_path` 에 `<버전>/SmartScreen.exe` 모양 제약을 건다 - 라이브의 켜진 행
8개(1.1.0~1.1.7)가 그 모양인 것을 anon 으로 읽어 확인했다. `release_admins` 의 쓰기 권한도 걷는다.
대시보드(`docs/dashboard.html`)는 Windows / Mac 목록과 승인이 따로이고, Mac 표가 없으면 "Mac
업데이트 표가 아직 없습니다" 만 보인다 (Windows 목록은 그대로).

### 내놓는 길 (release.bat 이 둘 다)

Windows 판을 지금까지처럼 내놓고 푸시한 뒤, 그 커밋의 CI 를 `gh` 로 기다려 artifact 를 받고
`VERSION` 과 zip 안 Info.plist 를 대조해 `Publish.exe --platform mac` 으로 올린다 (브라우저 로그인 한
번 더). Mac 표가 없으면 기다리지 않고 건너뛴다. Mac 단계가 실패해도 Windows 는 그대로이고
`release-mac.bat <버전>` 으로 다시 한다. `-NoMac` 으로 건너뛸 수 있다. `Publish.exe` 는 Windows
모드에서 `MZ` 로 시작하지 않는 파일을 거절하고, Mac 모드에서는 zip 안의 번들 id·버전을 직접 읽는다.
`gh` 가 있어야 한다 (이 노트북에는 있고 로그인돼 있다).

## 그 앞 세션: 서버와 주고받는 면 전체 검토 + 고치기, 그리고 1.1.5 · 1.1.6 (2026-09-30 ~ 10-01)

"anon 이 `contents` 에 쓸 수 있나" 를 보러 들어갔다가, 서버와 주고받는 면 전체를
검토하고 고쳤다. **1.1.5 로 나갔고**, 그 뒤 설정 창 문제 셋을 고쳐 **1.1.6 으로 나갔다**
(둘 다 `release.bat`, 2026-10-01). 두 마이그레이션도 적용됐다. 노트북은 1.1.6 으로 떠서
사용자가 "잘된다" 고 했고, 바로 뒤에 사용자가 혼자 `release.bat` 으로 **1.1.7** 을
내놓았다 (코드 변화 없음, 번호만 - 서버의 마지막은 1.1.7 이다). 아직 안 본 것은 아래
"남은 작업 0".

### 1.1.6 에서 고친 것 (사용자가 1.1.5 를 쓰다 찾은 것)

- **두 임계값이 갈라져 있었다.** 고급 창의 "신호 강도" 칸은 광고 임계값만 바꾸고
  연결(GATT) 임계값은 config 에서 따로 읽었다. 간단 창의 슬라이더는 둘 다 바꿨다.
  노트북은 광고 -67 / 연결 -61 로 갈라져, 폰 앱이 붙어 있으면(GATT linked) -61 로
  판정했고 앉은 자리(-60~-66)에서 잠겼다. 이제 [시작] 이 그 칸의 값을 둘 다에 넣고
  `gattRssiThreshold` 는 사본으로만 저장한다 (`StartMon`)
- **간단 창에서 바꾼 것이 고급 창에 안 갔다.** 슬라이더와 "몇 초 뒤" 단추가 전역과
  config 는 바꾸는데 고급 창의 컨트롤은 안 건드렸고, [시작] 은 그 컨트롤을 다시
  읽는다 - 다음 [시작] 에 예전 값으로 되돌아갔다 (위의 갈라짐도 이것 때문이다). 이제
  슬라이더가 "신호 강도" 칸을, 초 단추가 "유휴 시간" 콤보를 같이 맞춘다. 콤보에
  "바로"(0초)를 넣었다 - 간단 창에는 있는데 콤보에는 없어서 15초로 돌아갔다
- **고급 창의 X 가 프로그램을 끝냈다** - 감시가 [중지] 상태일 때만. 그 예외를 아는
  사람이 없었다. 이제 오버레이가 있는 한 X 는 숨기기만 한다
- STATE 로그: 입력 중이라 임계값을 안 본 NEAR 전환이 광고 임계값(`thr=-67`)을 찍어
  두 경로가 서로 다르게 보였다. 그 경로의 설정값을 찍는다
- 사용자 요청으로 `measuredBaseRssi` 를 -61 → **-67** 로 바꿨다 (config 직접 편집, 앱
  닫고). 이제 3단계는 -61 / **-67 (보통)** / -73 이다. 마법사가 마지막으로 잰 값은
  -61 이었지만(착석 -59..-44, 폰이 책상 위) 지금 자리에서는 연결 신호가 -66 까지
  내려간다 - 폰을 두는 곳이 달라진 것으로 보인다. 다시 재면 이 값은 덮인다

### 서버에서 나온 것 (정책을 직접 읽어서 확정 - `supabase/inspect_live.sql`)

- **anon 은 어디에도 못 쓴다.** anon 에게 걸린 정책은 `contents` · `releases` ·
  `org_release_approvals` 와 `content` · `releases` 버킷의 select 뿐이다
- **`content` 버킷의 쓰기가 "로그인한 아무나" 에게 열려 있었다.** 올리기와 지우기의
  조건이 `bucket_id = 'content'` 하나였다. `authenticated` 는 조직 멤버가 아니라 구글
  계정으로 로그인한 누구나다 - 남의 조직 파일을 지우고 같은 경로에 다른 파일을 올릴
  수 있었고, PC 는 해시를 안 보고 그걸 잠금 화면에 띄웠다. **`content_lockdown.sql` 로
  닫았고 적용됐다** (경로 첫 폴더 = 조직 id 의 멤버만). 적용 뒤 확인: 기존 파일 둘 다
  올린 계정이 멤버이고 크기·시각이 행과 맞는다 = 쓰인 흔적 없음
- `schema.sql` 이 라이브와 달랐던 것 전부: `active` 열, anon 읽기 정책 둘, `content`
  버킷 정책 넷, `org_members` 의 select 정책 (저장소 것은 자기 표를 다시 읽어 무한
  재귀가 나는 꼴이었다). **`schema.sql` 을 라이브(+두 마이그레이션)에 맞췄다**
- 읽기는 그대로다: anon key 로 모든 조직의 `contents` 행과 `content` 버킷이 읽힌다.
  조이려면 기업 PC 에 로그인이나 그에 준하는 것이 필요하다 - **정해지지 않았다**

### 검토 (1차 7 차원 → 3 렌즈 반박, 고친 뒤 2차 7 차원 → 3 렌즈)

1차 확정 44건 / 반박 4건(그중 3건은 검토 도중 이미 고친 것). 2차는 회귀 8건, 전부
low, 전부 고쳤다. 큰 것:

- **기업 콘텐츠 경로** (`client/enterprise/supabase.cpp`, 다시 썼다). `storage_path` 의
  마지막 `/` 뒤를 로컬 파일 이름으로 썼는데 역슬래시를 안 걸러서 `..\..\` 로
  `enterprise_content` 밖에 파일을 쓸 수 있었다 (쓰는 사람은 조직 멤버여야 한다).
  HTTP 상태를 안 봐서 오류 본문이 콘텐츠 파일로 저장됐고, `file_hash` 는 읽기만 하고
  안 썼다. 지금: 행의 모양을 검증하고(`<org>/<sha256>.<ext>`), 로컬 이름은 검증된
  해시로만 만들고, 2xx 만 받고, 크기와 SHA-256 이 맞아야 자리에 놓는다
- **콘텐츠가 처음 받은 것에 고정돼 있었다.** 받은 경로가 `config.ini` 에 저장되고
  이후 동기화는 "비어 있을 때만" 적용됐다 - 대시보드에서 바꾸거나 [송출 중지] 해도
  PC 는 그대로였다. 지금: `enterprise_content` 안의 경로는 동기화의 것이라 결과대로
  바뀌거나 비워진다. 사용자가 다른 곳에서 고른 그림은 그대로 둔다. "켜진 것이 없으면
  최신 둘" 대체 조회도 없앴다. 동기화는 여전히 **켤 때와 등록 단추뿐**이다 (주기 없음)
- 시작할 때의 동기화가 `WM_CREATE` 안에서 UI 스레드를 막고 있었다 → 작업 스레드 +
  `WM_ENTERPRISE_SYNC`
- **기업 등록**: 확인 전에 저장하던 것 → UUID 모양 + `org_exists` + 동기화가 끝난 뒤에만
  저장. 칸을 비우고 누르면 등록 해제 (그 전에는 해제하는 코드가 없었다)
- `config.ini`: 못 읽은 것과 없는 것을 가르고(못 읽었으면 저장을 거절), 임시 파일 +
  `MoveFileExW`. 회전된 refresh 토큰 저장은 실패하면 다시 한다
- 클립보드: 받을 때도 상한·PNG 서명·픽셀 수, 암호 관리자의 "올리지 말라" 표시,
  본문은 새 항목일 때만, 401 → `SessionInvalidate`, 기준선은 첫 성공한 조회가 정함
- 로그인 리스너: 엉뚱한 연결 하나에 끝나던 것, 조용한 연결에 멎던 것
- 대시보드: `escapeHtml` 이 따옴표를 안 바꿔 속성 안에서 XSS (멤버만), 구글 로그인 뒤
  [조직 생성] 이 RLS 에 거절되던 것(`.select()` = `INSERT ... RETURNING` 에 select 정책이
  걸린다), 확장자 허용 목록 `CONTENT_EXT`, 행 등록 실패 시 올린 파일 되돌리기
- iOS `adoptToken`: 올릴 때마다 지우고 올림, 실패하면 한 번 재시도하고 화면에 말함,
  Bluetooth 가 다른 상태를 거치면 처음부터. **컴파일 검증 못 했음**
- `client/p2p` 는 빌드에서 뺐다 (부르는 곳이 없는 인증 없는 LAN 서버였다). 파일은 남아
  있고, 화면의 "P2P 스마트 배포" 문구(`main.cpp`)도 그대로다 - 없는 기능을 말하고 있다

### 서버 쪽 조임: `supabase/hardening.sql` (적용됨, 2026-10-01)

`contents` 행의 모양 제약(1.1.4 PC 를 새 exe 받기 전까지 서버에서 지킨다), 위치마다
켜진 행 하나, `clip_items`/버킷 크기 상한, 승인자 본인 확인, `org_exists(uuid)`,
`org_members.created_at` 을 서버가 적기. 고친 대시보드가 GitHub Pages 에 올라간 뒤에
실행했다 (예전 대시보드는 확장자를 대문자 그대로 붙여 제약에 걸린다). 적용 뒤
`org_exists` 를 anon key 로 불러 실제 조직 `true`, 없는 uuid `false` 를 확인했다.

확장자 목록은 세 군데가 같아야 한다: `hardening.sql` 의 `contents_storage_path_shape`,
`dashboard.html` 의 `CONTENT_EXT`, `client/video/player.cpp` 의 `IsVideoFile`.

### 닫지 않은 것 (정해야 하는 것)

- **폰 토큰은 근처의 아무 BLE 기기나 읽을 수 있는 값이고, GATT 연결 경로에는 신원
  확인이 없다.** 둘 다 프로토콜을 바꿔야 한다 (토큰 대신 HMAC). 검은 화면은 마우스만
  움직여도 풀리므로 검증자들은 low~medium 으로 봤다
- `claim_device_token` 은 토큰을 바꾸지 못한다 (폰을 바꾸면 옛 폰의 신원을 물려받는다)
- 아무 계정이나 조직을 만들고, 남의 계정을 자기 조직에 넣을 수 있다 (초대 흐름이 없다)
- 대시보드의 supabase-js 가 버전 고정 없이 CDN 에서 온다 (파일을 받아 `docs/` 에 넣어야 한다)
- 로그인 리스너: 같은 PC 의 다른 프로세스가 가짜 `code=`/`error=` 로 로그인을 끝낼 수
  있다. 리다이렉트에 난수 경로를 넣으면 닫히는데, Supabase 의 Redirect URLs 허용 목록이
  경로를 받는지 저장소에서는 알 수 없다 (안 받으면 조용히 Site URL 로 바뀐다)
- `clip_items` 행 개수와 `clip` 버킷 파일 개수에는 서버 상한이 없다
- 1.1.4 이하에서 등록한 PC 의 `config.ini` 에는 `serverUrl`/`anonKey` 가 박혀 있고 그대로다
- 등록 전에 개인 그림을 골라 둔 자리에는 기업 콘텐츠가 안 뜨고, 그걸 지울 UI 가 없다

## 그 앞 세션: 프로그램 자동 업데이트 + release.bat

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

### 1.1.12 [등록 내역 삭제] 실기 확인

노트북: 간단 창 '내 폰' [바꾸기] → 창 왼쪽 아래 [등록 내역 삭제] → 확인 창 [예] → "아직 등록하지 않았어요" / [등록하기],
보호 꺼짐, `Select-String -Path "$env:APPDATA\SmartScreen\events.log" -Pattern 'register phone' | Select-Object -Last 2`
에 `registration deleted (token=1 irk=1, protection stopped)`. 그다음 [등록하기] → [예] (구글 계정)로 다시 등록, [보호 꺼짐]
을 눌러 켜기. **기기 키(IRK)도 지워지므로** 노트북의 IRK 쉼(1.1.11)은 고급 창 [기기 키] 로 다시 넣을 때까지 돌지 않는다 -
토큰 탐색만으로 돈다. 맥북도 같은 순서 (`grep "register phone" ~/Library/Application\ Support/SmartScreen/events.log | tail -2`)

### 1.1.11 실기 확인 (가장 먼저 - 2026-10-02 에 사용자에게 준 절차)

재보기는 **1.1.11 을 깐 뒤에** 한다 (프로버 쉼이 광고 표본의 짧은 꺼짐을 없애므로, 1.1.10 으로 재면 착석 최저가 낮게 나와
기준이 헐거워진다. 1.1.11 은 재보기 중 키보드를 써도 연결 신호를 잰다). 폰은 PC 하나에만 GATT 로 붙으므로 재는 쪽이 아닌
PC 의 앱은 끄고 잰다.

1. 받기: 노트북은 release.bat 이 1.1.11 로 다시 띄운다. 대시보드(https://icesgg.github.io/smartscreen/dashboard.html)에서
   1.1.11 [승인] (Windows, Mac). 맥북은 간단 창 띠 [업데이트] - **업데이트 직후 블루투스 허용 창이 다시 뜨는지, "앱 관리" 에
   막히는지** 본다. 데스크톱: `Select-String -Path "$env:APPDATA\SmartScreen\events.log" -Pattern 'start: SmartScreen|update:' |
   Select-Object -Last 5`, IRK 유무 `[bool](Select-String -Path "$env:APPDATA\SmartScreen\config.ini" -Pattern '^bleIrk=.+')`
2. 노트북 재보기: 맥북 오른쪽 위 작은 상자 [종료] → 아이폰 설정 > Bluetooth 끄고 3초 뒤 켜기 → 노트북
   `Select-String -Path "$env:APPDATA\SmartScreen\events.log" -Pattern 'GATT client' | Select-Object -Last 1` 이 subscribed →
   폰을 주머니에 넣고 간단 창 [내 자리에 맞게 다시 재기] → [시작하기] → 1분 평소처럼 → 폰을 꺼지길 원하는 곳에 두고 →
   [폰을 두고 왔어요] → 45초 → 숫자 적고 [이대로 쓰기]. 두 번 한다
3. 맥북 재보기: 노트북 오버레이 [종료] → 아이폰 Bluetooth 껐다 켜기 → 맥북 고급 창 아래 `GATT: linked` → 2와 같이 두 번 →
   `grep "재보기" ~/Library/Application\ Support/SmartScreen/events.log | tail -2`. 끝나면 노트북
   `Start-Process C:\work\smartscreen\build\SmartScreen.exe`
4. 두 대 다 켜고 1~2시간 평소대로, 한 번은 폰을 주머니에 넣은 채 1분 넘게 자리 비우기. 그 뒤 로그 (아래 틀)
5. 잠금 중 클립보드: 노트북 Win+L → 2분 → 아이폰이나 맥북에서 글 복사 → 1분 → 잠금 풀고 메모장 Ctrl+V →
   `Select-String -Path "$env:APPDATA\SmartScreen\events.log" -Pattern 'clip:' | Select-Object -Last 6`
   (기대: `clip: apply deferred - ... locked=1` → `clip: applied text (... bytes) after Ns`)
6. 덮개: 보호 중에 폰을 지닌 채 덮개 닫고 3분 → 열고 로그인 →
   `Select-String -Path "$env:APPDATA\SmartScreen\events.log" -Pattern 'SLEEP|WAKE|judge:|STATE|BLACK' | Select-Object -Last 8`
   (기대: `SLEEP`, `WAKE`, `judge: slept ...s`, 그 뒤 `NEAR -> FAR (GATT rssi=-100` 없음)
7. (선택) 아이폰 앱 새 소스: 맥북 터미널 `curl -L -o ~/Downloads/SSBeaconApp.swift
   https://raw.githubusercontent.com/icesgg/smartscreen/main/ios/SSBeacon/SSBeaconApp.swift` → Xcode 프로젝트의 SSBeaconApp.swift
   내용을 바꿔 넣고 ⌘R. 시험: 폰이 노트북에 붙은 채 잠그고 주머니 → 노트북 오버레이 [종료] →
   `Start-Process C:\work\smartscreen\build\SmartScreen.exe` → 2분 →
   `Select-String -Path "$env:APPDATA\SmartScreen\events.log" -Pattern 'START thr=|GATT client' | Select-Object -Last 3`
   (START 뒤 몇 초 만에 subscribed 인가 - 예전 앱은 19~27분 안 붙었다)
8. (선택) 맥북 구글 로그인 결과 창: 간단 창 '내 폰' [바꾸기] → [예] (구글 계정) → 같은 계정으로 로그인 → 결과 창이 브라우저
   앞에 뜨는가

결과를 받는 틀 (다음 세션 첫 메시지):

```
- 업데이트: 노트북 [1.1.11 / 아님], 맥북 [받았다 / 안 받았다], 블루투스 허용 창 [다시 떴다 / 안 떴다], 앱 관리 [막혔다 / 아니다],
  데스크톱 [받았다 / 안 받았다 / 모름], 데스크톱 IRK [True / False]
- 노트북 재보기 (주머니): 광고 [앉음 ~ / 비움 ~], 연결 [앉음 ~ / 비움 ~ / 못 쟀다]  x2
- 맥북 재보기 (주머니): 광고 [앉음 ~ / 비움 ~], 연결 [앉음 ~ / 비움 ~ / 못 쟀다]  x2
- 앉아 있는데 가려짐: 맥북 [없다 / 가끔 / 자주], 노트북 [없다 / 가끔 / 자주]
- 자리를 뜨면 가려짐: 맥북 [됐다 / 안 됐다], 노트북 [됐다 / 안 됐다], 광고 경로로 도는 쪽도 [됐다 / 안 됐다]
- 잠금 중 클립보드: [붙었다 / 안 붙었다 - 로그]
- 덮개 닫았다 열기: [깬 직후 가려짐 없음 / 있음 - 로그]
- 아이폰 새 소스: [안 했다 / 했다 - 재시작 뒤 subscribed 까지 N초]
- 구글 로그인 결과 창 (맥북): [앞 / 뒤에 숨음 / 안 해 봄]
- 노트북 로그: Select-String -Path "$env:APPDATA\SmartScreen\events.log" -Pattern '재보기|START thr=|STATE|BLACK|GATT client|ident: probes|probe failed|back, bound|judge:|SLEEP|WAKE|clip: apply|clip: deferred' | Select-Object -Last 120
- 맥북 로그: grep -E "재보기|START thr=|STATE|BLACK|GATT client|ident: .*locked|ident: probes|probe failed|judge:|scan: |SLEEP|WAKE|update:" ~/Library/Application\ Support/SmartScreen/events.log | tail -150
```

읽는 법: 짧은 광고 가림의 STATE 줄에 `, probing for` / `, probe ended` 꼬리가 붙어 있으면 그 맥북·PC 의 프로버가 방아쇠다
(노트북은 IRK 쉼이라 거의 안 나와야 한다 - `ident: probes paused` 줄). 맥북은 `scan: raw=` 줄로 R 이 언제 꺼지고 켜졌는지,
`scan: filter restarted` 가 자주 나오는지(필터가 멎는 Mac) 본다.

### Mac. 실기 시험 (2026-10-01 저녁에 대부분 됐다 - 결과는 "현재 기기 상태")

**남은 것은 셋이다.**
1. ~~임계값을 경로마다 따로 둘지~~ → **사용자가 "경로마다 따로" 로 정해 main 에 넣었다 (Windows + Mac, 아직 안
   내놓음 = 다음 1.1.10).** Mac 에서는 폰이 잰 연결(GATT) 신호가 Mac 이 잰 광고 신호보다 12~15 dB 약하다 (16:52
   같은 순간 광고 -41 / GATT -58). 설계:
   - 화면의 숫자는 그대로 하나 ("신호 강도" = 광고 기준). 새 키 `gattRssiOffset` (dB, 기본 0, [-40, 40]).
     GATT 기준 = clamp(광고 기준 + offset, -100, -30) 을 [시작]·거리 막대·재보기 적용 세 곳에서 만든다.
     `gattRssiThreshold` 는 사본. 따로 고칠 칸을 두지 않은 이유: 1.1.6 의 "두 값이 갈라진" 사고
   - 재보기가 같은 2분 동안 광고와 GATT 를 따로 모은다 (경로마다 새 표본일 때만, GATT 는 연결이 살아 있을 때만).
     광고 판정은 예전 그대로(실패면 전체 실패). GATT 가 착석 15 / 비움 8 개 이상이고 안 겹치면 offset =
     (GATT 착석 최저 - 2) - 광고 기준, 아니면 지금 offset 을 그대로 둔다. 결과 창에 두 경로가 따로 나온다
   - 옛 config (키 없음) = offset 0 = 지금과 같다. **재보기를 다시 해야 따로 맞춰진다** - GATT 를 재려면 그
     컴퓨터에 폰 앱이 붙어 있어야 한다 (`GATT: linked`)
   - 문구·로그 줄은 두 판이 글자까지 같다 (메인 세션이 직접 대조했다). 목록 줄도 그 경로의 기준으로 판단한다.
     Mac CI 248 통과, Windows 는 별도 폴더 MSVC 빌드. 실기 미확인
2. 아직 결과를 못 받은 것: 재보기 마법사 문구, 로그인 결과 창 위치, 잠자기 줄, 업데이트(1.1.10 을 낸 뒤 -
   블루투스 허용을 다시 묻는가)
3. ~~직접 읽기 스캔(R)을 끌지~~ → **사용자가 "GATT 가 붙어 있을 때만 끄기" 로 정해 1.1.11 에 넣었다** (2026-10-02,
   위 "직전 세션"). 완전히 끄는 안은 필터 단독이 실기에서 돈 적이 없고 멎으면 되살릴 길이 없어 권하지 않았다

2026-10-01 오후 세션에 사용자에게 준 절차 (명령어 그대로). 결과 줄의 뜻은 docs/MAC.md "확인하지 못한
것" 1. 앞의 것이 안 되면 뒤는 의미가 없다.

1. 설치 - 노트북의 `SmartScreen-mac.zip` 을 맥북 "다운로드" 로 옮긴 뒤 터미널에서
   `ditto -x -k ~/Downloads/SmartScreen-mac.zip ~/Downloads/SmartScreen-mac` →
   `rm -rf /Applications/SmartScreen.app` → `mv ~/Downloads/SmartScreen-mac/SmartScreen.app /Applications/` →
   `xattr -dr com.apple.quarantine /Applications/SmartScreen.app` →
   `/Applications/SmartScreen.app/Contents/MacOS/SmartScreen --version` (= zip 의 번호, 지금 `SmartScreen 1.1.9`)
2. **잠긴 폰을 어느 길로 찾는가.** SSBeacon 을 켜고 폰을 잠근 채
   `/Applications/SmartScreen.app/Contents/MacOS/SmartScreen --probe-scan 2>&1 | tee ~/Desktop/probe-scan.txt`.
   "터미널" 의 블루투스 허용 창에 [허용]. `요약` 블록을 받는다. `판정 못 함` 이면 다시
3. 앱 실행(`open /Applications/SmartScreen.app`) → [등록하기] → [예] → 구글 로그인. 결과 창이 브라우저 앞에
   뜨는가
4. [보호 꺼짐] → SmartScreen 의 블루투스 허용 창 → [보호 켜짐]
5. 전원 어댑터를 꽂거나 `caffeinate -di` 를 켠 채, 폰을 들고 떠나기 → 가려짐 → 1분 안에 돌아와 손대지
   않고 → 풀림. **가려지자마자 스스로 풀리면** 창을 띄우는 것이 입력 유휴 시간을 되돌리는 것이다
   (InputWatcher)
6. 재보기 마법사 - Mac 안테나는 Windows 와 10~20 dB 다르다. Windows 값을 옮기지 말 것
7. 고급 창 아래 `GATT:`. linked 면 [중지] → 5초 → [시작] 뒤 다시 linked 되는가
8. 클립보드: Windows ↔ Mac 글(한글, 여러 줄)과 그림, 아이폰에서 복사한 것은 Windows 로 안 가야 한다
9. 로그: `grep -E "START thr=|scan:|ident:|STATE|BLACK|GATT|SLEEP|WAKE|DISPLAY|register|BLE central|clip:"
   ~/Library/Application\ Support/SmartScreen/events.log | tail -150`
10. (깔린 것보다 새 번호를 내놓은 뒤 - 1.1.9 를 깔았으면 1.1.10) 업데이트: 간단 창 띠 [업데이트]. **업데이트 뒤 블루투스 허용을 다시 묻는가,
    "앱 관리" 에 막히는가** - 물으면 기업 Mac 자동 적용은 서명을 바꾸기(Developer ID) 전까지 끌 것
11. (선택) 아이폰 앱 다시 설치 - `ios/SSBeacon/SSBeaconApp.swift` 를 Xcode 프로젝트에 덮어쓰고 실행.
    그 뒤 7번을 다시 (Mac [보호 꺼짐→켜짐] 에 폰 화면이 "PC 서비스 꺼짐 - 다시 켜지길 기다리는 중" → "보고 중")

결과를 받는 틀 (사용자가 다음 세션 첫 메시지에 채워 오게):

```
- 설치: [됐다 / 막혔다 - 무엇이]
- --probe-scan 요약 블록: [붙여넣기]
- 구글 계정 등록: [됐다 / 실패 - 문구]   결과 창: [브라우저 앞 / 뒤에 숨음]
- [보호 켜짐] 후 블루투스 허용 창: [떴다 / 안 떴다]
- 떠나기 → 가려짐: [됐다 / 안 됐다 / 바로 다시 풀렸다]   돌아오기 → 풀림: [됐다 / 안 됐다]
- 재보기 마법사 결과: [문구]
- GATT: [linked / waiting / off]   [중지]→[시작] 뒤: [다시 linked / waiting]
- 클립보드 글·그림: [됐다 / 안 됐다]   아이폰에서 복사한 것: [Windows 로 안 감 / 감]
- 9번 grep 결과: [붙여넣기]
```

### 0. Windows 1.1.9 (6건) - 아직 안 본 것

노트북에서 (데스크톱은 받은 뒤 - 기업 PC 면 1.1.9 [승인] 이 있어야 받는다). 로그는 PowerShell 에서
`Get-Content "$env:APPDATA\SmartScreen\events.log" -Tail 30`.

- **GATT 거짓 NEAR** (가장 중요 - 2026-10-01 13:59 에 한 번 했다, 결과와 남은 질문은 "현재 기기 상태"): 고급 창 "잠금 해제 지연" 을 "즉시" → [시작] → 폰을 들고 떠나 가려지게 →
  먼 곳에서 아이폰 블루투스를 껐다 켠다 → 아무도 PC 에 안 간 채 30초. 화면이 계속 가려져 있어야 한다.
  `Select-String -Path "$env:APPDATA\SmartScreen\events.log" -Pattern 'GATT client subscribed' -Context 0,1 | Select-Object -Last 5`
  에서 `GATT client subscribed` 바로 다음 줄이 `STATE FAR -> NEAR (GATT ... thr=X set=X` (thr = set) 면 아직
  고장. 끝나면 지연을 원래 값(노트북은 10초)으로
- Q1: 떠나서 가려진 뒤 2분 넘게 있다가 돌아와 손대지 않고 풀리게 → 오버레이 셋째 줄 `Lock hh:mm` =
  `Unlock hh:mm` - 괄호 안 시간 (예전에는 9시간 어긋남)
- Q2: 지연 "10초" → 떠났다 돌아와 "잠금 • N초 후 해제" 동안 마우스로 풀기 → 곧바로 [지금 가리기] → 손 떼고
  20초. 계속 가려져 있고 "[해제] 를 눌러야 풀립니다" 여야 한다
- Q4: "근처 • 보호 중" 일 때 [중지] → 오버레이가 곧바로 회색 "정지됨"
- Q5: 감시 중에 [그림 고르기] → `Select-String -Path "$env:APPDATA\SmartScreen\config.ini" -Pattern 'centerImagePath'`
  에 바로 나오고, 오버레이 [종료] 후 다시 켜도 그 그림
- Q6: 일부러 일으키기 어렵다. [중지] 뒤 1분 동안 `STATE` / `BLACK ON` 줄이 안 생기는지만

### 0-1. 1.1.6/1.1.7 에서 아직 안 본 것

1.1.6 은 나갔고(1.1.7 은 같은 코드) 노트북에서 1.1.7 로 뜬다 (시작 경로: 세션 복구, 회전 토큰 저장, 기업 동기화
OK center=1, 업데이트 확인, BLE NEAR, 오버레이 [종료] 로 0.5초 만에 정상 종료. 설정 창
둘의 동기화와 X 는 사용자가 "잘된다"). 그 밖의 길은 아직 사람이 안 봤다:

- **데스크톱이 1.1.7 을 받는가.** 개인 PC 면 띠 → [업데이트], 기업 PC 면 대시보드의
  [승인] 뒤 (1.1.7 의 [승인] 을 눌렀는지 확인 안 됨). 받은 뒤 events.log 의
  `start: SmartScreen 1.1.7`. 받으면 [시작] 을 거치면서 그 PC 의 두 임계값도 같아진다
- 잠금 화면 자체 (1.1.5 부터 `DeactivateBlackScreen` 이 그림을 버리고 다음 잠금이 다시
  읽는다 - 매 잠금마다 그림을 새로 읽는 셈이다, 느려지는지 볼 것)
- 앉아 있는데 잠기는 일이 -67 로도 이어지면 폰을 평소 자리에 둔 채 [내 자리에 맞게
  다시 재기]. 잰 값이 "보통" 이 된다
- 대시보드에서 [송출 중지] → 앱 다시 켜기 → 그 자리가 비는가. 다시 켜면 돌아오는가.
  단, **노트북은 `centerImagePath` 가 개인 그림(`Pictures\대시보드.jpg`)이라 조직 영상이
  원래 안 뜬다** - 이 시험은 그 값을 비우거나(고급 창) 다른 PC 에서
- 기업 등록 창: 틀린 UUID → "그런 조직이 없어요", 칸을 비우고 누르기 → 등록 해제.
  **해제는 노트북에서 하면 다시 등록해야 한다**
- 클립보드: 노트북은 10-01 13:57 부터 `clipSync=1` (켜짐, 10-02 config.ini 로 확인). 두 대 사이 글·그림은 됐다.
  암호 관리자에서 복사한 것은 안 넘어가야 한다 (아직 안 봄)
- 구글 로그인 한 번 (리스너를 다시 썼다). `release.bat` 의 Publish 로그인은 통과했다 -
  같은 리스너다
- 대시보드: `사진.PNG` 올리기(소문자로 들어가야 한다), 같은 파일 두 번, 송출 토글, 삭제

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

이 경로는 2026-10-01 오후에 처음으로 컴파일이 확인됐다 (`ios.yml`, Xcode 16.4 / 26.x). 실행은 아직이다.
화면이 달라졌다: 서비스를 다시 올리는 동안 `기기 토큰` 줄이 사라졌다가
`didAdd` 가 성공하면 돌아온다. 올리기가 실패하면 "신원 서비스 등록 실패, 다시
시도합니다: ..." 가 한 번 뜨고, 두 번째도 실패하면 "신원 서비스 등록 실패: ..." 로
멈춘다. 그때는 "연동되었습니다" 대신 "계정은 연동됐지만 폰이 토큰을 내주지 못하고
있습니다" 가 뜬다.

### 2. App Store 심사 4.8

구글 로그인만 넣고 제출하면 Sign in with Apple 도 요구될 수 있다. Supabase 가 Apple
provider 를 지원한다. 사내 배포(TestFlight 내부)면 해당 없다.

### 3. 검토해 볼 것

- Mac 에서 고친 Windows 결함은 2026-10-01 오후에 client/ 에도 고쳤다 (main, 1.1.8 대기). 검토에서 보류한 것:
  - ~~Windows ScanThread 15초 조인~~ → **1.1.11 에서 고쳤다** (위 "직전 세션" - 같은 꼴의 GATT TickThread 3초 조인도)
  - 입력 중 keepalive TICK (30~45초마다 하나): 2026-10-02 에 **사용자가 고르지 않았다.** 이유: 폰에 깔린 앱은 감시가 없는 옛
    소스라 다시 깔기 전에는 이득이 0, 감시는 앱이 깨어 있을 때만 돌아 잠긴 폰의 묵은 링크는 이것으로도 못 고침. 새 폰 소스를
    깐 뒤 "앉은 채 GATT client lost → subscribed 쌍" 이 자주 보이면 그때 PC 는 2바이트 TICK(`[seq, 0x01]`, 옛 폰은 첫 바이트만
    읽어 호환) + 폰은 표식이 있으면 끊기 간격을 두 배로 늘리지 않는 안(A-2)
  - 잠긴 채 정지된 폰 앱은 묵은 구독을 알아챌 사건이 없다. 캐시되지 않는 특성을 PC 가 읽게 하면 깨울 수 있을지 모른다
    (Apple 문서상 bluetooth-peripheral 앱은 central 의 읽기에 깨어난다). 미뤘다: 먼저 위 절차 7(새 폰 소스 + 재시작 시험)로
    `didModifyServices` 가 잠긴 폰도 다시 구독시키는지 볼 것. 하게 되면 프로버(광고 주소)가 아니라 이미 맺어진 링크 위로 읽어야
    한다 - 노트북의 프로버 연결은 거의 늘 실패한다
  - Windows ProbeScan 의 첫 결과 블록은 "신원 서비스는 있는데 토큰 읽기 실패" 와 "신원 서비스 없음" 을 같은 문구로 말한다
    (Mac 요약은 가른다). 2026-10-02 에 고르지 않았다 - 아이폰 재설치 시험 전에 하면 득이 있다
  - 판정 쪽, 이번 변경 전부터 있던 것 둘 (위 "직전 세션 - 남긴 것"): 토큰만 쓰는 Windows PC 의 "GATT 1초 끊김 = 즉시 가림",
    GATT 가 끊긴 뒤 묵은 광고 샘플을 90초까지 씀. 고치면 잠그는 시점이 바뀐다 - 사용자에게 물을 것
  - 대시보드 supabase-js 가 `@2` 로만 불린다 (`docs/dashboard.html`). 정확한 버전 고정은 S 이고 공개 페이지 수정이라 사용자 확인.
    2026-10-02 에 고르지 않았다
- **`contents` 와 `content` 버킷은 여전히 로그인 없이 읽힌다** (전 org 의 행, 파일
  바이트, 목록). 쓰기는 닫혔다 (위 "직전 세션"). 조이려면 기업 PC 에 로그인이나 그에
  준하는 것이 필요해진다 (`org_release_approvals` 도 같은 이유로 anon 읽기다) - 그
  대가를 받아들일지는 정해지지 않았다. 조직이 하나뿐인 지금은 드러나지 않는다.
  로그인 없이 가는 길로 생각해 볼 것: 조직 id 를 아는 것 자체를 열쇠로 삼아, 표는
  `org_id` 를 받는 security definer 함수로만 읽게 하고 anon 의 select 정책을 없앤다
  (버킷 쪽은 같은 방법이 안 통한다 - 목록과 내려받기가 같은 select 정책이다)
- 위 "직전 세션 - 닫지 않은 것" 의 목록
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

- **Mac 판 빌드는 CI 에서만 된다.** `mac` 이나 `main` 에 `mac/**` 를 바꿔 푸시하면
  `mac.yml` 이 돈다. 다른 브랜치는 `gh workflow run mac.yml --ref <브랜치>` (workflow_dispatch) - 2026-10-02 에 갈래마다
  브랜치를 따로 두고 이렇게 돌렸다. 오류 보기: `gh run view <id> --log` 에서 `.swift:<줄>:<칸>: error:` 줄.
  zip 받기: `gh run download <id> -n SmartScreen-mac`. 판단 로직을 고치면 `mac/Tests` 에 시험을
  더할 것 - Mac 이 없는 곳에서 행동을 확인하는 유일한 길이다 (2026-10-01 오후 현재 237개)
- **iOS 컴파일은 `ios.yml` 이 본다** (`ios/**` 를 main / mac / ios 에 푸시). typecheck + SIL 까지이고
  링크·서명·실행은 아니다. 실행은 맥북의 Xcode 로만 (저장소에 .xcodeproj 가 없다 - 사용자의 프로젝트에
  `SSBeaconApp.swift` 를 덮어쓴다). Swift 를 고치면 "컴파일만 확인, 실행 미확인" 을 분명히 말할 것
- 작업 브랜치: `mac` (mac.yml), `ios`, `win-fixes` 는 전부 main 에 합쳤다. 워크플로 에이전트는
  `isolation: worktree` 로 `.claude/worktrees/` 에서 일하고, 각자 브랜치에 푸시한 것을 메인이 main 에
  올렸다 (이 저장소는 병합 커밋 없이 일자로 간다 - cherry-pick)
- Mac 앱의 진단 모드: `--version`, `--probe-scan`, `--adv-scan`, `--bt-check`, `--clip-test`
  (`SmartScreen.app/Contents/MacOS/SmartScreen` 에 붙인다). config 와 로그는
  `~/Library/Application Support/SmartScreen/`
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
- 클립보드 점검: `SmartScreen.exe --clip-test` (앱이 떠 있어도 된다 - 토큰 회전 걱정은 반박됐다, 아래
  함정). 결과는 창과 `%APPDATA%\SmartScreen\clip-test.txt`. Mac 판은 앱이 떠 있으면 거절한다
  (config.ini 를 쓰는 쪽이 둘이 되지 않게)
- 임계값 분석: `tools\rssi-threshold.ps1`. 구글 로그인 점검: `build\AuthTest.exe`
- 서버 스키마는 `supabase/*.sql` 을 대시보드 SQL Editor 에 붙여 넣어 적용한다.
  새 프로젝트용 넷(`schema.sql` / `device_tokens.sql` / `clipboard.sql` / `releases.sql`,
  이 순서)과, 돌고 있는 프로젝트를 고친 둘(`content_lockdown.sql`, `hardening.sql` - 둘 다
  적용됨). 넷은 "라이브 + 두 마이그레이션" 과 같게 맞춰 두었다 - 서버를 또 고치면
  새 마이그레이션 파일을 만들고 넷도 같이 고칠 것
- **라이브가 실제로 어떤지는 `supabase/inspect_live.sql` 로 본다** (읽기 전용, select
  하나, 결과 한 칸). 정책·RLS·버킷·함수·트리거가 다 나온다. anon key 로 밖에서 찔러
  보는 것보다 이게 먼저다 - 아래 함정
- `build-review\`, `build-s11\` 은 앱을 건드리지 않고 컴파일을 확인하려고 만든 폴더다
  (.gitignore). `do_build.bat` 와 같은 명령을 빌드 폴더만 바꿔 돌린 것이고, 지워도 된다. 2026-10-02 에는 원본과 빌드 폴더를
  인자로 받는 배치(vcvarsall → cmake `<원본>` -G "NMake Makefiles" → `nmake SmartScreen`)를 스크래치에 두고 썼다. **이
  하네스에서는 Bash 의 `cmd.exe` 호출이 막혀 있어 PowerShell 도구로 `& "<bat>" <원본> <빌드폴더>` 를 돌렸다**
- `.env` 에 Supabase URL/anon key 가 있다 (커밋 안 됨, `.env.example` 이 형식)
- config.ini 편집은 앱을 완전히 종료한 뒤에. 안 그러면 앱이 덮어쓴다
- Git Bash 에서 `cmd.exe /c x.bat` 은 `/c` 가 `C:/` 로 바뀌어 **배너만 찍고 끝난다.**
  `MSYS_NO_PATHCONV=1 cmd.exe /c ...`. `publish.bat --notes "한글"` 도 Git Bash 에서는
  따옴표가 깨진다 - cmd 에서 돌리거나 `build\Publish.exe` 를 직접 부를 것

## 함정

### 모든 PC 가 한꺼번에 "자리 비움" 이면 아이폰 앱의 서명 만료부터 볼 것 (무료 계정 = 7일)

2026-10-07 오전, 노트북과 데스크톱이 둘 다 폰을 못 찾았다. 사용자가 SSBeacon 을 눌러 보니 "앱을 열 수 없다" 가 떴다 - 무료
Apple 계정으로 Xcode 에서 깐 앱은 **설치 후 7일이면 서명이 만료되어 iOS 가 실행하지 않는다.** 앱이 멈추면 잠긴 아이폰은 광고를
거의 안 내므로(PROXIMITY.md) 모든 PC 가 부재로 판정한다. 풀기: 맥북 Xcode 에서 덮어 설치(⌘R, 앱을 지우지 말 것 - 토큰이
앱 데이터에 있다). 매주 생긴다. 유료 개발자 계정(연 $99)이면 1년 서명과 TestFlight·App Store 배포가 된다 - 남에게 나눠 주려면
어차피 필요하다.

같은 날 노트북에는 별개의 일이 둘 겹쳤다. (1) 09:59 ~ 11:29 블루투스가 주변 광고를 **하나도** 못 받았다 (`AdvScan.exe 15` 가
0건, 라디오 On, 장치 OK, Windows 이벤트 기록 없음) - 설정에서 블루투스를 껐다 켜니 1,288건. (2) 그 껐다 켜기에서 **앱의 광고
스캐너(WinRT watcher)가 멈춘 채 다시 시작되지 않았다** - GATT 광고 쪽은 `GATT advertisement restart #4` 로 스스로 살아났지만
`client/ble_rssi.cpp` 의 watcher 에는 Stopped 처리가 없다. [보호 꺼짐→켜짐] 으로만 풀린다 (결함, 아직 안 고침).
가르는 순서: `AdvScan.exe 15` 의 "주변 광고 N건" (0 이면 PC 블루투스) → 폰의 SSBeacon 이 열리는지 (안 열리면 만료) →
앱 로그의 `ident: probes paused/resumed` (IRK 가 폰을 듣는지).

### 짧은 가림을 기준값 탓으로만 읽지 말 것 - 같은 안테나의 다른 일과 시각을 맞춰 볼 것

2026-10-02 의 첫 진단은 "원인은 -67 기준, 코드는 설계대로" 였고 반박 검증자 둘이 모두 뒤집었다. 짧은 광고 FAR 의 시각을
프로버의 연결 시작(로그 시각 - 걸린 ms)과 맞대 보니 4/4 가 ±1.5초 안이었다. 기준값과 판정 규칙만 보면 이것이 안 보인다.
연결 시도, Classic 탐침, 광고 재시작처럼 같은 라디오를 쓰는 일의 시각을 먼저 겹쳐 볼 것. 1.1.11 부터 STATE 줄의 꼬리가
그것을 바로 말해 준다.

### GetTickCount64 는 잠든 시간을 센다

수신 시각과 "지금" 의 차이로 부재를 판단하는 코드는 깨어난 첫 판정에서 잠든 시간 전체를 "못 들은 시간" 으로 읽는다
(2026-10-02 06:40:19, 9시간 → 즉시 FAR). Mac 의 `CLOCK_MONOTONIC` 도 같다. 잠든 시간은 Windows
`GetTickCount64 - QueryUnbiasedInterruptTime/10000`, Mac `CLOCK_MONOTONIC - CLOCK_UPTIME_RAW` 로 잰다 (1.1.11 의 깨어남 유예).

### macOS 에서 경고창을 메인 큐 블록 안에서 띄우지 말 것

`DispatchQueue.main.async { ... NSAlert.runModal() ... }` 는 그 창이 닫힐 때까지 메인 큐의 다른
블록을 하나도 돌리지 않는다 (메인 큐는 직렬이고, 중첩 런 루프는 그것을 다시 비우지 않는다).
Windows 의 MessageBox 는 떠 있는 동안에도 `WM_SCAN_RESULT` 를 돌리므로 같은 모양으로 옮기면
틀린다 - Mac 첫 판에서 로그인 결과 창을 띄워 둔 채 자리를 떠도 화면이 바로 가려지지 않았다.
판정 결과는 `MainLoop.perform` (CFRunLoopPerformBlock, common modes) 으로 보내고, 다른 스레드의
결과로 경고창을 띄울 때는 `MainTimer.once(after: 0)` 로 한 번 건넌다. 타이머는 `.common` 모드로.

### Mac 의 "확인하지 못한 것" 은 진짜로 확인하지 못한 것이다

CI 는 컴파일과 시험까지만 한다. 블루투스, 잠금 화면, 권한(TCC), 서명, 자기 업데이트는 Mac 에서
한 번도 돈 적이 없다. "컴파일된다" 를 "된다" 로 읽지 말 것 - 이 저장소의 "쓰인 적 없는 코드는
틀린 줄 모른다" 가 Mac 판 전체에 해당한다.

### 검토가 내린 결론도 반박해 볼 것 (`--clip-test` 토큰 회전)

"Supabase 는 이미 쓴 refresh 토큰이 다시 오면 로그인 전체를 끊는다" 는 Mac 판 검토에서 나와 그대로
설계(Mac 은 앱이 떠 있으면 점검 거절)와 문서로 들어갔고, Windows "결함" 목록에도 올랐다. 2026-10-01 오후의
반박 검증자가 supabase/auth 소스를 읽어 보니 **바로 전 세대는 허용**이었다 (v1: 폐기된 토큰이 활성 토큰의
부모면 활성 토큰을 돌려주고 아무것도 끊지 않는다, v2: `counterDifference == 1`). 그럴듯한 서버 동작 주장은
소스나 실측으로 확인하기 전까지 가설이다. 설계에 넣었다면 그 근거를 같이 적어 둘 것.

### 주변장치는 central 을 끊지 못한다 - GATT 서비스를 지웠다 올리면 폰이 묵는다

`CBPeripheralManager` 에도 WinRT `GattServiceProvider` 에도 연결된 central 을 끊는 API 가 없다. PC 가
서비스를 지웠다 다시 올리면 (Mac 의 예전 [중지]→[시작], 두 판의 앱 재시작·자기 업데이트) 아이폰은 붙은
채로 무효가 된 핸들을 쥐고, 다시 구독하지 않으면 TICK 이 영영 안 온다. Windows 노트북 로그에서 앱 재시작
뒤 27분 동안 `GATT client subscribed` 가 없었고, 그동안 프로버는 같은 후보에 Unreachable 이었다. 고치는
쪽은 폰이다 (`didModifyServices` + TICK 감시). PC 쪽은 서비스를 지우지 않는 것만 할 수 있다 (Mac 은 이제
그렇게 한다).

### 터미널에서 돌린 Mac 진단의 권한은 터미널 것이다

셸에서 실행한 바이너리는 앱 묶음 안에 있어도 TCC 의 "책임 프로세스" 가 터미널이다. 그래서 `--probe-scan`
의 블루투스 허용 창은 "터미널" 이름으로 뜨고, 거절했다면 시스템 설정에서 SmartScreen 이 아니라 터미널을
켜야 한다. 허용 창이 떠 있는 동안 `CBManager.authorization` 은 `.notDetermined`, 상태는 `.unknown` 이다.
Info.plist 에 블루투스 설명 키가 없는 앱(VS Code 등의 터미널)에서 돌리면 묻지도 않고 죽을 수 있다.

### 배터리의 맥북은 2분 뒤 잠든다

macOS 기본값은 배터리에서 2분(전원 10분) 뒤 화면을 끄고, 노트북은 그때 잠든다. 잠든 동안은 스캔도
판정도 멎으므로 돌아와도 저절로 풀리지 않고 macOS 가 Touch ID / 암호를 묻는다 - 고장이 아니다. 실기
시험은 전원을 꽂거나 `caffeinate -di` 를 켜고 할 것. events.log 의 `SLEEP` / `WAKE` / `DISPLAY OFF` 줄로 가른다.

### 빌드 스크립트의 보고를 믿지 말 것 (release.ps1 에서 세 번)

- PowerShell 은 `$null` 을 .NET `string` 매개변수에 `""` 로 넘긴다. `FindWindow(cls,
  $null)` 은 "제목이 빈 창" 을 찾아 아무것도 못 찾는다. 둘째 인자를 `IntPtr` 로 선언
- PowerShell 이 네이티브 명령에 넘기는 인자 안의 `"` 는 `\"` 로 바뀐다. `cmd /c "call
  ""x.bat"" > ""log"""` 는 아무것도 못 하고 끝난다. 그리고 스크립트가 **지난번 로그
  파일**을 읽어 `BUILD_SUCCESS` 를 봤다 - 옛 로그는 먼저 지우고, 빌드 뒤 exe 시각과
  `Publish.exe --version` 을 직접 본다
- 네이티브 명령의 stderr 는 오류 레코드가 되고 `ErrorActionPreference=Stop` 이면
  vcvarsall 의 잡음 한 줄에도 스크립트가 죽는다. `Continue` 로 두고 `$LASTEXITCODE`

### 헤더만 바꾸면 다시 빌드되지 않는다 - 두 번 낡은 exe 가 나갔다 (1.1.0, 1.1.8)

CMake 의 NMake 생성기는 cl.exe 의 `/showIncludes` 출력에서 헤더 의존성을 읽는데, 그
접두어("참고: 포함 파일:")를 **바이트로** 맞춘다. 이 PC 의 cl.exe 는 `VSLANG=1033` 에도 한국어로
찍고(영어 언어 팩이 없다), 그 바이트는 콘솔 코드페이지마다 다르다 - **release.ps1 은 UTF-8, 손으로
돌린 cmd 는 CP949.** 설정할 때와 다른 코드페이지로 빌드하면 그때 컴파일된 `.obj.d` 가 0 바이트가
되고, 그 뒤로는 `version.h` 만 바꿔서는 그 소스가 다시 컴파일되지 않는다. 빌드는 "성공" 하고 exe 는
새로 링크되므로 시각 검사도 통과한다.

- 1.1.0: 낡은 exe 가 옛 번호로 다시 올라갔다 (2026-09-30). 그때 넣은 `VSLANG=1033` 은 효과가 없었다
- **1.1.8 (2026-10-01): `update.cpp.obj` 가 08:19 의 1.1.7 빌드 것이었다.** 화면과 로그는 1.1.8 인데
  업데이트 코드만 자기를 1.1.7 로 알아서 서버의 1.1.8 을 계속 "새 버전" 으로 본다
  (`update: 1.1.8 exists but not approved for org (running 1.1.7)` 가 증거였다). 기업 PC 에서 1.1.8 을
  승인하면 받고 → 다시 시작하고 → 또 받는다. 바로잡는 길은 제대로 빌드한 1.1.9 (1.1.8 PC 들도 1.1.9 >
  "1.1.7" 이라 받는다)

지금의 막이 셋이다. `do_build.bat` 은 빈 `.obj.d` 가 하나라도 있으면 캐시(`build\CMakeCache.txt`,
`build\CMakeFiles`)를 지우고 처음부터 설정한다. `release.ps1` 은 내놓는 빌드마다 캐시를 지우고 처음부터
빌드한다. 빌드 뒤에는 **exe 안에 새 번호가 있고 예전 번호(UTF-16)가 없는지**, `.obj.d` 가 비지 않았는지를
직접 본다. 처음부터 빌드하면 `.obj.d` 가 전부 채워지는 것은 2026-10-01 에 별도 폴더로 확인했다
(update.cpp.obj.d 39 KB, exe 에 1.1.7 없음).

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

**이 목록은 작업본의 그때 상태일 뿐이다.** index 는 전부 LF 이고, `core.autocrlf=true` 라서 git 이
체크아웃·병합·cherry-pick 으로 다시 쓴 파일은 CRLF 가 된다 (2026-10-01 오후 병합 뒤 `client/main.cpp` 와
`NEXT_SESSION.md` 가 CRLF 가 됐고, 새 worktree 에서는 전부 CRLF 다). 도구로 새로 쓴 파일만 LF 로 남는다.
`git ls-files --eol` 의 `w/` 열이 작업본의 실제 상태다.
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

### `authenticated` 는 "우리 사용자" 가 아니다

Supabase 의 `to authenticated` 는 **구글 계정으로 로그인한 아무나**다. 가입이 열려
있고 anon key 는 exe 와 대시보드에 박혀 있다. 조건이 `bucket_id = '...'` 하나뿐인
`authenticated` 정책은 사실상 공개다 - `content` 버킷이 그랬다. 정책에는 "누구의 것인가"
(`auth.uid()`, 조직 멤버십)가 반드시 들어가야 한다.

### 저장소의 SQL 은 라이브가 아니다

`schema.sql` 은 다섯 달 동안 라이브와 달랐다 (열 하나, 정책 일곱). 대시보드에서 손으로
고친 것은 저장소에 남지 않는다. 정책을 의심할 때는 `.sql` 파일을 읽지 말고
`inspect_live.sql` 을 돌려라. 그리고 밖에서 찔러 보는 것으로는 절반만 안다 - insert 는
저장될 수 없는 행으로 안전하게 찔러 볼 수 있지만, update / delete / Storage 쓰기는
실제로 바꾸지 않고는 알 수 없다. 정책을 읽으면 아무것도 안 쓰고 전부 안다.

### `INSERT ... RETURNING` 에는 select 정책도 걸린다

supabase-js 의 `.insert(...).select()` 는 `RETURNING` 이 되고, 그러면 그 표의 select
정책이 **새 행에** 걸린다 - 행이 들어가기 전에. select 정책이 "트리거가 만들어 주는
다른 행" 에 기대고 있으면(조직을 만들면 트리거가 멤버십을 만든다) 아직 없으니
거절된다. 오류 문구는 insert 정책 위반과 똑같다.

### 설정 창이 둘이면 [시작] 이 어느 쪽을 읽는지 봐야 한다

간단 창은 전역과 config 를 바꾸고, 고급 창은 자기 컨트롤(에디트·콤보)을 들고 있는데
`StartMon` 은 **고급 창의 컨트롤을 다시 읽는다.** 그래서 간단 창에서 바꾼 값은 다음
[시작] 에 조용히 예전 값으로 돌아갔고, 광고 임계값과 연결 임계값이 6dB 갈라진 채 몇
달을 갔다. 값 하나가 두 화면에 보이면 바꾸는 쪽이 다른 화면의 컨트롤까지 맞춰야
한다 - 그리고 두 화면의 선택지가 같아야 한다 ("바로" 가 콤보에 없었다). 증상은
"재시작하면 바뀌어 있다" 였다.

### 검토 도중에 고치면 검증자가 "이미 고쳐졌다" 고 한다

검증 에이전트는 작업 트리를 읽는다. 발견을 받자마자 고치면 그 발견은 반박표를
받는다 (1차의 반박 4건 중 3건이 그랬다). 틀린 것은 아니지만 집계가 흐려진다 - 고치는
것은 검증이 끝난 뒤에, 아니면 검증자에게 `git show HEAD:` 를 보라고 할 것.

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

- **1.1.11 이 나갔다** (사용자 release.bat, 2026-10-02 11:21 Windows / 11:24 Mac, 커밋 `3be9748`). 사용자: "모두 정상 업데이트
  됨". 확인한 것: 서버 `releases` 1.1.11 sha `4e9a164f…5537` = `build\SmartScreen.exe` = `dist\` = zip 안의 exe, exe 안에 1.1.11 만
  있고 1.1.10 없음. `mac_releases` 1.1.11 sha = 저장소 맨 위 `SmartScreen-mac.zip`
  `7824e52c3779a588077129347ca2b10af7e18668b938aa0b4777f2cb7ba076e7`. `SmartScreen-desktop.zip`
  `9162ed97cc2daf83c37de4be91a7eacc1503836b5f42b9b4b37b0debddc599e4`. 노트북 `start: SmartScreen 1.1.11` →
  `update: up to date (1.1.11, 12 row(s))`
- **1.1.11 노트북 첫 10분 (11:21~11:30)**: `ident: probes paused - IRK recognises the phone` 바로 뒤로 `probe failed` 가 한 줄도
  없다 (IRK 쉼이 돈다). 그런데도 광고 경로 짧은 FAR 3번 (11:26:24, 11:26:46, 11:29:34, 모두 adv -71, STATE 꼬리 없음 = 프로브
  없음, 11:29:34 는 idleCountdown=9). GATT 는 그동안 노트북에 안 붙었다 (폰이 맥북에 붙은 것으로 보임). **이 셋은 프로버가 아니라
  기준 -67 쪽이다** - 노트북 재보기(주머니)가 가장 급하다
- 승인 기록: `org_release_approvals` / `org_mac_release_approvals` 의 1.1.9·1.1.10 승인은 조직 `c40caa88-…` 이고, 노트북의
  orgId 와 콘텐츠의 조직은 `0dca070f-…` 다 (그 조직의 승인은 1.1.1 뿐). 노트북은 release.bat 이 직접 바꾸므로 상관없었다.
  1.1.11 승인은 아직 어느 조직에도 없다 (기업 등록 PC 가 승인을 기다리는지 볼 것)
- 노트북(1.1.10)은 **아직 다시 재지 않았다** (`gattRssiOffset=0`, 기준 -67, `clipSync=1` - 10-01 13:57 에 켰다). 07:32 부터 폰이
  노트북에 GATT 로 붙어 있었다. 밤새 앱을 켠 채 잠들었다가(21:20:39 덮개, S3) 06:40 에 깼다 - 앱이 켜진 채 잠자기를 건넌 것은
  로그 전체에서 이 한 번이다. Windows 는 21:20:38 잠금 ~ 06:55:19 해제
- 노트북 events.log 는 6,000줄 남짓이고 절반 넘게 `probe failed` 다 (1.1.11 의 IRK 쉼과 실패 줄 요약으로 줄어야 한다)
- 맥북·데스크톱의 1.1.10 결과(재보기, 업데이트 때 블루투스 허용 창, 로그인 결과 창)는 이번에도 못 받았다
- **1.1.10 이 나갔다** (사용자 release.bat, 2026-10-01 18:50 - 경로마다 따로, 아이폰 클립보드) 와 승인 (Windows,
  Mac). 서버 Windows exe `0007a7af...`, Mac zip `47438c233f90ea7da0c8caf55a5d1cafbc934cfd48d3284f40d154e043103755`
  (= 저장소 맨 위 `SmartScreen-mac.zip`), `SmartScreen-desktop.zip` `cda52a67dc6e4a0d0ba08d2bc707a2802a86e4365a85e99f07cb98de2c5ac9cd`.
  노트북은 1.1.10 으로 떴고 **아직 다시 재지 않았다** (`gattRssiOffset=0`, 기준 -67)
- **맥북은 1.1.10 으로 다시 쟀다**: 광고 기준 -53, 연결 -62 (차이 -9). **폰을 책상 위에 두고 쟀더니, 바지
  주머니에 넣자 앉아서도 가려졌다** (연결 -58 ~ -60, 풀리려면 -58 이상 필요). 사용자 제안대로 재보기 안내를
  "폰을 평소처럼 지닌 채 (주머니에 넣고 다니면 주머니에 넣은 채로)" 로 바꿨다 - Windows·Mac 같은 글, 두
  README 의 문제 해결 줄도 (main `c00e63c`, Mac CI 248, Windows 별도 폴더 빌드. **아직 안 내놓음** = 다음 1.1.11).
  사용자는 지금 버전으로도 주머니에 넣은 채 다시 재면 된다
- **Mac: 맥북(M1)에 1.1.9 가 깔려 돈다** (2026-10-01 오후, 사용자 - 위에서 1.1.10 으로 올라갔다). 실기로 확인된 것은 **GATT 하나**:
  - 처음엔 `GATT: waiting` - 폰이 Windows 노트북에 붙어 있었다 (노트북 16:45:20 `GATT client subscribed`).
    폰 앱은 PC 하나에만 붙는다. 그때 노트북의 AdvScan 이 맥북의 PC 서비스 광고를 -51 dBm 으로 봤다
    (주소 `C889F3D41613`, Apple 대역) = Mac 의 CBPeripheralManager 광고는 된다
  - 노트북 앱 [종료] → 아이폰 블루투스 껐다 켜기 → 맥북 `GATT: linked`, [중지]→[시작] 절차까지 사용자가
    "잘된다" (Mac 의 events.log 줄은 못 받았다 - `kept across restart` 였는지는 모른다)
  - **그 뒤 사용자가 맥북 events.log 를 보냈다 (16:22~17:30). 실기로 확인된 것:**
    - **잠긴 폰을 찾는다 - 포팅의 전제가 맞았다.** `scan: filter=on raw=on`, `ident: X locked adverts via filter`
      (여섯 번), 한 번은 `via filter + raw bit 31`. macOS 서비스 필터가 잠긴 폰의 overflow 광고를 맞춰 준다.
      직접 읽기도 가끔 비트 **31** 을 본다 - Windows 가 배운 값과 같다 (비트는 UUID 에서 정해진다).
      `--probe-scan` 요약은 받지 않았다 (이 로그로 답이 나왔다)
    - 주소가 15분마다 바뀌면 `went quiet, looking again` 뒤 1~3초 안에 새 주소로 `bound to ... via filter`
    - 잠금/해제: FAR → `BLACK ON`, 돌아오면 NEAR → `BLACK OFF`. **가림막이 스스로 풀리지 않는다** (16:47:46 ~
      16:51:03 196초 등 오래 버틴 잠금이 여럿 - 창을 띄우는 것이 입력 유휴 시간을 되돌리지 않는다). 0~2초 만에
      풀린 몇 번은 사용자의 입력으로 본다
    - GATT: 16:52:35 `GATT client subscribed` → `companion app seen - GATT connection is now required for NEAR`.
      끊겼다 다시 붙기 1초 (16:57:41 → 42, 17:13:54 → 55). 앱을 다시 띄운 뒤 7초 만에 다시 붙었다 (17:19:35)
    - 클립보드: 양쪽으로 글·그림 (`clip: sent` / `applied`). 아이폰에서 복사한 것도 Windows 로 넘어갔다 -
      `not sent ... Universal Clipboard` 줄이 없다 = 이 macOS 에서는 `com.apple.is-remote-clipboard` 가 안 붙었다.
      사용자가 원하는 쓰임이라 그 갈래를 아예 뺐다 (main `ClipSync.swift`, CI 237 통과, 다음 릴리스에 들어간다)
  - **Mac 임계값 - 앉아서도 자주 가려진다.** 16:27~16:51 `thr=-50`: 앉은 광고 신호 -35 ~ -54 라 1~2분마다 FAR.
    16:52 GATT 가 붙자 GATT 신호 -52 ~ -65 → 거의 늘 FAR (입력 중에만 NEAR). 17:19 `thr=-56` 으로 올렸지만
    (사용자가) GATT 가 끊긴 뒤 광고 -49 ~ -61 로 또 FAR. **Mac 에서는 폰이 잰 GATT 신호가 Mac 이 잰 광고 신호보다
    12~15 dB 약하다** - 한 값을 두 경로에 쓰는 구조(1.1.6)와 안 맞는다 ("남은 작업 Mac" 1). 그동안의 권고:
    `GATT: linked` 인 채로 재보기 (붙으면 GATT 가 NEAR 의 조건이 되므로 그쪽에 맞춘다)
  - **Mac 재보기 결과 (2026-10-01 저녁)**: 앉아 있을 때 -57 ~ -51, 비웠을 때 -69 ~ -65 → "보통" = -59
    (앉은 최저 -2). 비운 쪽과 6 dB 떨어져 있다. 어느 경로(GATT / 광고)로 쟀는지는 화면에 안 나온다 -
    그 시각의 events.log `GATT client subscribed/lost` 로 가린다. 사용자에게 [이대로 쓰기] 뒤 한동안 써 보고
    로그를 보내 달라고 했다
  - **그 로그 (1.1.9, 16:57~18:27)**: 17:41:18 재보기는 GATT 로 쟀다 (17:38:57 subscribed ~ 17:43:43 lost).
    그 뒤 GATT 가 끊겨 광고 경로 + 기준 -59 로 돌았고, 44분 동안 잠금은 둘: 17:57:24 (광고 -60, 21초 - 앉아
    있었다면 1 dB 차이의 헛잠금) 와 18:20:12 ~ 18:27:21 (7분 자리 비움, 광고 -65 로 잠기고 -55 로 풀림 = 맞다).
    그 전 17:22~17:28 (기준 -56, 광고) 은 앉아서 -57/-58 로 1~2분마다 잠겼다.
    **두 경로의 차이는 폰을 둔 자리에 따라 바뀐다**: 16:27~16:52 는 광고 -35 ~ -46 / GATT -52 ~ -65 (15 dB),
    17:20~18:27 은 광고 앉음 -49 ~ -60 / GATT 앉음 -51 ~ -57 (거의 같다). 그래서 새 재보기는 두 경로를 같은 2분에
    같이 잰다 - 폰 자리를 바꾸면 다시 잴 것
- **1.1.9 가 나갔다 (사용자가 release.bat, 2026-10-01 14:19~14:21, 빌드 고침만 - 코드는 1.1.8 과 같다).**
  고친 release.ps1 이 캐시를 지우고 처음부터 빌드했다. 확인: `.obj.d` 22개 중 빈 것 0, exe 안에 1.1.9 만
  있고 1.1.8 / 1.1.7 없음, 노트북 로그 `start: SmartScreen 1.1.9` → `update: up to date (1.1.9, 10 row(s))`.
  저장소 맨 위 zip (= 서버 행):
  `SmartScreen-desktop.zip` `ef91cc1d3b602e482b5e900d6d4cf7d6dc2c67c359569beed29bcd2f04b84ceb`
  (안의 exe `2abdad3aeb35a621f33c3450a69a8786b9b0e1a9f0f55f294c56fe665a030a21`),
  `SmartScreen-mac.zip` `9d607a5fc0c829d42e255bf86b33f832f35bc18e8cccfd659ae219bcd6620be8`
- 1.1.8 (13:53~13:57) 은 Windows exe 의 업데이트 코드만 1.1.7 이었다 (함정 "헤더만 바꾸면", 서버 exe
  `237953f2...`). 1.1.8 을 받은 PC 도 1.1.9 를 받는다 (1.1.9 > 그 PC 가 아는 "1.1.7"). **1.1.8 은 조직
  승인에 넣지 말 것**. **1.1.9 는 승인됐다** (2026-10-01 14:31 Windows, 14:30 Mac - anon 으로 읽어 확인,
  1.1.8 승인은 없다). Mac 1.1.8 은 CI 가 처음부터 빌드해서 멀쩡했다
- 노트북은 GATT 시험 때문에 **잠금 해제 지연을 "즉시"(unlockDelay=0)** 로 바꿨다 - 10초로 되돌리기를
  부탁했다 (확인 안 됨, `START ... unlockDelay=` 줄로 본다)
- **GATT 거짓 NEAR 고침은 실기에서 맞게 돌았다** (노트북, 1.1.8, 13:59:57): 구독 직후
  `STATE FAR -> NEAR (GATT rssi=-62 dBm thr=-63 set=-67)` → BLACK OFF. thr = set+4 라 예전 결함(간격 0
  갈래, thr = set)이 아니라 폰의 첫 실제 보고 -62 를 판정한 것이고, **사용자는 그때 돌아오는 중이었다** -
  맞게 푼 것이다. 재연결 직후 첫 보고 하나로 푸는 것은 그대로 두기로 했다. 같은 표의 11:50:45 / 12:47:55
  쌍(thr = set)은 1.1.7 시절의 예전 결함이다 (13번째)
- 아이폰 앱: 폰에 깔린 것은 2026-10-01 오후 전의 소스다 (`didModifyServices`·TICK 감시·`import Combine` 없음).
  사용자가 Xcode 로 다시 설치해야 들어간다
- 노트북(LG gram 14Z990, Intel 내장): **1.1.10** (10-02), 기업 등록(`enterpriseRegistered=1`,
  orgId `0dca070f-…`), **`measuredBaseRssi=-67`, `nearRssiThreshold=-67` =
  `gattRssiThreshold=-67` (거리 3단계의 [보통])**, `idleCountdownSec=15`, `bleDebugLog=0`.
  IRK 와 폰 토큰 둘 다 설정돼 있다. **`centerImagePath` 는 개인 그림
  (`Pictures\대시보드.jpg`)**, `clipSync=1`, `gattRssiOffset=0` (2026-10-02 에 config.ini 를 직접 봤다). 앱은
  `C:\work\smartscreen\build\SmartScreen.exe` 로 돌고 있다 (release.bat 이 그걸 닫았다
  다시 띄운다; `dist\` 의 exe 와 같은 파일이다)
- 데스크톱: 마지막으로 확인한 것은 **1.1.4** (1.1.5/1.1.6 을 받았는지 확인 안 됨 - 위
  "남은 작업 0"), 듀얼 모니터. 기업 등록인지 개인인지는 확인 못 했다
- 같은 구글 계정(icesgg@gmail.com). 클립보드 공유는 노트북에서 **켜졌다** (2026-10-01 13:57 `clip: started`,
  14:00 글과 그림을 보냈다 - 맥북 쪽 시험으로 보인다)
- Supabase: 네 스키마(`schema`/`device_tokens`/`clipboard`/`releases`) +
  `content_lockdown.sql` + `hardening.sql` 적용됨 (2026-09-30/10-01). `contents` 에 두 행
  (png 꺼짐, mp4 켜짐). `releases` 에 1.1.0 ~ 1.1.9 (1.1.0 은 낡은 빌드가 실수로 다시
  올라간 것 - 해는 없음; 1.1.7 은 1.1.6 과 같은 코드; **1.1.8 은 update.cpp 가 낡은 빌드** - 위;
  1.1.9 는 1.1.8 과 같은 코드를 제대로 빌드한 것). `mac_releases.sql` 적용됨 (`mac_releases` 에 1.1.8,
  1.1.9). `release_admins` 에 icesgg@gmail.com. `org_release_approvals` 에는 1.1.1 한 줄뿐이었다
  (2026-10-01 14시 전, anon 으로 읽음)
- `client/version.h` = 1.1.11 = 서버의 마지막(Windows, Mac) = `build\` = `dist\` = 두 zip (2026-10-02 11:24)
