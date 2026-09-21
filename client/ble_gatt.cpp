// ble_gatt.cpp - BLE GATT 서버 구현 (WinRT GattServiceProvider)

// config.h -> common.h가 winsock2.h를 포함하므로 WinRT(windows.h)보다 먼저 와야 함
#include "config.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Storage.Streams.h>

#include "ble_gatt.h"
#include "ble_rssi.h"   // KalmanFilter
#include <atomic>
#include <mutex>
#include <cmath>
#include <cstdio>
#include <algorithm>

using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Storage::Streams;

BleGattServer g_bleGatt;

static winrt::guid GuidFromString(const wchar_t* s) {
    GUID g{};
    CLSIDFromString(s, &g);
    return winrt::guid(g);
}

struct BleGattServer::Impl {
    GattServiceProvider provider{ nullptr };
    GattLocalCharacteristic tickChar{ nullptr };
    GattLocalCharacteristic rssiChar{ nullptr };
    winrt::event_token subToken{}, writeToken{};

    std::atomic<bool> running{ false };
    std::atomic<int>  subscribers{ 0 };
    std::atomic<int>  rawRssi{ -100 };
    std::atomic<int>  smoothedRssi{ -100 };
    std::atomic<ULONGLONG> lastReportTick{ 0 };
    std::atomic<ULONGLONG> pollStartTick{ 0 };
    std::atomic<ULONGLONG> lostTick{ 0 };
    std::atomic<bool> everSubscribed{ false };
    std::atomic<DWORD> intervalMs{ 0 };

    KalmanFilter kalman{ 4.0, 10.0 };  // 1Hz 샘플링: v1(Q=1)보다 빠르게 반응
    std::mutex kalmanMutex;

    HANDLE reportEvent{ CreateEventW(nullptr, FALSE, FALSE, nullptr) };
    HANDLE stopEvent{ nullptr };
    HANDLE thread{ nullptr };

    FILE* logFile{ nullptr };
    std::mutex logMutex;

    // 폴링 정책: RSSI가 필요한 건 "자리를 떴을지도 모를 때"뿐 → 입력 중에는 폰 앱을 깨우지 않음 (배터리)
    static DWORD DesiredIntervalMs() {
        if (g_bBlackActive) return 2000;                 // 잠김 상태: 복귀 감시
        ULONGLONG idle = GetTickCount64() - g_lastInputTick.load();
        if (idle < 5000)   return 0;                     // 입력 중 = 자리에 있음
        if (idle < 120000) return 1000;                  // 입력 멈춤 직후: 빠르게 확인
        return 3000;                                     // 오래 가만히 있음: 느리게
    }

    void OnReport(int rssi, int seq) {
        if (rssi >= 0 || rssi <= -127) return;           // iOS: 127 = 측정 불가
        ULONGLONG now = GetTickCount64();
        int sm;
        {
            std::lock_guard<std::mutex> lock(kalmanMutex);
            ULONGLONG prev = lastReportTick;
            double dt = prev ? (now - prev) / 1000.0 : 1.0;
            sm = (int)std::lround(kalman.Update((double)rssi, dt));
        }
        rawRssi = rssi;
        smoothedRssi = sm;
        lastReportTick = now;
        SetEvent(reportEvent);

        std::lock_guard<std::mutex> lock(logMutex);
        if (logFile) {
            SYSTEMTIME st; GetLocalTime(&st);
            fwprintf(logFile, L"%02d:%02d:%02d.%03d,%d,%d,%d,%lu\n",
                st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, seq, rssi, sm, intervalMs.load());
            fflush(logFile);
        }
    }

    // 광고가 멈춰 있으면 다시 켠다. Stop() 직후 재시작하면 Windows가 Aborted로 떨어지는 경우가 있음
    std::atomic<int> advRetries{ 0 };

    void EnsureAdvertising() {
        if (!provider || !running) return;
        try {
            auto st = provider.AdvertisementStatus();
            if (st == GattServiceProviderAdvertisementStatus::Started ||
                st == GattServiceProviderAdvertisementStatus::StartedWithoutAllAdvertisementData) {
                advRetries = 0;
                return;
            }
            // Aborted 상태에서는 StartAdvertising만 다시 불러도 살아나지 않는다. 먼저 멈춘다.
            try { provider.StopAdvertising(); } catch (...) {}
            Sleep(200);
            GattServiceProviderAdvertisingParameters adv;
            adv.IsConnectable(true);
            adv.IsDiscoverable(true);
            provider.StartAdvertising(adv);
            int n = ++advRetries;
            DbgEvent(L"GATT advertisement restart #%d -> status=%d", n, (int)provider.AdvertisementStatus());
        } catch (winrt::hresult_error const& e) {
            DbgEvent(L"GATT advertisement restart failed: 0x%08X", (unsigned)e.code());
        } catch (...) {
            DbgEvent(L"GATT advertisement restart failed");
        }
    }

    static DWORD WINAPI TickThread(LPVOID p) {
        auto* self = (Impl*)p;
        try { winrt::init_apartment(winrt::apartment_type::multi_threaded); } catch (...) {}
        ULONGLONG lastSent = 0, lastAdvCheck = 0;
        uint8_t seq = 0;
        while (WaitForSingleObject(self->stopEvent, 200) != WAIT_OBJECT_0) {
            ULONGLONG t = GetTickCount64();
            if (self->subscribers == 0 && (t - lastAdvCheck) > 3000) {
                lastAdvCheck = t;
                self->EnsureAdvertising();
            }
            DWORD want = (self->subscribers > 0) ? DesiredIntervalMs() : 0;
            DWORD prev = self->intervalMs.exchange(want);
            ULONGLONG now = GetTickCount64();
            if (want > 0 && prev == 0) self->pollStartTick = now;
            if (want == 0 || (now - lastSent) < want) continue;
            try {
                DataWriter w;
                w.WriteByte(seq++);
                self->tickChar.NotifyValueAsync(w.DetachBuffer());  // fire-and-forget
                lastSent = now;
            } catch (...) {}
        }
        return 0;
    }
};

BleGattServer::BleGattServer() : m_impl(new Impl()) {}

BleGattServer::~BleGattServer() {
    Stop();
    CloseHandle(m_impl->reportEvent);
    delete m_impl;
}

bool BleGattServer::Start(bool plain, const std::wstring& logPath) {
    if (m_impl->running) Stop();

    m_impl->subscribers = 0;
    m_impl->rawRssi = -100;
    m_impl->smoothedRssi = -100;
    m_impl->lastReportTick = 0;
    m_impl->pollStartTick = 0;
    m_impl->lostTick = 0;
    m_impl->everSubscribed = false;
    m_impl->intervalMs = 0;
    {
        std::lock_guard<std::mutex> lock(m_impl->kalmanMutex);
        m_impl->kalman.Reset();
    }

    try {
        try { winrt::init_apartment(winrt::apartment_type::multi_threaded); } catch (...) {}

        auto adapter = BluetoothAdapter::GetDefaultAsync().get();
        if (!adapter || !adapter.IsPeripheralRoleSupported()) {
            DbgEvent(L"GATT start failed: adapter has no peripheral role");
            return false;
        }

        auto created = GattServiceProvider::CreateAsync(GuidFromString(SS_GATT_SERVICE_UUID)).get();
        if (created.Error() != BluetoothError::Success) {
            DbgEvent(L"GATT start failed: CreateAsync error %d", (int)created.Error());
            return false;
        }
        m_impl->provider = created.ServiceProvider();

        // 본딩된 기기의 암호화 연결만 허용 → 제3자가 연결해서 가짜 RSSI를 써 넣는 것을 차단
        auto level = plain ? GattProtectionLevel::Plain : GattProtectionLevel::EncryptionRequired;

        GattLocalCharacteristicParameters tickParams;
        tickParams.CharacteristicProperties(GattCharacteristicProperties::Notify);
        tickParams.ReadProtectionLevel(level);
        tickParams.WriteProtectionLevel(level);
        auto tickRes = m_impl->provider.Service().CreateCharacteristicAsync(
            GuidFromString(SS_GATT_TICK_UUID), tickParams).get();
        if (tickRes.Error() != BluetoothError::Success) {
            DbgEvent(L"GATT start failed: tick characteristic error %d", (int)tickRes.Error());
            m_impl->provider = nullptr;
            return false;
        }
        m_impl->tickChar = tickRes.Characteristic();

        GattLocalCharacteristicParameters rssiParams;
        rssiParams.CharacteristicProperties(
            GattCharacteristicProperties::Write | GattCharacteristicProperties::WriteWithoutResponse);
        rssiParams.WriteProtectionLevel(level);
        auto rssiRes = m_impl->provider.Service().CreateCharacteristicAsync(
            GuidFromString(SS_GATT_RSSI_UUID), rssiParams).get();
        if (rssiRes.Error() != BluetoothError::Success) {
            DbgEvent(L"GATT start failed: rssi characteristic error %d", (int)rssiRes.Error());
            m_impl->tickChar = nullptr; m_impl->provider = nullptr;
            return false;
        }
        m_impl->rssiChar = rssiRes.Characteristic();

        Impl* impl = m_impl;
        m_impl->subToken = m_impl->tickChar.SubscribedClientsChanged(
            [impl](GattLocalCharacteristic const& sender, winrt::Windows::Foundation::IInspectable const&)
        {
            int n = (int)sender.SubscribedClients().Size();
            int prev = impl->subscribers.exchange(n);
            ULONGLONG now = GetTickCount64();
            if (n > 0 && prev == 0) {
                impl->pollStartTick = now;
                impl->lastReportTick = 0;
                impl->everSubscribed = true;
                {
                    std::lock_guard<std::mutex> lock(impl->kalmanMutex);
                    impl->kalman.Reset();
                }
                DbgEvent(L"GATT client subscribed");
            } else if (n == 0 && prev > 0) {
                impl->lostTick = now;
                DbgEvent(L"GATT client lost (last rssi=%d dBm)", impl->smoothedRssi.load());
            }
            SetEvent(impl->reportEvent);
        });

        m_impl->writeToken = m_impl->rssiChar.WriteRequested(
            [impl](GattLocalCharacteristic const&, GattWriteRequestedEventArgs const& args)
        {
            auto deferral = args.GetDeferral();
            try {
                auto req = args.GetRequestAsync().get();
                if (req) {
                    auto buf = req.Value();
                    if (buf && buf.Length() >= 1) {
                        auto reader = DataReader::FromBuffer(buf);
                        int rssi = (int8_t)reader.ReadByte();
                        int seq = (buf.Length() >= 2) ? reader.ReadByte() : -1;
                        impl->OnReport(rssi, seq);
                    }
                    if (req.Option() == GattWriteOption::WriteWithResponse) req.Respond();
                }
            } catch (...) {}
            deferral.Complete();
        });

        if (!logPath.empty()) {
            std::lock_guard<std::mutex> lock(m_impl->logMutex);
            m_impl->logFile = _wfsopen(logPath.c_str(), L"a,ccs=UTF-8", _SH_DENYWR);
            if (m_impl->logFile) {
                fwprintf(m_impl->logFile, L"# session\ntime,seq,rawRssi,smoothedRssi,pollIntervalMs\n");
                fflush(m_impl->logFile);
            }
        }

        // 광고 상태 변화를 로그로 남김 (StartedWithoutAllAdvertisementData = UUID가 광고에 안 실림)
        m_impl->provider.AdvertisementStatusChanged(
            [](GattServiceProvider const& p, GattServiceProviderAdvertisementStatusChangedEventArgs const&)
        {
            const wchar_t* s = L"?";
            switch (p.AdvertisementStatus()) {
            case GattServiceProviderAdvertisementStatus::Created: s = L"Created"; break;
            case GattServiceProviderAdvertisementStatus::Stopped: s = L"Stopped"; break;
            case GattServiceProviderAdvertisementStatus::Started: s = L"Started"; break;
            case GattServiceProviderAdvertisementStatus::Aborted: s = L"Aborted"; break;
            case GattServiceProviderAdvertisementStatus::StartedWithoutAllAdvertisementData:
                s = L"StartedWithoutAllAdvertisementData"; break;
            }
            DbgEvent(L"GATT advertisement status: %s", s);
        });

        GattServiceProviderAdvertisingParameters adv;
        adv.IsConnectable(true);
        adv.IsDiscoverable(true);
        m_impl->provider.StartAdvertising(adv);
        DbgEvent(L"GATT advertising: status=%d (2=Started, 3=Aborted)",
                 (int)m_impl->provider.AdvertisementStatus());

        m_impl->stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        m_impl->thread = CreateThread(nullptr, 0, Impl::TickThread, m_impl, 0, nullptr);
        m_impl->running = true;
        DbgEvent(L"GATT server started (%s)", plain ? L"plain" : L"encryption required");
        return true;

    } catch (winrt::hresult_error const& e) {
        DbgEvent(L"GATT start failed: hresult 0x%08X", (unsigned)e.code());
    } catch (...) {
        DbgEvent(L"GATT start failed: unknown exception");
    }
    m_impl->tickChar = nullptr; m_impl->rssiChar = nullptr; m_impl->provider = nullptr;
    return false;
}

void BleGattServer::Stop() {
    if (!m_impl->running) return;
    m_impl->running = false;

    if (m_impl->thread) {
        SetEvent(m_impl->stopEvent);
        WaitForSingleObject(m_impl->thread, 3000);
        CloseHandle(m_impl->thread); m_impl->thread = nullptr;
        CloseHandle(m_impl->stopEvent); m_impl->stopEvent = nullptr;
    }
    try {
        if (m_impl->tickChar) m_impl->tickChar.SubscribedClientsChanged(m_impl->subToken);
        if (m_impl->rssiChar) m_impl->rssiChar.WriteRequested(m_impl->writeToken);
        if (m_impl->provider) m_impl->provider.StopAdvertising();
    } catch (...) {}
    Sleep(300);   // Windows가 광고를 정리할 시간 (바로 재시작하면 Aborted가 됨)
    m_impl->tickChar = nullptr;
    m_impl->rssiChar = nullptr;
    m_impl->provider = nullptr;
    m_impl->subscribers = 0;
    m_impl->intervalMs = 0;
    {
        std::lock_guard<std::mutex> lock(m_impl->logMutex);
        if (m_impl->logFile) { fclose(m_impl->logFile); m_impl->logFile = nullptr; }
    }
}

bool BleGattServer::IsRunning() const { return m_impl->running; }
bool BleGattServer::IsClientSubscribed() const { return m_impl->subscribers > 0; }
bool BleGattServer::EverSubscribed() const { return m_impl->everSubscribed; }

bool BleGattServer::IsHealthy() const {
    if (m_impl->subscribers <= 0) return false;
    DWORD iv = m_impl->intervalMs;
    if (iv == 0) return true;   // 폴링 쉬는 중: 연결 유지만으로 충분
    ULONGLONG ref = (std::max)(m_impl->lastReportTick.load(), m_impl->pollStartTick.load());
    ULONGLONG limit = (std::max)((ULONGLONG)iv * 3, (ULONGLONG)8000);
    return (GetTickCount64() - ref) < limit;
}

DWORD BleGattServer::CurrentPollIntervalMs() const { return m_impl->intervalMs; }
int   BleGattServer::GetSmoothedRssi() const { return m_impl->smoothedRssi; }
int   BleGattServer::GetRawRssi() const { return m_impl->rawRssi; }

DWORD BleGattServer::ReportAgeMs() const {
    ULONGLONG t = m_impl->lastReportTick;
    if (t == 0) return 0xFFFFFFFF;
    return (DWORD)(GetTickCount64() - t);
}

ULONGLONG BleGattServer::LostTick() const { return m_impl->lostTick; }
HANDLE BleGattServer::ReportEvent() const { return m_impl->reportEvent; }
