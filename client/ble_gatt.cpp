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
    // subscribers / intervalMs / pollStartTick / lastReportTick 를 한 묶음으로 바꾸는 잠금.
    // 틱 스레드와 SubscribedClientsChanged 가 서로의 값을 덮어쓰지 않게 한다 (아래 람다 주석).
    std::mutex pollMutex;

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
        // 재보기 중: 입력이 있어도 1초마다 깨운다. 아래 "입력 중 = 0" 을 그대로 두면 앉아
        // 있는 1분 동안 키보드를 만진 사람은 연결 표본이 하나도 안 쌓여 "연결 신호 못 쟀어요"
        // 가 된다. 재는 동안은 잠그지 않으므로(g_measuring) 판정이 연결 RSSI 를 봐도 괜찮다.
        if (g_measuring) return 1000;
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

    // 틱 스레드가 받는 것. 스레드가 시작하면서 지운다.
    struct TickParam {
        Impl*  self;
        HANDLE stopEvent;   // 이 스레드 몫의 사본 (DuplicateHandle). 스레드가 끝날 때 닫는다
    };

    // 정지 이벤트는 멤버(stopEvent)를 매번 다시 읽지 않고 자기 사본을 기다린다. 예전에는
    // Stop 이 3초 조인을 넘겨도 멤버를 닫고 null 로 만들어서, 그때 아직 돌던 스레드의 대기가
    // 바로 실패(WAIT_FAILED)하며 200ms 쉼 없이 돌았고, 다음 Start 가 만든 이벤트를 제 것으로
    // 삼아 틱 스레드가 둘이 됐다. 사본은 Stop 이 자기 것을 닫아도 살아 있고 이미 신호돼 있다.
    static DWORD WINAPI TickThread(LPVOID p) {
        auto* prm = (TickParam*)p;
        Impl* self = prm->self;
        HANDLE stopEv = prm->stopEvent;
        delete prm;
        try { winrt::init_apartment(winrt::apartment_type::multi_threaded); } catch (...) {}
        ULONGLONG lastSent = 0, lastAdvCheck = 0;
        uint8_t seq = 0;
        while (WaitForSingleObject(stopEv, 200) == WAIT_TIMEOUT) {
            ULONGLONG t = GetTickCount64();
            if (self->subscribers == 0 && (t - lastAdvCheck) > 3000) {
                lastAdvCheck = t;
                self->EnsureAdvertising();
                // 광고를 다시 켜는 데는 시간이 걸린다 (멈춤 -> 200ms -> 시작). 그 사이 Stop 이
                // 지나갔으면 tickChar 를 비우는 중일 수 있다 - 만지지 않고 나간다.
                if (WaitForSingleObject(stopEv, 0) != WAIT_TIMEOUT) break;
            }
            DWORD want;
            ULONGLONG now;
            {
                // 구독 콜백과 같은 잠금 안에서 정한다. 잠금이 없으면 "구독자 0 -> 간격 0" 을
                // 계산한 직후 콜백이 첫 간격을 내놓고, 그 위에 0 을 덮어써 버릴 수 있다.
                std::lock_guard<std::mutex> lock(self->pollMutex);
                want = (self->subscribers > 0) ? DesiredIntervalMs() : 0;
                DWORD prev = self->intervalMs.exchange(want);
                now = GetTickCount64();
                if (want > 0 && prev == 0) self->pollStartTick = now;
            }
            if (want == 0 || (now - lastSent) < want) continue;
            try {
                DataWriter w;
                w.WriteByte(seq++);
                self->tickChar.NotifyValueAsync(w.DetachBuffer());  // fire-and-forget
                lastSent = now;
            } catch (...) {}
        }
        CloseHandle(stopEv);
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
            // 새 구독이면 폴링 간격을 여기서 바로 정해 구독자 수와 한 번에 내놓는다 (200 ms
            // 틱과 같은 규칙). 예전에는 구독자 수만 0 -> 1 로 바꾸고 아래 SetEvent 로 판정
            // 스레드를 깨웠는데, intervalMs 는 틱 스레드가 최대 200 ms 뒤에야 정했다. 그 사이
            // 판정은 "구독자 있음, 간격 0" 을 본다: 간격 0 이면 IsHealthy 는 무조건 true 이고
            // 판정은 "간격 0 = 사용자가 입력 중" 으로 읽어 NEAR 를 낸다. 자리에 아무도 없는데
            // 잠긴 화면이 풀릴 수 있었다 (events.log 의 "GATT client subscribed" 바로 뒤
            // "STATE FAR -> NEAR (GATT ...)"). Mac 판 GattServer 와 같은 고침이다.
            // IsHealthy 는 subscribers 를 먼저 읽으므로 간격과 시각을 구독자 수보다 먼저 쓴다.
            // DesiredIntervalMs 는 잠금 밖에서 계산한다 (잠금 안에서는 값만 바꾼다).
            DWORD firstIv = Impl::DesiredIntervalMs();
            ULONGLONG now = GetTickCount64();
            int prev;
            {
                std::lock_guard<std::mutex> lock(impl->pollMutex);
                prev = impl->subscribers.load();
                if (n > 0 && prev == 0) {
                    impl->intervalMs = firstIv;
                    // 첫 보고가 오기 전까지 판정은 상태를 그대로 둔다 (ReportAgeMs = 0xFFFFFFFF).
                    impl->pollStartTick = now;
                    impl->lastReportTick = 0;
                }
                impl->subscribers = n;
            }
            if (n > 0 && prev == 0) {
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

        // 틱 스레드는 정지 이벤트의 사본을 따로 받는다 (TickThread 주석). 멤버는 Stop 의 몫이다.
        m_impl->stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        auto* tp = new Impl::TickParam{ m_impl, nullptr };
        if (m_impl->stopEvent &&
            DuplicateHandle(GetCurrentProcess(), m_impl->stopEvent, GetCurrentProcess(),
                            &tp->stopEvent, 0, FALSE, DUPLICATE_SAME_ACCESS))
            m_impl->thread = CreateThread(nullptr, 0, Impl::TickThread, tp, 0, nullptr);
        if (!m_impl->thread) {
            // 예전에는 확인하지 않았다. 틱이 없으면 폰 앱이 깨지 않아 보고가 안 온다.
            DbgEvent(L"GATT tick thread could not start (err=%lu)", GetLastError());
            if (tp->stopEvent) CloseHandle(tp->stopEvent);
            delete tp;
        }
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
        // 넘기면 스레드는 그대로 두고 갈 길을 간다. 스레드는 자기 사본(이미 신호됨)을
        // 기다리므로 지금 하던 일을 마치면 스스로 끝난다. 여기서는 내 사본만 닫는다.
        if (WaitForSingleObject(m_impl->thread, 3000) != WAIT_OBJECT_0)
            DbgEvent(L"GATT tick thread did not stop in 3s - left to finish");
        CloseHandle(m_impl->thread); m_impl->thread = nullptr;
    }
    if (m_impl->stopEvent) { CloseHandle(m_impl->stopEvent); m_impl->stopEvent = nullptr; }
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
ULONGLONG BleGattServer::LastReportTick() const { return m_impl->lastReportTick; }
HANDLE BleGattServer::ReportEvent() const { return m_impl->reportEvent; }
