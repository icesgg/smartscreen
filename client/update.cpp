// update.cpp - 프로그램 자동 업데이트. 설계 근거는 update.h 머리말과 docs/UPDATE.md.
#include "common.h"
#include "config.h"
#include "update.h"
#include "version.h"
#include "relver.h"
#include "enterprise/auth.h"

#include <winhttp.h>
#include <bcrypt.h>
#include <mutex>
#include <vector>
#include <set>

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "bcrypt.lib")

namespace {

struct Candidate {
    std::wstring version;
    std::wstring storagePath;    // 'releases' 버킷 안의 경로
    std::wstring notes;
    std::string  sha256;         // 소문자 hex 64자
    unsigned long long size = 0;
};

std::mutex        s_mx;              // 아래 s_st / s_cand / s_downloaded / s_dismissed* 를 지킨다
std::wstring      s_url, s_key, s_org, s_channel;
HWND              s_notifyWnd = nullptr;
UINT              s_notifyMsg = 0;
UpdateStatus      s_st;
Candidate         s_cand;
std::wstring      s_downloaded;      // 해시까지 확인한 파일
std::wstring      s_dismissedVer;    // [나중에] 를 누른 후보 버전
bool              s_dismissedNow = false;   // 후보 없는 상태(오프라인 실패)에서 [나중에]

HANDLE            s_thread = nullptr;
std::atomic<bool> s_stopFlag{ false };
std::atomic<bool> s_busy{ false };
enum class Job { Check, Download };
Job               s_job = Job::Check;
bool              s_manual = false;

void Notify() {
    if (s_notifyWnd) PostMessageW(s_notifyWnd, s_notifyMsg, 0, 0);
}

// 잠금을 잡지 않은 채로 부른다. fromMarker: -1 = 그대로, 0/1 = 같이 바꾼다 - 따로
// 바꾸면 그 사이에 UI 가 읽어 접두어가 두 번 붙거나 창이 안 뜬다.
void SetPhase(UpdatePhase p, const std::wstring& msg = L"", int fromMarker = -1) {
    {
        std::lock_guard<std::mutex> lock(s_mx);
        s_st.phase = p;
        s_st.msg = msg;
        if (fromMarker >= 0) s_st.fromMarker = (fromMarker != 0);
        if (p != UpdatePhase::Downloading) s_st.progressPct = 0;
    }
    Notify();
}

void WriteMarker(const std::wstring& ver, const std::wstring& reason);

void Fail(const std::wstring& why) {
    DbgEvent(L"update: FAILED - %s", why.c_str());
    SetPhase(UpdatePhase::Failed, why, 0);     // 기록에서 온 실패가 아니다
}

// 앱 안에서 난 실패지만 기록으로 남겨야 하는 것 (다시 켜도 같을 실패). 기업 PC 는 한
// 시간마다 같은 실패를 조용히 되풀이하게 되므로, 기록이 있어야 띠가 뜨고 사람이 본다.
void FailMarked(const std::wstring& ver, const std::wstring& why) {
    DbgEvent(L"update: FAILED (recorded for %s) - %s", ver.c_str(), why.c_str());
    if (!ver.empty()) WriteMarker(ver, why);
    // 지금 난 실패다 - "지난번" 은 다시 켠 뒤 기록을 읽는 CheckJob 쪽의 말이다.
    SetPhase(UpdatePhase::Failed, L"적용 실패: " + why, 1);
}

std::wstring UpdateDir() {
    std::wstring dir = GetConfigDir() + L"\\update";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

// ---------------------------------------------------------------------------
// 실패 기록 (update.h "실패는 기억해야 한다")
// ---------------------------------------------------------------------------
std::wstring MarkerPath(const std::wstring& ver) {
    return UpdateDir() + L"\\failed-" + ver + L".txt";
}

bool ReadMarker(const std::wstring& ver, std::wstring& outReason) {
    outReason.clear();
    FILE* f = nullptr;
    if (_wfopen_s(&f, MarkerPath(ver).c_str(), L"r, ccs=UTF-8") != 0 || !f) return false;
    wchar_t line[512] = L"";
    if (fgetws(line, _countof(line), f)) outReason = line;
    fclose(f);
    while (!outReason.empty() && (outReason.back() == L'\n' || outReason.back() == L'\r')) outReason.pop_back();
    return true;
}

void WriteMarker(const std::wstring& ver, const std::wstring& reason) {
    FILE* f = nullptr;
    if (_wfopen_s(&f, MarkerPath(ver).c_str(), L"w, ccs=UTF-8") != 0 || !f) return;
    fputws(reason.c_str(), f);
    fputws(L"\n", f);
    fclose(f);
}

void ClearMarker(const std::wstring& ver) {
    if (!ver.empty()) DeleteFileW(MarkerPath(ver).c_str());
}

// ---------------------------------------------------------------------------
// 서버 응답 읽기
// ---------------------------------------------------------------------------
// PostgREST 가 배열을 주므로 최상위 객체 단위로 자른다. 문자열 안의 중괄호와
// 이스케이프를 건너뛴다 - 배포 메모(notes)에는 무엇이든 들어올 수 있다.
std::vector<std::string> SplitObjects(const std::string& body) {
    std::vector<std::string> out;
    int depth = 0; bool inStr = false; size_t start = 0;
    for (size_t i = 0; i < body.size(); ++i) {
        char c = body[i];
        if (inStr) {
            if (c == '\\') { ++i; continue; }
            if (c == '"') inStr = false;
            continue;
        }
        if (c == '"') { inStr = true; continue; }
        if (c == '{') { if (depth == 0) start = i; ++depth; }
        else if (c == '}') {
            if (depth > 0 && --depth == 0) out.push_back(body.substr(start, i - start + 1));
        }
    }
    return out;
}

// 실패 이유를 사람이 읽는 한 줄로. 표가 아직 없는 경우를 따로 알려 준다 -
// 그 증상은 "업데이트 확인이 안 된다" 인데 원인은 SQL 을 안 돌린 것이라,
// 여기서 말해 주지 않으면 클라이언트 코드를 의심하게 된다.
std::wstring ErrText(const std::string& body, unsigned long status) {
    if (body.find("PGRST205") != std::string::npos || body.find("42P01") != std::string::npos)
        return L"서버에 releases 표가 없어요 (supabase/releases.sql 을 아직 안 돌렸어요)";
    for (const char* k : { "message", "msg", "error_description", "error" }) {
        std::string v;
        if (JsonGetString(body, k, v) && !v.empty()) return Utf8ToWide(v);
    }
    wchar_t buf[64];
    swprintf_s(buf, L"HTTP %lu", status);
    return buf;
}

bool Get(const std::wstring& pathAndQuery, unsigned long& status, std::string& body) {
    std::vector<std::wstring> h = {
        L"apikey: " + s_key,
        L"Authorization: Bearer " + s_key,    // 로그인 없이 읽는다 (update.h 머리말)
    };
    return SupabaseHttp(L"GET", s_url + pathAndQuery, h, std::string(), status, body);
}

// 버킷 안의 경로로만 쓴다. 행을 쓸 수 있는 사람은 관리자뿐이지만, 그래도 URL 을
// 벗어나는 값은 받지 않는다 - 서버 쪽 실수 하나가 이상한 곳을 읽게 만들 이유가 없다.
bool ValidStoragePath(const std::wstring& p) {
    if (p.empty() || p.size() > 200) return false;
    if (p.front() == L'/' || p.find(L"..") != std::wstring::npos) return false;
    for (wchar_t c : p) {
        bool ok = (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
                  c == L'.' || c == L'_' || c == L'-' || c == L'/';
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 내려받기: 파일로 흘려 쓰면서 SHA-256 을 같이 잰다
// ---------------------------------------------------------------------------
// SupabaseHttp 는 본문을 메모리에 다 모으고 진행률이 없다. exe 는 몇 MB 라
// 메모리는 문제가 아니지만, 사용자가 보는 것은 진행률이고, 해시는 어차피
// 흘려 재는 편이 한 번 덜 읽는다.
struct Sha256Stream {
    BCRYPT_ALG_HANDLE  alg = nullptr;
    BCRYPT_HASH_HANDLE h = nullptr;
    bool ok = false;
    Sha256Stream() {
        if (BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0)) &&
            BCRYPT_SUCCESS(BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0)))
            ok = true;
    }
    void Add(const void* p, size_t n) {
        if (ok && n) BCryptHashData(h, (PUCHAR)p, (ULONG)n, 0);
    }
    std::string Finish() {
        unsigned char d[32] = {};
        if (ok) BCryptFinishHash(h, d, sizeof(d), 0);
        static const char* hx = "0123456789abcdef";
        std::string s;
        for (unsigned char b : d) { s += hx[b >> 4]; s += hx[b & 15]; }
        return s;
    }
    ~Sha256Stream() {
        if (h) BCryptDestroyHash(h);
        if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    }
};

bool StreamToFile(const std::wstring& url, const std::wstring& file,
                  unsigned long long expectSize,
                  std::string& outHex, unsigned long long& outGot,
                  std::wstring& outErr) {
    outHex.clear(); outGot = 0; outErr.clear();

    URL_COMPONENTS uc{}; uc.dwStructSize = sizeof(uc);
    wchar_t host[256] = {}, path[2048] = {};
    uc.lpszHostName = host; uc.dwHostNameLength = _countof(host);
    uc.lpszUrlPath = path;  uc.dwUrlPathLength = _countof(path);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) { outErr = L"주소가 이상해요"; return false; }

    HINTERNET hs = WinHttpOpen(L"SmartScreen/" SS_VERSION_STR, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                               WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hs) { outErr = L"WinHTTP 를 열지 못했어요"; return false; }
    // 느린 회선에서 몇 MB 를 받는다. 읽기 타임아웃은 한 덩이 기준이라 30초면 넉넉하다.
    WinHttpSetTimeouts(hs, 15000, 15000, 30000, 30000);

    HINTERNET hc = WinHttpConnect(hs, host, uc.nPort, 0);
    if (!hc) { WinHttpCloseHandle(hs); outErr = L"서버에 닿지 않아요"; return false; }
    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hr = WinHttpOpenRequest(hc, L"GET", path, nullptr, WINHTTP_NO_REFERER,
                                      WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!hr) { WinHttpCloseHandle(hc); WinHttpCloseHandle(hs); outErr = L"요청을 만들지 못했어요"; return false; }

    std::wstring hdr = L"apikey: " + s_key + L"\r\nAuthorization: Bearer " + s_key;
    WinHttpAddRequestHeaders(hr, hdr.c_str(), (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD);

    bool ok = false;
    FILE* f = nullptr;
    std::wstring tmp = file + L".part";
    do {
        if (!WinHttpSendRequest(hr, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
            !WinHttpReceiveResponse(hr, nullptr)) {
            outErr = L"서버에 닿지 않아요";
            break;
        }
        DWORD code = 0, sz = sizeof(code);
        WinHttpQueryHeaders(hr, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &code, &sz, WINHTTP_NO_HEADER_INDEX);
        if (code < 200 || code >= 300) {
            std::string body; char eb[2048]; DWORD n = 0;
            while (WinHttpReadData(hr, eb, sizeof(eb), &n) && n > 0) body.append(eb, n);
            outErr = L"파일을 받지 못했어요: " + ErrText(body, code);
            break;
        }

        if (_wfopen_s(&f, tmp.c_str(), L"wb") != 0 || !f) { outErr = L"파일을 만들지 못했어요"; break; }

        Sha256Stream sha;
        std::vector<char> buf(64 * 1024);
        DWORD n = 0;
        int lastPct = -1;
        bool aborted = false, readOk = true;
        for (;;) {
            readOk = WinHttpReadData(hr, buf.data(), (DWORD)buf.size(), &n) != 0;
            if (!readOk || n == 0) break;
            if (s_stopFlag.load()) { aborted = true; outErr = L"중단됐어요"; break; }
            if (fwrite(buf.data(), 1, n, f) != n) { outErr = L"디스크에 쓰지 못했어요"; aborted = true; break; }
            sha.Add(buf.data(), n);
            outGot += n;
            if (expectSize) {
                int pct = (int)((outGot * 100) / expectSize);
                if (pct > 100) pct = 100;
                if (pct != lastPct && (pct - lastPct >= 4 || pct == 100)) {
                    lastPct = pct;
                    { std::lock_guard<std::mutex> lock(s_mx); s_st.progressPct = pct; }
                    Notify();
                }
            }
        }
        DWORD readErr = readOk ? 0 : GetLastError();   // fclose 가 덮어쓰기 전에
        fclose(f); f = nullptr;
        if (!readOk) {
            // 읽기가 끊긴 것은 끝난 것이 아니다. 해시 불일치로 보이게 두면 원인을 잘못 짚는다.
            wchar_t b[96]; swprintf_s(b, L"내려받는 중 연결이 끊겼어요 (오류 %lu)", readErr);
            outErr = b; aborted = true;
        }
        if (aborted) { DeleteFileW(tmp.c_str()); break; }

        outHex = sha.Finish();
        DeleteFileW(file.c_str());
        if (!MoveFileW(tmp.c_str(), file.c_str())) { DeleteFileW(tmp.c_str()); outErr = L"파일 이름을 바꾸지 못했어요"; break; }
        ok = true;
    } while (false);

    if (f) { fclose(f); DeleteFileW(tmp.c_str()); }
    WinHttpCloseHandle(hr); WinHttpCloseHandle(hc); WinHttpCloseHandle(hs);
    return ok;
}

// 이미 검증해 둔 파일이 그대로 있나 (크기와 해시). 있으면 다시 받지 않는다.
bool VerifiedFileReady(const Candidate& c, const std::wstring& file) {
    if (file.empty() || c.sha256.size() != 64) return false;
    std::string hex; unsigned long long sz = 0;
    if (!Sha256File(file, hex, sz)) return false;
    if (c.size && sz != c.size) return false;
    return _stricmp(hex.c_str(), c.sha256.c_str()) == 0;
}

// ---------------------------------------------------------------------------
// 작업: 확인
// ---------------------------------------------------------------------------
void DownloadJob();

// 확인이 실패했을 때. 손으로 누른 것이면 띠에 띄우고, 한 시간마다 도는 것이면
// 로그만 남기고 보이던 상태를 그대로 둔다 (update.h 의 UpdateCheckAsync 주석).
void CheckFailed(const std::wstring& why, bool manual, UpdatePhase prev) {
    if (manual) { Fail(why); return; }
    DbgEvent(L"update: background check failed - %s (keeping %d)", why.c_str(), (int)prev);
    {
        std::lock_guard<std::mutex> lock(s_mx);
        // checkedTick 은 그대로 둔다 - 갱신하면 머리 단추가 "최신 버전이에요" 를 6초 보여 준다
        if (s_st.phase == UpdatePhase::Checking) s_st.phase = prev;
    }
    Notify();
}

void CheckJob(bool manual) {
    UpdatePhase prev;
    {
        std::lock_guard<std::mutex> lock(s_mx);
        prev = s_st.phase;
        s_dismissedNow = false;      // 새 결과가 나오면 "이번만 감추기" 는 끝난다
        if (manual) {
            // 손으로 눌렀다 = 결과를 보여 달라는 것. 전에 [나중에] 를 눌렀어도 이번 결과는 보인다.
            s_st.dismissed = false;
            s_dismissedVer.clear();
        }
    }
    // 한 시간마다 도는 확인은 보이는 띠(Available/Pending/Failed)를 그대로 둔 채 묻는다.
    // Checking 으로 바꾸면 띠가 사라지고 창이 줄었다 다시 자란다 - 매시간 깜빡이게 된다.
    // 손으로 누른 것은 반응이 보여야 하므로 언제나 Checking 을 거친다.
    if (manual || prev == UpdatePhase::Idle || prev == UpdatePhase::UpToDate) SetPhase(UpdatePhase::Checking);
    if (prev == UpdatePhase::Checking) prev = UpdatePhase::Idle;

    SemVer cur{};
    ParseSemVer(SS_VERSION_STR, cur);

    unsigned long st = 0;
    std::string body;
    std::wstring q = L"/rest/v1/releases?select=version,storage_path,sha256,size,notes"
                     L"&active=eq.true&channel=eq." + s_channel + L"&order=published_at.desc";
    if (!Get(q, st, body)) { CheckFailed(L"서버에 닿지 않아요", manual, prev); return; }
    if (st < 200 || st >= 300) { CheckFailed(ErrText(body, st), manual, prev); return; }

    // 기업 PC 는 관리자가 승인한 버전만 후보다.
    const bool enterprise = !s_org.empty();
    std::set<std::wstring> approved;
    if (enterprise) {
        std::string ab;
        if (!Get(L"/rest/v1/org_release_approvals?select=version&org_id=eq." + s_org, st, ab)) {
            CheckFailed(L"서버에 닿지 않아요 (승인 목록)", manual, prev); return;
        }
        if (st < 200 || st >= 300) { CheckFailed(L"승인 목록: " + ErrText(ab, st), manual, prev); return; }
        for (const auto& o : SplitObjects(ab)) {
            std::string v;
            if (JsonGetString(o, "version", v)) approved.insert(Utf8ToWide(v));
        }
    }

    Candidate best, newest;          // best = 받을 것, newest = 있긴 한 가장 새 것
    SemVer bestV{}, newestV{};
    bool haveBest = false, haveNewest = false;
    int rows = 0;
    for (const auto& o : SplitObjects(body)) {
        ++rows;
        Candidate c;
        std::string v, sp, sha, notes; long long size = 0;
        if (!JsonGetString(o, "version", v) || !JsonGetString(o, "storage_path", sp) ||
            !JsonGetString(o, "sha256", sha)) continue;
        JsonGetString(o, "notes", notes);
        JsonGetNumber(o, "size", size);
        c.version = Utf8ToWide(v); c.storagePath = Utf8ToWide(sp);
        c.notes = Utf8ToWide(notes); c.sha256 = sha; c.size = (unsigned long long)(size > 0 ? size : 0);
        for (auto& ch : c.sha256) ch = (char)tolower((unsigned char)ch);

        SemVer sv{};
        if (!ParseSemVer(c.version, sv) || c.sha256.size() != 64 || !ValidStoragePath(c.storagePath)) {
            DbgEvent(L"update: skipping malformed row (version '%s')", c.version.c_str());
            continue;
        }
        if (CmpSemVer(sv, cur) <= 0) continue;           // 내 버전 이하는 관심 없다
        if (!haveNewest || CmpSemVer(sv, newestV) > 0) { newest = c; newestV = sv; haveNewest = true; }
        if (enterprise && !approved.count(c.version)) continue;
        if (!haveBest || CmpSemVer(sv, bestV) > 0) { best = c; bestV = sv; haveBest = true; }
    }

    // 지난번에 이 버전을 적용하다 실패했나 (update.h "실패는 기억해야 한다").
    std::wstring failedWhy;
    bool failedBefore = haveBest && ReadMarker(best.version, failedWhy);

    {
        std::lock_guard<std::mutex> lock(s_mx);
        s_st.checkedTick = GetTickCount64();
        s_st.autoApply = enterprise;
        if (haveBest) {
            if (s_cand.version != best.version) s_downloaded.clear();   // 다른 버전의 파일은 쓸모없다
            s_cand = best;
            s_st.version = best.version;
            s_st.notes = best.notes;
            s_st.dismissed = (s_dismissedVer == best.version);
        } else if (haveNewest) {
            s_cand = Candidate{};
            s_downloaded.clear();
            s_st.version = newest.version;
            s_st.notes = newest.notes;
            s_st.dismissed = (s_dismissedVer == newest.version);
        } else {
            s_cand = Candidate{};
            s_downloaded.clear();
            s_st.version.clear();
            s_st.notes.clear();
            s_st.dismissed = false;
        }
    }

    if (haveBest && failedBefore) {
        DbgEvent(L"update: %s available but a previous apply failed (%s) - waiting for [retry]",
                 best.version.c_str(), failedWhy.c_str());
        SetPhase(UpdatePhase::Failed, L"지난번 적용 실패: " + failedWhy, 1);
    } else if (haveBest) {
        DbgEvent(L"update: %s available (running %s, %d row(s)%s)%s", best.version.c_str(),
                 SS_VERSION_STR, rows, enterprise ? L", org-approved" : L"",
                 manual ? L" [manual]" : L"");
        SetPhase(UpdatePhase::Available, L"", 0);
        if (enterprise) DownloadJob();      // 승인됐으면 묻지 않는다
    } else if (haveNewest && enterprise) {
        DbgEvent(L"update: %s exists but not approved for org (running %s)",
                 newest.version.c_str(), SS_VERSION_STR);
        SetPhase(UpdatePhase::Pending, L"관리자 승인을 기다려요", 0);
    } else {
        DbgEvent(L"update: up to date (%s, %d row(s))%s", SS_VERSION_STR, rows,
                 manual ? L" [manual]" : L"");
        SetPhase(UpdatePhase::UpToDate, L"", 0);
    }
}

// ---------------------------------------------------------------------------
// 작업: 내려받기
// ---------------------------------------------------------------------------
void DownloadJob() {
    Candidate c; std::wstring have;
    { std::lock_guard<std::mutex> lock(s_mx); c = s_cand; have = s_downloaded; }
    if (c.version.empty()) { Fail(L"받을 버전이 정해지지 않았어요"); return; }
    if (c.sha256.size() != 64) { Fail(L"서버 행의 해시가 이상해요"); return; }

    std::wstring file = UpdateDir() + L"\\SmartScreen-" + c.version + L".exe";

    // updater 를 못 띄워 Failed 가 됐다가 [다시 시도] 로 왔으면 파일은 이미 있다.
    if (!have.empty() && VerifiedFileReady(c, have)) {
        DbgEvent(L"update: %s already downloaded and verified", c.version.c_str());
        SetPhase(UpdatePhase::Ready, L"준비됨");
        return;
    }

    SetPhase(UpdatePhase::Downloading, c.version + L" 내려받는 중");
    DbgEvent(L"update: downloading %s (%llu bytes)", c.version.c_str(), c.size);

    std::string hex; unsigned long long got = 0; std::wstring err;
    if (!StreamToFile(s_url + L"/storage/v1/object/authenticated/releases/" + c.storagePath,
                      file, c.size, hex, got, err)) {
        DeleteFileW(file.c_str());
        Fail(err);
        return;
    }
    if (c.size && got != c.size) {
        DeleteFileW(file.c_str());
        wchar_t b[160];
        swprintf_s(b, L"크기가 달라요 (받음 %llu / 서버 %llu)", got, c.size);
        Fail(b);
        return;
    }
    if (_stricmp(hex.c_str(), c.sha256.c_str()) != 0) {
        DeleteFileW(file.c_str());
        // 서버의 파일이 행과 다르다. 전송이 깨졌거나, 누가 파일만 바꿨다.
        // 어느 쪽이든 이 파일은 실행하지 않는다 - 그게 해시가 행에 있는 이유다.
        Fail(L"내려받은 파일의 해시가 서버 기록과 달라요");
        return;
    }

    { std::lock_guard<std::mutex> lock(s_mx); s_downloaded = file; }
    DbgEvent(L"update: %s verified (%s)", c.version.c_str(), file.c_str());
    SetPhase(UpdatePhase::Ready, L"준비됨");
}

DWORD WINAPI Worker(LPVOID) {
    if (s_job == Job::Check) CheckJob(s_manual);
    else                     DownloadJob();
    s_busy = false;
    return 0;
}

bool StartJob(Job j, bool manual) {
    if (s_url.empty()) return false;            // UpdateInit 전
    if (s_busy.exchange(true)) return false;    // 하나만
    if (s_thread) { CloseHandle(s_thread); s_thread = nullptr; }
    s_job = j; s_manual = manual;
    s_thread = CreateThread(nullptr, 0, Worker, nullptr, 0, nullptr);
    if (!s_thread) { s_busy = false; return false; }
    return true;
}

// ---------------------------------------------------------------------------
// --apply-update 쪽 도우미
// ---------------------------------------------------------------------------
bool Launch(const std::wstring& exe) {
    std::wstring dir = exe.substr(0, exe.find_last_of(L"\\/"));
    std::wstring cmd = L"\"" + exe + L"\"";
    std::vector<wchar_t> buf(cmd.begin(), cmd.end()); buf.push_back(0);
    STARTUPINFOW si{}; si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(exe.c_str(), buf.data(), nullptr, nullptr, FALSE, 0, nullptr,
                        dir.c_str(), &si, &pi)) return false;
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return true;
}

std::wstring Lower(std::wstring s) {
    for (auto& c : s) c = (wchar_t)towlower(c);
    return s;
}

std::wstring BaseName(const std::wstring& p) {
    size_t k = p.find_last_of(L"\\/");
    return k == std::wstring::npos ? p : p.substr(k + 1);
}

// 적용 실패의 마무리: 기록을 남기고 예전 exe 를 다시 띄운다. 대화상자는 예전 exe 를
// 못 띄웠을 때만 - 띄웠으면 그 앱의 띠가 기록을 읽어 이유를 보여 준다. 대화상자를
// 먼저 띄우면 누가 확인을 누를 때까지 앱이 꺼진 채라 화면을 아무도 지키지 않는다.
int ApplyFailed(const std::wstring& ver, const std::wstring& why, const std::wstring& dst, bool relaunch) {
    DbgEvent(L"update: apply FAILED - %s", why.c_str());
    if (!ver.empty()) WriteMarker(ver, why);
    if (relaunch && !Launch(dst)) {
        MessageBoxW(nullptr,
            (L"업데이트를 적용하지 못했고, 예전 버전도 다시 띄우지 못했습니다.\n\n" + why +
             L"\n\n직접 실행해 주세요:\n" + dst).c_str(),
            L"SmartScreen 업데이트", MB_OK | MB_ICONERROR);
    }
    return 1;
}

} // namespace

// ---------------------------------------------------------------------------
// 공개 함수
// ---------------------------------------------------------------------------
void UpdateInit(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                const std::wstring& orgId, const std::wstring& channel,
                void* notifyWnd, unsigned notifyMsg) {
    std::lock_guard<std::mutex> lock(s_mx);
    s_url = supabaseUrl; s_key = anonKey; s_org = orgId;
    s_channel = channel.empty() ? L"stable" : channel;
    s_notifyWnd = (HWND)notifyWnd; s_notifyMsg = notifyMsg;
    s_stopFlag = false;
    s_st = UpdateStatus{};
}

bool UpdateEnabled() {
    std::lock_guard<std::mutex> lock(s_mx);
    return !s_url.empty();
}

void UpdateCheckAsync(bool manual) {
    UpdatePhase p;
    { std::lock_guard<std::mutex> lock(s_mx); p = s_st.phase; }
    // 이미 받아 둔 것이 있으면 다시 묻지 않는다 - 곧 적용될 것이다.
    if (p == UpdatePhase::Downloading || p == UpdatePhase::Ready || p == UpdatePhase::Applying) return;
    if (!StartJob(Job::Check, manual) && manual)
        DbgEvent(L"update: check requested while busy - ignored");
}

bool UpdateHasCandidate() {
    std::lock_guard<std::mutex> lock(s_mx);
    return !s_cand.version.empty();
}

void UpdateDownloadAsync() {
    UpdatePhase p; std::wstring ver;
    { std::lock_guard<std::mutex> lock(s_mx); p = s_st.phase; ver = s_cand.version; }
    if (p != UpdatePhase::Available && p != UpdatePhase::Failed) return;
    if (ver.empty()) return;
    // 일이 실제로 시작된 뒤에 기록을 지운다. 배경 확인이 도는 중이면 StartJob 이 거절하고,
    // 그때 기록을 지워 두면 다음 확인이 그 버전을 새것처럼 다시 받으러 간다.
    if (!StartJob(Job::Download, true)) return;
    // 그 사이 배경 확인이 후보를 바꿨을 수 있다 - 지금 후보의 기록을 지운다
    { std::lock_guard<std::mutex> lock(s_mx); ver = s_cand.version; s_st.fromMarker = false; }
    ClearMarker(ver);      // 사용자가 다시 하라고 했다
}

bool UpdateLaunchApplier(std::wstring& outErr) {
    outErr.clear();
    std::wstring src; Candidate c;
    {
        std::lock_guard<std::mutex> lock(s_mx);
        if (s_st.phase != UpdatePhase::Ready || s_downloaded.empty()) {
            outErr = L"준비된 업데이트가 없어요";
            return false;
        }
        src = s_downloaded; c = s_cand;
    }

    wchar_t self[MAX_PATH]; GetModuleFileNameW(nullptr, self, MAX_PATH);
    std::wstring dir = UpdateDir();

    // 복사본은 이름이 SmartScreen.exe 인 파일만 바꾼다 (UpdateApplyMain). 여기서 먼저 보지
    // 않으면 앱은 종료되고 복사본이 거절해서, 사용자에게는 앱이 사라진 것만 보인다.
    if (Lower(BaseName(self)) != L"smartscreen.exe") {
        outErr = L"실행 파일 이름이 SmartScreen.exe 가 아니라 자동 업데이트를 못 해요 - 이름을 바꿔 주세요";
        FailMarked(c.version, outErr);     // 다시 켜도 같을 실패다. 기록이 있어야 기업 PC 도 본다
        return false;
    }

    // 지난번 updater 가 아직 끝나지 않았으면 그 파일은 잠겨 있다. 이름을 바꿔 피한다.
    std::wstring updater = dir + L"\\updater.exe";
    if (!CopyFileW(self, updater.c_str(), FALSE)) {
        updater = dir + L"\\updater-" + std::to_wstring(GetCurrentProcessId()) + L".exe";
        if (!CopyFileW(self, updater.c_str(), FALSE)) {
            wchar_t b[128]; swprintf_s(b, L"updater 복사본을 만들지 못했어요 (오류 %lu)", GetLastError());
            outErr = b;
            Fail(outErr);            // Ready 에 갇히지 않게. 파일은 그대로라 [다시 시도] 가 바로 Ready 로 온다
            return false;
        }
    }

    std::wstring cmd = L"\"" + updater + L"\" --apply-update " +
                       std::to_wstring(GetCurrentProcessId()) +
                       L" \"" + src + L"\" \"" + std::wstring(self) + L"\"" +
                       L" --sha " + Utf8ToWide(c.sha256) +
                       L" --ver " + c.version;
    std::vector<wchar_t> buf(cmd.begin(), cmd.end()); buf.push_back(0);
    STARTUPINFOW si{}; si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(updater.c_str(), buf.data(), nullptr, nullptr, FALSE, 0, nullptr,
                        dir.c_str(), &si, &pi)) {
        wchar_t b[128]; swprintf_s(b, L"updater 를 띄우지 못했어요 (오류 %lu)", GetLastError());
        outErr = b;
        Fail(outErr);
        return false;
    }
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);

    { std::lock_guard<std::mutex> lock(s_mx); s_st.phase = UpdatePhase::Applying; s_st.msg = L"다시 시작하는 중"; }
    DbgEvent(L"update: applier launched for %s (updater pid %lu)", c.version.c_str(), pi.dwProcessId);
    return true;
}

void UpdateDismiss() {
    std::lock_guard<std::mutex> lock(s_mx);
    s_st.dismissed = true;
    if (!s_st.version.empty()) s_dismissedVer = s_st.version;
    else s_dismissedNow = true;
}

UpdateStatus UpdateGetStatus() {
    std::lock_guard<std::mutex> lock(s_mx);
    UpdateStatus s = s_st;
    if (s_dismissedNow) s.dismissed = true;
    return s;
}

bool UpdateBusy() { return s_busy.load(); }

void UpdateCleanupAfterStart() {
    wchar_t self[MAX_PATH]; GetModuleFileNameW(nullptr, self, MAX_PATH);
    std::wstring bak = std::wstring(self) + L".bak";
    if (GetFileAttributesW(bak.c_str()) != INVALID_FILE_ATTRIBUTES) {
        if (DeleteFileW(bak.c_str())) DbgEvent(L"update: removed %s (new build started fine)", bak.c_str());
    }
    // 내려받은 파일들. updater*.exe 는 아직 돌고 있을 수 있어 실패해도 상관없다.
    // failed-*.txt 는 두어야 한다 (update.h).
    std::wstring dir = UpdateDir();
    WIN32_FIND_DATAW fd{};
    HANDLE hf = FindFirstFileW((dir + L"\\*.exe").c_str(), &fd);
    if (hf != INVALID_HANDLE_VALUE) {
        do {
            if (wcsncmp(fd.cFileName, L"SmartScreen-", 12) == 0 || wcsncmp(fd.cFileName, L"updater", 7) == 0)
                DeleteFileW((dir + L"\\" + fd.cFileName).c_str());    // 잠겨 있으면 그냥 실패
        } while (FindNextFileW(hf, &fd));
        FindClose(hf);
    }
    hf = FindFirstFileW((dir + L"\\*.part").c_str(), &fd);
    if (hf != INVALID_HANDLE_VALUE) {
        do { DeleteFileW((dir + L"\\" + fd.cFileName).c_str()); } while (FindNextFileW(hf, &fd));
        FindClose(hf);
    }
}

void UpdateShutdown() {
    s_stopFlag = true;
    if (s_thread) {
        // 일꾼이 서버 응답을 기다리는 중이면 5초 안에 못 끝날 수 있다. 그때는 그냥
        // 두고 나간다 - 프로세스가 끝나면 같이 끝난다. 핸들을 여기서 닫지 않는 이유는
        // 일꾼이 그 뒤에도 잠깐 살아 있을 수 있기 때문이다.
        if (WaitForSingleObject(s_thread, 5000) != WAIT_OBJECT_0) {
            DbgEvent(L"update: worker did not finish in 5 s - leaving it to process exit");
            return;
        }
        CloseHandle(s_thread); s_thread = nullptr;
    }
}

// ---------------------------------------------------------------------------
// --apply-update: 복사본 exe 로 실행된다
// ---------------------------------------------------------------------------
int UpdateApplyMain(int argc, wchar_t** argv) {
    // argv: <exe> --apply-update <pid> <src> <dst> [--sha <hex>] [--ver <버전>] [--no-relaunch]
    if (argc < 5) return 2;
    DWORD pid = wcstoul(argv[2], nullptr, 10);
    std::wstring src = argv[3], dst = argv[4];
    std::string  wantSha; std::wstring ver;
    bool relaunch = true;
    for (int i = 5; i < argc; ++i) {
        if (wcscmp(argv[i], L"--no-relaunch") == 0) relaunch = false;
        else if (wcscmp(argv[i], L"--sha") == 0 && i + 1 < argc) wantSha = WideToUtf8(argv[++i]);
        else if (wcscmp(argv[i], L"--ver") == 0 && i + 1 < argc) ver = argv[++i];
    }
    for (auto& ch : wantSha) ch = (char)tolower((unsigned char)ch);
    DbgEvent(L"update: applier start (pid %lu, ver %s) %s -> %s", pid, ver.c_str(), src.c_str(), dst.c_str());

    // 무엇을 하든 - 실패해서 예전 exe 를 다시 띄우는 것까지 - 원래 프로세스가 끝난 뒤에
    // 한다. 살아 있는데 다시 띄우면 새 인스턴스가 단일 실행 뮤텍스에 걸려 죽고, 원래
    // 것까지 끝나면 아무것도 남지 않는다. 정상 종료가 BLE 스레드(15초)와 클립보드
    // 스레드를 기다리므로 넉넉히 준다. 그래도 안 끝나면 종료 절차가 멎은 것이다 -
    // 끝내고 진행한다. OpenProcess 로 얻은 핸들이 그 프로세스 객체를 붙잡고 있으므로
    // 그 사이 pid 가 다른 프로세스에 재사용될 수는 없다.
    if (pid) {
        HANDLE h = OpenProcess(SYNCHRONIZE | PROCESS_TERMINATE, FALSE, pid);
        if (!h && GetLastError() != ERROR_INVALID_PARAMETER) {
            // 열지 못했는데 없는 pid 도 아니다 = 살아 있는지 확인할 길이 없다. 확인 못 한 채
            // 파일을 바꾸면 위와 같은 일이 난다. 물러난다.
            DbgEvent(L"update: cannot open old process %lu (error %lu) - giving up", pid, GetLastError());
            if (!ver.empty()) WriteMarker(ver, L"예전 프로그램이 끝났는지 확인하지 못했어요");
            return 1;
        }
        if (h) {
            bool gone = WaitForSingleObject(h, 120000) == WAIT_OBJECT_0;
            if (!gone) {
                DbgEvent(L"update: old process %lu still alive after 120 s - terminating it", pid);
                TerminateProcess(h, 1);
                gone = WaitForSingleObject(h, 10000) == WAIT_OBJECT_0;
            }
            CloseHandle(h);
            if (!gone) {
                // 끝내지도 못했다. 파일을 바꾸면 못 바꾸고(잠김), 다시 띄우면 뮤텍스에 걸린다.
                // 원래 앱은 아직 돌고 있으니 사용자에게 앱은 있다 - 기록만 남기고 물러난다.
                DbgEvent(L"update: old process %lu would not exit - giving up", pid);
                if (!ver.empty()) WriteMarker(ver, L"예전 프로그램이 끝나지 않아 바꾸지 못했어요");
                return 1;
            }
        }
    }

    // 아무 파일이나 바꾸는 도구가 되지 않게 (update.h 의 UpdateApplyMain 주석). 거절해도
    // dst 는 손대지 않았으므로 다시 띄우는 것은 안전하다 - 조용히 끝내면 앱이 사라진 채로 남는다.
    std::wstring updDir = Lower(UpdateDir() + L"\\");
    if (Lower(src).compare(0, updDir.size(), updDir) != 0 || src.find(L"..") != std::wstring::npos)
        return ApplyFailed(ver, L"내려받은 파일 위치가 이상해요", dst, relaunch);
    if (Lower(BaseName(dst)) != L"smartscreen.exe")
        return ApplyFailed(ver, L"실행 파일 이름이 SmartScreen.exe 가 아니라 자동 업데이트를 못 해요", dst, relaunch);
    if (wantSha.size() != 64)
        return ApplyFailed(ver, L"기대하는 해시가 없어요", dst, relaunch);

    // 내려받은 파일이 지금도 행의 해시와 같은지. 받은 뒤 %APPDATA% 에 놓여 있는 사이에
    // 바뀌었으면 여기서 걸린다.
    std::string have; unsigned long long sz = 0;
    if (!Sha256File(src, have, sz))
        return ApplyFailed(ver, L"내려받은 파일을 읽지 못했어요", dst, relaunch);
    if (have != wantSha)
        return ApplyFailed(ver, L"내려받은 파일의 해시가 기록과 달라요", dst, relaunch);

    std::wstring bak = dst + L".bak";
    DeleteFileW(bak.c_str());
    bool moved = false; DWORD lastErr = 0;
    for (int i = 0; i < 20 && !moved; ++i) {
        moved = MoveFileExW(dst.c_str(), bak.c_str(), MOVEFILE_REPLACE_EXISTING) != 0;
        if (!moved) {
            lastErr = GetLastError();
            if (lastErr == ERROR_ACCESS_DENIED) break;   // 권한 문제는 기다려도 안 풀린다
            Sleep(500);    // 프로세스가 끝난 직후 잠깐 잠겨 있을 수 있다
        }
    }
    if (!moved) {
        if (lastErr == ERROR_ACCESS_DENIED)
            return ApplyFailed(ver, L"이 폴더에는 쓸 권한이 없어요 - 프로그램을 사용자 폴더로 옮기면 자동 업데이트가 돼요", dst, relaunch);
        wchar_t b[160];
        swprintf_s(b, L"기존 파일을 옮기지 못했어요 (오류 %lu)", lastErr);
        return ApplyFailed(ver, b, dst, relaunch);
    }

    std::string got;
    bool copied = CopyFileW(src.c_str(), dst.c_str(), FALSE) != 0;
    DWORD copyErr = copied ? 0 : GetLastError();
    bool same = copied && Sha256File(dst, got, sz) && got == wantSha;
    if (!same) {
        // 되돌린다. 방금 놓은 새 파일이나 .bak 을 백신·색인기가 잠깐 잡고 있을 수 있어
        // 지우기와 옮기기를 둘 다 되풀이한다.
        bool restored = false;
        for (int i = 0; i < 20 && !restored; ++i) {
            DeleteFileW(dst.c_str());
            restored = MoveFileExW(bak.c_str(), dst.c_str(), MOVEFILE_REPLACE_EXISTING) != 0;
            if (!restored) Sleep(500);
        }
        wchar_t b[200];
        swprintf_s(b, copied ? L"새 파일을 놓았는데 내용이 달라요" : L"새 파일을 놓지 못했어요 (오류 %lu)", copyErr);
        if (!restored) {
            // 가장 나쁜 경우: 제대로 된 실행 파일이 없다. 이건 대화상자로 말해야 한다.
            DbgEvent(L"update: apply FAILED and rollback FAILED - %s", b);
            if (!ver.empty()) WriteMarker(ver, b);
            MessageBoxW(nullptr,
                (std::wstring(L"업데이트를 적용하지 못했고, 예전 파일을 되돌리지도 못했습니다.\n\n") + b +
                 L"\n\n이 폴더에서 SmartScreen.exe 가 남아 있으면 지우고,\n"
                 L"SmartScreen.exe.bak 의 이름을 SmartScreen.exe 로 바꿔 주세요:\n" +
                 dst.substr(0, dst.find_last_of(L"\\/"))).c_str(),
                L"SmartScreen 업데이트", MB_OK | MB_ICONERROR);
            return 1;
        }
        return ApplyFailed(ver, b, dst, relaunch);
    }

    DeleteFileW(src.c_str());
    ClearMarker(ver);
    DbgEvent(L"update: applied %s -> %s (old kept as .bak until the new build starts)", ver.c_str(), dst.c_str());
    if (relaunch && !Launch(dst)) {
        MessageBoxW(nullptr,
            (L"새 버전을 놓았는데 실행하지 못했습니다. 직접 실행해 주세요:\n" + dst).c_str(),
            L"SmartScreen 업데이트", MB_OK | MB_ICONERROR);
        return 1;
    }
    return 0;
}
