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
#include <chrono>
#include <map>
#include <mutex>

using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::Advertisement;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Storage::Streams;

static winrt::guid ToGuid(const wchar_t* s) {
    GUID g{}; CLSIDFromString(s, &g); return winrt::guid(g);
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

bool ReadPhoneToken(uint64_t addr, bool randomAddr,
                    std::wstring& tokenHex, std::wstring& why) {
    tokenHex.clear();
    why.clear();
    static const winrt::guid identGuid = ToGuid(SS_IDENT_SERVICE_UUID);
    static const winrt::guid tokenGuid = ToGuid(SS_IDENT_TOKEN_UUID);

    try { winrt::init_apartment(winrt::apartment_type::multi_threaded); } catch (...) {}

    BluetoothLEDevice dev{ nullptr };
    try {
        auto op = BluetoothLEDevice::FromBluetoothAddressAsync(
            addr, randomAddr ? BluetoothAddressType::Random : BluetoothAddressType::Public);
        if (op.wait_for(std::chrono::seconds(10)) != winrt::Windows::Foundation::AsyncStatus::Completed) {
            why = L"device object timeout"; return false;
        }
        dev = op.GetResults();
    } catch (hresult_error const& e) {
        wchar_t b[64]; swprintf_s(b, L"device object 0x%08X", (unsigned)e.code());
        why = b; return false;
    }
    if (!dev) { why = L"device object null"; return false; }

    bool ok = false;
    GattDeviceServicesResult res{ nullptr };
    try {
        // Uncached 라야 실제로 붙는다. 캐시를 주면 예전 서비스 목록이 돌아온다.
        auto sop = dev.GetGattServicesAsync(BluetoothCacheMode::Uncached);
        if (sop.wait_for(std::chrono::seconds(20)) != winrt::Windows::Foundation::AsyncStatus::Completed) {
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
                    if (cop.wait_for(std::chrono::seconds(10)) != winrt::Windows::Foundation::AsyncStatus::Completed) {
                        why = L"characteristic discovery timeout"; break;
                    }
                    auto cres = cop.GetResults();
                    if (cres.Status() != GattCommunicationStatus::Success) {
                        why = StatusText(cres.Status()); break;
                    }
                    for (auto const& ch : cres.Characteristics()) {
                        if (ch.Uuid() != tokenGuid) continue;
                        auto rop = ch.ReadValueAsync(BluetoothCacheMode::Uncached);
                        if (rop.wait_for(std::chrono::seconds(10)) != winrt::Windows::Foundation::AsyncStatus::Completed) {
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
                        ok = !tokenHex.empty();
                        if (!ok) why = L"token empty";
                        break;
                    }
                    break;
                }
                if (!found) why = L"ident service absent";
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
    if (res) { try { for (auto const& s : res.Services()) s.Close(); } catch (...) {} }
    // 연결을 붙잡고 있으면 폰이 광고를 멈출 수 있으니 반드시 놓아준다
    try { dev.Close(); } catch (...) {}
    return ok;
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
    if (!ReadPhoneToken(best, bestRandom, tokenHex, reason)) {
        why = L"연결은 했지만 토큰을 읽지 못했습니다 (" + reason + L")";
        return false;
    }
    return true;
}
