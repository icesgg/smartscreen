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

## 직전 세션: 서버와 주고받는 면 전체 검토 + 고치기, 그리고 1.1.5 · 1.1.6 (2026-09-30 ~ 10-01)

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

### 0. 1.1.6/1.1.7 에서 아직 안 본 것

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
- 클립보드: 노트북은 `clipSync=0` 이라 꺼져 있다 (브리프에 "켜짐" 이라 적혀 있던 것은
  틀렸다). 켜서 두 대 사이 글·그림, 암호 관리자에서 복사한 것은 안 넘어가야 한다
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

직전 세션에서 이 경로를 고쳤다 (컴파일 검증 못 했음 - **Xcode 에서 먼저 빌드가 되는지
볼 것**). 화면이 달라졌다: 서비스를 다시 올리는 동안 `기기 토큰` 줄이 사라졌다가
`didAdd` 가 성공하면 돌아온다. 올리기가 실패하면 "신원 서비스 등록 실패, 다시
시도합니다: ..." 가 한 번 뜨고, 두 번째도 실패하면 "신원 서비스 등록 실패: ..." 로
멈춘다. 그때는 "연동되었습니다" 대신 "계정은 연동됐지만 폰이 토큰을 내주지 못하고
있습니다" 가 뜬다.

### 2. App Store 심사 4.8

구글 로그인만 넣고 제출하면 Sign in with Apple 도 요구될 수 있다. Supabase 가 Apple
provider 를 지원한다. 사내 배포(TestFlight 내부)면 해당 없다.

### 3. 검토해 볼 것

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
- 서버 스키마는 `supabase/*.sql` 을 대시보드 SQL Editor 에 붙여 넣어 적용한다.
  새 프로젝트용 넷(`schema.sql` / `device_tokens.sql` / `clipboard.sql` / `releases.sql`,
  이 순서)과, 돌고 있는 프로젝트를 고친 둘(`content_lockdown.sql`, `hardening.sql` - 둘 다
  적용됨). 넷은 "라이브 + 두 마이그레이션" 과 같게 맞춰 두었다 - 서버를 또 고치면
  새 마이그레이션 파일을 만들고 넷도 같이 고칠 것
- **라이브가 실제로 어떤지는 `supabase/inspect_live.sql` 로 본다** (읽기 전용, select
  하나, 결과 한 칸). 정책·RLS·버킷·함수·트리거가 다 나온다. anon key 로 밖에서 찔러
  보는 것보다 이게 먼저다 - 아래 함정
- `build-review\` 는 직전 세션이 앱을 건드리지 않고 컴파일을 확인하려고 만든 폴더다
  (.gitignore). `do_build.bat` 와 같은 명령을 빌드 폴더만 바꿔 돌린 것이고, 지워도 된다
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

- 노트북(LG gram 14Z990, Intel 내장): **1.1.7**, 기업 등록(`enterpriseRegistered=1`,
  orgId `0dca070f-…`), **`measuredBaseRssi=-67`, `nearRssiThreshold=-67` =
  `gattRssiThreshold=-67` (거리 3단계의 [보통])**, `idleCountdownSec=15`, `bleDebugLog=0`.
  IRK 와 폰 토큰 둘 다 설정돼 있다. **`centerImagePath` 는 개인 그림
  (`Pictures\대시보드.jpg`), `clipSync=0`** (2026-10-01 에 config.ini 를 직접 봤다). 앱은
  `C:\work\smartscreen\build\SmartScreen.exe` 로 돌고 있다 (release.bat 이 그걸 닫았다
  다시 띄운다; `dist\` 의 exe 와 같은 파일이다)
- 데스크톱: 마지막으로 확인한 것은 **1.1.4** (1.1.5/1.1.6 을 받았는지 확인 안 됨 - 위
  "남은 작업 0"), 듀얼 모니터. 기업 등록인지 개인인지는 확인 못 했다
- 같은 구글 계정(icesgg@gmail.com). 클립보드 공유는 노트북에서 꺼져 있다
- Supabase: 네 스키마(`schema`/`device_tokens`/`clipboard`/`releases`) +
  `content_lockdown.sql` + `hardening.sql` 적용됨 (2026-09-30/10-01). `contents` 에 두 행
  (png 꺼짐, mp4 켜짐). `releases` 에 1.1.0 ~ 1.1.7 (1.1.0 은 낡은 빌드가 실수로 다시
  올라간 것 - 해는 없음; 1.1.7 은 1.1.6 과 같은 코드). `release_admins` 에
  icesgg@gmail.com. **1.1.7 의 [승인] 을 눌렀는지 확인 안 됨** (노트북은 이미 1.1.7
  이지만, 다른 기업 PC 는 승인이 있어야 받는다)
- `client/version.h` = 1.1.7 = 서버의 마지막 = `build\` = `dist\` = `SmartScreen-desktop.zip`
