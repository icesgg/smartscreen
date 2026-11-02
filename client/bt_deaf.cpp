// bt_deaf.cpp - 블루투스 귀먹음 판단과 라디오 껐다 켜기 순서 (bt_deaf.h)
#include "bt_deaf.h"

#include <algorithm>
#include <cstdarg>
#include <cstdio>

namespace {

std::wstring Fmt(const wchar_t* fmt, ...) {
    wchar_t buf[512];
    va_list ap; va_start(ap, fmt);
    _vsnwprintf_s(buf, _countof(buf), _TRUNCATE, fmt, ap);
    va_end(ap);
    return buf;
}

constexpr ULONGLONG kOffWaitMs  = 5000;   // 끄기 요청 뒤 꺼짐을 기다리는 한도
constexpr ULONGLONG kPauseMs    = 3000;   // 꺼진 뒤 쉼. 설정에서 손으로 껐다 켤 때만큼은 둔다
constexpr ULONGLONG kOnWaitMs   = 10000;  // 첫 켜기 뒤 켜짐을 기다리는 한도
constexpr ULONGLONG kOnRetryMs  = 5000;   // 다시 켜기 간격 (세 번 = 약 15초)
constexpr int       kOnRetries  = 3;
constexpr DWORD     kPollMs     = 100;

// 라디오가 want 상태가 될 때까지 deadline 까지 본다.
bool WaitState(BtRadioOps& r, int want, ULONGLONG deadline) {
    for (;;) {
        if (r.State() == want) return true;
        if (r.Now() >= deadline) return false;
        r.Sleep(kPollMs);
    }
}

}  // namespace

BtToggleResult BtToggleRadio(BtRadioOps& r, const BtLogSink& log) {
    BtToggleResult res;
    std::wstring why;
    // 끝나는 중이면 시작하지 않는다 - 아직 아무것도 안 바꿨다.
    if (r.Stopping()) { res.why = L"app is closing"; return res; }
    if (!r.Access(why)) { res.why = L"access " + why; return res; }
    if (!r.Find(why)) { res.why = why; return res; }
    // 이미 꺼져 있는 라디오는 건드리지 않는다. 켜는 것은 사용자가 정할 일이다 (꺼 둔 이유가 있다).
    int st = r.State();
    if (st != 1) { res.why = st == 0 ? L"radio is off" : L"radio state unknown"; return res; }

    ULONGLONG t0 = r.Now();
    bool offAccepted = r.Set(false, (DWORD)kOffWaitMs, why);
    std::wstring offWhy = why;
    bool wentOff = offAccepted ? WaitState(r, 0, t0 + kOffWaitMs)
                               : (r.State() == 0);   // 거절이라면서 꺼졌을 수도 있다
    // 꺼짐을 못 봤어도 (거절, 답 없음, 5초 넘김) 켜기는 한다. 끄기 요청이 늦게 먹힐 수 있는데,
    // 켜기 요청이 그 뒤에 줄을 서면 마지막 상태는 켜짐이다. 켜진 라디오에 켜기는 해가 없다.
    if (wentOff) {
        // 앱이 끝나는 중이면 쉬지 않고 바로 켠다 (소멸자가 기다린다).
        ULONGLONG until = r.Now() + kPauseMs;
        while (r.Now() < until && !r.Stopping()) r.Sleep(kPollMs);
    }

    bool on = false;
    for (int i = 0; i <= kOnRetries; i++) {
        res.onTries = i + 1;
        ULONGLONG limit = i == 0 ? kOnWaitMs : kOnRetryMs;
        ULONGLONG t = r.Now();
        bool accepted = r.Set(true, (DWORD)limit, why);
        on = accepted ? WaitState(r, 1, t + limit) : (r.State() == 1);
        if (on) break;
        std::wstring w = accepted ? Fmt(L"not on after %llus", limit / 1000) : why;
        if (log)
            log(Fmt(L"bluetooth: turning the radio on failed (try %d of %d: %s)%s",
                    i + 1, kOnRetries + 1, w.c_str(), i < kOnRetries ? L" - trying again" : L""));
        if (i == kOnRetries) break;
        // 바로 거절당했으면 간격을 채운다 - 다시 켜기 세 번이 약 15초에 걸치게.
        ULONGLONG next = t + kOnRetryMs;
        ULONGLONG now = r.Now();
        if (now < next) r.Sleep((DWORD)(next - now));
    }
    // 마지막으로 한 번 더 본다. 켜짐 확인 한도를 막 넘겨 켜졌을 수 있다.
    if (!on) on = (r.State() == 1);
    res.tookMs = r.Now() - t0;
    res.wentOff = wentOff || !on;
    if (!on) {
        res.leftOff = true;
        res.why = Fmt(L"radio is still off after %d tries", res.onTries);
    } else if (!wentOff) {
        res.why = offAccepted ? Fmt(L"did not turn off within %llus", kOffWaitMs / 1000)
                              : L"off: " + offWhy;
    } else {
        res.ok = true;
    }
    return res;
}

bool BtDeafWatch::Tick(const In& in, std::vector<std::wstring>& lines) {
    // 잠들었다 깼다. 잠든 동안은 광고가 없는 것이 맞다 - 깬 때부터 다시 센다.
    // 라디오가 다시 켜지기를 기다리던 중이었으면 그 120초도 깬 때부터.
    if (lastTick_ != 0 && in.now > lastTick_ + kGapMs) {
        resumedAt_ = in.now;
        if (waitSince_ != 0) waitSince_ = in.now;
    }
    lastTick_ = in.now;

    if (deaf_) {
        if (in.lastAdv > advMark_) {
            // 어느 기기의 광고든 하나라도 오면 끝. 알림도 전부 내린다.
            lines.push_back(Fmt(L"bluetooth: adverts heard again after %llus",
                                (in.now - deafSince_) / 1000));
            if (toggledThisEpisode_) toggleHelped_ = true;
            deaf_ = false;
            waitSince_ = 0;
            restartSaid_ = false;
            toggledThisEpisode_ = false;
            health_ = RadioHealth::Ok;
            return false;
        }
        if (in.radioBack) {
            // 라디오가 꺼졌다 켜졌다 - 사용자가 알림대로 했거나, 껐다 켜기 직후다. 그동안의 알림은
            // 내리고, 광고가 돌아오는지 120초 본다. 안 돌아오면 다시 시작하라고 한다.
            waitSince_ = in.now;
            restartSaid_ = false;
            health_ = RadioHealth::Ok;
        }
        if (waitSince_ != 0 && !restartSaid_ && in.now >= waitSince_ + kDeafMs) {
            lines.push_back(L"bluetooth: still no adverts 120s after the toggle - a restart is needed");
            health_ = RadioHealth::NeedsRestart;
            restartSaid_ = true;
        }
        return false;
    }

    // 감시자가 돌고 있다고 믿을 때만 본다. 멈춰서 다시 세우는 중이면 그쪽 복구가 먼저다.
    if (!in.up) return false;
    ULONGLONG from = (std::max)({ in.lastAdv, in.upSince, resumedAt_ });
    if (from == 0 || in.now < from + kDeafMs) return false;

    deaf_ = true;
    deafSince_ = in.now;
    advMark_ = in.lastAdv;
    toggledThisEpisode_ = false;
    waitSince_ = 0;
    restartSaid_ = false;
    if (toggledAt_ != 0 && in.now < toggledAt_ + kToggleGapMs) {
        lines.push_back(L"bluetooth: no adverts from any device for 120s - already toggled within 30 min");
        // 지난번 껐다 켜기가 광고를 되살렸으면 또 하면 된다 - 손으로 하라고 한다. 되살리지 못했으면
        // 또 해 봐야 같다 - 다시 시작하라고 한다.
        health_ = toggleHelped_ ? RadioHealth::NeedsUserToggle : RadioHealth::NeedsRestart;
        return false;
    }
    lines.push_back(L"bluetooth: no adverts from any device for 120s - turning Bluetooth off and on");
    health_ = RadioHealth::Toggling;
    return true;
}

void BtDeafWatch::Toggled(const BtToggleResult& r, ULONGLONG now, bool sameSession,
                          std::vector<std::wstring>& lines) {
    // 껐다 켜는 동안 이 스레드는 틱을 돌지 않았다. 그 공백을 잠으로 읽지 않게 한다.
    lastTick_ = now;
    if (r.wentOff) { toggledAt_ = now; toggleHelped_ = false; }
    if (r.ok)
        lines.push_back(Fmt(L"bluetooth: radio toggled off and on in %llus", r.tookMs / 1000));
    else if (r.leftOff)
        lines.push_back(Fmt(L"bluetooth: radio is still off after %d tries", r.onTries));
    else
        lines.push_back(Fmt(L"bluetooth: could not toggle the radio (%s)", r.why.c_str()));
    // 그사이 감시를 멈췄거나 다시 시작했다 - 그쪽이 알림을 지웠다. 되살리지 않는다.
    if (!sameSession || !deaf_) return;
    if (r.wentOff) toggledThisEpisode_ = true;
    if (r.ok) {
        // 다시 켜졌다. 감시자가 다시 서서 광고가 오면 Tick 이 끝낸다. 120초 안에 안 오면 다시 시작하라고.
        health_ = RadioHealth::Ok;
        waitSince_ = now;
        restartSaid_ = false;
    } else if (r.leftOff) {
        health_ = RadioHealth::RadioOff;
    } else {
        health_ = RadioHealth::NeedsUserToggle;
    }
}

void BtDeafWatch::Reset() {
    deaf_ = false;
    deafSince_ = 0;
    advMark_ = 0;
    toggledThisEpisode_ = false;
    waitSince_ = 0;
    restartSaid_ = false;
    health_ = RadioHealth::Ok;
}
