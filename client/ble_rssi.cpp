// ble_rssi.cpp - BLE RSSI 스캐너 구현 (WinRT)
// WinRT BluetoothLEAdvertisementWatcher를 사용하여 BLE 광고 패킷의 RSSI를 읽음
// 키플과 동일한 원리: 물리적 신호 강도(dBm)를 칼만 필터로 스무딩

// config.h 는 winsock2.h 를 끌어오므로 windows.h 를 끌고 오는
// WinRT 헤더보다 먼저 와야 한다 (DbgEvent 용)
#include "config.h"

// WinRT 헤더 (PIMPL로 격리 - 이 파일에서만 사용)
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Storage.Streams.h>

#include "ble_rssi.h"
#include "ble_ident.h"  // ReadPhoneToken - 연결로 신원 확인
#include "ble_gatt.h"   // SS_IDENT_SERVICE_UUID (컴패니언 앱이 광고하는 UUID)
#include <windows.h>
#include <bcrypt.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <map>
#include <vector>

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

    // ---- 연결로 확인하는 신원 (IRK 대체). 설계 배경은 ble_ident.h ----
    // 광고만으로는 잠긴 폰을 특정할 수 없어, 후보에 한 번 붙어 토큰을 읽고
    // 주소를 묶는다. 그 뒤로는 주소가 바뀔 때까지 주소로 추적한다.
    // 토큰은 등록할 때 UI 스레드가 갈아치우고, 광고 콜백 스레드와 프로버
    // 스레드가 읽는다. 32자 문자열은 힙에 있어서 그냥 대입하면 읽는 쪽이
    // 해제된 버퍼를 보게 된다. 그래서 문자열은 잠금으로 감싸고, 광고마다 도는
    // 뜨거운 경로는 "켜졌는지"만 보므로 잠금 없이 읽는 사본을 따로 둔다.
    std::mutex identMutex;
    std::wstring identToken;                    // 등록된 토큰(32 hex). identMutex 로 보호
    std::atomic<bool> identOn{ false };         // identToken 이 비어 있지 않은지 = 이 경로 켜짐
    std::atomic<int> identBit{ -1 };            // 학습된 overflow 비트 (-1 = 모름)
    std::atomic<int> identBitLearned{ -1 };     // 새로 배워서 저장해야 할 값
    std::atomic<int> probeFloor{ -75 };         // 이보다 약하면 탐색하지 않는다
    std::atomic<uint64_t> boundAddr{ 0 };       // 토큰으로 확인된 현재 주소
    // 조용해져서 놓아준 주소. 같은 주소가 다시 광고하면 탐색 없이 다시 묶는다 - 토큰으로
    // 확인했던 주소이고, 랜덤 주소가 우연히 같을 일은 없다. GATT 쉼 동안에는 탐색을 안 하므로
    // 이것이 없으면 잠깐 조용했을 뿐인 폰도 링크가 끝날 때까지 광고 경로에서 빠진다.
    std::atomic<uint64_t> quietAddr{ 0 };
    std::atomic<ULONGLONG> boundSeenTick{ 0 };  // 그 주소를 마지막으로 본 시각

    // 못 붙은 것은 금방 다시 해 본다. 실측에서 맞는 주소인데도 Unreachable 이
    // 다섯 번 연달아 났고, 60초 간격이라 4분에 다섯 번밖에 시도하지 못했다.
    // 다만 같은 주소가 계속 못 붙으면 15, 30, 60, 120, 120... 초로 벌린다.
    // 로그에서 결합 38번 중 32번이 폰이 GATT 로 막 붙은 뒤 60초 안이었다. 그 밖에서
    // 연달아 못 붙는 주소는 다음에도 못 붙기 쉬운데, 시도마다 최악 10초씩 라디오를 쥔다.
    // 그래서 다섯 번째 시도가 위 실측(15초 간격)보다 늦어지는 것을 감수하고, 붙을
    // 가능성이 달라지는 때(깨어남, GATT 링크가 생기거나 끊김, 토큰 변경, 감시 시작)에
    // 처음 간격으로 되돌린다 - ResetBackoff.
    static constexpr ULONGLONG kRetryUnreachableMs = 15000;
    static constexpr ULONGLONG kRetryUnreachableMaxMs = 120000;
    // 붙었는데 우리 서비스가 없던 기기는 다시 볼 이유가 없다. 주소가 바뀌면
    // 어차피 새 후보로 들어온다.
    static constexpr ULONGLONG kRetryNotOursMs = 600000;
    // 이 PC 에 폰 앱이 GATT 로 이만큼 붙어 있으면 탐색을 쉰다. 링크가 생긴 직후가
    // 결합이 되는 때라(위 32/38) 그 60초는 평소대로 찾는다.
    static constexpr ULONGLONG kGattHoldAfterMs = 60000;
    // IRK 가 이 안에 폰의 광고를 풀었으면 탐색을 쉰다 - 폰은 이미 알아보고 있다.
    static constexpr ULONGLONG kIrkPauseMs = 30000;
    // 이만큼 탐색하지 않은 주소의 연속 실패는 끝난 것으로 본다 (주소가 바뀌었거나 멀어짐).
    static constexpr ULONGLONG kStreakIdleMs = 300000;

    struct Cand { bool rnd; int rssi; int bit; ULONGLONG seen; };
    std::mutex candMutex;
    std::map<uint64_t, Cand> cands;             // overflow 비트 하나짜리 광고들
    // 주소별 재시도 금지 시각. 실패 종류에 따라 길이가 다르다 -
    // 남의 기기로 확인된 주소를 계속 다시 찌르면 맞는 기기에 쓸 시도를 낭비한다.
    // set 은 금지를 건 시각: 간격을 처음으로 되돌릴 때 "첫 실패였다면" 으로 줄이는 데 쓴다.
    // notOurs 는 10분짜리 "남의 폰" 판정 - 되돌리기와 GATT 링크 끊김이 건드리지 않는다.
    struct Hold { ULONGLONG until; ULONGLONG set; bool notOurs; };
    std::map<uint64_t, Hold> probedUntil;
    // 주소별 연속 Unreachable. 재시도 간격을 몇 번째인지로 정하고, 실패 줄을 묶는다 -
    // 첫 실패만 그대로 적고 나머지는 10번째마다와 끝날 때 "x<N> since" 한 줄로 적는다.
    // 같은 주소의 실패를 한 줄씩 적으면 그 사이의 STATE 줄을 찾기 어렵다. candMutex 로 보호.
    struct Streak {
        int fails = 0;          // 이번 연속의 실패 수 (= 재시도 간격의 몇 번째)
        int logged = 0;         // 그중 로그에 이미 담긴 수
        SYSTEMTIME firstWall{}; // 첫 실패의 벽시계 시각 (since 표시용)
        ULONGLONG firstTick = 0; // 첫 실패 시각. 한꺼번에 끝난 묶음 줄을 이 순서로 적는다
        ULONGLONG lastTick = 0; // 마지막 실패 시각 = 마지막으로 탐색한 시각
        std::wstring lastWhy;
        DWORD lastMs = 0;
    };
    std::map<uint64_t, Streak> streaks;
    HANDLE proberThread{ nullptr };
    HANDLE proberStop{ nullptr };

    // 탐색 조절 상태. 판정 스레드(SetGattLinked), 광고 콜백(irkMatchTick),
    // UI 스레드(ProbeTagForLog, IrkRecognisesPhone)가 함께 보므로 원자값으로 둔다.
    std::atomic<ULONGLONG> gattLinkSince{ 0 };  // GATT 링크가 생긴 시각, 끊겨 있으면 0
    std::atomic<bool> measuring{ false };       // 재보기가 재는 중 (SetMeasuring). 그동안 GATT 쉼 없음
    std::atomic<ULONGLONG> irkMatchTick{ 0 };   // IRK 가 폰의 광고를 마지막으로 푼 시각
    std::atomic<ULONGLONG> probeStartTick{ 0 }; // 진행 중인 탐색의 시작 시각, 없으면 0
    std::atomic<ULONGLONG> probeEndTick{ 0 };   // 마지막 탐색이 끝난 시각

    // 다른 스레드가 방금 적은 시각은 now 보다 클 수 있다. 그냥 빼면 부호 없는 값이
    // 넘어가 "아주 오래 전" 이 된다 - 방금 광고한 묶인 폰을 went quiet 로 읽는 식.
    static ULONGLONG Elapsed(ULONGLONG now, ULONGLONG t) { return now > t ? now - t : 0; }

    // 잠금을 쥔 채로 파일에 쓰지 않으려고 줄을 먼저 만든다. DbgEvent 는 파일을 열고
    // 닫으므로, candMutex 를 쥔 채 부르면 광고 콜백이 그동안 기다린다.
    static std::wstring Fmt(const wchar_t* fmt, ...) {
        wchar_t buf[512];
        va_list ap; va_start(ap, fmt);
        _vsnwprintf_s(buf, _countof(buf), _TRUNCATE, fmt, ap);
        va_end(ap);
        return buf;
    }
    static void LogLines(const std::vector<std::wstring>& lines) {
        for (auto const& l : lines) DbgEvent(L"%s", l.c_str());
    }

    // n 번째 연속 실패 뒤의 재시도 간격: 15초에서 두 배씩, 120초에서 멈춘다.
    static ULONGLONG UnreachableRetryMs(int n) {
        ULONGLONG ms = kRetryUnreachableMs;
        for (int i = 1; i < n && ms < kRetryUnreachableMaxMs; i++) ms *= 2;
        return (std::min)(ms, kRetryUnreachableMaxMs);
    }

    // 연속 실패 묶음 줄. 첫 실패는 따로 적혀 있으므로 그 뒤가 하나라도 남았을 때만.
    static void StreakLine(uint64_t a, const Streak& s, std::vector<std::wstring>& lines) {
        if (s.fails <= 1 || s.fails <= s.logged) return;
        lines.push_back(Fmt(L"ident: %012llX probe failed x%d since %02d:%02d:%02d (last: %s, %lums)",
            (unsigned long long)a, s.fails,
            s.firstWall.wHour, s.firstWall.wMinute, s.firstWall.wSecond,
            s.lastWhy.c_str(), s.lastMs));
    }
    // candMutex 를 쥔 채 부른다. 그 주소의 연속 실패를 끝낸다 (묶임, 남의 폰 판정).
    void EndStreak(uint64_t a, std::vector<std::wstring>& lines) {
        auto it = streaks.find(a);
        if (it == streaks.end()) return;
        StreakLine(it->first, it->second, lines);
        streaks.erase(it);
    }
    // 한꺼번에 끝난 연속 실패들의 묶음 줄을 첫 실패 순으로 적는다 (같으면 주소 순).
    // map 순서(주소 순)로 적으면 "since 07:12:30" 뒤에 "since 07:05:10" 이 오는 식으로
    // 로그의 시간이 거꾸로 읽힌다. Mac ProbeFailStreaks.summaries 도 첫 실패 순이다.
    static void StreakLinesByFirstFail(std::vector<std::pair<uint64_t, Streak>>& ended,
                                       std::vector<std::wstring>& lines) {
        std::sort(ended.begin(), ended.end(), [](auto const& x, auto const& y) {
            if (x.second.firstTick != y.second.firstTick) return x.second.firstTick < y.second.firstTick;
            return x.first < y.first;
        });
        for (auto const& [a, s] : ended) StreakLine(a, s, lines);
    }
    // candMutex 를 쥔 채 부른다. 모든 연속 실패를 끝낸다 (쉼, 감시 중지, 되돌리기).
    void EndAllStreaks(std::vector<std::wstring>& lines) {
        std::vector<std::pair<uint64_t, Streak>> ended(streaks.begin(), streaks.end());
        streaks.clear();
        StreakLinesByFirstFail(ended, lines);
    }

    // 재시도 간격을 처음으로 되돌리고 연속 실패 수를 잊는다. 잊기 전에 묶음 줄은 남긴다 -
    // 안 그러면 "x7" 같은 실패가 로그에서 사라진다.
    // 이미 걸린 못-붙음 금지는 "첫 실패였다면" 의 길이(15초)로 줄인다.
    // clearUnreachable 이면 아예 지워서 다음 2초 틱에 바로 찾는다 (GATT 링크 끊김, 감시 시작).
    // "남의 폰" 판정(10분)은 건드리지 않는다 - 다시 붙어도 같은 답이다.
    void ResetBackoff(bool clearUnreachable) {
        std::vector<std::wstring> lines;
        {
            std::lock_guard<std::mutex> lock(candMutex);
            EndAllStreaks(lines);
            for (auto it = probedUntil.begin(); it != probedUntil.end(); ) {
                if (it->second.notOurs) { ++it; continue; }
                if (clearUnreachable) { it = probedUntil.erase(it); continue; }
                it->second.until = (std::min)(it->second.until, it->second.set + kRetryUnreachableMs);
                ++it;
            }
        }
        LogLines(lines);
    }

    // IRK 가 최근에 폰의 광고를 풀었는지. 그동안 탐색은 같은 폰을 다시 확인할 뿐이다.
    bool IrkMatchedRecently(ULONGLONG now) {
        ULONGLONG t = irkMatchTick.load();
        return t != 0 && Elapsed(now, t) < kIrkPauseMs && HasIrk();
    }
    // GATT 링크가 60초 넘게 이어졌는지. 결합은 대부분(위 32/38) 그 60초 안에 됐다.
    // 재보기가 재는 동안은 아니다 (BleRssiScanner::SetMeasuring 주석).
    bool GattHeld(ULONGLONG now) const {
        if (measuring) return false;
        ULONGLONG s = gattLinkSince.load();
        return s != 0 && Elapsed(now, s) >= kGattHoldAfterMs;
    }

    // 최근 수신 시각 링버퍼 (초당 수신 건수 계산용)
    static constexpr int kRateSlots = 256;
    ULONGLONG rateTicks[kRateSlots]{};
    std::atomic<uint32_t> rateHead{ 0 };
    std::mutex rateMutex;

    void NotePacket(ULONGLONG now) {
        std::lock_guard<std::mutex> lock(rateMutex);
        rateTicks[rateHead % kRateSlots] = now;
        rateHead++;
    }

    double PacketRate() {
        std::lock_guard<std::mutex> lock(rateMutex);
        ULONGLONG now = GetTickCount64();
        int n = 0;
        for (int i = 0; i < kRateSlots; i++)
            if (rateTicks[i] != 0 && (now - rateTicks[i]) <= 10000) n++;
        return n / 10.0;
    }

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
        static const winrt::guid ident = [] {
            GUID g{}; CLSIDFromString(SS_IDENT_SERVICE_UUID, &g); return winrt::guid(g);
        }();
        // 예전 앱 빌드는 PC 쪽 서비스 UUID를 광고했다. 둘 다 받아 준다.
        static const winrt::guid legacy = [] {
            GUID g{}; CLSIDFromString(SS_GATT_SERVICE_UUID, &g); return winrt::guid(g);
        }();
        try {
            for (auto const& u : adv.ServiceUuids())
                if (u == ident || u == legacy) return true;
        } catch (...) {}
        return false;
    }

    // Apple 백그라운드 광고의 overflow 영역: 제조사 데이터 = 01 + 16바이트 비트필드.
    // 앱이 서비스 UUID 하나를 광고하면 그중 딱 한 비트만 켜진다.
    // 주변에 훨씬 흔한 24바이트짜리 `01 09 20 22 ...` 메시지는 길이에서 걸러지고,
    // 실측(주소 4048개)에서 이 모양은 13개뿐이었다. 비트가 하나가 아니면 -1.
    static int SingleOverflowBit(BluetoothLEAdvertisement const& adv) {
        try {
            auto md = adv.ManufacturerData();
            for (uint32_t i = 0; i < md.Size(); i++) {
                if (md.GetAt(i).CompanyId() != 0x004C) continue;
                auto buf = md.GetAt(i).Data();
                if (buf.Length() != 17) continue;
                auto r = Windows::Storage::Streams::DataReader::FromBuffer(buf);
                if (r.ReadByte() != 0x01) continue;
                int found = -1, n = 0;
                for (int b = 0; b < 16; b++) {
                    uint8_t v = r.ReadByte();
                    for (int k = 0; k < 8; k++) {
                        if (!(v & (1 << k))) continue;
                        if (found < 0) found = b * 8 + k;
                        n++;
                    }
                }
                if (n == 1) return found;
            }
        } catch (...) {}
        return -1;
    }

    // 후보 하나를 골라 붙어 보고, 토큰이 맞으면 그 주소를 묶는다.
    // 스캔 콜백 스레드에서 하면 안 된다 - 연결은 최악 10초까지 걸린다.
    static DWORD WINAPI ProberThunk(LPVOID p) { ((Impl*)p)->ProberLoop(); return 0; }

    // 탐색을 쉬는 이유. 둘 다면 IRK 쪽만 적는다 - 로그에는 지금 효력이 있는 이유 하나.
    enum class Pause { None, Irk, Gatt };

    void ProberLoop() {
        Pause pause = Pause::None;   // 이 스레드만 쓴다
        while (WaitForSingleObject(proberStop, 2000) == WAIT_TIMEOUT) {
            // 스캔이 꺼져 있으면 논다. 스레드를 Impl 수명 내내 살려 두는 이유는
            // 연결 한 번이 최악 10초라 Stop 에서 조인하면 UI 가 그만큼 멈추기 때문이다.
            // 쉬던 이유는 조용히 내려놓는다 - 다시 시작하면 그 세션에서 처음부터 적는다.
            if (!running || !identOn) { pause = Pause::None; continue; }
            ULONGLONG now = GetTickCount64();

            // 쉴지 정한다. 바뀔 때만 한 줄. 쉬기 시작하면 연속 실패도 끝낸다 -
            // 쉬는 동안의 공백을 건너 "x<N>" 이 이어지면 실패가 촘촘했던 것처럼 읽힌다.
            Pause next = IrkMatchedRecently(now) ? Pause::Irk
                       : GattHeld(now)           ? Pause::Gatt
                       :                           Pause::None;
            if (next != pause) {
                if (next != Pause::None) {
                    std::vector<std::wstring> lines;
                    { std::lock_guard<std::mutex> lock(candMutex); EndAllStreaks(lines); }
                    LogLines(lines);
                }
                if (next == Pause::Irk)
                    DbgEvent(L"ident: probes paused - IRK recognises the phone");
                else if (next == Pause::Gatt)
                    DbgEvent(L"ident: probes held - GATT linked for 60s");
                else if (pause == Pause::Irk)
                    DbgEvent(L"ident: probes resumed - IRK has not matched for 30s");
                else if (measuring && gattLinkSince.load() != 0)
                    // 링크는 그대로인데 재보기가 재기 시작했다 (SetMeasuring 주석)
                    DbgEvent(L"ident: probes resumed - measuring");
                else
                    DbgEvent(L"ident: probes resumed - GATT link ended");
                pause = next;
            }

            // 5분 동안 탐색하지 않은 주소의 연속 실패는 끝났다 (주소가 바뀌었거나 멀어졌다).
            // 묶여 있거나 쉬는 동안에도 본다 - 묶음 줄이 그 주소를 마지막으로 본 때에 가깝게 남는다.
            {
                std::vector<std::wstring> lines;
                {
                    std::lock_guard<std::mutex> lock(candMutex);
                    std::vector<std::pair<uint64_t, Streak>> ended;
                    for (auto it = streaks.begin(); it != streaks.end(); ) {
                        if (Elapsed(now, it->second.lastTick) < kStreakIdleMs) { ++it; continue; }
                        ended.emplace_back(it->first, std::move(it->second));
                        it = streaks.erase(it);
                    }
                    StreakLinesByFirstFail(ended, lines);
                }
                LogLines(lines);
            }

            // IRK 가 폰을 알아보는 동안에는 결합도 그대로 둔다 (예전대로). 그동안 폰의 광고는
            // IRK 로 잡히므로 옛 주소가 남아 있어도 판정은 같다. 쉼이 끝나는 틱에 아래에서
            // 바로 풀고 찾는다.
            if (pause == Pause::Irk) continue;

            // 묶인 주소가 아직 광고 중이면 할 일이 없다.
            // 30초로 잡은 이유: 실측 광고 간격의 최대가 19.9초였다. 20초로 두면
            // 정상적인 공백에도 결합이 풀려 헛된 탐색이 돈다. 늦게 풀어도 손해가
            // 적은 쪽인데, 결합이 풀려도 RSSI 는 bleTimeoutSec(90초)까지 살아 있다.
            if (boundAddr && Elapsed(now, boundSeenTick) < 30000) continue;
            // GATT 로 쉬는 동안에도 조용해진 결합은 푼다. 예전에는 쉼 내내 그대로 두어서
            // 폰이 주소를 바꾼 뒤에도 BoundAddress() 가 옛 주소를 가리켰다 - 링크가 이어지는
            // 내내 상태바는 "토큰" 으로 묶여 있다고 말하고, 로그에는 언제 놓쳤는지가 남지 않았다.
            if (boundAddr) {
                DbgEvent(L"ident: %012llX went quiet, looking again",
                         (unsigned long long)boundAddr.load());
                quietAddr = boundAddr.load();
                boundAddr = 0;
            }
            // 찾는 것만은 쉰다. GATT 쉼은 링크가 오래된 뒤의 탐색이 거의 결합되지 않아
            // 일부러 둔 것이다 (kGattHoldAfterMs). 쉼이 끝나는 틱에 아래로 내려가 찾는다 -
            // 위 줄의 "looking again" 은 그때부터다.
            if (pause == Pause::Gatt) continue;

            uint64_t pick = 0; bool pickRnd = true; int pickBit = -1, pickRssi = -127;
            {
                std::lock_guard<std::mutex> lock(candMutex);
                for (auto it = cands.begin(); it != cands.end(); ) {
                    if (Elapsed(now, it->second.seen) > 30000) it = cands.erase(it);
                    else ++it;
                }
                // 주소는 주기적으로 바뀌므로 그냥 두면 계속 쌓인다
                for (auto it = probedUntil.begin(); it != probedUntil.end(); ) {
                    if (now > it->second.until + 300000) it = probedUntil.erase(it);
                    else ++it;
                }
                int want = identBit.load();
                // 1차는 학습한 비트와 일치하는 후보만 본다. 못 찾으면 2차에서
                // 전체를 신호 순으로 - 비트는 광고 UUID가 바뀌면 같이 옮겨간다.
                for (int pass = 0; pass < 2 && !pick; pass++) {
                    if (pass == 0 && want < 0) continue;
                    for (auto const& [a, c] : cands) {
                        if (pass == 0 && c.bit != want) continue;
                        if (c.rssi < probeFloor) continue;   // 자리 판정에 쓸 수 없는 거리는 건드리지 않는다
                        auto pit = probedUntil.find(a);
                        if (pit != probedUntil.end() && now < pit->second.until) continue;
                        if (c.rssi > pickRssi) {
                            pick = a; pickRnd = c.rnd; pickBit = c.bit; pickRssi = c.rssi;
                        }
                    }
                }
                // 잠정 금지: 탐색 중에 같은 주소를 다시 고르지 않게. 결과가 덮어쓴다.
                if (pick) probedUntil[pick] = Hold{ now + kRetryUnreachableMs, now, false };
            }
            if (!pick) continue;

            std::wstring tok, why;
            DWORD took = 0;
            // STATE 줄 꼬리(ProbeTagForLog)용. 읽는 쪽은 시작을 먼저 보고 0 이면 끝을 본다.
            // 그래서 끝난 시각을 먼저 적고 시작을 지운다 - 거꾸로면 방금 끝난 탐색이
            // 꼬리에서 한 번 빠진다 (시작은 지워졌는데 끝은 지난 탐색의 것).
            probeStartTick = (std::max)(GetTickCount64(), 1ULL);
            ProbeOutcome r = ReadPhoneToken(pick, pickRnd, tok, why, &took);
            ULONGLONG done = GetTickCount64();
            probeEndTick = done;
            probeStartTick = 0;
            // 연결에 수 초가 걸리므로 등록된 값은 붙잡고 있지 않고 지금 다시 읽는다.
            // 탐색 중에 등록이 바뀌었으면 새 값으로 판정하는 편이 맞다.
            std::wstring want;
            { std::lock_guard<std::mutex> lock(identMutex); want = identToken; }
            bool ours = (r == ProbeOutcome::Token) &&
                        (_wcsicmp(tok.c_str(), want.c_str()) == 0);
            std::vector<std::wstring> lines;
            if (!ours) {
                // 붙었는데 아닌 것으로 확인된 기기는 한동안 접어 둔다.
                // 못 붙은 것은 일시적일 수 있으니 금방 다시 해 본다 -
                // 실측에서 맞는 주소인데도 연달아 다섯 번 Unreachable 이 났다.
                // 같은 주소가 계속 못 붙으면 간격을 벌린다 (kRetryUnreachableMs 주석).
                bool settled = (r != ProbeOutcome::Unreachable);
                const wchar_t* reason = why.empty() ? L"token mismatch" : why.c_str();
                {
                    std::lock_guard<std::mutex> lock(candMutex);
                    if (settled) {
                        // 남의 폰으로 확인됐으니 그 주소의 연속 실패는 여기서 끝난다
                        EndStreak(pick, lines);
                        probedUntil[pick] = Hold{ done + kRetryNotOursMs, done, true };
                        lines.push_back(Fmt(L"ident: %012llX is not our phone (%s, %lums)",
                                            (unsigned long long)pick, reason, took));
                    } else {
                        Streak& s = streaks[pick];
                        if (s.fails == 0) { GetLocalTime(&s.firstWall); s.firstTick = done; }
                        s.fails++;
                        s.lastTick = done;
                        s.lastWhy = reason;
                        s.lastMs = took;
                        probedUntil[pick] = Hold{ done + UnreachableRetryMs(s.fails), done, false };
                        // 첫 실패는 예전과 똑같이 적는다 - 한 번 실패하고 바로 묶이는 흔한
                        // 경우는 로그가 달라지지 않는다. 그 뒤는 10번째마다 묶음 줄.
                        if (s.fails == 1) {
                            lines.push_back(Fmt(L"ident: %012llX probe failed (%s, %lums)",
                                                (unsigned long long)pick, reason, took));
                            s.logged = 1;
                        } else if (s.fails % 10 == 0) {
                            StreakLine(pick, s, lines);
                            s.logged = s.fails;
                        }
                    }
                }
                LogLines(lines);
                continue;
            }
            // 묶였으니 그 주소의 연속 실패는 끝난다. 묶음 줄을 bound 줄보다 먼저 적는다.
            { std::lock_guard<std::mutex> lock(candMutex); EndStreak(pick, lines); }
            LogLines(lines);
            boundAddr = pick;
            boundSeenTick = GetTickCount64();
            DbgEvent(L"ident: bound to %012llX (%d dBm, %lums)",
                     (unsigned long long)pick, pickRssi, took);
            if (pickBit >= 0 && pickBit != identBit.load()) {
                identBit = pickBit;
                identBitLearned = pickBit;   // 설정에 저장하도록 알린다
                DbgEvent(L"ident: overflow bit is now %d", pickBit);
            }
        }
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
    if (m_impl->proberThread) {
        SetEvent(m_impl->proberStop);
        WaitForSingleObject(m_impl->proberThread, 30000);
        CloseHandle(m_impl->proberThread);
        CloseHandle(m_impl->proberStop);
    }
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
    // 감시 시작은 새 세션이다. 지난 세션의 IRK 일치나 GATT 링크로 쉬지 않고,
    // 재시도 간격도 처음부터 (Stop 사이에 끝난 탐색이 남긴 것까지 지운다).
    // 판정 스레드는 이 뒤에 뜨므로 gattLinkSince 를 여기서 써도 겹치지 않는다.
    m_impl->irkMatchTick = 0;
    m_impl->gattLinkSince = 0;
    m_impl->ResetBackoff(true);

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
            uint64_t bound = m_impl->boundAddr.load();
            if (bound == 0 && m_impl->identOn && addr != 0) {
                uint64_t q = addr;
                if (m_impl->quietAddr.compare_exchange_strong(q, 0)) {
                    // 놓아준 주소가 돌아왔다 (위 quietAddr 주석). 한 번만 일어나도록 비교-교환으로.
                    uint64_t none = 0;
                    if (m_impl->boundAddr.compare_exchange_strong(none, addr)) {
                        bound = addr;
                        DbgEvent(L"ident: %012llX back, bound again", (unsigned long long)addr);
                    }
                }
            }
            bool identMatch = (bound != 0 && addr == bound);
            if (identMatch) {
                m_impl->boundSeenTick = GetTickCount64();
            } else if (m_impl->identOn) {
                // 아직 못 묶었으면 후보로만 쌓아 둔다. 붙는 일은 프로버 스레드가 한다.
                int bit = Impl::SingleOverflowBit(args.Advertisement());
                if (bit >= 0) {
                    std::lock_guard<std::mutex> lock(m_impl->candMutex);
                    auto& c = m_impl->cands[addr];
                    c.rnd = (args.BluetoothAddressType()
                             != Windows::Devices::Bluetooth::BluetoothAddressType::Public);
                    c.rssi = rssi; c.bit = bit; c.seen = GetTickCount64();
                }
            }

            // IRK 해석은 묶인 주소여도 따로 본다. 탐색을 쉴지(IrkRecognisesPhone)가
            // 여기서 정해지는데, 묶인 주소라고 건너뛰면 IRK 가 폰을 알아보는 동안에도
            // 30초 뒤 "IRK has not matched" 로 읽힌다. 주소별 캐시라 다시 계산하지는 않는다.
            bool irkMatch = m_impl->ResolveRpa(addr);
            if (irkMatch) m_impl->irkMatchTick = (std::max)(GetTickCount64(), 1ULL);

            bool matched = identMatch
                || irkMatch
                || Impl::NameContains(advName, m_impl->targetName)
                || (m_impl->targetAddr != 0 && addr == m_impl->targetAddr)
                // 서비스 UUID 는 앱 설치본마다 같으므로 폰을 특정하지 못한다.
                // IRK 도 토큰도 없을 때의 임시방편일 뿐이다.
                || (!m_impl->HasIrk() && !m_impl->identOn
                    && Impl::HasOurService(args.Advertisement()));
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
                ULONGLONG nowTick = GetTickCount64();
                m_impl->lastReceivedTick = nowTick;
                m_impl->receiving = true;
                m_impl->NotePacket(nowTick);
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

        if (!m_impl->proberThread && m_impl->identOn) {
            m_impl->proberStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            m_impl->proberThread = CreateThread(nullptr, 0, Impl::ProberThunk, m_impl, 0, nullptr);
        }
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

    // 프로버 스레드는 그대로 두고(위 주석 참고) 묶인 주소만 버린다.
    // 다시 시작하면 처음부터 후보를 모아 다시 확인한다.
    // 감시를 멈추면 연속 실패도 끝난다 - 아직 안 적힌 실패는 묶음 줄로 남긴다.
    m_impl->boundAddr = 0;
    m_impl->quietAddr = 0;
    m_impl->irkMatchTick = 0;
    std::vector<std::wstring> lines;
    {
        std::lock_guard<std::mutex> lock(m_impl->candMutex);
        m_impl->cands.clear();
        m_impl->probedUntil.clear();
        m_impl->EndAllStreaks(lines);
    }
    Impl::LogLines(lines);
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
double BleRssiScanner::RecentPacketRate() const {
    return m_impl->PacketRate();
}

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

// 등록된 폰이 바뀌었을 수도 있다는 전제로 쓴다. 감시를 시작할 때만 불리는 게
// 아니라 계정으로 등록을 마친 직후에도 불리므로, 스캔이 도는 중에 바뀔 수 있다.
void BleRssiScanner::SetIdentity(const std::wstring& tokenHex, int ovfBit, int probeFloorRssi) {
    bool changed;
    {
        std::lock_guard<std::mutex> lock(m_impl->identMutex);
        changed = (_wcsicmp(m_impl->identToken.c_str(), tokenHex.c_str()) != 0);
        m_impl->identToken = tokenHex;
        m_impl->identOn = !tokenHex.empty();
    }
    m_impl->identBit = ovfBit;
    m_impl->probeFloor = probeFloorRssi;

    if (changed) {
        // 지금까지의 판정은 모두 예전 토큰에 대한 것이다. "남의 기기" 라는
        // 결론은 10분을 버티므로 그대로 두면 새로 등록한 폰을 그만큼 무시한다.
        // 묶여 있던 주소도 더는 확인된 주소가 아니다 - 다른 폰을 등록했는데
        // 예전 폰이 계속 묶여 있으면 그게 화면을 열어둔다.
        // 연속 실패 수도 예전 토큰을 찾던 것이라 새 토큰은 처음 간격부터 찾는다.
        size_t dropped;
        std::vector<std::wstring> lines;
        {
            std::lock_guard<std::mutex> lock(m_impl->candMutex);
            dropped = m_impl->probedUntil.size();
            m_impl->probedUntil.clear();
            m_impl->EndAllStreaks(lines);
            m_impl->boundAddr = 0;
            m_impl->quietAddr = 0;   // 예전 토큰으로 확인한 주소다
        }
        Impl::LogLines(lines);
        // 등록을 바꾼 직후 폰을 못 알아보는 일이 로그에서 갈리도록 남긴다.
        DbgEvent(L"ident: token %s, dropped %d past verdict(s) and the binding",
                 m_impl->identOn ? L"set" : L"cleared", (int)dropped);
    }

    // 스캔이 이미 돌고 있으면 Start 를 다시 지나지 않는다. 여기서 띄우지 않으면
    // 처음 등록한 경우 프로버 스레드가 아예 없어서, "등록했습니다" 라고 말한
    // 뒤에도 폰을 끝까지 확인하지 못한다.
    if (m_impl->running && m_impl->identOn && !m_impl->proberThread) {
        m_impl->proberStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        m_impl->proberThread = CreateThread(nullptr, 0, Impl::ProberThunk, m_impl, 0, nullptr);
    }
}

int BleRssiScanner::TakeLearnedOverflowBit() {
    return m_impl->identBitLearned.exchange(-1);
}

uint64_t BleRssiScanner::BoundAddress() const {
    return m_impl->boundAddr.load();
}

// ---------------------------------------------------------------------------
// 확인 연결 조절
// ---------------------------------------------------------------------------
// 판정 스레드가 반복마다 부른다. 바뀔 때만 일한다. 링크가 생기면 그 뒤 60초가
// 결합이 되는 때라 재시도 간격을 처음으로 되돌리고, 끊기면 못 붙음 금지까지 지워
// 다음 2초 틱에 바로 찾는다 - 링크가 있는 동안 쉬었으므로 그 사이 바뀐 주소를 모른다.
// "탐색 재개" 줄과 60초 뒤의 "쉼" 은 프로버 스레드가 이 시각을 보고 적는다.
void BleRssiScanner::SetGattLinked(bool linked) {
    bool was = m_impl->gattLinkSince.load() != 0;
    if (linked == was) return;
    m_impl->gattLinkSince = linked ? (std::max)(GetTickCount64(), 1ULL) : 0;
    m_impl->ResetBackoff(!linked);
}

// 판정 스레드가 반복마다 부른다. 값만 둔다 - "탐색 재개 - measuring" 줄과 재기가 끝난 뒤의
// "쉼" 은 프로버 스레드가 다음 2초 틱에 GattHeld 를 보고 적는다.
void BleRssiScanner::SetMeasuring(bool measuring) {
    m_impl->measuring = measuring;
}

// 깨어남 등. 잠든 동안 폰도 주소도 달라졌을 수 있어 처음 간격부터 다시 찾는다.
void BleRssiScanner::ResetProbeBackoff() {
    m_impl->ResetBackoff(false);
}

// STATE 줄 꼬리. UI 스레드가 부르므로 원자값만 읽는다. Mac probeTagForLog 와 같은 글자.
std::wstring BleRssiScanner::ProbeTagForLog() const {
    ULONGLONG now = GetTickCount64();
    wchar_t buf[64];
    ULONGLONG s = m_impl->probeStartTick.load();
    if (s != 0) {
        swprintf_s(buf, L", probing for %.1fs", Impl::Elapsed(now, s) / 1000.0);
        return buf;
    }
    ULONGLONG e = m_impl->probeEndTick.load();
    if (e != 0 && Impl::Elapsed(now, e) <= 3000) {
        swprintf_s(buf, L", probe ended %.1fs ago", Impl::Elapsed(now, e) / 1000.0);
        return buf;
    }
    return std::wstring();
}

bool BleRssiScanner::IrkRecognisesPhone() const {
    return m_impl->IrkMatchedRecently(GetTickCount64());
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
    ULONGLONG elapsed = Impl::Elapsed(GetTickCount64(), m_impl->lastReceivedTick);
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
    ULONGLONG elapsed = Impl::Elapsed(GetTickCount64(), m_impl->lastReceivedTick);
    if (elapsed > m_impl->timeoutMs) return -100;
    return m_impl->rawRssi;
}

// ---------------------------------------------------------------------------
// 마지막 수신 이후 경과 시간
// ---------------------------------------------------------------------------
DWORD BleRssiScanner::GetTimeSinceLastReceived() const {
    if (m_impl->lastReceivedTick == 0) return 99999;
    return (DWORD)Impl::Elapsed(GetTickCount64(), m_impl->lastReceivedTick);
}

// ---------------------------------------------------------------------------
// 신호 수신 중 여부 (타임아웃 이내 수신 있음)
// ---------------------------------------------------------------------------
bool BleRssiScanner::IsReceiving() const {
    if (m_impl->lastReceivedTick == 0) return false;
    return Impl::Elapsed(GetTickCount64(), m_impl->lastReceivedTick) < m_impl->timeoutMs;
}

// ---------------------------------------------------------------------------
// BLE 사용 가능 여부
// ---------------------------------------------------------------------------
bool BleRssiScanner::IsAvailable() const {
    return m_impl->available;
}
