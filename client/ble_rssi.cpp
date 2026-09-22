// ble_rssi.cpp - BLE RSSI 스캐너 구현 (WinRT)
// WinRT BluetoothLEAdvertisementWatcher를 사용하여 BLE 광고 패킷의 RSSI를 읽음
// 키플과 동일한 원리: 물리적 신호 강도(dBm)를 칼만 필터로 스무딩

// WinRT 헤더 (PIMPL로 격리 - 이 파일에서만 사용)
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Storage.Streams.h>

#include "ble_rssi.h"
#include "ble_gatt.h"   // SS_GATT_SERVICE_UUID (컴패니언 앱이 광고하는 UUID)
#include <windows.h>
#include <bcrypt.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <map>

using namespace winrt;
using namespace Windows::Devices::Bluetooth::Advertisement;

// ---------------------------------------------------------------------------
// 칼만 필터 구현
// ---------------------------------------------------------------------------
KalmanFilter::KalmanFilter(double processNoise, double measureNoise)
    : m_x(0), m_P(1.0), m_Q(processNoise), m_R(measureNoise), m_init(false) {}

double KalmanFilter::Update(double measurement, double dtSec) {
    if (!m_init) {
        // 첫 측정값으로 초기화
        m_x = measurement;
        m_P = 1.0;
        m_init = true;
        return m_x;
    }

    // 예측 단계 (Predict)
    // Q는 초당 프로세스 노이즈: 패킷 간격이 길수록 불확실성이 커져 새 측정값을 더 크게 반영
    if (dtSec < 0.05) dtSec = 0.05;
    if (dtSec > 60.0) dtSec = 60.0;
    double P_pred = m_P + m_Q * dtSec;

    // 업데이트 단계 (Update)
    double K = P_pred / (P_pred + m_R);  // 칼만 이득
    m_x = m_x + K * (measurement - m_x); // 상태 업데이트
    m_P = (1.0 - K) * P_pred;            // 오차 공분산 업데이트

    return m_x;
}

double KalmanFilter::GetEstimate() const {
    return m_x;
}

void KalmanFilter::Reset() {
    m_init = false;
    m_x = 0;
    m_P = 1.0;
}

// ---------------------------------------------------------------------------
// BLE RSSI 스캐너 내부 구현 (PIMPL)
// ---------------------------------------------------------------------------
struct BleRssiScanner::Impl {
    BluetoothLEAdvertisementWatcher watcher{ nullptr };
    winrt::event_token receivedToken{};
    std::wstring targetName;           // 매칭할 대상 기기 이름
    uint64_t targetAddr{ 0 };          // 매칭할 대상 주소 (LE 본딩 시 Windows가 RPA를 identity 주소로 해석)
    std::atomic<int> rawRssi{ -100 };  // 최신 raw RSSI (dBm)
    std::atomic<int> smoothedRssi{ -100 }; // 칼만 필터 적용 RSSI
    std::atomic<bool> receiving{ false };   // 신호 수신 중
    std::atomic<bool> available{ false };   // WinRT 사용 가능
    std::atomic<bool> running{ false };     // 스캔 실행 중
    std::atomic<ULONGLONG> lastReceivedTick{ 0 }; // 마지막 수신 시각 (콜백 스레드에서 기록)
    KalmanFilter kalman{ 1.0, 10.0 };      // RSSI 스무딩 필터 (Q=초당 1.0, R=10.0)
    std::atomic<DWORD> timeoutMs{ 90000 };  // 이 시간 동안 수신 없으면 "끊김" (iOS 백그라운드 광고는 간격이 수십 초까지 벌어짐)
    std::mutex kalmanMutex;                // 칼만 필터 동기화
    HANDLE packetEvent{ CreateEventW(nullptr, FALSE, FALSE, nullptr) };  // 유효 패킷 수신 알림

    // 진단 로그 (CSV) - 경로가 비어 있으면 비활성
    std::wstring logPath;
    FILE* logFile{ nullptr };
    std::mutex logMutex;
    std::map<uint64_t, ULONGLONG> lastLoggedTick;  // 비매칭 기기는 주소별 5초에 1회만 기록

    void LogAdv(uint64_t addr, const wchar_t* addrType, int companyId,
                const std::wstring& name, bool matched, int raw, int smoothed,
                const std::wstring& payload, const std::wstring& svcUuid) {
        std::lock_guard<std::mutex> lock(logMutex);
        if (!logFile) return;
        ULONGLONG now = GetTickCount64();
        if (!matched) {
            auto it = lastLoggedTick.find(addr);
            if (it != lastLoggedTick.end() && (now - it->second) < 5000) return;
            lastLoggedTick[addr] = now;
        }
        SYSTEMTIME st; GetLocalTime(&st);
        wchar_t company[16] = L"";
        if (companyId >= 0) swprintf_s(company, L"0x%04X", companyId);
        fwprintf(logFile, L"%02d:%02d:%02d.%03d,%012llX,%s,%s,%s,%d,%d,",
            st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
            (unsigned long long)addr, addrType, company, name.c_str(), matched ? 1 : 0, raw);
        if (matched) fwprintf(logFile, L"%d", smoothed);
        fwprintf(logFile, L",%s,%s", payload.c_str(), svcUuid.c_str());
        fwprintf(logFile, L"\n");
        fflush(logFile);
    }

    // RPA(Resolvable Private Address) 해석 - LE 본딩 시 교환된 IRK 사용
    // iPhone은 이름 없이 ~15분마다 바뀌는 랜덤 주소로 광고하므로 IRK로만 식별 가능
    // ah(IRK, prand) = AES128(IRK, 0..0 || prand) 하위 24bit == 주소 하위 24bit(hash)
    BCRYPT_ALG_HANDLE aesAlg{ nullptr };
    BCRYPT_KEY_HANDLE irkKeys[2]{ nullptr, nullptr };  // 저장된 순서 / 역순 (바이트 순서 양쪽 시도)
    std::mutex rpaMutex;
    std::map<uint64_t, bool> rpaCache;               // 주소별 해석 결과 캐시

    void ClearIrk() {
        std::lock_guard<std::mutex> lock(rpaMutex);
        for (auto& k : irkKeys) { if (k) { BCryptDestroyKey(k); k = nullptr; } }
        if (aesAlg) { BCryptCloseAlgorithmProvider(aesAlg, 0); aesAlg = nullptr; }
        rpaCache.clear();
    }

    bool SetIrk(const std::wstring& hex) {
        ClearIrk();
        if (hex.size() != 32) return false;
        BYTE key[16], rev[16];
        for (int i = 0; i < 16; i++) {
            wchar_t b[3] = { hex[i * 2], hex[i * 2 + 1], 0 };
            wchar_t* end = nullptr;
            key[i] = (BYTE)wcstoul(b, &end, 16);
            if (end != b + 2) return false;
        }
        for (int i = 0; i < 16; i++) rev[i] = key[15 - i];

        std::lock_guard<std::mutex> lock(rpaMutex);
        if (BCryptOpenAlgorithmProvider(&aesAlg, BCRYPT_AES_ALGORITHM, nullptr, 0) < 0) return false;
        BCryptSetProperty(aesAlg, BCRYPT_CHAINING_MODE, (PUCHAR)BCRYPT_CHAIN_MODE_ECB,
                          sizeof(BCRYPT_CHAIN_MODE_ECB), 0);
        bool ok = BCryptGenerateSymmetricKey(aesAlg, &irkKeys[0], nullptr, 0, key, 16, 0) >= 0
               && BCryptGenerateSymmetricKey(aesAlg, &irkKeys[1], nullptr, 0, rev, 16, 0) >= 0;
        SecureZeroMemory(key, sizeof(key)); SecureZeroMemory(rev, sizeof(rev));
        return ok;
    }

    bool HasIrk() {
        std::lock_guard<std::mutex> lock(rpaMutex);
        return irkKeys[0] != nullptr;
    }

    bool ResolveRpa(uint64_t addr) {
        if (((addr >> 46) & 3) != 1) return false;   // 상위 2bit 01 = resolvable private
        std::lock_guard<std::mutex> lock(rpaMutex);
        if (!irkKeys[0]) return false;
        auto it = rpaCache.find(addr);
        if (it != rpaCache.end()) return it->second;

        BYTE pt[16] = {}, ct[16];
        pt[13] = (BYTE)(addr >> 40); pt[14] = (BYTE)(addr >> 32); pt[15] = (BYTE)(addr >> 24);
        bool hit = false;
        for (auto k : irkKeys) {
            ULONG cb = 0;
            if (!k || BCryptEncrypt(k, pt, 16, nullptr, nullptr, 0, ct, 16, &cb, 0) < 0) continue;
            if (ct[13] == (BYTE)(addr >> 16) && ct[14] == (BYTE)(addr >> 8) && ct[15] == (BYTE)addr) { hit = true; break; }
        }
        if (rpaCache.size() > 4096) rpaCache.clear();
        rpaCache[addr] = hit;
        return hit;
    }

    // 컴패니언 앱이 광고하는 서비스 UUID인지.
    // 이 UUID는 앱을 쓰는 모든 폰이 똑같이 광고하므로 "내 폰"을 가리지 못한다
    // (옆자리 동료 폰도 걸린다). IRK가 있으면 그쪽만 쓰고, 없을 때만 보조로 쓴다.
    // 포그라운드에서는 UUID가 광고에 실리지만, 잠금/백그라운드에서는 iOS가
    // Apple overflow 영역으로 옮겨 버려서 어차피 이 경로로는 안 보인다.
    static bool HasOurService(BluetoothLEAdvertisement const& adv) {
        static const winrt::guid target = [] {
            GUID g{}; CLSIDFromString(SS_GATT_SERVICE_UUID, &g); return winrt::guid(g);
        }();
        try {
            for (auto const& u : adv.ServiceUuids()) if (u == target) return true;
        } catch (...) {}
        return false;
    }

    // 기기 이름 대소문자 무시 비교
    static bool NameContains(const std::wstring& advName, const std::wstring& target) {
        if (target.empty() || advName.empty()) return false;
        // 대소문자 무시 포함 검사
        std::wstring advLower = advName;
        std::wstring tgtLower = target;
        std::transform(advLower.begin(), advLower.end(), advLower.begin(), ::towlower);
        std::transform(tgtLower.begin(), tgtLower.end(), tgtLower.begin(), ::towlower);
        return advLower.find(tgtLower) != std::wstring::npos;
    }
};

// ---------------------------------------------------------------------------
// 전역 인스턴스
// ---------------------------------------------------------------------------
BleRssiScanner g_bleScanner;

// ---------------------------------------------------------------------------
// 생성자 / 소멸자
// ---------------------------------------------------------------------------
BleRssiScanner::BleRssiScanner() : m_impl(new Impl()) {}

BleRssiScanner::~BleRssiScanner() {
    Stop();
    m_impl->ClearIrk();
    CloseHandle(m_impl->packetEvent);
    delete m_impl;
}

// ---------------------------------------------------------------------------
// Start - BLE Advertisement Watcher 시작
// ---------------------------------------------------------------------------
bool BleRssiScanner::Start(const std::wstring& targetDeviceName, uint64_t targetAddress) {
    if (m_impl->running) Stop();

    m_impl->targetName = targetDeviceName;
    m_impl->targetAddr = targetAddress;
    m_impl->rawRssi = -100;
    m_impl->smoothedRssi = -100;
    m_impl->receiving = false;
    m_impl->lastReceivedTick = 0;
    {
        std::lock_guard<std::mutex> lock(m_impl->kalmanMutex);
        m_impl->kalman.Reset();
    }

    try {
        // WinRT COM 초기화 (MTA)
        // 이미 초기화되어 있으면 무시됨
        try { winrt::init_apartment(winrt::apartment_type::multi_threaded); }
        catch (...) { /* 이미 초기화됨 - 정상 */ }

        // 진단 로그 열기 (설정된 경우)
        if (!m_impl->logPath.empty()) {
            std::lock_guard<std::mutex> lock(m_impl->logMutex);
            m_impl->lastLoggedTick.clear();
            // 모니터링 중에도 다른 프로그램에서 읽을 수 있도록 공유 모드로 열기
            m_impl->logFile = _wfsopen(m_impl->logPath.c_str(), L"a,ccs=UTF-8", _SH_DENYWR);
            if (m_impl->logFile) {
                fwprintf(m_impl->logFile, L"# session target=%s\n", targetDeviceName.c_str());
                fwprintf(m_impl->logFile, L"time,address,addrType,company,name,matched,rawRssi,smoothedRssi,mfgData,svcUuid\n");
            }
        }

        // BLE Advertisement Watcher 생성
        m_impl->watcher = BluetoothLEAdvertisementWatcher();

        // 스캔 모드: Active (디바이스에 Scan Response 요청 → 더 많은 정보)
        m_impl->watcher.ScanningMode(BluetoothLEScanningMode::Active);

        // 광고 수신 콜백 등록
        m_impl->receivedToken = m_impl->watcher.Received(
            [this](BluetoothLEAdvertisementWatcher const&,
                   BluetoothLEAdvertisementReceivedEventArgs const& args)
        {
            // 광고 패킷에서 기기 이름 추출
            std::wstring advName;
            try {
                auto localName = args.Advertisement().LocalName();
                if (!localName.empty()) {
                    advName = std::wstring(localName.c_str());
                }
            } catch (...) {}

            uint64_t addr = args.BluetoothAddress();
            int16_t rssi = args.RawSignalStrengthInDBm();  // dBm, 음수값

            // 이 광고가 "내 폰"인지. IRK 해석이 유일하게 폰을 특정하는 방법이라 먼저 본다.
            bool matched = m_impl->ResolveRpa(addr)
                || Impl::NameContains(advName, m_impl->targetName)
                || (m_impl->targetAddr != 0 && addr == m_impl->targetAddr)
                || (!m_impl->HasIrk() && Impl::HasOurService(args.Advertisement()));
            int smoothedInt = -100;

            // -127 dBm은 실제 측정값이 아니라 Windows가 "범위 이탈"을 알리는 표식 → 필터에 넣지 않음
            bool validRssi = (rssi > -127);

            if (matched && validRssi) {
                // 칼만 필터로 스무딩 후 공개 상태 갱신
                {
                    std::lock_guard<std::mutex> lock(m_impl->kalmanMutex);
                    ULONGLONG prev = m_impl->lastReceivedTick;
                    double dt = prev ? (GetTickCount64() - prev) / 1000.0 : 1.0;
                    smoothedInt = (int)std::lround(m_impl->kalman.Update((double)rssi, dt));
                }
                m_impl->rawRssi = rssi;
                m_impl->smoothedRssi = smoothedInt;
                m_impl->lastReceivedTick = GetTickCount64();
                m_impl->receiving = true;
                SetEvent(m_impl->packetEvent);
            }

            // 진단 로그: 주변 모든 광고를 기록해 대상 기기가 어떤 형태로 보이는지 확인
            if (m_impl->logFile) {
                const wchar_t* addrType = L"?";
                int companyId = -1;
                std::wstring payload, svcUuid;
                try {
                    switch (args.BluetoothAddressType()) {
                    case Windows::Devices::Bluetooth::BluetoothAddressType::Public: addrType = L"public"; break;
                    case Windows::Devices::Bluetooth::BluetoothAddressType::Random: addrType = L"random"; break;
                    default: break;
                    }
                    auto md = args.Advertisement().ManufacturerData();
                    if (md.Size() > 0) {
                        companyId = md.GetAt(0).CompanyId();
                        // 제조사 데이터 앞 24바이트 (Apple: 첫 바이트가 메시지 종류. 0x01=앱 백그라운드 광고, 0x10=Nearby Info 등)
                        auto buf = md.GetAt(0).Data();
                        auto reader = Windows::Storage::Streams::DataReader::FromBuffer(buf);
                        uint32_t n = (std::min)(buf.Length(), (uint32_t)24);
                        wchar_t hx[4];
                        for (uint32_t i = 0; i < n; i++) { swprintf_s(hx, L"%02X", reader.ReadByte()); payload += hx; }
                    }
                    auto uuids = args.Advertisement().ServiceUuids();
                    if (uuids.Size() > 0) svcUuid = winrt::to_hstring(uuids.GetAt(0)).c_str();
                } catch (...) {}
                m_impl->LogAdv(addr, addrType, companyId, advName, matched, rssi, smoothedInt, payload, svcUuid);
            }
        });

        // 스캔 시작
        m_impl->watcher.Start();
        m_impl->available = true;
        m_impl->running = true;
        return true;

    } catch (winrt::hresult_error const&) {
        // WinRT 초기화 실패 (BLE 어댑터 없음, Windows 10 미만 등)
        m_impl->available = false;
        m_impl->running = false;
        return false;
    } catch (...) {
        m_impl->available = false;
        m_impl->running = false;
        return false;
    }
}

// ---------------------------------------------------------------------------
// Stop - BLE 스캔 중지
// ---------------------------------------------------------------------------
void BleRssiScanner::Stop() {
    if (!m_impl->running) return;

    try {
        if (m_impl->watcher) {
            m_impl->watcher.Received(m_impl->receivedToken);
            m_impl->watcher.Stop();
            m_impl->watcher = nullptr;
        }
    } catch (...) {}

    {
        std::lock_guard<std::mutex> lock(m_impl->logMutex);
        if (m_impl->logFile) { fclose(m_impl->logFile); m_impl->logFile = nullptr; }
    }

    m_impl->running = false;
    m_impl->receiving = false;
}

// ---------------------------------------------------------------------------
// 진단 로그 경로 설정 (Start 전에 호출, 빈 문자열이면 비활성)
// ---------------------------------------------------------------------------
void BleRssiScanner::SetDebugLog(const std::wstring& path) {
    m_impl->logPath = path;
}

// ---------------------------------------------------------------------------
// IRK 설정 (32자리 hex, Start 전에 호출). 빈 문자열이면 RPA 해석 비활성
// ---------------------------------------------------------------------------
ULONGLONG BleRssiScanner::LastReceivedTick() const {
    return m_impl->lastReceivedTick;
}

HANDLE BleRssiScanner::PacketEvent() const {
    return m_impl->packetEvent;
}

void BleRssiScanner::SetTimeoutSec(DWORD sec) {
    if (sec < 5) sec = 5;
    if (sec > 600) sec = 600;
    m_impl->timeoutMs = sec * 1000;
}

bool BleRssiScanner::SetIrk(const std::wstring& irkHex) {
    if (irkHex.empty()) { m_impl->ClearIrk(); return false; }
    return m_impl->SetIrk(irkHex);
}

// ---------------------------------------------------------------------------
// 이번 세션에서 대상 기기의 BLE 광고를 한 번이라도 수신했는지
// ---------------------------------------------------------------------------
bool BleRssiScanner::HasEverReceived() const {
    return m_impl->lastReceivedTick != 0;
}

// ---------------------------------------------------------------------------
// 스무딩된 RSSI 반환
// ---------------------------------------------------------------------------
int BleRssiScanner::GetSmoothedRssi() const {
    // 마지막 수신으로부터 타임아웃(기본 90초) 이상 경과하면 -100 (수신 없음) 반환
    if (m_impl->lastReceivedTick == 0) return -100;
    ULONGLONG elapsed = GetTickCount64() - m_impl->lastReceivedTick;
    if (elapsed > m_impl->timeoutMs) {
        m_impl->receiving = false;
        return -100;
    }
    return m_impl->smoothedRssi;
}

// ---------------------------------------------------------------------------
// Raw RSSI 반환
// ---------------------------------------------------------------------------
int BleRssiScanner::GetRawRssi() const {
    if (m_impl->lastReceivedTick == 0) return -100;
    ULONGLONG elapsed = GetTickCount64() - m_impl->lastReceivedTick;
    if (elapsed > m_impl->timeoutMs) return -100;
    return m_impl->rawRssi;
}

// ---------------------------------------------------------------------------
// 마지막 수신 이후 경과 시간
// ---------------------------------------------------------------------------
DWORD BleRssiScanner::GetTimeSinceLastReceived() const {
    if (m_impl->lastReceivedTick == 0) return 99999;
    return (DWORD)(GetTickCount64() - m_impl->lastReceivedTick);
}

// ---------------------------------------------------------------------------
// 신호 수신 중 여부 (타임아웃 이내 수신 있음)
// ---------------------------------------------------------------------------
bool BleRssiScanner::IsReceiving() const {
    if (m_impl->lastReceivedTick == 0) return false;
    return (GetTickCount64() - m_impl->lastReceivedTick) < m_impl->timeoutMs;
}

// ---------------------------------------------------------------------------
// BLE 사용 가능 여부
// ---------------------------------------------------------------------------
bool BleRssiScanner::IsAvailable() const {
    return m_impl->available;
}
