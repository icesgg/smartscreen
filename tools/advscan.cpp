// advscan.cpp - SmartScreen 광고 수신 확인 도구
// 다른 PC에서 실행해서, SmartScreen 이 돌고 있는 PC의 BLE 광고가 실제로 잡히는지 본다.
// "PC 는 광고 중이라는데 폰이 못 찾는다" 상황에서 PC 쪽 문제인지 폰 쪽 문제인지 가른다.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <atomic>
#include <mutex>
#include <set>

using namespace winrt;
using namespace Windows::Devices::Bluetooth::Advertisement;

// client/ble_gatt.h 의 SS_GATT_SERVICE_UUID 와 동일해야 함
static const wchar_t* kServiceUuid = L"{7A1C0010-5353-4243-8E2B-9F3D5A6C7E10}";

int main(int argc, char** argv) {
    SetConsoleOutputCP(CP_UTF8);
    int seconds = (argc > 1) ? atoi(argv[1]) : 30;

    GUID g{}; CLSIDFromString(kServiceUuid, &g);
    winrt::guid target(g);

    printf("SmartScreen 광고 수신 확인\n");
    printf("=====================================\n");
    printf("찾는 서비스: %ls\n", kServiceUuid);
    printf("%d초 동안 주변 BLE 광고를 듣습니다...\n\n", seconds);
    printf("다른 PC에서 SmartScreen 을 실행하고 \"시작\" 을 누른 상태여야 합니다.\n\n");

    std::atomic<int> total{ 0 }, hits{ 0 };
    std::mutex mx;
    std::set<uint64_t> seen;

    try {
        init_apartment();
        BluetoothLEAdvertisementWatcher w;
        w.ScanningMode(BluetoothLEScanningMode::Active);
        w.Received([&](BluetoothLEAdvertisementWatcher const&,
                       BluetoothLEAdvertisementReceivedEventArgs const& a) {
            total++;
            bool match = false;
            try {
                for (auto const& u : a.Advertisement().ServiceUuids()) {
                    if (u == target) { match = true; break; }
                }
            } catch (...) {}
            if (!match) return;
            uint64_t addr = a.BluetoothAddress();
            {
                std::lock_guard<std::mutex> lock(mx);
                if (!seen.insert(addr).second) return;   // 주소별 1회만 출력
            }
            hits++;
            SYSTEMTIME st; GetLocalTime(&st);
            printf("[발견] %02d:%02d:%02d  주소 %012llX  신호 %d dBm\n",
                st.wHour, st.wMinute, st.wSecond,
                (unsigned long long)addr, (int)a.RawSignalStrengthInDBm());
        });
        w.Start();
        Sleep(seconds * 1000);
        w.Stop();
    } catch (hresult_error const& e) {
        printf("[실패] BLE 스캔 오류 0x%08X\n", (unsigned)e.code());
    } catch (...) {
        printf("[실패] BLE 스캔 중 알 수 없는 오류\n");
    }

    printf("\n-------------------------------------\n");
    printf("주변 광고 %d건 수신, 그중 SmartScreen %d대 발견\n", total.load(), hits.load());
    if (hits > 0) {
        printf("\n결과: PC 광고는 정상입니다.\n");
        printf("      폰이 못 찾는다면 아이폰 쪽 문제입니다.\n");
    } else if (total > 0) {
        printf("\n결과: 주변 BLE 는 잘 들리는데 SmartScreen 광고만 안 보입니다.\n");
        printf("      그 PC 가 실제로는 광고를 못 내보내고 있습니다.\n");
    } else {
        printf("\n결과: 주변 BLE 광고가 하나도 안 잡힙니다.\n");
        printf("      이 PC 의 블루투스를 확인하세요.\n");
    }
    printf("-------------------------------------\n");

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
    return 0;
}
