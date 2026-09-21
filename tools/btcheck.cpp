// btcheck.cpp - SmartScreen 블루투스 어댑터 점검 도구
// 이 PC에서 "빠른 모드"(PC가 BLE 주변장치가 되어 컴패니언 앱과 연결)를 쓸 수 있는지 확인한다.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <windows.h>
#include <cstdio>
#include <string>

using namespace winrt;
using namespace Windows::Devices::Bluetooth;

static void Out(FILE* f, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    if (f) { va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap); }
}

int main() {
    SetConsoleOutputCP(CP_UTF8);

    // 결과를 exe 옆 파일로도 남긴다 (창이 닫혀도 확인 가능)
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring dir(path);
    dir = dir.substr(0, dir.find_last_of(L"\\/") + 1);
    // ccs=UTF-8 로 열면 스트림이 wide 모드가 되어 fprintf(좁은 문자)와 섞을 수 없음.
    // 바이너리로 열고 BOM + UTF-8 바이트를 직접 쓴다.
    FILE* f = nullptr;
    _wfopen_s(&f, (dir + L"BtCheck_result.txt").c_str(), L"wb");
    if (f) fwrite("\xEF\xBB\xBF", 1, 3, f);

    Out(f, "SmartScreen 블루투스 어댑터 점검\n");
    Out(f, "=====================================\n\n");

    bool peripheral = false, le = false, found = false;
    try {
        init_apartment();
        auto a = BluetoothAdapter::GetDefaultAsync().get();
        if (!a) {
            Out(f, "[실패] 블루투스 어댑터를 찾을 수 없습니다.\n");
            Out(f, "       블루투스가 꺼져 있거나 어댑터가 없는 PC입니다.\n");
        } else {
            found = true;
            le = a.IsLowEnergySupported();
            peripheral = a.IsPeripheralRoleSupported();
            Out(f, "  저전력 블루투스(BLE) 지원 : %s\n", le ? "예" : "아니오");
            Out(f, "  주변장치 역할 지원        : %s\n", peripheral ? "예" : "아니오");
            Out(f, "  중앙장치 역할 지원        : %s\n", a.IsCentralRoleSupported() ? "예" : "아니오");
            Out(f, "  클래식 블루투스 지원      : %s\n", a.IsClassicSupported() ? "예" : "아니오");
        }
    } catch (hresult_error const& e) {
        Out(f, "[실패] 블루투스 확인 중 오류 (0x%08X)\n", (unsigned)e.code());
    } catch (...) {
        Out(f, "[실패] 블루투스 확인 중 알 수 없는 오류\n");
    }

    Out(f, "\n-------------------------------------\n");
    if (found && le && peripheral) {
        Out(f, "결과: 빠른 모드를 쓸 수 있습니다.\n\n");
        Out(f, "아이폰에 컴패니언 앱(SSBeacon)을 설치하면\n");
        Out(f, "자리를 뜬 뒤 10~15초 안에 화면이 잠깁니다.\n\n");
        Out(f, "[주의] 이 값은 드라이버가 보고하는 것이라 실제와 다를 수 있습니다.\n");
        Out(f, "       일부 USB 동글은 \"예\" 라고 답하면서도 전파를 못 내보냅니다.\n");
        Out(f, "       SmartScreen 을 실행해 폰 앱이 연결되는지로 확인하세요.\n");
        Out(f, "       또는 다른 PC 에서 AdvScan.exe 를 돌려 송출을 확인하세요.\n");
    } else if (found && le) {
        Out(f, "결과: 빠른 모드를 쓸 수 없습니다. (주변장치 역할 미지원)\n\n");
        Out(f, "느린 모드로는 동작합니다. 다만 아이폰은 잠금 상태에서\n");
        Out(f, "신호를 거의 안 보내므로 감지가 느리거나 끊깁니다.\n");
        Out(f, "블루투스 5.0 이상 USB 동글을 쓰면 빠른 모드가 될 수 있습니다.\n");
    } else if (found) {
        Out(f, "결과: 이 어댑터로는 SmartScreen을 쓸 수 없습니다. (BLE 미지원)\n");
    } else {
        Out(f, "결과: 블루투스를 켠 뒤 다시 실행해 주세요.\n");
    }
    Out(f, "-------------------------------------\n");
    Out(f, "\n이 내용은 BtCheck_result.txt 파일로도 저장했습니다.\n");

    if (f) fclose(f);

    printf("\n창을 닫으려면 아무 키나 누르세요...");
    fflush(stdout);
    // 더블클릭 실행 시 창이 바로 닫히지 않도록 대기
    HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
    FlushConsoleInputBuffer(hIn);
    INPUT_RECORD rec; DWORD n = 0;
    while (true) {
        if (WaitForSingleObject(hIn, 120000) != WAIT_OBJECT_0) break;  // 2분 뒤 자동 종료
        if (!ReadConsoleInputW(hIn, &rec, 1, &n) || n == 0) break;
        if (rec.EventType == KEY_EVENT && rec.Event.KeyEvent.bKeyDown) break;
    }
    return 0;
}
