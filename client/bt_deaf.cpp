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

constexpr ULONGLONG kOffWaitMs   = 5000;   // 끄기 요청 뒤 꺼짐을 기다리는 한도
constexpr ULONGLONG kOffLateMs   = 15000;  // 답이 없던 끄기 요청이 끝나기를 더 기다리는 한도
constexpr ULONGLONG kOffSeeMs    = 2000;   // 그 요청이 끝난 뒤 꺼짐이 보이기를 기다리는 한도
constexpr ULONGLONG kPauseMs     = 3000;   // 꺼진 뒤 쉼. 설정에서 손으로 껐다 켤 때만큼은 둔다
constexpr ULONGLONG kOnWaitMs    = 10000;  // 첫 켜기 뒤 켜짐을 기다리는 한도
constexpr ULONGLONG kOnRetryMs   = 5000;   // 다시 켜기 간격 (세 번 = 약 15초)
constexpr int       kOnRetries   = 3;
constexpr ULONGLONG kSettleMs    = 5000;   // 꺼짐을 못 보고 켰을 때, 켜진 채인지 지켜보는 시간
constexpr ULONGLONG kSettleMaxMs = 15000;  // 끄기 요청이 아직 돌면 이만큼까지 지켜본다
constexpr DWORD     kPollMs      = 100;

// 라디오가 want 상태가 될 때까지 deadline 까지 본다.
bool WaitState(BtRadioOps& r, int want, ULONGLONG deadline) {
    for (;;) {
        if (r.State() == want) return true;
        if (r.Now() >= deadline) return false;
        r.Sleep(kPollMs);
    }
}

// 켠다: 켜기 요청, 켜짐 확인 (10초까지). 안 되면 5초 간격으로 세 번 더. 켜졌으면 true.
bool TurnOn(BtRadioOps& r, BtToggleResult& res, const BtLogSink& log) {
    std::wstring why;
    bool on = false;
    for (int i = 0; i <= kOnRetries; i++) {
        res.onTries++;
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
    return on;
}

}  // namespace

BtToggleResult BtToggleRadio(BtRadioOps& r, const BtLogSink& log) {
    BtToggleResult res;
    std::wstring why;
    // 끝나는 중이면 시작하지 않는다 - 아직 아무것도 안 바꿨다.
    if (r.Stopping()) { res.why = L"app is closing"; return res; }
    bool lasting = false;
    if (!r.Access(why, lasting)) { res.why = L"access " + why; res.lasting = lasting; return res; }
    if (!r.Find(why)) { res.why = why; return res; }
    // 이미 꺼져 있는 라디오는 건드리지 않는다. 켜는 것은 사용자가 정할 일이다 (꺼 둔 이유가 있다).
    // 알림은 "꺼져 있어요" 로 한다 (wasOff) - "껐다 켜 주세요" 가 아니다.
    int st = r.State();
    if (st == 0) { res.why = L"radio is off"; res.wasOff = true; return res; }
    if (st != 1) { res.why = L"radio state unknown"; return res; }
    // Access 와 Find 는 WinRT 를 기다린다 (처음이면 최악 25초쯤). 그사이 끝나기 시작했으면 끄지
    // 않는다 - 끈 뒤 다시 켜기 전에 프로세스가 끝나면 꺼진 채 남는다.
    if (r.Stopping()) { res.why = L"app is closing"; return res; }

    ULONGLONG t0 = r.Now();
    bool offAccepted = r.Set(false, (DWORD)kOffWaitMs, why);
    std::wstring offWhy = why;
    bool wentOff = offAccepted ? WaitState(r, 0, t0 + kOffWaitMs)
                               : (r.State() == 0);   // 거절이라면서 꺼졌을 수도 있다
    if (!wentOff && !offAccepted && r.OffPending()) {
        // 끄기 요청이 답이 없다. 지금 켜면 라디오는 아직 켜져 있어 켜기가 바로 끝나고, 그 뒤 늦게
        // 먹힌 끄기가 마지막이 되어 꺼진 채 남을 수 있다 (두 요청이 차례대로 처리된다는 보장이 없다).
        // 그 요청이 끝나기를 더 기다린다. 끝나는 중이면 기다리지 않는다 - 켜고, 켠 뒤를 지켜본다.
        ULONGLONG until = r.Now() + kOffLateMs;
        while (r.OffPending() && r.State() != 0 && r.Now() < until && !r.Stopping()) r.Sleep(kPollMs);
        wentOff = (r.State() == 0);
        // 끝났다 - 받아들여졌다면 꺼짐이 곧 보인다
        if (!wentOff && !r.OffPending()) wentOff = WaitState(r, 0, r.Now() + kOffSeeMs);
    }
    // 꺼짐을 못 봤어도 (거절, 답 없음, 5초 넘김) 켜기는 한다. 켜진 라디오에 켜기는 해가 없다.
    if (wentOff) {
        // 앱이 끝나는 중이면 쉬지 않고 바로 켠다 (소멸자와 WM_ENDSESSION 이 기다린다).
        ULONGLONG until = r.Now() + kPauseMs;
        while (r.Now() < until && !r.Stopping()) r.Sleep(kPollMs);
    }

    bool on = TurnOn(r, res, log);
    if (on && !wentOff) {
        // 꺼짐을 못 본 채 켰다. 늦게 먹힌 끄기가 지금 라디오를 끌 수 있다 - 몇 초 지켜보고, 꺼지면
        // 다시 켠다. 끄기 요청이 아직 돌면 더 오래 본다. 끝나는 중이어도 짧게는 본다.
        ULONGLONG start = r.Now();
        for (;;) {
            if (r.State() == 0) {
                wentOff = true;
                if (log) log(L"bluetooth: the radio went off after it was turned on - turning it on again");
                on = TurnOn(r, res, log);
                break;
            }
            ULONGLONG el = r.Now() - start;
            if (el >= kSettleMaxMs || (el >= kSettleMs && (!r.OffPending() || r.Stopping()))) break;
            r.Sleep(kPollMs);
        }
    }
    res.tookMs = r.Now() - t0;
    res.wentOff = wentOff || !on;
    if (!on) {
        res.leftOff = true;
        res.why = Fmt(L"radio is still off after %d tries", res.onTries);
    } else if (!wentOff) {
        res.why = offAccepted ? Fmt(L"did not turn off within %llus", kOffWaitMs / 1000)
                              : L"off: " + offWhy + (r.OffPending() ? L", still pending" : L"");
    } else {
        res.ok = true;
    }
    return res;
}

bool BtDeafWatch::CanToggle(ULONGLONG now) {
    toggledAt_.erase(std::remove_if(toggledAt_.begin(), toggledAt_.end(),
                                    [now](ULONGLONG t) { return t + kToggleGapMs <= now; }),
                     toggledAt_.end());
    return toggledAt_.size() < kMaxToggles;
}

void BtDeafWatch::StartToggle(const wchar_t* line, std::vector<std::wstring>& lines) {
    lines.push_back(line);
    health_ = RadioHealth::Toggling;
    limited_ = false;
    retryAt_ = 0;
    quiet_ = false;   // 껐다 켜기를 적었으니 끝("heard again")도 적는다
}

bool BtDeafWatch::Tick(const In& in, std::vector<std::wstring>& lines) {
    // 잠들었다 깼다. 잠든 동안은 광고가 없는 것이 맞다 - 깬 때부터 다시 센다.
    // 라디오가 다시 켜지기를 기다리던 중이었으면 그 120초도 깬 때부터.
    if (lastTick_ != 0 && in.now > lastTick_ + kGapMs) {
        resumedAt_ = in.now;
        if (waitSince_ != 0) waitSince_ = in.now;
    }
    lastTick_ = in.now;

    // 앱이 끄고 못 켠 라디오가 다시 켜졌다 - 누가 켰든 (StateChanged), 또는 그 뒤에 감시자가 섰다
    // (꺼진 라디오에서는 서지 못한다).
    if (leftOff_ && (in.radioBack || (in.up && in.upSince > leftOffAt_))) RadioBack();

    if (deaf_) {
        if (in.lastAdv > advMark_) {
            // 어느 기기의 광고든 하나라도 오면 끝. 알림도 전부 내린다.
            if (!quiet_)
                lines.push_back(Fmt(L"bluetooth: adverts heard again after %llus",
                                    (in.now - deafSince_) / 1000));
            if (toggledThisEpisode_) toggleHelped_ = true;
            deaf_ = false;
            waitSince_ = 0;
            restartSaid_ = false;
            toggledThisEpisode_ = false;
            limited_ = false;
            retryAt_ = 0;
            quiet_ = false;
            health_ = RadioHealth::Ok;
            return false;
        }
        if (in.radioBack) {
            // 라디오가 꺼졌다 켜졌다 - 사용자가 알림대로 했거나, 껐다 켜기 직후다. 그동안의 알림은
            // 내리고, 광고가 돌아오는지 120초 본다. 안 돌아오면 다시 시작하라고 한다.
            waitSince_ = in.now;
            restartSaid_ = false;
            limited_ = false;
            retryAt_ = 0;
            health_ = RadioHealth::Ok;
        }
        if (waitSince_ != 0 && !restartSaid_ && in.now >= waitSince_ + kDeafMs) {
            quiet_ = false;
            lines.push_back(L"bluetooth: still no adverts 120s after the toggle - a restart is needed");
            health_ = RadioHealth::NeedsRestart;
            restartSaid_ = true;
        }
        // 귀먹음이 이어지는 동안에도, 막혔던 까닭이 풀리면 다시 껐다 켠다 (bt_deaf.h 클래스 주석).
        // 예전에는 처음 알아챈 틱에서만 정해서, 광고가 한 번 돌아오기 전에는 다시 하지 않았다 -
        // 2026-10-07 처럼 90분 이어지면 그동안 내내 손으로 하라는 알림만 떠 있었다.
        if (limited_ && CanToggle(in.now)) {
            StartToggle(L"bluetooth: still no adverts from any device - 30 min passed, turning Bluetooth off and on again", lines);
            return true;
        }
        if (retryAt_ != 0 && in.now >= retryAt_) {
            retryAt_ = 0;
            if (CanToggle(in.now)) {
                StartToggle(L"bluetooth: still no adverts from any device - trying to turn Bluetooth off and on again", lines);
                return true;
            }
            limited_ = true;   // 그사이 두 번을 다 썼다 - 창이 비기를 기다린다
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
    limited_ = false;
    retryAt_ = 0;
    retryGap_ = kRetryMs;
    quiet_ = false;
    bool can = CanToggle(in.now);
    if (!toggledAt_.empty() && (!can || !toggleHelped_)) {
        // 30분 안에 이미 껐다 켰다. 지난번 껐다 켜기가 광고를 되살리지 못했으면 또 해 봐야 같다 -
        // 다시 시작하라고 한다. 되살렸는데 두 번을 다 썼으면 손으로 하라고 하고, 창이 비면 다시 한다.
        // 줄은 한 창에 한 번만 - 광고가 드문드문 오는 곳에서 몇 분마다 같은 두 줄이 쌓이지 않게.
        ULONGLONG window = toggledAt_.front();
        if (limitSaidFor_ == window) {
            quiet_ = true;
        } else {
            lines.push_back(L"bluetooth: no adverts from any device for 120s - already toggled within 30 min");
            limitSaidFor_ = window;
        }
        if (!toggleHelped_) {
            health_ = RadioHealth::NeedsRestart;
        } else {
            health_ = RadioHealth::NeedsUserToggle;
            limited_ = true;
        }
        return false;
    }
    StartToggle(L"bluetooth: no adverts from any device for 120s - turning Bluetooth off and on", lines);
    return true;
}

void BtDeafWatch::Toggled(const BtToggleResult& r, ULONGLONG now, bool sameSession,
                          std::vector<std::wstring>& lines) {
    // 껐다 켜는 동안 이 스레드는 틱을 돌지 않았다. 그 공백을 잠으로 읽지 않게 한다.
    lastTick_ = now;
    if (r.wentOff) { toggledAt_.push_back(now); toggleHelped_ = false; }
    if (r.ok)
        lines.push_back(Fmt(L"bluetooth: radio toggled off and on in %llus", r.tookMs / 1000));
    else if (r.leftOff)
        lines.push_back(Fmt(L"bluetooth: radio is still off after %d tries", r.onTries));
    else
        lines.push_back(Fmt(L"bluetooth: could not toggle the radio (%s)", r.why.c_str()));
    // 앱이 끄고 못 켰다. 이것은 Stop/Start 가 지우지 않는다 (Reset) - 다른 데서는 아무도 말하지
    // 않는다. 라디오가 다시 켜지면 내린다 (RadioBack).
    if (r.leftOff) { leftOff_ = true; leftOffAt_ = now; }
    // 그사이 감시를 멈췄거나 다시 시작했다 - 그쪽이 알림을 지웠다. 되살리지 않는다 (꺼 둔 것만 빼고).
    if (!sameSession || !deaf_) {
        if (r.leftOff) health_ = RadioHealth::RadioOff;
        return;
    }
    if (r.wentOff) toggledThisEpisode_ = true;
    if (r.ok) {
        // 다시 켜졌다. 감시자가 다시 서서 광고가 오면 Tick 이 끝낸다. 120초 안에 안 오면 다시 시작하라고.
        health_ = RadioHealth::Ok;
        waitSince_ = now;
        restartSaid_ = false;
    } else if (r.leftOff || r.wasOff) {
        health_ = RadioHealth::RadioOff;
    } else {
        // 라디오를 끄지도 못했다. 시간 넘김 같은 일시적인 실패면 5분 뒤 다시 해 본다 - 그동안은
        // 손으로 하라고 한다. 또 안 되면 10, 20, 30분 뒤 (귀먹음이 길게 이어져도 줄이 쌓이지 않게).
        // 권한 거절은 다시 물어도 같다.
        health_ = RadioHealth::NeedsUserToggle;
        if (!r.lasting) {
            retryAt_ = now + retryGap_;
            retryGap_ = (std::min)(retryGap_ * 2, kToggleGapMs);
        }
    }
}

void BtDeafWatch::RadioBack() {
    if (!leftOff_) return;
    leftOff_ = false;
    if (health_ == RadioHealth::RadioOff) health_ = RadioHealth::Ok;
}

void BtDeafWatch::Reset() {
    deaf_ = false;
    deafSince_ = 0;
    advMark_ = 0;
    toggledThisEpisode_ = false;
    waitSince_ = 0;
    restartSaid_ = false;
    limited_ = false;
    retryAt_ = 0;
    quiet_ = false;
    health_ = leftOff_ ? RadioHealth::RadioOff : RadioHealth::Ok;
}
