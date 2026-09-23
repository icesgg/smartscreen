// ble_gatt.h - BLE GATT 서버 (v2 근접 감지)
// 역할 반전: PC가 GATT 서버(주변장치), iPhone 컴패니언 앱이 central로 연결을 유지.
//  - PC가 TICK 특성으로 알림을 보내면 iOS가 (잠금 상태에서도) 앱을 깨움
//  - 앱이 연결 RSSI를 읽어 RSSI 특성에 써 줌 → PC는 ~1Hz로 RSSI를 받음
// iOS 백그라운드 "광고"는 10~50초에 한 번뿐이지만, "연결"은 스로틀되지 않음.
#pragma once

#include <windows.h>
#include <string>

// SmartScreen v2 GATT 서비스 (iOS 앱과 동일해야 함)
#define SS_GATT_SERVICE_UUID  L"{7A1C0010-5353-4243-8E2B-9F3D5A6C7E10}"
#define SS_GATT_TICK_UUID     L"{7A1C0011-5353-4243-8E2B-9F3D5A6C7E10}"  // notify: PC -> 폰 (seq 1바이트)
#define SS_GATT_RSSI_UUID     L"{7A1C0012-5353-4243-8E2B-9F3D5A6C7E10}"  // write : 폰 -> PC (int8 rssi, seq)

// 폰이 올리는 신원 서비스 (ios/SSBeacon 의 kIdentUUID / kTokenUUID 와 동일해야 함).
// 위의 서비스는 PC가, 이쪽은 폰이 올린다 - 일부러 다른 UUID를 쓴다.
// 같은 값이면 폰 앱의 central 스캔이 옆자리 폰을 PC로 착각해 붙으려 든다.
// 잠금 상태 광고에서는 이 UUID가 Apple overflow 영역의 비트 하나로만 남는다.
#define SS_IDENT_SERVICE_UUID L"{7A1C0020-5353-4243-8E2B-9F3D5A6C7E10}"
#define SS_IDENT_TOKEN_UUID   L"{7A1C0021-5353-4243-8E2B-9F3D5A6C7E10}"  // read : PC <- 폰 (16바이트)

class BleGattServer {
public:
    BleGattServer();
    ~BleGattServer();

    // plain=true면 암호화 요구 없이 동작 (디버깅용. 기본은 본딩된 기기의 암호화 연결만 허용)
    // logPath가 비어 있지 않으면 RSSI 보고를 CSV로 기록
    bool Start(bool plain, const std::wstring& logPath);
    void Stop();

    bool IsRunning() const;

    // 폰 앱이 연결되어 TICK을 구독 중인지
    bool IsClientSubscribed() const;

    // 이번 세션에서 폰 앱이 한 번이라도 연결된 적이 있는지
    bool EverSubscribed() const;

    // 연결되어 있고, 폴링 중이라면 보고가 제때 들어오고 있는지
    // (입력 활성으로 폴링을 쉬는 중에는 연결만으로 healthy)
    bool IsHealthy() const;

    // 현재 폴링 간격(ms). 0 = 사용자가 입력 중이라 폴링 쉬는 중
    DWORD CurrentPollIntervalMs() const;

    int   GetSmoothedRssi() const;   // 칼만 필터 적용 (폰이 측정한 연결 RSSI, dBm)
    int   GetRawRssi() const;
    DWORD ReportAgeMs() const;       // 마지막 RSSI 보고 이후 경과 시간

    // 마지막으로 구독이 끊긴 시각 (GetTickCount64). 끊긴 적 없으면 0
    ULONGLONG LostTick() const;

    // 마지막 RSSI 보고 시각 (GetTickCount64). 보고가 없으면 0.
    // 같은 값이면 같은 보고를 다시 보고 있는 것이다 - 판정에서 샘플을 셀 때 쓴다.
    ULONGLONG LastReportTick() const;

    // RSSI 보고/연결 상태 변화 시 신호되는 auto-reset 이벤트 (판정 스레드 깨우기용)
    HANDLE ReportEvent() const;

private:
    struct Impl;
    Impl* m_impl;
};

extern BleGattServer g_bleGatt;
