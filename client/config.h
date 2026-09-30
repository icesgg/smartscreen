// config.h - Configuration persistence (JSON-based)
#pragma once
#include "common.h"

struct AppConfig {
    BTH_ADDR btAddress = 0;
    DWORD nearLatencyMs = 200;
    // 임계값 기본값은 자리마다 다시 재는 것이 전제다 (docs/PROXIMITY.md, dist/README.txt 4장).
    // 측정한 세 자리에서 착석 구간이 이 아래로 5초 이상 이어진 적이 없어, 붙어 있는
    // 사람을 잘못 잠그지는 않는 쪽으로 잡았다. 늦게 잠기는 것이 잘못 잠기는 것보다 낫다.
    int nearRssiThreshold = -65;  // [광고] 경로 (dBm)
    bool bleDebugLog = false;     // BLE 광고 진단 로그 (ble_scan_log.csv)
    DWORD bleTimeoutSec = 90;     // BLE 수신 끊김 판정 시간(초). 주머니 속 iPhone은 광고 간격이 70초까지 벌어짐
    bool bleGattServer = true;    // v2: PC가 GATT 서버가 되어 폰 앱의 1Hz RSSI 보고를 받음
    // 링크 암호화(=LE 본딩) 요구. 기본 끔: 본딩은 PC마다 따로 맺어야 해서 PC를 옮길 때마다 막힌다.
    // 기기 확인은 IRK로 연결 상대 주소를 푸는 방식을 쓴다 (본딩과 무관하게 동작)
    bool bleGattEncrypt = false;
    bool gattSeen = false;        // 컴패니언 앱이 연결된 적 있음 → 이후 미연결은 "부재"로 간주
    DWORD gattGraceSec = 90;      // 시작 후 앱 연결을 기다리는 시간(초)
    // -55 였는데, 실측에서 착석 분포(-62~-45) 안에 들어가 있어 자리에 앉아 있는데도
    // 화면을 잠갔다. 연결 경로가 실제로 붙기 전에는 이 값이 쓰인 적이 없어 드러나지 않았다.
    int gattRssiThreshold = -65;  // [연결] 경로 (dBm, 폰이 측정한 연결 RSSI)
    bool bleLostMeansFar = true;  // BLE 끊김 = 범위 이탈. 컴패니언 앱이 상시 광고하므로 기본 켬
    std::wstring bleIrk;         // LE 본딩 기기의 IRK (32자리 hex) - iPhone 랜덤 주소 해석용
    // IRK 를 대체하는 신원 확인 (ble_ident.h 참고). 본딩도 Phone Link 도 필요 없다.
    std::wstring phoneToken;     // 폰이 GATT 로 내주는 16바이트 신원값 (32자리 hex)
    // 폰의 Apple overflow 비트 번호. 후보를 좁히는 필터일 뿐 신원이 아니다 -
    // 광고하는 UUID 가 바뀌면 같이 바뀌고, 그 외에도 가끔 옮겨간다 (실측: 116 -> 85).
    int phoneOvfBit = -1;        // -1 = 아직 모름. 탐색에 성공하면 그때 배운다
    DWORD keepAliveSec = 5;
    DWORD scanIntervalSec = 2;
    int idleCountdownSec = 20;
    bool unlockAuto = true;
    int unlockDelaySec = 0;
    std::wstring centerImagePath;
    std::wstring bannerImagePath;
    // 간단 화면의 거리 3단계가 기준으로 삼는 값. 재보기로 정해진다.
    // 0 = 아직 안 재봤음 - 그러면 3단계는 근거 없는 대략값이라, 화면에서 그렇게 말해 준다.
    // 같은 "보통"이 자리와 어댑터에 따라 10~20 dB 달라지므로 고정값으로 둘 수 없다.
    int measuredBaseRssi = 0;
    // 구글 로그인 세션 (client/enterprise/auth.h 참고).
    // authRefresh 는 DPAPI 로 봉해서 넣는다 - 이 파일은 %APPDATA% 의 평문이고,
    // 리프레시 토큰은 폰 토큰과 달리 계정 자체를 여는 값이다.
    std::wstring authRefresh;
    std::wstring authUserId;
    std::wstring authEmail;     // 누구로 로그인했는지 보여주기 위한 것뿐
    // 같은 계정으로 로그인한 다른 PC 와 클립보드를 주고받는다 (client/clipsync.h).
    // 기본 꺼짐이고 그래야 한다: 켜면 복사한 그림과 텍스트가 서버를 지나간다.
    // 자리비움 감지와 달리 이건 사용자가 알고 켜는 일이어야 한다.
    bool clipSync = false;
    // 이보다 큰 항목은 건너뛴다. 다중 모니터 전체 캡처가 수십 MB 가 되는데,
    // 그걸 복사할 때마다 올리면 회선만 쓴다.
    DWORD clipMaxKB = 4096;
    // Enterprise
    std::wstring orgId;
    std::wstring serverUrl;
    std::wstring anonKey;
    bool enterpriseRegistered = false;
};

std::wstring GetConfigDir();

// 진단용 이벤트 로그 (events.log). g_debugEvents가 true일 때만 기록
extern bool g_debugEvents;
void DbgEvent(const wchar_t* fmt, ...);
bool LoadAppConfig(AppConfig& cfg);
void SaveAppConfig(const AppConfig& cfg);

// "reg query ... /v IRK" 출력 파일에서 IRK를 읽어 cfg.bleIrk에 넣고 파일을 삭제
// (BTHPORT 키는 SYSTEM 권한으로만 읽을 수 있어 사용자가 1회 추출한 파일을 가져옴)
bool ImportBleIrkFile(AppConfig& cfg, const std::wstring& path);
