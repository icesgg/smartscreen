// bt_deaf.h - 블루투스가 "귀먹은" 것을 알아채고 라디오를 껐다 켜는 판단 (WinRT 없음)
//
// 노트북의 인텔 블루투스가 두 번 (2026-10-07 09:59-11:29, 2026-11-02 19:46-20:06) 라디오는 켜져 있고
// 장치도 정상인데 어느 기기의 광고도 하나 못 받는 상태가 됐다 (AdvScan 15 -> 0). 폰의 GATT 링크도
// 같이 끊겼다. 두 번 다 윈도우 설정에서 블루투스를 껐다 켜니 나았고, 1.1.13 부터는 그 뒤 광고
// 감시자도 스스로 다시 선다 (ble_rssi.cpp "광고 감시자 복구"). 사용자가 고른 것: 이것을 앱이
// 알아서 하고, 안 되면 알린다.
//
// 판단(BtDeafWatch)과 껐다 켜는 순서(BtToggleRadio)를 여기 둔다. 실제 라디오는 BtRadioOps 뒤에
// 있다 - ble_rssi.cpp 가 WinRT Radio 로 구현하고, 시험 하네스는 가짜 시계와 가짜 라디오로 같은
// 코드를 돌린다. 라디오를 실제로 끄지 않고 갈래를 전부 볼 수 있게 하려는 것이다.
#pragma once

#include <windows.h>
#include <functional>
#include <string>
#include <vector>

// 블루투스 알림 상태. 간단 창 상태 칸의 둘째 줄, 오버레이 둘째 줄, 고급 창 상태바가 보여 준다.
enum class RadioHealth {
    Ok,               // 알릴 것 없음
    Toggling,         // 앱이 지금 블루투스를 껐다 켜는 중
    NeedsUserToggle,  // 광고를 못 받는데 앱이 껐다 켤 수 없었다 (권한, 라디오, 30분 안에 이미 함)
    NeedsRestart,     // 껐다 켜도 광고가 안 돌아왔다
    RadioOff,         // 껐다가 다시 켜지 못했다
};

// 간단 창 상태 칸의 둘째 줄. 한 줄에 안 들어가면 그리는 쪽이 " · " 에서 두 줄로 나눈다.
// Ok 면 nullptr - 원래 글을 그대로 둔다.
inline const wchar_t* RadioHealthTileText(RadioHealth h) {
    switch (h) {
    case RadioHealth::Toggling:        return L"블루투스를 다시 켜는 중이에요";
    case RadioHealth::NeedsRestart:    return L"블루투스가 신호를 받지 못해요 · PC 를 다시 시작해 주세요";
    case RadioHealth::NeedsUserToggle: return L"블루투스가 신호를 받지 못해요 · 설정에서 블루투스를 껐다 켜 주세요";
    case RadioHealth::RadioOff:        return L"블루투스가 꺼져 있어요 · 설정에서 켜 주세요";
    default: break;
    }
    return nullptr;
}

// 오버레이 둘째 줄과 고급 창 상태바. 오버레이 줄은 256px 폭에 20px 굵은 글꼴이고 넘치면 잘린다 -
// 같은 글꼴로 재 보니 가장 긴 "껐다 켜기" 가 216px 이다 (2026-11-02, 이 노트북). 늘릴 때는 다시 잰다.
// 간단 창 칸(332px, 14px)에서는 "설정에서 블루투스를 껐다 켜 주세요" 쪽 글만 338px 로 넘쳐 두 줄이 된다.
inline const wchar_t* RadioHealthShortText(RadioHealth h) {
    switch (h) {
    case RadioHealth::Toggling:        return L"블루투스 다시 켜는 중";
    case RadioHealth::NeedsRestart:    return L"블루투스 신호 없음 · 재부팅";
    case RadioHealth::NeedsUserToggle: return L"블루투스 신호 없음 · 껐다 켜기";
    case RadioHealth::RadioOff:        return L"블루투스 꺼짐 · 켜 주세요";
    default: break;
    }
    return nullptr;
}

// 라디오를 만지는 쪽. 실제는 ble_rssi.cpp 의 WinRT Radio, 하네스는 가짜.
struct BtRadioOps {
    virtual ~BtRadioOps() = default;
    virtual ULONGLONG Now() = 0;
    virtual void Sleep(DWORD ms) = 0;
    // 앱이 끝나는 중. 그래도 꺼 둔 라디오는 켜고 나간다 - 기다림만 줄인다.
    virtual bool Stopping() = 0;
    // 라디오를 바꿔도 되는지 (Radio::RequestAccessAsync). 한 번 묻고 기억한다. 안 되면 why.
    virtual bool Access(std::wstring& why) = 0;
    // 껐다 켤 블루투스 라디오를 고른다. 없으면 why.
    virtual bool Find(std::wstring& why) = 0;
    // SetStateAsync. 받아들여졌으면 true. timeoutMs 안에 답이 없거나 거절되면 why.
    virtual bool Set(bool on, DWORD timeoutMs, std::wstring& why) = 0;
    // 1 켜짐, 0 꺼짐, -1 모름
    virtual int State() = 0;
};

struct BtToggleResult {
    bool ok = false;        // 꺼졌다가 다시 켜졌다
    bool wentOff = false;   // 라디오가 실제로 꺼졌었다. 30분 규칙은 이것만 센다
    bool leftOff = false;   // 켜기를 끝내 못 했다 (그래도 시도는 다 했다)
    int  onTries = 0;       // 켜기를 몇 번 했나
    ULONGLONG tookMs = 0;   // 끄기 요청부터 켜짐 확인까지
    std::wstring why;       // ok 가 아니면 이유
};

using BtLogSink = std::function<void(const std::wstring&)>;

// 껐다 켠다: 끄기 요청, 꺼짐 확인 (5초까지), 3초 쉼, 켜기 요청, 켜짐 확인 (10초까지).
// 켜기가 안 되면 5초 간격으로 세 번 더 한다. 라디오를 꺼 둔 채로 끝내지 않으려는 것이다.
// 켜기 시도마다의 실패는 log 로 바로 적는다 (없으면 안 적는다 - --bt-reset).
BtToggleResult BtToggleRadio(BtRadioOps& r, const BtLogSink& log);

// 감시 스레드의 1초 틱이 부르는 판단. 잠금은 부르는 쪽이 쥔다 (ble_rssi.cpp watcherMutex).
class BtDeafWatch {
public:
    static constexpr ULONGLONG kDeafMs = 120000;              // 이만큼 아무 광고도 없으면 귀먹음
    static constexpr ULONGLONG kToggleGapMs = 30ULL * 60000;  // 자동으로 껐다 켜는 것은 30분에 한 번
    // 틱 사이가 이보다 벌어지면 PC 가 잠들었던 것이다. GetTickCount64 는 잠든 시간도 센다 -
    // 그대로 두면 깨자마자 "120초 동안 광고 없음" 으로 읽고 라디오를 껐다 켠다.
    static constexpr ULONGLONG kGapMs = 10000;

    struct In {
        ULONGLONG now = 0;
        bool up = false;          // 광고 감시자가 Up (돌고 있다고 믿는 상태)
        ULONGLONG upSince = 0;    // Up 이 된 시각
        ULONGLONG lastAdv = 0;    // 아무 기기의 마지막 광고 (0 = 없음)
        bool radioBack = false;   // 라디오가 꺼졌다 켜졌다 (StateChanged, 누가 했든)
    };

    // true 면 지금 라디오를 껐다 켠다. 결과는 Toggled 로 돌려준다.
    bool Tick(const In& in, std::vector<std::wstring>& lines);
    // 껐다 켠 결과. sameSession 이 아니면 (그사이 Stop/Start) 알림은 건드리지 않고 적기만 한다.
    void Toggled(const BtToggleResult& r, ULONGLONG now, bool sameSession, std::vector<std::wstring>& lines);
    // Start, Stop. 알림을 지운다. 마지막으로 껐다 켠 시각(30분 규칙)은 남긴다.
    void Reset();
    RadioHealth Health() const { return health_; }
    bool Deaf() const { return deaf_; }

private:
    bool deaf_ = false;
    ULONGLONG deafSince_ = 0;      // 귀먹음을 알아챈 시각 ("heard again after" 의 기준)
    ULONGLONG advMark_ = 0;        // 그때의 마지막 광고. 이보다 새 광고가 오면 끝
    ULONGLONG toggledAt_ = 0;      // 마지막 자동 껐다 켜기 (라디오가 실제로 꺼졌던 것만). 0 = 없음
    bool toggleHelped_ = false;    // 그 뒤로 광고가 다시 들렸다
    bool toggledThisEpisode_ = false;
    ULONGLONG waitSince_ = 0;      // 라디오가 다시 켜진 뒤 광고를 기다리기 시작한 시각. 0 = 안 기다림
    bool restartSaid_ = false;
    ULONGLONG lastTick_ = 0;
    ULONGLONG resumedAt_ = 0;      // 잠들었다 깬 시각 (kGapMs)
    RadioHealth health_ = RadioHealth::Ok;
};
