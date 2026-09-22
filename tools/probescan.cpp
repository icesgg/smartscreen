// probescan.cpp - 잠긴 아이폰에서 신원 토큰을 읽어올 수 있는지 확인하는 도구
//
// 배경: 백그라운드/잠금 상태의 아이폰 광고에는 이름도 서비스 UUID도 실리지 않고
//       주기적으로 바뀌는 랜덤 주소(RPA)만 남는다. 지금 제품은 IRK로 RPA를 풀어
//       식별하는데, IRK를 얻으려면 그 PC에서 한 번은 BLE 본딩(사실상 Phone Link)을
//       해야 한다. 데스크톱 배포에서는 이게 설치의 최대 장벽이다.
//
//       대안은 "연결해서 물어보는 것"이다. PC가 central로 붙어 토큰 특성을 읽으면
//       IRK 없이 신원이 확정된다. 그게 되는지가 이 도구가 답하는 질문이다.
//
// 후보 고르기: Apple 백그라운드 광고의 제조사 데이터는 `01` + 16바이트 비트필드
//       (overflow 영역) 형태이고, 앱이 서비스 UUID 하나를 광고하면 그중 딱 한 비트가
//       켜진다. 실측 로그에서 주소 4048개 중 이 형태는 13개뿐이었고 팝카운트 1은
//       우리 폰뿐이었다. 그래서 이 모양을 1차 필터로 쓴다. 비트 번호 자체는 폰이
//       재부팅되면 바뀌므로(실측: 116 -> 85) 신원으로는 못 쓰고 필터로만 쓴다.
//
// 사용법: ProbeScan.exe [스캔초=20] [주소(12자리 16진수)]
//         주소를 주면 스캔을 건너뛰고 그 주소만 찔러본다.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Storage.Streams.h>
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>

using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::Advertisement;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Storage::Streams;

// ios/SSBeacon 의 kIdentUUID / kTokenUUID 와 동일해야 함.
// PC가 올리는 서비스(ble_gatt.h 의 7A1C0010)와는 다른 UUID다 - 폰이 올리는 쪽은 7A1C0020.
// 같은 값을 쓰면 폰 앱의 central 스캔이 옆자리 폰을 PC로 착각해서 붙으려 든다.
static const wchar_t* kIdentUuid = L"{7A1C0020-5353-4243-8E2B-9F3D5A6C7E10}";
static const wchar_t* kTokenUuid = L"{7A1C0021-5353-4243-8E2B-9F3D5A6C7E10}";
static const int kAppleCompanyId = 0x004C;

enum ProbeResult { PROBE_FAILED = 0, PROBE_DISCOVERED = 1, PROBE_TOKEN = 2 };

struct Candidate {
    uint64_t addr{ 0 };
    BluetoothAddressType type{ BluetoothAddressType::Random };
    int rssi{ -127 };
    int bitCount{ 0 };      // overflow 비트필드에서 켜진 비트 수
    int firstBit{ -1 };     // 그중 첫 번째 비트 번호 (등록 때 학습할 값)
    bool plain{ false };    // 광고에 서비스 UUID가 그대로 실린 경우 (앱 포그라운드)
    std::wstring name;
};

static winrt::guid ToGuid(const wchar_t* s) {
    GUID g{}; CLSIDFromString(s, &g); return winrt::guid(g);
}

// Apple overflow 영역인지 보고, 켜진 비트를 세어 준다.
// 제조사 데이터가 정확히 17바이트(01 + 16바이트 비트필드)일 때만 해당한다.
// 주변에 훨씬 흔한 24바이트짜리 `01 09 20 22 ...` 메시지는 길이에서 걸러진다.
static bool OverflowBits(IBuffer const& data, int& count, int& firstBit) {
    count = 0; firstBit = -1;
    if (data.Length() != 17) return false;
    auto r = DataReader::FromBuffer(data);
    if (r.ReadByte() != 0x01) return false;
    for (int i = 0; i < 16; i++) {
        uint8_t b = r.ReadByte();
        for (int k = 0; k < 8; k++) {
            if (b & (1 << k)) {
                if (firstBit < 0) firstBit = i * 8 + k;
                count++;
            }
        }
    }
    return true;
}

static const char* StatusText(GattCommunicationStatus s) {
    switch (s) {
    case GattCommunicationStatus::Success:       return "Success";
    case GattCommunicationStatus::Unreachable:   return "Unreachable (연결 실패)";
    case GattCommunicationStatus::ProtocolError: return "ProtocolError";
    case GattCommunicationStatus::AccessDenied:  return "AccessDenied (페어링 요구)";
    default:                                     return "?";
    }
}

// 신원 서비스에서 토큰 특성을 찾아 읽는다. 성공하면 true.
static bool ReadToken(GattDeviceService const& svc) {
    static const winrt::guid tokenGuid = ToGuid(kTokenUuid);
    auto cop = svc.GetCharacteristicsAsync(BluetoothCacheMode::Uncached);
    if (cop.wait_for(std::chrono::seconds(10)) != AsyncStatus::Completed) {
        printf("      특성 탐색 시간 초과\n");
        return false;
    }
    auto cres = cop.GetResults();
    printf("      특성 탐색: %s\n", StatusText(cres.Status()));
    if (cres.Status() != GattCommunicationStatus::Success) return false;

    for (auto const& ch : cres.Characteristics()) {
        if (ch.Uuid() != tokenGuid) {
            printf("      특성 %ls\n", to_hstring(ch.Uuid()).c_str());
            continue;
        }
        auto rop = ch.ReadValueAsync(BluetoothCacheMode::Uncached);
        if (rop.wait_for(std::chrono::seconds(10)) != AsyncStatus::Completed) {
            printf("      토큰 읽기 시간 초과\n");
            return false;
        }
        auto rres = rop.GetResults();
        if (rres.Status() != GattCommunicationStatus::Success) {
            printf("      토큰 읽기: %s\n", StatusText(rres.Status()));
            return false;
        }
        auto buf = rres.Value();
        auto rd = DataReader::FromBuffer(buf);
        std::string hex;
        char b[4];
        for (uint32_t i = 0; i < buf.Length(); i++) {
            sprintf_s(b, "%02X", rd.ReadByte());
            hex += b;
        }
        printf("      >>> 토큰 %s (%u바이트)\n", hex.c_str(), (unsigned)buf.Length());
        return true;
    }
    printf("      토큰 특성이 없습니다\n");
    return false;
}

// 한 후보에 실제로 붙어서 서비스 목록을 받고, 우리 서비스가 있으면 토큰까지 읽는다.
static ProbeResult Probe(Candidate const& c) {
    static const winrt::guid identGuid = ToGuid(kIdentUuid);

    printf("\n-------------------------------------\n");
    printf("[시도] 주소 %012llX  신호 %d dBm",
        (unsigned long long)c.addr, c.rssi);
    if (c.firstBit >= 0) printf("  overflow 비트 %d(총 %d개)", c.firstBit, c.bitCount);
    if (c.plain)         printf("  [광고에 서비스 UUID 노출]");
    if (!c.name.empty()) printf("  이름 \"%ls\"", c.name.c_str());
    printf("\n");

    BluetoothLEDevice dev{ nullptr };
    try {
        auto op = BluetoothLEDevice::FromBluetoothAddressAsync(c.addr, c.type);
        if (op.wait_for(std::chrono::seconds(10)) != AsyncStatus::Completed) {
            printf("  결과: 기기 객체를 얻지 못했습니다 (10초 초과)\n");
            return PROBE_FAILED;
        }
        dev = op.GetResults();
    } catch (hresult_error const& e) {
        printf("  결과: 기기 객체 생성 오류 0x%08X\n", (unsigned)e.code());
        return PROBE_FAILED;
    }
    if (!dev) {
        printf("  결과: 기기 객체가 null 입니다 (주소가 이미 사라졌을 수 있음)\n");
        return PROBE_FAILED;
    }

    bool paired = false;
    try { paired = dev.DeviceInformation().Pairing().IsPaired(); } catch (...) {}
    printf("  페어링 상태: %s\n", paired ? "페어링됨" : "페어링 안 됨");

    // WinRT 에서 연결을 확실히 세우는 방법은 GattSession 을 잡고 MaintainConnection 을 켜는 것이다.
    // GetGattServicesAsync 만 불러도 연결이 일어나기는 하지만, 실패했을 때
    // "연결이 안 선 것"인지 "붙었는데 탐색이 막힌 것"인지 구분할 수가 없다.
    GattSession sess{ nullptr };
    try {
        auto ssop = GattSession::FromDeviceIdAsync(dev.BluetoothDeviceId());
        if (ssop.wait_for(std::chrono::seconds(10)) == AsyncStatus::Completed) {
            sess = ssop.GetResults();
            if (sess) sess.MaintainConnection(true);
        }
    } catch (hresult_error const& e) {
        printf("  GattSession 오류 0x%08X\n", (unsigned)e.code());
    } catch (...) {}

    if (sess) {
        try {
            printf("  세션: status=%s  maintain가능=%s\n",
                sess.SessionStatus() == GattSessionStatus::Active ? "Active" : "Closed",
                sess.CanMaintainConnection() ? "예" : "아니오");
        } catch (...) { printf("  세션: 속성 읽기 실패\n"); }
    } else {
        printf("  세션: 생성 실패\n");
    }
    try { printf("  기기 ID: %ls\n", dev.DeviceInformation().Id().c_str()); } catch (...) {}

    bool connected = false;
    for (int i = 0; i < 50 && !connected; i++) {
        try { connected = (dev.ConnectionStatus() == BluetoothConnectionStatus::Connected); } catch (...) {}
        if (!connected) Sleep(200);
    }
    printf("  연결 상태: %s\n", connected ? "Connected" : "Disconnected (10초 대기 후)");
    if (sess) {
        try {
            printf("  세션(대기 후): status=%s\n",
                sess.SessionStatus() == GattSessionStatus::Active ? "Active" : "Closed");
        } catch (...) {}
    }

    ProbeResult result = PROBE_FAILED;
    try {
        // Uncached 로 요청해야 실제로 연결이 일어난다 (캐시된 목록을 돌려주지 않음)
        auto sop = dev.GetGattServicesAsync(BluetoothCacheMode::Uncached);
        if (sop.wait_for(std::chrono::seconds(20)) != AsyncStatus::Completed) {
            printf("  결과: 서비스 탐색 20초 초과 - 연결되지 않았습니다\n");
            dev.Close();
            return PROBE_FAILED;
        }
        auto res = sop.GetResults();
        printf("  서비스 탐색: %s\n", StatusText(res.Status()));
        if (res.Status() == GattCommunicationStatus::Success) {
            result = PROBE_DISCOVERED;
            auto svcs = res.Services();
            printf("  서비스 %u개:\n", (unsigned)svcs.Size());
            for (auto const& s : svcs) {
                bool mine = (s.Uuid() == identGuid);
                printf("    %ls%s\n", to_hstring(s.Uuid()).c_str(),
                    mine ? "   <<< SmartScreen 신원 서비스" : "");
                if (mine && ReadToken(s)) result = PROBE_TOKEN;
            }
            // 서비스 핸들을 쥐고 있으면 Windows 가 LE 연결을 놓지 않는다.
            // 몇 대만 훑어도 연결 슬롯이 말라 이후가 전부 Unreachable 이 된다.
            for (auto const& s : svcs) { try { s.Close(); } catch (...) {} }
        }
    } catch (hresult_error const& e) {
        printf("  결과: 서비스 탐색 오류 0x%08X\n", (unsigned)e.code());
    } catch (...) {
        printf("  결과: 서비스 탐색 중 알 수 없는 오류\n");
    }

    // 연결을 붙잡고 있으면 폰이 광고를 멈출 수 있으니 반드시 놓아준다
    if (sess) { try { sess.MaintainConnection(false); sess.Close(); } catch (...) {} }
    try { dev.Close(); } catch (...) {}
    Sleep(1500);   // 해제가 끝나기 전에 다음 기기로 넘어가면 같은 증상이 난다
    return result;
}

static void WaitForKey() {
    printf("\n창을 닫으려면 아무 키나 누르세요...");
    fflush(stdout);
    HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
    FlushConsoleInputBuffer(hIn);
    INPUT_RECORD rec; DWORD n = 0;
    while (true) {
        if (WaitForSingleObject(hIn, 120000) != WAIT_OBJECT_0) break;
        if (!ReadConsoleInputW(hIn, &rec, 1, &n) || n == 0) break;
        if (rec.EventType == KEY_EVENT && rec.Event.KeyEvent.bKeyDown) break;
    }
}

int main(int argc, char** argv) {
    SetConsoleOutputCP(CP_UTF8);
    int seconds = (argc > 1) ? atoi(argv[1]) : 20;
    if (seconds < 5) seconds = 5;
    uint64_t onlyAddr = (argc > 2) ? _strtoui64(argv[2], nullptr, 16) : 0;

    printf("아이폰 신원 토큰 읽기 확인\n");
    printf("=====================================\n");
    printf("찾는 서비스: %ls\n", kIdentUuid);
    printf("읽을 특성  : %ls\n\n", kTokenUuid);
    printf("아이폰에서 SSBeacon 을 실행한 뒤 화면을 끄고 잠근 상태로 두세요.\n");
    printf("이 PC 와 아이폰이 페어링되어 있지 않아야 실제 배포 상황과 같습니다.\n\n");

    std::vector<Candidate> list;
    try {
        init_apartment();
        const winrt::guid identGuid = ToGuid(kIdentUuid);

        if (onlyAddr) {
            Candidate c; c.addr = onlyAddr; c.type = BluetoothAddressType::Random;
            list.push_back(c);
            printf("주소 %012llX 만 확인합니다.\n", (unsigned long long)onlyAddr);
        } else {
            printf("%d초 동안 후보를 찾습니다...\n", seconds);
            std::mutex mx;
            std::map<uint64_t, Candidate> found;
            BluetoothLEAdvertisementWatcher w;
            w.ScanningMode(BluetoothLEScanningMode::Active);
            w.Received([&](BluetoothLEAdvertisementWatcher const&,
                           BluetoothLEAdvertisementReceivedEventArgs const& a) {
                Candidate c;
                c.addr = a.BluetoothAddress();
                c.type = a.BluetoothAddressType();
                c.rssi = (int)a.RawSignalStrengthInDBm();
                try {
                    auto ln = a.Advertisement().LocalName();
                    if (!ln.empty()) c.name = std::wstring(ln.c_str());
                    for (auto const& u : a.Advertisement().ServiceUuids())
                        if (u == identGuid) c.plain = true;
                    auto md = a.Advertisement().ManufacturerData();
                    for (uint32_t i = 0; i < md.Size(); i++) {
                        if (md.GetAt(i).CompanyId() != kAppleCompanyId) continue;
                        int n = 0, first = -1;
                        if (OverflowBits(md.GetAt(i).Data(), n, first) && n > 0) {
                            c.bitCount = n; c.firstBit = first;
                        }
                    }
                } catch (...) {}
                // 우리 서비스를 대놓고 광고했거나(포그라운드), overflow 비트가 1~3개인
                // 기기만 후보다. 팝카운트 40 이상인 흔한 Apple 메시지는 길이에서 이미 걸러졌다.
                if (!c.plain && (c.bitCount < 1 || c.bitCount > 3)) return;
                std::lock_guard<std::mutex> lock(mx);
                auto it = found.find(c.addr);
                if (it == found.end() || c.rssi > it->second.rssi) found[c.addr] = c;
            });
            w.Start();
            Sleep(seconds * 1000);
            w.Stop();
            for (auto const& kv : found) list.push_back(kv.second);
            // 가까운 것부터 - 멀리 있는 남의 폰은 어차피 자리 판정에 쓸모가 없다
            std::sort(list.begin(), list.end(),
                [](Candidate const& a, Candidate const& b) { return a.rssi > b.rssi; });
        }

        printf("\n후보 %d대\n", (int)list.size());
        if (list.empty()) {
            printf("\n결과: 후보가 없습니다.\n");
            printf("      아이폰에서 SSBeacon 이 실제로 광고 중인지 확인하세요.\n");
            printf("      (앱을 켠 채 화면을 끄면 잠금 상태에서도 광고가 이어져야 합니다)\n");
            printf("-------------------------------------\n");
            WaitForKey();
            return 0;
        }

        int discovered = 0, tokens = 0;
        for (auto const& c : list) {
            ProbeResult r = Probe(c);
            if (r >= PROBE_DISCOVERED) discovered++;
            if (r == PROBE_TOKEN)      tokens++;
        }

        printf("\n=====================================\n");
        printf("후보 %d대 중 서비스 탐색 성공 %d대, 토큰 읽기 성공 %d대\n",
            (int)list.size(), discovered, tokens);
        if (tokens > 0) {
            printf("\n결과: 잠긴 폰에서 신원 토큰을 읽었습니다.\n");
            printf("      IRK 도 Phone Link 도 없이 폰을 특정할 수 있습니다.\n");
        } else if (discovered > 0) {
            printf("\n결과: 연결과 서비스 탐색은 되는데 신원 서비스가 안 보입니다.\n");
            printf("      아이폰 앱이 신원 서비스를 올리는 버전인지 확인하세요.\n");
            printf("      (앱을 지웠다 다시 설치한 뒤 한 번 실행해야 반영됩니다)\n");
        } else {
            printf("\n결과: 붙지 못했습니다.\n");
            printf("      AccessDenied 면 Windows 가 페어링을 요구하는 것입니다.\n");
            printf("      전부 Unreachable 이면 폰이 아니라 이 PC 의 어댑터가\n");
            printf("      직전 연결을 아직 물고 있는 경우가 많습니다. 1~2분 두었다\n");
            printf("      다시 실행해 보세요.\n");
        }
        printf("=====================================\n");
    } catch (hresult_error const& e) {
        printf("\n[실패] BLE 오류 0x%08X\n", (unsigned)e.code());
    } catch (...) {
        printf("\n[실패] 알 수 없는 오류\n");
    }

    WaitForKey();
    return 0;
}
