// ble_ident.cpp - 연결로 폰의 신원을 확인한다 (헤더의 설계 배경 참고)
// config.h 는 winsock2.h 를 끌어오므로 windows.h 를 끌고 오는
// WinRT 헤더보다 먼저 와야 한다 (DbgEvent 용)
#include "config.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Storage.Streams.h>

#include "ble_ident.h"
#include "ble_gatt.h"   // SS_IDENT_SERVICE_UUID / SS_IDENT_TOKEN_UUID
#include <windows.h>
#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>

using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::Advertisement;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Storage::Streams;
using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Foundation::IAsyncOperation;

static winrt::guid ToGuid(const wchar_t* s) {
    GUID g{}; CLSIDFromString(s, &g); return winrt::guid(g);
}

// 버린 작업이 늦게 끝나서 그 결과를 닫은 일. 취소가 먹히면 이 줄은 아예 안 나온다 -
// 나오면 취소를 무시하는 스택이고, 예전 코드였다면 그만큼 연결이 쌓였다는 뜻이다.
// 탐색은 2초마다라 그때마다 적으면 STATE 줄이 묻힌다. 5분에 한 줄, 누적 횟수와 함께.
static void NoteLateClose(const wchar_t* what) {
    static std::atomic<long> count{ 0 };
    static std::atomic<ULONGLONG> lastLog{ 0 };
    long n = ++count;
    ULONGLONG now = GetTickCount64();
    ULONGLONG last = lastLog.load();
    if (last != 0 && now - last < 300000) return;
    if (!lastLog.compare_exchange_strong(last, now)) return;   // 다른 스레드가 방금 적었다
    DbgEvent(L"ident: closed a late %s after giving up (%ld so far)", what, n);
}

// 늦게 끝난 결과를 닫는 것들 (WaitOrCancel 의 closeLate)
static void CloseLateDevice(BluetoothLEDevice const& d) {
    if (!d) return;
    try { d.Close(); } catch (...) {}
    NoteLateClose(L"device object");
}
static void CloseLateServices(GattDeviceServicesResult const& r) {
    if (!r) return;
    bool any = false;
    try {
        for (auto const& s : r.Services()) { try { s.Close(); } catch (...) {} any = true; }
    } catch (...) {}
    if (any) NoteLateClose(L"service list");
}
// 특성 목록과 읽은 값은 닫을 것이 없다 - 서비스를 닫으면 같이 놓인다.
template <typename T> static void NothingToClose(T const&) {}

// 비동기 작업을 ms 만큼 기다린다. 시간을 넘기면 작업을 취소하고 Started 를 준다 (= 시간 초과).
// 취소한 뒤에 그래도 끝나면 그 결과는 closeLate 가 닫는다.
//
// 예전에는 wait_for 가 시간을 넘기면 작업을 취소하지 않고 그냥 두었다. 작업은 뒤에서 계속
// 붙으려 했고, 늦게라도 끝나면 그 결과(기기 객체, 서비스 핸들)는 아무도 닫지 않았다 - 아래
// "서비스 핸들을 쥐고 있으면 Windows 가 LE 연결을 놓지 않는다" 가 보이지 않게 쌓이는 길이다.
// 노트북 로그에서 PC 가 폰에 새로 붙는 연결은 앱을 막 켰을 때와 깨어난 직후 말고는 거의
// 다(~99.5%) 실패했다.
// wait_for 는 자기 완료 콜백을 거는데 작업 하나에 완료 콜백은 하나뿐이다. 그래서 늦게 온
// 결과를 닫으려면 처음부터 우리 콜백으로 기다려야 한다.
template <typename T, typename CloseLate>
static AsyncStatus WaitOrCancel(IAsyncOperation<T> const& op, DWORD ms, CloseLate closeLate) {
    // 결과의 주인은 기다리는 쪽과 완료 콜백 중 먼저 온 쪽이다.
    // 0 = 아직, 1 = 제때 끝났다 (기다린 쪽이 결과를 쓰고 닫는다), 2 = 버렸다 (콜백이 닫는다)
    struct Shared {
        HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        std::atomic<int> owner{ 0 };
        ~Shared() { if (done) CloseHandle(done); }
    };
    auto sh = std::make_shared<Shared>();
    if (!sh->done) {
        // 이벤트도 못 만드는 상황이면 예전 방식으로 기다리고 취소만 한다
        AsyncStatus st = op.wait_for(std::chrono::milliseconds(ms));
        if (st == AsyncStatus::Started) { try { op.Cancel(); } catch (...) {} }
        return st;
    }
    // 이미 끝난 작업이면 이 자리에서 바로 불린다 - 그래도 같은 규칙이다
    op.Completed([sh, closeLate](IAsyncOperation<T> const& o, AsyncStatus s) {
        int expect = 0;
        if (sh->owner.compare_exchange_strong(expect, 1)) { SetEvent(sh->done); return; }
        if (s != AsyncStatus::Completed) return;   // 취소됐거나 실패했다 - 닫을 결과가 없다
        try { closeLate(o.GetResults()); } catch (...) {}
    });
    WaitForSingleObject(sh->done, ms);
    int expect = 0;
    if (sh->owner.compare_exchange_strong(expect, 2)) {
        try { op.Cancel(); } catch (...) {}
        return AsyncStatus::Started;
    }
    return op.Status();
}

static const wchar_t* StatusText(GattCommunicationStatus s) {
    switch (s) {
    case GattCommunicationStatus::Success:       return L"Success";
    case GattCommunicationStatus::Unreachable:   return L"Unreachable";
    case GattCommunicationStatus::ProtocolError: return L"ProtocolError";
    case GattCommunicationStatus::AccessDenied:  return L"AccessDenied";
    default:                                     return L"?";
    }
}

ProbeOutcome ReadPhoneToken(uint64_t addr, bool randomAddr,
                            std::wstring& tokenHex, std::wstring& why,
                            DWORD* elapsedMs) {
    tokenHex.clear();
    why.clear();
    ULONGLONG t0 = GetTickCount64();
    struct Timer {
        ULONGLONG t0; DWORD* out;
        ~Timer() { if (out) *out = (DWORD)(GetTickCount64() - t0); }
    } timer{ t0, elapsedMs };
    static const winrt::guid identGuid = ToGuid(SS_IDENT_SERVICE_UUID);
    static const winrt::guid tokenGuid = ToGuid(SS_IDENT_TOKEN_UUID);

    try { winrt::init_apartment(winrt::apartment_type::multi_threaded); } catch (...) {}

    // 시간을 넘긴 작업은 모두 WaitOrCancel 이 취소하고, 그 뒤에 늦게 끝나도 결과를 닫는다.
    // 받은 기기와 서비스는 어느 길로 나가든 아래 끝에서 닫는다.
    BluetoothLEDevice dev{ nullptr };
    try {
        auto op = BluetoothLEDevice::FromBluetoothAddressAsync(
            addr, randomAddr ? BluetoothAddressType::Random : BluetoothAddressType::Public);
        if (WaitOrCancel(op, 5000, CloseLateDevice) != AsyncStatus::Completed) {
            why = L"device object timeout"; return ProbeOutcome::Unreachable;
        }
        dev = op.GetResults();
    } catch (hresult_error const& e) {
        wchar_t b[64]; swprintf_s(b, L"device object 0x%08X", (unsigned)e.code());
        why = b; return ProbeOutcome::Unreachable;
    } catch (...) {
        // 프로버 스레드는 예외를 받지 않는다 - 새면 앱이 통째로 끝난다.
        // dev 는 마지막 줄에서야 채워지므로 여기서는 아직 비어 있다.
        why = L"device object unknown error"; return ProbeOutcome::Unreachable;
    }
    if (!dev) { why = L"device object null"; return ProbeOutcome::Unreachable; }

    ProbeOutcome outcome = ProbeOutcome::Unreachable;
    GattDeviceServicesResult res{ nullptr };
    try {
        // Uncached 라야 실제로 붙는다. 캐시를 주면 예전 서비스 목록이 돌아온다.
        auto sop = dev.GetGattServicesAsync(BluetoothCacheMode::Uncached);
        if (WaitOrCancel(sop, 10000, CloseLateServices) != AsyncStatus::Completed) {
            why = L"service discovery timeout";
        } else {
            res = sop.GetResults();
            if (res.Status() != GattCommunicationStatus::Success) {
                why = StatusText(res.Status());
            } else {
                auto svcs = res.Services();
                bool found = false;
                for (auto const& s : svcs) {
                    if (s.Uuid() != identGuid) continue;
                    found = true;
                    auto cop = s.GetCharacteristicsAsync(BluetoothCacheMode::Uncached);
                    if (WaitOrCancel(cop, 5000, NothingToClose<GattCharacteristicsResult>)
                            != AsyncStatus::Completed) {
                        why = L"characteristic discovery timeout"; break;
                    }
                    auto cres = cop.GetResults();
                    if (cres.Status() != GattCommunicationStatus::Success) {
                        why = StatusText(cres.Status()); break;
                    }
                    for (auto const& ch : cres.Characteristics()) {
                        if (ch.Uuid() != tokenGuid) continue;
                        auto rop = ch.ReadValueAsync(BluetoothCacheMode::Uncached);
                        if (WaitOrCancel(rop, 5000, NothingToClose<GattReadResult>)
                                != AsyncStatus::Completed) {
                            why = L"token read timeout"; break;
                        }
                        auto rres = rop.GetResults();
                        if (rres.Status() != GattCommunicationStatus::Success) {
                            why = StatusText(rres.Status()); break;
                        }
                        auto buf = rres.Value();
                        auto rd = DataReader::FromBuffer(buf);
                        wchar_t hx[4];
                        for (uint32_t i = 0; i < buf.Length(); i++) {
                            swprintf_s(hx, L"%02X", rd.ReadByte());
                            tokenHex += hx;
                        }
                        if (tokenHex.empty()) why = L"token empty";
                        else outcome = ProbeOutcome::Token;
                        break;
                    }
                    break;
                }
                if (!found) { why = L"ident service absent"; outcome = ProbeOutcome::NotOurs; }
            }
        }
    } catch (hresult_error const& e) {
        wchar_t b[64]; swprintf_s(b, L"gatt 0x%08X", (unsigned)e.code());
        why = b;
    } catch (...) {
        why = L"gatt unknown error";
    }

    // 서비스 핸들을 쥐고 있으면 Windows가 LE 연결을 놓지 않는다.
    // 몇 대만 훑어도 연결 슬롯이 말라 이후가 전부 Unreachable 이 된다.
    // 하나가 던져도 나머지는 닫는다.
    if (res) {
        try { for (auto const& s : res.Services()) { try { s.Close(); } catch (...) {} } } catch (...) {}
    }
    // 연결을 붙잡고 있으면 폰이 광고를 멈출 수 있으니 반드시 놓아준다
    try { dev.Close(); } catch (...) {}
    return outcome;
}

bool RegisterPhone(int scanSec, std::wstring& tokenHex, std::wstring& why) {
    tokenHex.clear();
    why.clear();
    if (scanSec < 3) scanSec = 3;
    static const winrt::guid identGuid = ToGuid(SS_IDENT_SERVICE_UUID);

    try { winrt::init_apartment(winrt::apartment_type::multi_threaded); } catch (...) {}

    uint64_t best = 0;
    bool bestRandom = true;
    int bestRssi = -127;
    try {
        std::mutex mx;
        BluetoothLEAdvertisementWatcher w;
        w.ScanningMode(BluetoothLEScanningMode::Active);
        w.Received([&](BluetoothLEAdvertisementWatcher const&,
                       BluetoothLEAdvertisementReceivedEventArgs const& a) {
            bool plain = false;
            try {
                for (auto const& u : a.Advertisement().ServiceUuids())
                    if (u == identGuid) { plain = true; break; }
            } catch (...) {}
            if (!plain) return;   // 잠긴 폰은 UUID를 overflow로 옮기므로 여기 안 걸린다 - 의도한 것
            int rssi = (int)a.RawSignalStrengthInDBm();
            std::lock_guard<std::mutex> lock(mx);
            if (rssi > bestRssi) {
                bestRssi = rssi;
                best = a.BluetoothAddress();
                bestRandom = (a.BluetoothAddressType() != BluetoothAddressType::Public);
            }
        });
        w.Start();
        Sleep(scanSec * 1000);
        w.Stop();
    } catch (hresult_error const& e) {
        wchar_t b[64]; swprintf_s(b, L"scan 0x%08X", (unsigned)e.code());
        why = b; return false;
    }

    if (!best) {
        why = L"앱을 화면에 띄운 폰을 찾지 못했습니다";
        return false;
    }
    DbgEvent(L"register: candidate %012llX rssi=%d dBm", (unsigned long long)best, bestRssi);

    std::wstring reason;
    if (ReadPhoneToken(best, bestRandom, tokenHex, reason) != ProbeOutcome::Token) {
        why = L"연결은 했지만 토큰을 읽지 못했습니다 (" + reason + L")";
        return false;
    }
    return true;
}
