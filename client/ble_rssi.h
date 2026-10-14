// ble_rssi.h - BLE RSSI 스캐너 (WinRT) + 칼만 필터
// 키플과 동일한 원리: BLE 신호 강도(RSSI, dBm)를 직접 측정하여 거리 추정
#pragma once

#include <windows.h>
#include <string>
#include <atomic>
#include <mutex>

// ---------------------------------------------------------------------------
// 칼만 필터 - RSSI 노이즈 스무딩
// Raw RSSI: -65, -80, -62, -75, -68 (±18dBm 변동)
// Smoothed: -65, -68, -67, -69, -69 (±4dBm 변동)
// ---------------------------------------------------------------------------
class KalmanFilter {
public:
    // processNoise(Q, 초당): 작을수록 느리지만 안정적, 클수록 빠르지만 노이즈 많음
    // measureNoise(R): 측정 노이즈 추정치. BLE RSSI는 보통 10~15 정도
    KalmanFilter(double processNoise = 1.0, double measureNoise = 10.0);

    // 새 RSSI 측정값 입력 → 스무딩된 값 반환
    // dtSec: 직전 측정 이후 경과 시간(초). 간격이 길수록 새 값을 더 신뢰
    double Update(double measurement, double dtSec = 1.0);

    // 현재 추정값 반환
    double GetEstimate() const;

    // 상태 초기화
    void Reset();

private:
    double m_x;      // 추정 상태 (RSSI)
    double m_P;      // 추정 오차 공분산
    double m_Q;      // 프로세스 노이즈 공분산
    double m_R;      // 측정 노이즈 공분산
    bool   m_init;   // 초기화 여부
};

// ---------------------------------------------------------------------------
// BLE RSSI 스캐너 - WinRT BluetoothLEAdvertisementWatcher 래퍼
// PIMPL 패턴으로 WinRT 헤더를 .cpp에 격리
// ---------------------------------------------------------------------------
class BleRssiScanner {
public:
    BleRssiScanner();
    ~BleRssiScanner();

    // 대상 기기 이름으로 BLE 스캔 시작 (iPhone BLE 주소 ≠ Classic BT 주소이므로 이름 매칭)
    // targetAddress: 기기의 공개(identity) 주소. LE 본딩된 기기는 이름 없이도 주소로 매칭됨
    // false 면 지금은 감시자를 못 세웠다 (라디오 꺼짐 등). 그래도 Stop 전까지는 감시 스레드가
    // 3초마다 다시 세워 본다. 도는 중에 멈춘 감시자도 같은 식으로 다시 세운다.
    bool Start(const std::wstring& targetDeviceName, uint64_t targetAddress = 0);

    // 스캔 중지. 다시 세우는 중이었으면 그것도 멈춘다 (그 시도가 끝나기를 기다렸다가 내린다).
    void Stop();

    // 칼만 필터 적용된 스무딩 RSSI 반환 (dBm, 음수값. 예: -65)
    int  GetSmoothedRssi() const;

    // 최신 raw RSSI 반환 (dBm)
    int  GetRawRssi() const;

    // 마지막 BLE 신호 수신 이후 경과 시간 (ms)
    DWORD GetTimeSinceLastReceived() const;

    // BLE 신호를 수신 중인지 (타임아웃 이내 수신 있음)
    bool IsReceiving() const;

    // BLE 스캐너가 사용 가능한지. 이번 Start 이후 광고 감시자를 한 번이라도 세웠으면 true.
    // 도중에 감시자가 멈춰 다시 세우는 중이어도 true 로 둔다. 판정(main.cpp ScanThread)이
    // 이 값으로 갈래를 고르는데, 멈췄다고 false 로 내리면 블루투스를 껐다 켜는 순간
    // bleTimeoutSec 을 기다리지 않고 바로 부재(또는 latency 폴백)로 넘어간다 - 예전에는
    // 멈춘 감시자에서 광고가 안 오는 것으로 bleTimeoutSec 뒤에 부재가 됐고, 그대로 둔다.
    // 멈춘 것은 IsScanStopped 로 본다.
    bool IsAvailable() const;

    // 광고 감시자가 멈춰서 다시 세우는 중인지 (블루투스를 껐다 켬, 동글을 뺐다 꽂음,
    // 처음 Start 때 라디오가 꺼져 있었음). 상태바가 보여 주는 데 쓴다. 판정은 보지 않는다.
    bool IsScanStopped() const;

    // 최근 10초간 수신한 대상 기기 광고 수 (초당 환산). 튜닝 시 신호가 얼마나 촘촘한지 확인용
    double RecentPacketRate() const;

    // 마지막 유효 패킷 수신 시각 (GetTickCount64). 없으면 0
    ULONGLONG LastReceivedTick() const;

    // 이번 세션에서 대상 기기의 BLE 광고를 한 번이라도 수신했는지
    // (수신 이력이 있는데 끊긴 경우 = 범위 이탈로 간주해야 함)
    bool HasEverReceived() const;

    // 대상 기기의 유효 패킷이 수신될 때마다 신호되는 auto-reset 이벤트 (판정 스레드 깨우기용)
    HANDLE PacketEvent() const;

    // 수신 끊김 판정 시간(초). 기본 90
    void SetTimeoutSec(DWORD sec);

    // 연결로 신원을 확인하는 경로를 켠다 (IRK 대체, ble_ident.h 참고). Start() 전에 호출.
    // tokenHex 가 비어 있으면 비활성. ovfBit 은 지난번에 배운 값(-1이면 모름).
    // probeFloorRssi 보다 약한 기기는 건드리지 않는다 - 자리 판정에 쓸 수 없는 거리다.
    void SetIdentity(const std::wstring& tokenHex, int ovfBit, int probeFloorRssi);

    // 탐색 중 새로 배운 overflow 비트. 없으면 -1.
    // 한 번 가져가면 -1 로 돌아가므로, 받은 쪽이 설정에 저장해야 한다.
    int TakeLearnedOverflowBit();

    // 토큰으로 확인된 현재 주소. 아직 못 찾았으면 0
    uint64_t BoundAddress() const;

    // --- 확인 연결(토큰 탐색) 조절 ---
    // 이 PC 에 폰 앱이 GATT 로 붙어 있는지(IsHealthy) 판정 스레드가 반복마다 알린다.
    // 붙은 지 60초가 지나면 탐색을 쉬고, 떨어지면 재시도 간격을 처음으로 되돌려 바로 찾는다.
    void SetGattLinked(bool linked);
    // 재보기(g_measuring)가 재는 중인지. 판정 스레드가 SetGattLinked 옆에서 반복마다 알린다.
    // 재는 동안에는 GATT 링크가 오래됐어도 쉬지 않는다 - 토큰으로 알아보는 폰의 광고 표본은
    // 묶인 주소에서만 오는데, 쉬는 중에 주소가 바뀌면 재는 1분 내내 광고 표본이 안 쌓인다.
    // 끝났을 때 링크가 아직 60초를 넘겼으면 쉼이 다시 걸린다.
    void SetMeasuring(bool measuring);
    // 같은 주소의 연속 실패로 늘어난 재시도 간격(15 -> 120초)을 처음으로 되돌린다 (깨어남 등).
    void ResetProbeBackoff();
    // STATE 줄 꼬리. 탐색 중이면 ", probing for 1.3s", 끝난 지 3초 안이면
    // ", probe ended 0.4s ago", 아니면 빈 문자열. Mac AdvScanner.probeTagForLog 와 같은 글자.
    std::wstring ProbeTagForLog() const;
    // IRK 가 최근 30초 안에 폰의 광고를 풀었는지. 그동안은 탐색을 쉰다.
    bool IrkRecognisesPhone() const;

    // LE 본딩된 기기의 IRK(32자리 hex) 설정. Start() 전에 호출
    // 설정되면 랜덤 주소(RPA)로 광고하는 기기(iPhone 등)를 이름 없이도 식별
    bool SetIrk(const std::wstring& irkHex);

    // 진단 로그(CSV) 경로 설정. Start() 전에 호출, 빈 문자열이면 비활성
    void SetDebugLog(const std::wstring& path);

private:
    struct Impl;
    Impl* m_impl;
};

// 전역 BLE RSSI 스캐너 인스턴스
extern BleRssiScanner g_bleScanner;
