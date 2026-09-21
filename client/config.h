// config.h - Configuration persistence (JSON-based)
#pragma once
#include "common.h"

struct AppConfig {
    BTH_ADDR btAddress = 0;
    DWORD nearLatencyMs = 200;
    int nearRssiThreshold = -50;  // BLE RSSI 임계값 (dBm). 실측: 주머니+착석 -35~-47, 10m 이탈 -52~-61
    bool bleDebugLog = false;     // BLE 광고 진단 로그 (ble_scan_log.csv)
    DWORD bleTimeoutSec = 90;     // BLE 수신 끊김 판정 시간(초). 주머니 속 iPhone은 광고 간격이 70초까지 벌어짐
    bool bleGattServer = true;    // v2: PC가 GATT 서버가 되어 폰 앱의 1Hz RSSI 보고를 받음
    bool bleGattPlain = false;    // v2 디버깅용: 암호화 요구 끄기
    bool gattSeen = false;        // 컴패니언 앱이 연결된 적 있음 → 이후 미연결은 "부재"로 간주
    DWORD gattGraceSec = 90;      // 시작 후 앱 연결을 기다리는 시간(초)
    int gattRssiThreshold = -55;  // v2 임계값 (dBm, 폰이 측정한 연결 RSSI)
    bool bleLostMeansFar = false; // BLE 끊김 = 범위 이탈 (비콘 등 상시 광고 기기에서만 켤 것)
    std::wstring bleIrk;         // LE 본딩 기기의 IRK (32자리 hex) - iPhone 랜덤 주소 해석용
    DWORD keepAliveSec = 5;
    DWORD scanIntervalSec = 2;
    int idleCountdownSec = 20;
    bool unlockAuto = true;
    int unlockDelaySec = 0;
    std::wstring centerImagePath;
    std::wstring bannerImagePath;
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
