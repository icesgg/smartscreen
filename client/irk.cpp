// irk.cpp - IRK 가져오기 구현

// config.h -> common.h가 winsock2.h를 포함하므로 WinRT(windows.h)보다 먼저 와야 한다
#include "config.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.Bluetooth.h>

#include "irk.h"
#include <shellapi.h>
#include <map>
#include <vector>
#include <algorithm>

using namespace winrt;
using namespace Windows::Devices::Enumeration;
using namespace Windows::Devices::Bluetooth;

static constexpr const wchar_t* kTaskName = L"SmartScreenIrkExport";
static constexpr const wchar_t* kKeysPath =
    L"SYSTEM\\CurrentControlSet\\Services\\BTHPORT\\Parameters\\Keys";

// ---------------------------------------------------------------------------
bool IsElevated() {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
    TOKEN_ELEVATION el{};
    DWORD cb = 0;
    bool ok = GetTokenInformation(token, TokenElevation, &el, sizeof(el), &cb) && el.TokenIsElevated;
    CloseHandle(token);
    return ok;
}

static std::wstring ExePath() {
    wchar_t p[MAX_PATH];
    GetModuleFileNameW(nullptr, p, MAX_PATH);
    return p;
}

// 창 없이 실행하고 끝날 때까지 기다린다
static bool RunHidden(const std::wstring& cmdLine, DWORD timeoutMs, DWORD* exitCode = nullptr) {
    std::wstring cmd = cmdLine;   // CreateProcessW는 쓰기 가능한 버퍼를 요구한다
    STARTUPINFOW si{ sizeof(si) };
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) return false;
    DWORD w = WaitForSingleObject(pi.hProcess, timeoutMs);
    if (exitCode && w == WAIT_OBJECT_0) GetExitCodeProcess(pi.hProcess, exitCode);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return w == WAIT_OBJECT_0;
}

// ---------------------------------------------------------------------------
// [3단계] SYSTEM 측: 레지스트리 덤프
// ---------------------------------------------------------------------------
static bool ReadIrkValue(HKEY hDev, std::wstring& outHex) {
    BYTE buf[64]{};
    DWORD cb = sizeof(buf), type = 0;
    if (RegQueryValueExW(hDev, L"IRK", nullptr, &type, buf, &cb) != ERROR_SUCCESS) return false;
    if (type != REG_BINARY || cb != 16) return false;
    wchar_t hex[33];
    for (int i = 0; i < 16; i++) swprintf_s(hex + i * 2, 3, L"%02X", buf[i]);
    outHex.assign(hex, 32);
    return true;
}

int DumpIrkFromRegistry(const std::wstring& outPath) {
    HKEY hKeys = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kKeysPath, 0, KEY_READ, &hKeys) != ERROR_SUCCESS)
        return 0;

    std::wstring text;
    // Keys\<어댑터주소>\<기기주소> 구조. 어댑터가 여러 개일 수 있어 두 단계를 훑는다.
    for (DWORD ai = 0; ; ai++) {
        wchar_t adapter[64]; DWORD alen = _countof(adapter);
        if (RegEnumKeyExW(hKeys, ai, adapter, &alen, nullptr, nullptr, nullptr, nullptr)
            != ERROR_SUCCESS) break;

        HKEY hAdapter = nullptr;
        if (RegOpenKeyExW(hKeys, adapter, 0, KEY_READ, &hAdapter) != ERROR_SUCCESS) continue;

        for (DWORD di = 0; ; di++) {
            wchar_t dev[64]; DWORD dlen = _countof(dev);
            if (RegEnumKeyExW(hAdapter, di, dev, &dlen, nullptr, nullptr, nullptr, nullptr)
                != ERROR_SUCCESS) break;

            HKEY hDev = nullptr;
            if (RegOpenKeyExW(hAdapter, dev, 0, KEY_READ, &hDev) != ERROR_SUCCESS) continue;
            std::wstring hex;
            if (ReadIrkValue(hDev, hex)) {
                text += dev;
                text += L"=";
                text += hex;
                text += L"\n";
            }
            RegCloseKey(hDev);
        }
        RegCloseKey(hAdapter);
    }
    RegCloseKey(hKeys);

    FILE* f = nullptr;
    _wfopen_s(&f, outPath.c_str(), L"w,ccs=UTF-8");
    if (!f) return 0;
    fwprintf(f, L"%s", text.c_str());
    fclose(f);

    int n = 0;
    for (wchar_t c : text) if (c == L'\n') n++;
    return n;
}

// ---------------------------------------------------------------------------
// [2단계] 관리자 측
// ---------------------------------------------------------------------------
static std::map<uint64_t, std::wstring> ReadDump(const std::wstring& path) {
    std::map<uint64_t, std::wstring> out;
    FILE* f = nullptr;
    _wfopen_s(&f, path.c_str(), L"r,ccs=UTF-8");
    if (!f) return out;
    wchar_t line[256];
    while (fgetws(line, _countof(line), f)) {
        std::wstring s(line);
        while (!s.empty() && (s.back() == L'\n' || s.back() == L'\r')) s.pop_back();
        auto eq = s.find(L'=');
        if (eq == std::wstring::npos) continue;
        std::wstring addr = s.substr(0, eq), hex = s.substr(eq + 1);
        if (hex.size() != 32) continue;
        wchar_t* end = nullptr;
        uint64_t a = wcstoull(addr.c_str(), &end, 16);
        if (a != 0) out[a] = hex;
    }
    fclose(f);
    return out;
}

// 페어링된 BLE 기기의 이름과 주소를 모은다 (어느 IRK가 대상 기기 것인지 고르는 데 쓴다)
static std::map<uint64_t, std::wstring> PairedLeDevices() {
    std::map<uint64_t, std::wstring> out;
    try {
        try { winrt::init_apartment(winrt::apartment_type::multi_threaded); } catch (...) {}
        auto sel = BluetoothLEDevice::GetDeviceSelectorFromPairingState(true);
        auto found = DeviceInformation::FindAllAsync(sel).get();
        for (auto const& d : found) {
            try {
                auto dev = BluetoothLEDevice::FromIdAsync(d.Id()).get();
                if (dev) out[dev.BluetoothAddress()] = std::wstring(d.Name().c_str());
            } catch (...) {}
        }
    } catch (...) {}
    return out;
}

static bool NameMatches(const std::wstring& a, const std::wstring& b) {
    if (a.empty() || b.empty()) return false;
    std::wstring x = a, y = b;
    std::transform(x.begin(), x.end(), x.begin(), ::towlower);
    std::transform(y.begin(), y.end(), y.begin(), ::towlower);
    return x.find(y) != std::wstring::npos || y.find(x) != std::wstring::npos;
}

bool ImportIrkElevated(const std::wstring& targetName, std::wstring& outMessage) {
    const std::wstring dumpPath = GetConfigDir() + L"\\irk_export.tmp";
    DeleteFileW(dumpPath.c_str());

    // SYSTEM으로 도는 1회성 예약 작업. /ru SYSTEM 이라 관리자 권한이 필요하다.
    std::wstring tr = L"\\\"" + ExePath() + L"\\\" --dump-irk \\\"" + dumpPath + L"\\\"";
    std::wstring create = L"schtasks.exe /create /tn " + std::wstring(kTaskName) +
        L" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f /tr \"" + tr + L"\"";
    std::wstring run = L"schtasks.exe /run /tn " + std::wstring(kTaskName);
    std::wstring del = L"schtasks.exe /delete /tn " + std::wstring(kTaskName) + L" /f";

    if (!RunHidden(create, 20000)) {
        outMessage = L"예약 작업을 만들지 못했습니다. 관리자 권한으로 실행됐는지 확인하세요.";
        return false;
    }
    bool ran = RunHidden(run, 20000);

    // 작업은 비동기로 돌기 시작한다. 덤프 파일이 생길 때까지 잠깐 기다린다.
    bool haveFile = false;
    for (int i = 0; i < 100 && ran; i++) {
        if (GetFileAttributesW(dumpPath.c_str()) != INVALID_FILE_ATTRIBUTES) {
            Sleep(200);          // 쓰기가 끝나도록 여유를 둔다
            haveFile = true;
            break;
        }
        Sleep(100);
    }
    RunHidden(del, 20000);

    if (!haveFile) {
        outMessage = L"SYSTEM 작업이 키를 내보내지 못했습니다.";
        return false;
    }

    auto irks = ReadDump(dumpPath);
    DeleteFileW(dumpPath.c_str());   // 키를 디스크에 남기지 않는다

    if (irks.empty()) {
        outMessage = L"저장된 IRK가 없습니다.\n\n"
                     L"아이폰이 이 PC와 BLE 본딩된 적이 없는 상태입니다.\n"
                     L"Windows 설정 > 모바일 장치에서 \"휴대폰과 연결\"로\n"
                     L"아이폰을 한 번 연결한 뒤 다시 시도하세요.";
        return false;
    }

    // 어느 것이 대상 기기 것인지 고른다
    auto paired = PairedLeDevices();
    std::wstring chosen;
    std::wstring chosenName;
    for (auto const& [addr, hex] : irks) {
        auto it = paired.find(addr);
        if (it != paired.end() && NameMatches(it->second, targetName)) {
            chosen = hex;
            chosenName = it->second;
            break;
        }
    }
    if (chosen.empty() && irks.size() == 1) {
        // 후보가 하나뿐이면 그것으로 본다
        chosen = irks.begin()->second;
        chosenName = L"(이름 확인 불가)";
    }
    if (chosen.empty()) {
        wchar_t buf[256];
        swprintf_s(buf, L"IRK를 %zu개 찾았지만 \"%s\"의 것을 고르지 못했습니다.\n\n"
                        L"아이폰을 \"휴대폰과 연결\"로 한 번 연결한 뒤 다시 시도하세요.",
                   irks.size(), targetName.c_str());
        outMessage = buf;
        return false;
    }

    AppConfig cfg;
    LoadAppConfig(cfg);
    cfg.bleIrk = chosen;
    SaveAppConfig(cfg);
    SecureZeroMemory(&chosen[0], chosen.size() * sizeof(wchar_t));

    outMessage = L"기기 키를 가져왔습니다. (" + chosenName + L")\n\n"
                 L"이제 아이폰이 잠긴 상태에서도 인식됩니다.\n"
                 L"\"시작\"을 다시 눌러 주세요.";
    return true;
}

// ---------------------------------------------------------------------------
// [1단계] 사용자 측
// ---------------------------------------------------------------------------
bool RequestIrkImport(const std::wstring& targetName, std::wstring& outMessage) {
    if (IsElevated()) return ImportIrkElevated(targetName, outMessage);

    std::wstring args = L"--import-irk \"" + targetName + L"\"";
    SHELLEXECUTEINFOW ei{ sizeof(ei) };
    ei.fMask = SEE_MASK_NOCLOSEPROCESS;
    ei.lpVerb = L"runas";                 // UAC 승격 요청
    ei.lpFile = ExePath().c_str();
    ei.lpParameters = args.c_str();
    ei.nShow = SW_HIDE;
    if (!ShellExecuteExW(&ei)) {
        DWORD e = GetLastError();
        outMessage = (e == ERROR_CANCELLED)
            ? L"관리자 권한 요청이 취소되었습니다."
            : L"관리자 권한으로 실행하지 못했습니다.";
        return false;
    }
    WaitForSingleObject(ei.hProcess, 120000);
    DWORD code = 1;
    GetExitCodeProcess(ei.hProcess, &code);
    CloseHandle(ei.hProcess);

    if (code == 0) {
        outMessage = L"기기 키를 가져왔습니다.\n\n"
                     L"이제 아이폰이 잠긴 상태에서도 인식됩니다.\n"
                     L"\"시작\"을 다시 눌러 주세요.";
        return true;
    }
    outMessage = L"기기 키를 가져오지 못했습니다.\n\n"
                 L"아이폰이 이 PC와 BLE 본딩되어 있어야 합니다.\n"
                 L"Windows 설정 > 모바일 장치에서 \"휴대폰과 연결\"로\n"
                 L"아이폰을 한 번 연결한 뒤 다시 시도하세요.";
    return false;
}
