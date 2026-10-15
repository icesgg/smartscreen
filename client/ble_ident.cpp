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
#include <werapi.h>     // WerSetFlags - 도우미가 죽어도 창을 띄우지 않게
#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

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

// ---------------------------------------------------------------------------
// 도우미 프로세스로 탐색하기 (왜 그러는지는 ble_ident.h ReadPhoneTokenIsolated)
// ---------------------------------------------------------------------------

// 도우미의 종료 코드. 줄과 같은 것을 말한다 - 줄을 못 읽었을 때 로그에 남기는 것은 이쪽이다.
static const int kHelperExitToken       = 0;
static const int kHelperExitNotOurs     = 2;
static const int kHelperExitUnreachable = 3;
static const int kHelperExitBadArgs     = 64;

// 도우미 안의 시간 제한을 모두 쓰면 25초다 (5+10+5+5). 조금 더 기다린다 - 이것을 넘기면
// 도우미 안에서도 무언가 멎은 것이다.
static const DWORD kHelperDeadlineMs = 30000;
// 답 줄을 받은 뒤 도우미가 끝나기를 기다리는 시간. 끝나는 데서 멎어도 받은 답은 쓴다 -
// 그러지 않으면 멎을 때마다 탐색 하나가 30초가 된다.
static const DWORD kHelperExitGraceMs = 2000;
// 토큰 특성값은 최대 512바이트 = 1024자다. 줄이 이보다 훨씬 길면 망가진 것이다.
static const size_t kHelperMaxOut = 4096;
// 도우미 자체가 답하지 못한 것("helper output" / "helper timeout")이 연달아 이만큼이면 한동안
// 이 프로세스 안에서 탐색한다. 도우미가 뜨기는 하는데 매번 죽는 PC (뜬 자식을 죽이는 보안
// 프로그램, 새 프로세스마다 0xC0000142 로 죽는 데스크톱 힙 고갈) 에서는 그러지 않으면 모든
// 탐색이 Unreachable 이고 자기 폰도 영영 묶이지 않는다 - 앱을 다시 켜도 새 프로세스가 같은
// 도우미를 쓰니 낫지 않는다. 도우미가 직접 말한 UNREACHABLE 은 세지 않는다 (폰이 안 닿은 것이다).
static const int kHelperFailLimit = 3;
// 이 프로세스 안에서 탐색하는 기간. 끝나면 도우미를 다시 해 본다 - 도우미를 쓰는 까닭(오래 돈
// 프로세스가 LE 연결을 막는 것)이 있으니 영영 버리지는 않는다. 다시 해 본 첫 번에 또 실패하면
// 바로 돌아오고 기간을 두 배로 늘린다 (최대 2시간) - 늘 망가진 PC 에서 시험과 로그 줄을 줄인다.
static const ULONGLONG kHelperInProcMs    = 15ULL * 60 * 1000;
static const ULONGLONG kHelperInProcMaxMs = 120ULL * 60 * 1000;

static int HexDigit(wchar_t c) {
    if (c >= L'0' && c <= L'9') return c - L'0';
    if (c >= L'A' && c <= L'F') return c - L'A' + 10;
    if (c >= L'a' && c <= L'f') return c - L'a' + 10;
    return -1;
}

// why 는 한 줄 안에 있어야 한다. 지금의 글자들은 모두 한 줄이지만, 줄바꿈이 섞여 들면
// 부모가 줄을 잘못 자르고 탐색 하나를 "helper output" 으로 버린다.
static std::wstring OneLine(std::wstring s) {
    for (auto& c : s) if (c < 0x20 || c == 0x7F) c = L' ';
    return s;
}

// GUI 서브시스템이라 stdout 은 부모가 넘긴 파이프뿐이다. 손으로 띄웠으면 없다 - 그러면
// 조용히 넘어간다 (종료 코드는 그대로 결과를 말한다).
static void HelperWriteLine(const std::wstring& line) {
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (out == nullptr || out == INVALID_HANDLE_VALUE) return;
    int n = WideCharToMultiByte(CP_UTF8, 0, line.c_str(), (int)line.size(),
                                nullptr, 0, nullptr, nullptr);
    if (n <= 0) return;
    std::string s((size_t)n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, line.c_str(), (int)line.size(), s.data(), n, nullptr, nullptr);
    const char* p = s.data();
    DWORD left = (DWORD)s.size();
    while (left) {
        DWORD wrote = 0;
        if (!WriteFile(out, p, left, &wrote, nullptr) || wrote == 0) return;
        p += wrote;
        left -= wrote;
    }
}

int ReadTokenHelperMain(int argc, wchar_t** argv) {
    // 엄격하게 본다. 이 길은 블루투스 연결을 연다 - 모양이 다르면 아무것도 하지 않는다.
    if (!argv || argc != 4 || wcscmp(argv[1], L"--read-token") != 0) return kHelperExitBadArgs;
    if (wcslen(argv[2]) != 12) return kHelperExitBadArgs;
    uint64_t addr = 0;
    for (int i = 0; i < 12; i++) {
        int v = HexDigit(argv[2][i]);
        if (v < 0) return kHelperExitBadArgs;
        addr = (addr << 4) | (uint64_t)v;
    }
    bool randomAddr;
    if (wcscmp(argv[3], L"r") == 0)      randomAddr = true;
    else if (wcscmp(argv[3], L"p") == 0) randomAddr = false;
    else return kHelperExitBadArgs;

    // 로그는 부모가 쓴다. 도우미가 쓰면 (늦게 닫은 결과의 NoteLateClose 등) 2초마다 뜨는
    // 프로세스들이 events.log 한 파일에 섞여 들어가고, 같은 일이 두 번 적힌다.
    g_debugEvents = false;
    // 도우미가 죽어도 오류 창을 띄우지 않는다. 2초마다 뜨는 프로세스라 창이 책상 위에 쌓인다.
    // 죽은 것은 부모가 "helper output" 과 종료 코드로 남긴다.
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    WerSetFlags(WER_FAULT_REPORTING_NO_UI);

    std::wstring tok, why;
    DWORD took = 0;
    ProbeOutcome r = ReadPhoneToken(addr, randomAddr, tok, why, &took);
    wchar_t ms[16];
    swprintf_s(ms, L"%lu", took);
    std::wstring line;
    int rc;
    switch (r) {
    case ProbeOutcome::Token:
        line = L"TOKEN " + tok + L" " + ms;
        rc = kHelperExitToken;
        break;
    case ProbeOutcome::NotOurs:
        line = L"NOTOURS " + OneLine(why) + L" " + ms;
        rc = kHelperExitNotOurs;
        break;
    default:
        // why 가 빈 채로 오는 길이 있다 (서비스는 있는데 토큰 특성이 없다). 그러면 칸이 둘
        // 붙는다 - 부모는 첫 칸과 마지막 칸 사이를 why 로 읽으므로 빈 why 가 그대로 간다.
        line = L"UNREACHABLE " + OneLine(why) + L" " + ms;
        rc = kHelperExitUnreachable;
        break;
    }
    HelperWriteLine(line + L"\n");
    return rc;
}

// 어느 길로 나가든 닫는다
struct OwnedHandle {
    HANDLE h = nullptr;
    OwnedHandle() = default;
    explicit OwnedHandle(HANDLE x) : h(x) {}
    ~OwnedHandle() { reset(); }
    OwnedHandle(const OwnedHandle&) = delete;
    OwnedHandle& operator=(const OwnedHandle&) = delete;
    void reset(HANDLE x = nullptr) {
        if (h && h != INVALID_HANDLE_VALUE) CloseHandle(h);
        h = x;
    }
    HANDLE release() { HANDLE x = h; h = nullptr; return x; }
};

// 0 은 "성공" 으로 쓰므로 오류 번호가 비어 있으면 대신 하나를 준다
static DWORD LastErrorOr(DWORD fallback = ERROR_GEN_FAILURE) {
    DWORD e = GetLastError();
    return e ? e : fallback;
}

// 도우미를 모두 담는 작업(job). 한 번 만들고 닫지 않는다 - 앱이 어떻게 끝나든 (정상 종료,
// 업데이트가 끝내는 것, 작업 관리자) OS 가 이 핸들을 닫고, 그때 남은 도우미가 모두 죽는다.
// 도우미는 만들어질 때부터 이 작업 안에 있다 (StartHelper 의 작업 목록) - 작업 밖에 있는 순간이 없다.
// 살아남은 도우미는 SmartScreen.exe 파일을 잡고 있다 - 업데이트(update.cpp)와 release.bat 은
// 앱이 끝난 뒤에 그 파일을 바꾼다.
// DIE_ON_UNHANDLED_EXCEPTION: 도우미가 죽을 때 오류 보고 창을 띄우지 않는다 (위 SetErrorMode 와 같은 이유).
static HANDLE HelperJob(DWORD& err) {
    static DWORD s_err = 0;
    static HANDLE s_job = []() -> HANDLE {
        HANDLE j = CreateJobObjectW(nullptr, nullptr);
        if (!j) { s_err = LastErrorOr(); return nullptr; }
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION li{};
        li.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        if (!SetInformationJobObject(j, JobObjectExtendedLimitInformation, &li, sizeof(li))) {
            s_err = LastErrorOr();
            CloseHandle(j);
            return nullptr;
        }
        return j;
    }();
    err = s_err;
    return s_job;
}

static std::wstring OwnExePath() {
    std::wstring p(MAX_PATH, L'\0');
    for (;;) {
        DWORD n = GetModuleFileNameW(nullptr, p.data(), (DWORD)p.size());
        if (n == 0) return std::wstring();
        if (n < p.size()) { p.resize(n); return p; }
        if (p.size() >= 32768) return std::wstring();
        p.resize(p.size() * 2);
    }
}

// 도우미를 띄운다. 0 이면 proc 과 readEnd 가 찬다. 아니면 오류 번호이고 아무것도 남기지 않는다.
static DWORD StartHelper(uint64_t addr, bool randomAddr, OwnedHandle& proc, OwnedHandle& readEnd) {
    DWORD err = 0;
    HANDLE job = HelperJob(err);
    if (!job) return err ? err : ERROR_GEN_FAILURE;

    std::wstring exe = OwnExePath();
    if (exe.empty()) return LastErrorOr();

    // 파이프는 둘 다 상속되지 않게 만들고, 쓰는 쪽만 CreateProcess 바로 앞에서 상속되게
    // 바꿨다가 바로 뒤에 닫는다. 이 프로세스의 다른 CreateProcess 는 모두 상속을 끄지만
    // (update.cpp, irk.cpp), 쓰는 쪽이 다른 자식에게 새면 그 자식이 끝날 때까지 EOF 가 오지 않는다.
    HANDLE rd = nullptr, wr = nullptr;
    if (!CreatePipe(&rd, &wr, nullptr, 64 * 1024)) return LastErrorOr();
    OwnedHandle r(rd), w(wr);

    // 속성 둘: 상속할 핸들 목록과 넣을 작업 목록.
    // 상속 목록에는 쓰는 쪽 하나만. 목록이 없으면 bInheritHandles=TRUE 가 이 프로세스의
    // 상속 가능한 핸들을 모두 넘긴다 (작업 핸들이 넘어가면 앱이 끝나도 작업이 닫히지 않는다).
    // 작업 목록: 도우미를 처음부터 작업 안에서 만든다 (커널이 프로세스를 만들 때 넣는다).
    // 예전에는 멈춘 채로 띄운 뒤 AssignProcessToJobObject 로 넣고 재개했다. 그 사이에 앱이
    // 끝나면 (업데이트의 TerminateProcess, 작업 관리자, 크래시) 아직 한 줄도 돌지 않은 도우미가
    // 작업 밖에 멈춘 채 남았다 - 아무도 재개하지도 죽이지도 않고, SmartScreen.exe 를 잡고 있어
    // 업데이트의 .bak 삭제와 release.ps1 이 막힌다. 틈은 생각보다 넓다 - 커널이 프로세스를 만든
    // 뒤에도 CreateProcess 안에서 할 일이 남아 있어, 노트북에서 재 보니 몇 ms 였다 (부모를 그
    // 사이에 죽이면 대부분 남았다). 만들 때 넣으면 그 틈이 없다. 멈춘 채로
    // 띄웠다가 재개하는 모양(보안 프로그램이 프로세스 할로잉으로 볼 수 있는 모양)도 없어진다.
    // 이 속성은 Win10 1607 부터다. 그 전 Windows 에는 탐색에 쓰는 BLE API(1703)도 없다 -
    // 실패하면 띄우지 못한 것으로 친다 (부르는 쪽이 이 프로세스 안에서 탐색한다).
    SIZE_T attrSize = 0;
    InitializeProcThreadAttributeList(nullptr, 2, 0, &attrSize);
    if (attrSize == 0) return LastErrorOr();
    std::vector<BYTE> attrBuf(attrSize);
    auto attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attrBuf.data());
    if (!InitializeProcThreadAttributeList(attrs, 2, 0, &attrSize)) return LastErrorOr();
    struct AttrList {
        LPPROC_THREAD_ATTRIBUTE_LIST a;
        ~AttrList() { DeleteProcThreadAttributeList(a); }
    } attrGuard{ attrs };
    // 두 배열은 CreateProcess 가 끝날 때까지 살아 있어야 한다 (속성 목록은 가리키기만 한다)
    HANDLE inherit[1] = { w.h };
    HANDLE jobs[1] = { job };
    if (!UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inherit, sizeof(inherit), nullptr, nullptr))
        return LastErrorOr();
    if (!UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                   jobs, sizeof(jobs), nullptr, nullptr))
        return LastErrorOr();
    if (!SetHandleInformation(w.h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)) return LastErrorOr();

    STARTUPINFOEXW si{};
    si.StartupInfo.cb = sizeof(si);
    // FORCEOFFFEEDBACK: GUI 프로그램을 띄우면 마우스 커서가 몇 초 "작업 중" 으로 바뀐다.
    // 2초마다 띄우므로 이것이 없으면 커서가 내내 돈다.
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_FORCEOFFFEEDBACK;
    si.StartupInfo.hStdOutput = w.h;   // stdin, stderr 는 없다
    si.lpAttributeList = attrs;

    wchar_t args[64];
    swprintf_s(args, L" --read-token %012llX %c",
               (unsigned long long)addr, randomAddr ? L'r' : L'p');
    std::wstring cmd = L"\"" + exe + L"\"" + args;   // CreateProcessW 는 쓰기 가능한 버퍼를 요구한다

    // 작업 목록(위) 덕분에 CreateProcess 가 돌아올 때 도우미는 이미 작업 안에 있다 -
    // 멈춘 채로 띄울 까닭이 없다. 작업에 넣지 못하면 CreateProcess 자체가 실패한다.
    PROCESS_INFORMATION pi{};
    BOOL ok = CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, TRUE,
                             EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW,
                             nullptr, nullptr, &si.StartupInfo, &pi);
    if (!ok) err = LastErrorOr();
    // 내 사본은 바로 닫는다 - 그래야 도우미가 끝날 때 읽는 쪽에 EOF 가 온다
    w.reset();
    if (!ok) return err;
    CloseHandle(pi.hThread);
    proc.reset(pi.hProcess);
    readEnd.reset(r.release());
    return 0;
}

// 파이프에 지금 있는 것을 모두 읽는다. 막혀 기다리지 않는다 (PeekNamedPipe) - 쓰는 쪽을
// 누가 쥐고 있든 마감은 지킨다. false = EOF (쓰는 쪽이 모두 닫혔다).
static bool DrainPipe(HANDLE rd, std::string& out, bool& tooLong) {
    for (;;) {
        DWORD avail = 0;
        if (!PeekNamedPipe(rd, nullptr, 0, nullptr, &avail, nullptr)) return false;
        if (avail == 0) return true;
        char buf[512];
        DWORD got = 0;
        if (!ReadFile(rd, buf, (std::min)(avail, (DWORD)sizeof(buf)), &got, nullptr)) return false;
        size_t room = out.size() < kHelperMaxOut ? kHelperMaxOut - out.size() : 0;
        if (got > room) tooLong = true;
        out.append(buf, (std::min)((size_t)got, room));
    }
}

enum class HelperEnd { Exited, TimedOut, Aborted };

// 도우미가 끝날 때까지 (EOF 또는 프로세스 끝), 답 줄을 받고 잠깐 더, 또는 마감까지 모은다.
static HelperEnd CollectHelper(HANDLE proc, HANDLE rd, HANDLE abortEvent, ULONGLONG deadline,
                               std::string& out, bool& tooLong) {
    HANDLE waits[2] = { proc, abortEvent };
    DWORD nWaits = abortEvent ? 2 : 1;
    bool haveLine = false;
    for (;;) {
        if (!DrainPipe(rd, out, tooLong)) return HelperEnd::Exited;
        if (!haveLine && out.find('\n') != std::string::npos) {
            haveLine = true;
            deadline = (std::min)(deadline, GetTickCount64() + kHelperExitGraceMs);
        }
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) return HelperEnd::TimedOut;
        DWORD slice = (DWORD)(std::min)(deadline - now, (ULONGLONG)100);
        DWORD w = WaitForMultipleObjects(nWaits, waits, FALSE, slice);
        if (w == WAIT_OBJECT_0) {
            // 끝났다. 쓴 것은 이미 파이프에 있으니 남은 것만 읽는다. EOF 는 기다리지 않는다 -
            // 쓰는 쪽이 어딘가에 새어 있으면 오지 않는다.
            DrainPipe(rd, out, tooLong);
            return HelperEnd::Exited;
        }
        if (w == WAIT_OBJECT_0 + 1) return HelperEnd::Aborted;
        if (w == WAIT_FAILED) Sleep(slice);   // 기다릴 수 없으면 쉬어 가며 돈다 - 마감은 그대로
    }
}

// 도우미의 줄을 읽는다. 모양이 조금이라도 다르면 false 이고 아무것도 바꾸지 않는다.
// "<종류> <가운데> <ms>\n" - 가운데는 첫 칸과 마지막 칸 사이 (why 에는 칸이 있다, 비어 있을 수 있다).
static bool ParseHelperLine(const std::string& out, ProbeOutcome& outcome,
                            std::wstring& tokenHex, std::wstring& why, DWORD& ms) {
    size_t nl = out.find('\n');
    if (nl == std::string::npos || nl + 1 != out.size()) return false;   // 정확히 한 줄
    std::string line = out.substr(0, nl);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    for (unsigned char c : line) if (c < 0x20 || c == 0x7F) return false;
    size_t sp1 = line.find(' ');
    size_t sp2 = line.rfind(' ');
    if (sp1 == std::string::npos || sp2 == sp1) return false;
    std::string kind = line.substr(0, sp1);
    std::string mid = line.substr(sp1 + 1, sp2 - sp1 - 1);
    std::string num = line.substr(sp2 + 1);

    if (num.empty() || num.size() > 10) return false;
    unsigned long long v = 0;
    for (char c : num) {
        if (c < '0' || c > '9') return false;
        v = v * 10 + (unsigned)(c - '0');
    }
    if (v > 0xFFFFFFFFull) return false;

    ProbeOutcome r;
    if (kind == "TOKEN") {
        if (mid.empty()) return false;
        for (char c : mid) if (HexDigit((wchar_t)(unsigned char)c) < 0) return false;
        r = ProbeOutcome::Token;
    } else if (kind == "NOTOURS") {
        r = ProbeOutcome::NotOurs;
    } else if (kind == "UNREACHABLE") {
        r = ProbeOutcome::Unreachable;
    } else {
        return false;
    }
    std::wstring wmid;
    if (!mid.empty()) {
        int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, mid.data(), (int)mid.size(),
                                    nullptr, 0);
        if (n <= 0) return false;
        wmid.resize((size_t)n);
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, mid.data(), (int)mid.size(),
                            wmid.data(), n);
    }
    outcome = r;
    if (r == ProbeOutcome::Token) { tokenHex = wmid; why.clear(); }
    else                          { tokenHex.clear(); why = wmid; }
    ms = (DWORD)v;
    return true;
}

// 도우미 자체 실패를 세고, 이 프로세스 안에서 탐색할 기간을 정한다 (kHelperFailLimit 주석).
// 탐색은 프로버 스레드 하나에서만 돌지만 값 몇 개라 atomic 으로 둔다.
static std::atomic<int>       s_helperFails{ 0 };              // 연달아 실패한 수
static std::atomic<ULONGLONG> s_inProcUntil{ 0 };              // 0 이 아니면 이때까지 이 프로세스 안에서
static std::atomic<ULONGLONG> s_inProcMs{ kHelperInProcMs };   // 지난 기간의 길이 (다시 실패하면 두 배)
static std::atomic<bool>      s_helperRetry{ false };          // 기간이 끝나고 도우미를 다시 해 보는 중

// 도우미가 줄로 답했다 (TOKEN / NOTOURS / UNREACHABLE 무엇이든 - 도우미는 제 일을 했다)
static void NoteHelperAnswered() {
    s_helperFails = 0;
    if (s_helperRetry.exchange(false)) DbgEvent(L"ident: probe helper works again");
}

// 도우미 자체가 답하지 못했다. why 는 그 사유 (종료 코드가 들어 있다).
// 이번 탐색은 그대로 Unreachable 로 돌려준다 - 바로 이 프로세스 안에서 다시 하면 탐색 하나가
// 30초를 넘겨 앱이 끝날 때 프로버 스레드를 기다리는 시간(30초)을 넘길 수 있다. 다음 탐색부터 바꾼다.
static void NoteHelperFailed(const std::wstring& why) {
    int n = ++s_helperFails;
    bool retry = s_helperRetry.exchange(false);
    if (!retry && n < kHelperFailLimit) return;
    ULONGLONG len = retry ? (std::min)(s_inProcMs.load() * 2, kHelperInProcMaxMs) : kHelperInProcMs;
    s_inProcMs = len;
    s_helperFails = 0;
    s_inProcUntil = GetTickCount64() + len;
    if (retry)
        DbgEvent(L"ident: probe helper failed again (%s) - probing in-process for %llu min",
                 why.c_str(), len / 60000);
    else
        DbgEvent(L"ident: probe helper failed %d times in a row (last: %s) - probing in-process for %llu min",
                 n, why.c_str(), len / 60000);
}

ProbeOutcome ReadPhoneTokenIsolated(uint64_t addr, bool randomAddr,
                                    std::wstring& tokenHex, std::wstring& why,
                                    DWORD* elapsedMs, HANDLE abortEvent) {
    tokenHex.clear();
    why.clear();
    ULONGLONG t0 = GetTickCount64();
    auto wallMs = [t0]() { return (DWORD)(GetTickCount64() - t0); };

    if (abortEvent && WaitForSingleObject(abortEvent, 0) == WAIT_OBJECT_0) {
        why = L"helper stopped";
        if (elapsedMs) *elapsedMs = 0;
        return ProbeOutcome::Unreachable;
    }

    // 도우미가 연달아 실패해서 한동안 이 프로세스 안에서 탐색하는 중이다 (kHelperFailLimit 주석)
    ULONGLONG until = s_inProcUntil.load();
    if (until != 0) {
        if (t0 < until) return ReadPhoneToken(addr, randomAddr, tokenHex, why, elapsedMs);
        // 기간이 끝났다 - 도우미를 다시 해 본다. 어떻게 됐는지는 NoteHelperAnswered /
        // NoteHelperFailed 가 한 줄로 적는다.
        s_inProcUntil = 0;
        s_helperRetry = true;
    }

    OwnedHandle proc, rd;
    DWORD err = StartHelper(addr, randomAddr, proc, rd);
    if (err != 0) {
        // 탐색을 안 하는 것보다는 예전처럼 이 프로세스 안에서 하는 것이 낫다
        static std::atomic<bool> s_saidFallback{ false };
        if (!s_saidFallback.exchange(true))
            DbgEvent(L"ident: probe helper could not start (err=%lu) - probing in-process", err);
        return ReadPhoneToken(addr, randomAddr, tokenHex, why, elapsedMs);
    }
    static std::atomic<bool> s_saidHelper{ false };
    if (!s_saidHelper.exchange(true))
        DbgEvent(L"ident: probes run in a helper process");

    std::string out;
    bool tooLong = false;
    HelperEnd end = CollectHelper(proc.h, rd.h, abortEvent, t0 + kHelperDeadlineMs, out, tooLong);

    // 아직 살아 있으면 끝낸다. EOF 로 나왔으면 조금 기다린다 - 핸들이 닫히는 것(EOF)이
    // 프로세스가 끝났다고 표시되는 것보다 조금 앞선다.
    // reaped: 죽였는데도 5초 안에 끝나지 않으면 false - 커널 안(블루투스 드라이버 같은 곳)에서
    // 멎은 것이다. 이 변경이 의심하는 스택 정체와 이어질 수 있어 사유에 따로 적는다.
    DWORD waitMs = (end == HelperEnd::Exited) ? kHelperExitGraceMs : 0;
    bool reaped = true;
    if (WaitForSingleObject(proc.h, waitMs) != WAIT_OBJECT_0) {
        TerminateProcess(proc.h, ERROR_TIMEOUT);
        reaped = (WaitForSingleObject(proc.h, 5000) == WAIT_OBJECT_0);
    }
    DWORD exitCode = 0;
    if (!GetExitCodeProcess(proc.h, &exitCode)) exitCode = 0xFFFFFFFF;

    if (end == HelperEnd::Aborted) {
        // 앱이 끝나는 중이다 - 도우미의 잘잘못이 아니니 세지 않는다
        why = L"helper stopped";
        if (elapsedMs) *elapsedMs = wallMs();
        return ProbeOutcome::Unreachable;
    }
    DrainPipe(rd.h, out, tooLong);   // 끊기 바로 앞에 쓴 것

    ProbeOutcome r = ProbeOutcome::Unreachable;
    DWORD helperMs = 0;
    if (!tooLong && ParseHelperLine(out, r, tokenHex, why, helperMs)) {
        NoteHelperAnswered();
        if (elapsedMs) *elapsedMs = helperMs;
        return r;
    }
    if (end == HelperEnd::TimedOut) {
        why = reaped ? L"helper timeout" : L"helper timeout, not reaped";
    } else {
        // 줄 없이 끝난 것은 거의 도우미가 죽은 것이다. 무엇으로 죽었는지는 종료 코드에만 있다
        // (도우미는 오류 창도 stderr 도 없다). 그래서 사유에 넣는다 - 그러면 첫 실패 줄과 묶음 줄
        // ("x<N> since ... (last: ...)") 에 매번 실린다. 한 번만 적으면 첫 실패가 일시적인 것
        // (로그온 직후 백신 검사 등) 일 때 몇 시간 뒤 다른 까닭으로 계속 죽어도 그 까닭이 어디에도 없다.
        // 0x000005B4 (ERROR_TIMEOUT) 는 줄 없이 EOF 를 낸 뒤 끝나지 않아 이쪽이 죽인 것이다.
        wchar_t b[64];
        swprintf_s(b, L"helper output 0x%08lX%s", exitCode, reaped ? L"" : L", not reaped");
        why = b;
        // 몇 바이트가 왔는지는 처음 한 번만 (빈 것인지 망가진 줄인지 가르는 데는 그것이면 된다)
        static std::atomic<bool> s_saidOutput{ false };
        if (!s_saidOutput.exchange(true))
            DbgEvent(L"ident: probe helper gave no usable line (exit=0x%08lX, %u bytes)",
                     exitCode, (unsigned)out.size());
    }
    NoteHelperFailed(why);
    if (elapsedMs) *elapsedMs = wallMs();
    return ProbeOutcome::Unreachable;
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

    // 등록은 사람이 버튼을 눌러 한 번 하는 일이라 예전대로 이 프로세스 안에서 읽는다.
    // 도우미(ReadPhoneTokenIsolated)는 프로버가 몇 시간씩 되풀이하는 탐색을 위한 것이다.
    std::wstring reason;
    if (ReadPhoneToken(best, bestRandom, tokenHex, reason) != ProbeOutcome::Token) {
        why = L"연결은 했지만 토큰을 읽지 못했습니다 (" + reason + L")";
        return false;
    }
    return true;
}
