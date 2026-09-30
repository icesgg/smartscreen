// supabase.cpp - Enterprise: Supabase REST API client via WinHTTP
//
// 기업 PC 는 로그인 없이 (anon key 로) 조직의 contents 행을 읽고, 그 행이 가리키는
// 파일을 받아 잠금 화면에 띄운다. 행을 쓸 수 있는 사람은 그 조직의 멤버 전부이므로
// (관리자만이 아니다) 행의 글자는 믿는 값이 아니다. 그래서 여기서는
//   - 행은 정해진 모양과 글자 그대로 맞을 때만 받고,
//   - 로컬 파일 이름은 검증된 조각으로만 만들고,
//   - 받은 파일은 크기와 SHA-256 이 행과 같을 때만 제자리에 놓는다.
// 2026-09-30 검토 전까지는 셋 다 없었다: storage_path 의 마지막 '/' 뒤가 그대로
// 파일 이름이 됐고 (역슬래시로 폴더 밖에 쓸 수 있었다), HTTP 상태를 보지 않아
// 서버의 오류 본문이 콘텐츠 파일로 저장됐고, file_hash 는 읽기만 하고 쓰지 않았다.
#include "supabase.h"
#include "auth.h"
#include "../config.h"
#include <winhttp.h>
#include <mutex>

#pragma comment(lib, "winhttp.lib")

// 받기를 거절하는 크기. 서버의 contents_file_size_range 제약, 'content' 버킷의
// file_size_limit 과 같은 값이다 (supabase/hardening.sql).
static const long long kMaxContentBytes = 200LL * 1024 * 1024;

// 목록 응답의 상한. 행 하나가 300바이트쯤이라 1 MB 면 수천 행이다.
static const size_t kMaxManifestBytes = 1024 * 1024;

// ---------------------------------------------------------------------------
// 모양 검사
// ---------------------------------------------------------------------------
static bool IsLowerHex(wchar_t c) {
    return (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f');
}

static bool IsHash64(const std::wstring& s) {
    if (s.size() != 64) return false;
    for (wchar_t c : s) if (!IsLowerHex(c)) return false;
    return true;
}

// 확장자: [a-z0-9]{1,8}
static bool IsExt(const std::wstring& s) {
    if (s.empty() || s.size() > 8) return false;
    for (wchar_t c : s) {
        if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'z'))) return false;
    }
    return true;
}

// 로그 한 줄에 넣을 수 있게: 길이를 자르고 제어 문자를 지운다. 서버에서 온 글자를
// 그대로 찍으면 줄바꿈 하나로 events.log 에 가짜 줄을 만들 수 있다.
static std::wstring OneLine(const std::wstring& s, size_t maxLen = 48) {
    std::wstring out = s.substr(0, maxLen);
    for (auto& c : out) {
        if (c < 0x20 || c == 0x7F) c = L'?';
    }
    return out;
}

bool NormalizeOrgId(const std::wstring& in, std::wstring& out) {
    out.clear();
    auto isSpace = [](wchar_t c) {
        return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n';
    };
    size_t b = 0, e = in.size();
    while (b < e && isSpace(in[b])) ++b;
    while (e > b && isSpace(in[e - 1])) --e;
    if (e - b != 36) return false;

    std::wstring s;
    s.reserve(36);
    for (size_t k = 0; k < 36; ++k) {
        wchar_t c = in[b + k];
        if (k == 8 || k == 13 || k == 18 || k == 23) {
            if (c != L'-') return false;
        } else if (c >= L'A' && c <= L'F') {
            c = (wchar_t)(c - L'A' + L'a');
        } else if (!IsLowerHex(c)) {
            return false;
        }
        s += c;
    }
    out = s;
    return true;
}

// "<org uuid>/<hash>.<ext>" 를 세 조각으로. 글자 그대로 그 모양일 때만 true.
// 36(uuid) + 1('/') + 64(hash) + 1('.') = 102, 그 뒤가 확장자다. 비교가 전부
// "이 자리에 이 글자" 라서 "..", 역슬래시, '?', '#', 공백이 들어갈 자리가 없다.
static bool SplitStoragePath(const std::wstring& p, std::wstring& org,
                             std::wstring& hash, std::wstring& ext) {
    if (p.size() < 103 || p.size() > 110) return false;
    if (p[36] != L'/' || p[101] != L'.') return false;
    const std::wstring rawOrg = p.substr(0, 36);
    if (!NormalizeOrgId(rawOrg, org) || org != rawOrg) return false;   // 소문자 정규형만
    hash = p.substr(37, 64);
    ext = p.substr(102);
    return IsHash64(hash) && IsExt(ext);
}

// ---------------------------------------------------------------------------
// 서버 응답 읽기
// ---------------------------------------------------------------------------
// PostgREST 가 주는 배열을 최상위 객체 단위로 자른다. 문자열 안의 중괄호와
// 이스케이프를 건너뛴다 (client/update.cpp 의 SplitObjects 와 같은 논리다 - 거기는
// 익명 네임스페이스라 부를 수 없다). 예전에는 '{' 다음에 처음 나오는 '}' 에서
// 잘랐고, 이름에 '}' 가 든 파일(promo}.png) 하나가 그 행을 통째로 잃게 했다.
static std::vector<std::string> SplitObjects(const std::string& body) {
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

// 행 하나를 읽는다. 공유된 모양과 글자 그대로 맞을 때만 true 이고, 아니면 whyNot 에
// 이유를 둔다.
//
// JsonGetString 은 "키" 가 처음 나오는 곳을 집는다. 값 안에 키 이름이 들어 있으면
// 엉뚱한 곳을 집을 수 있는데, 여기서는 그게 통과로 이어지지 않는다: 열을 읽는
// 순서가 서버가 주는 순서(select= 에 적은 순서)와 같고, 앞의 값이 검증을 통과해야만
// 다음 값을 읽으므로, 통과한 행은 앞에서부터 차례로 제 키를 집은 행이다.
static bool ParseContentRow(const std::string& obj, const std::wstring& orgId,
                            ContentItem& ci, const wchar_t*& whyNot) {
    std::string id, org, sp, hash, type, pos;
    long long size = 0;

    JsonGetString(obj, "id", id);
    ci.id = Utf8ToWide(id);

    if (!JsonGetString(obj, "org_id", org) || Utf8ToWide(org) != orgId) {
        whyNot = L"org_id is not this PC's org"; return false;
    }
    if (!JsonGetString(obj, "storage_path", sp) || !JsonGetString(obj, "file_hash", hash)) {
        whyNot = L"storage_path or file_hash missing"; return false;
    }
    ci.storagePath = Utf8ToWide(sp);
    ci.fileHash = Utf8ToWide(hash);

    std::wstring pOrg, pHash, pExt;
    if (!SplitStoragePath(ci.storagePath, pOrg, pHash, pExt) ||
        pOrg != orgId || pHash != ci.fileHash) {
        whyNot = L"storage_path is not <org_id>/<file_hash>.<ext>"; return false;
    }
    if (!JsonGetNumber(obj, "file_size", size) || size <= 0 || size > kMaxContentBytes) {
        whyNot = L"file_size out of range (1 .. 200 MB)"; return false;
    }
    if (!JsonGetString(obj, "content_type", type) || (type != "image" && type != "video")) {
        whyNot = L"content_type is not image/video"; return false;
    }
    if (!JsonGetString(obj, "display_position", pos) || (pos != "center" && pos != "banner")) {
        whyNot = L"display_position is not center/banner"; return false;
    }

    ci.fileSize = size;
    ci.contentType = Utf8ToWide(type);
    ci.displayPos = Utf8ToWide(pos);
    // 이름은 검증된 조각으로 만든다 - storage_path 를 잘라 쓰지 않는다.
    ci.localName = pHash + L"." + pExt;
    return true;
}

// ---------------------------------------------------------------------------
// Enterprise content directory
// ---------------------------------------------------------------------------
std::wstring GetEnterpriseContentDir() {
    std::wstring dir = GetConfigDir() + L"\\enterprise_content";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

bool IsEnterpriseContentPath(const std::wstring& path) {
    if (path.empty()) return false;
    const std::wstring prefix = GetEnterpriseContentDir() + L"\\";
    return path.size() > prefix.size() &&
           _wcsnicmp(path.c_str(), prefix.c_str(), prefix.size()) == 0;
}

// ---------------------------------------------------------------------------
// 조직이 있는가
// ---------------------------------------------------------------------------
int CheckOrgExists(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                   const std::wstring& orgIdIn) {
    std::wstring orgId;
    if (!NormalizeOrgId(orgIdIn, orgId)) return 0;   // uuid 가 아닌 조직 id 는 없다

    std::vector<std::wstring> headers = {
        L"apikey: " + anonKey,
        L"Authorization: Bearer " + anonKey,
        L"Content-Type: application/json",
    };
    // orgId 는 위에서 hex 와 '-' 만 남았으므로 JSON 에 그대로 넣어도 된다.
    std::string body = "{\"p_org\":\"" + WideToUtf8(orgId) + "\"}";

    unsigned long status = 0;
    std::string resp;
    if (!SupabaseHttp(L"POST", supabaseUrl + L"/rest/v1/rpc/org_exists", headers, body,
                      status, resp, 4096)) {
        DbgEvent(L"enterprise: org_exists - request failed (HTTP %lu)", status);
        return -1;
    }
    if (status < 200 || status >= 300) {
        // 404 (PGRST202) 는 함수가 아직 서버에 없다는 뜻이다. "조직이 없다" 가 아니다.
        DbgEvent(L"enterprise: org_exists - HTTP %lu, cannot tell", status);
        return -1;
    }
    // 본문은 true 또는 false 한 낱말이다.
    size_t b = resp.find_first_not_of(" \t\r\n");
    size_t e = resp.find_last_not_of(" \t\r\n");
    std::string word = (b == std::string::npos) ? std::string() : resp.substr(b, e - b + 1);
    if (word == "true") return 1;
    if (word == "false") return 0;
    DbgEvent(L"enterprise: org_exists - unexpected answer, cannot tell");
    return -1;
}

// ---------------------------------------------------------------------------
// Fetch manifest
// ---------------------------------------------------------------------------
bool FetchManifest(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                   const std::wstring& orgIdIn, ContentManifest& out) {
    out.items.clear();
    out.orgId.clear();

    // 조직 id 는 URL 에 그대로 들어간다. uuid 모양이 아니면 아예 묻지 않는다.
    std::wstring orgId;
    if (!NormalizeOrgId(orgIdIn, orgId)) {
        DbgEvent(L"enterprise: org id '%s' is not a uuid - nothing requested",
                 OneLine(orgIdIn).c_str());
        return false;
    }
    out.orgId = orgId;

    // active 인 행만 받는다. 예전에는 active 가 하나도 없으면 "가장 새 두 행" 을
    // active 와 무관하게 받아 띄웠다 - 관리자가 송출을 전부 멈춰도 새로 등록한 PC 는
    // 멈춘 콘텐츠를 보여 줬다. active 가 없다는 것은 "띄울 것이 없다" 는 뜻이다.
    //
    // 새 것부터 받는다. 한 자리에 active 가 둘이면 (대시보드는 하나만 켜 두지만
    // 스키마는 막지 않는다) 새 쪽을 쓴다.
    std::vector<std::wstring> headers = {
        L"apikey: " + anonKey,
        L"Authorization: Bearer " + anonKey,
    };
    std::wstring url = supabaseUrl + L"/rest/v1/contents?org_id=eq." + orgId +
        L"&active=eq.true"
        L"&select=id,org_id,storage_path,file_hash,file_size,content_type,display_position"
        L"&order=created_at.desc";

    unsigned long status = 0;
    std::string body;
    if (!SupabaseHttp(L"GET", url, headers, std::string(), status, body, kMaxManifestBytes)) {
        DbgEvent(L"enterprise: contents request failed (HTTP %lu)", status);
        return false;
    }
    if (status < 200 || status >= 300) {
        DbgEvent(L"enterprise: contents request answered HTTP %lu", status);
        return false;
    }
    // 2xx 인데 배열이 아니면 PostgREST 의 답이 아니다. "행이 없다" 로 읽지 않는다.
    size_t first = body.find_first_not_of(" \t\r\n");
    if (first == std::string::npos || body[first] != '[') {
        DbgEvent(L"enterprise: contents answer is not a JSON array");
        return false;
    }

    for (const auto& obj : SplitObjects(body)) {
        ContentItem ci{};
        const wchar_t* whyNot = L"";
        if (!ParseContentRow(obj, orgId, ci, whyNot)) {
            DbgEvent(L"enterprise: row skipped - %s (id %s)", whyNot, OneLine(ci.id).c_str());
            continue;
        }
        out.items.push_back(ci);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Download file via WinHTTP
// ---------------------------------------------------------------------------
// 파일로 흘려 쓴다 (영상은 수십 MB 라 SupabaseHttp 처럼 메모리에 모으지 않는다).
//
//   1  = 2xx 이고 본문을 끝까지 받아 tmpPath 에 썼다
//   0  = 서버가 줄 수 없다고 답했거나(4xx) 본문이 maxBytes 를 넘었거나 디스크에 못 썼다
//        - 다시 물어도 같을 실패
//   -1 = 서버에 닿지 못했거나 도중에 끊겼다 (5xx, 408, 429 포함) - 나중에는 될 실패
//
// 1 이 아니면 tmpPath 에 아무것도 남기지 않는다. 예전에는 상태 코드를 보지 않아서
// 404 의 JSON 오류 본문이 콘텐츠 파일이 됐고, 읽기가 도중에 끊겨도 잘린 파일을
// 제자리로 옮겼다.
static int DownloadToFile(const std::wstring& url, const std::wstring& anonKey,
                          const std::wstring& tmpPath, unsigned long long maxBytes,
                          unsigned long& outStatus) {
    outStatus = 0;

    URL_COMPONENTS uc = {}; uc.dwStructSize = sizeof(uc);
    wchar_t host[256] = {}, path[2048] = {};
    uc.lpszHostName = host; uc.dwHostNameLength = _countof(host);
    uc.lpszUrlPath = path; uc.dwUrlPathLength = _countof(path);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return -1;

    HINTERNET hSession = WinHttpOpen(L"SmartScreen/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return -1;
    // 기본값(이름 풀이 무제한, 연결 60초)에 맡기지 않는다. 읽기 제한은 한 덩이
    // 기준이라 큰 영상도 30초면 넉넉하다 (client/update.cpp 의 내려받기와 같은 값).
    WinHttpSetTimeouts(hSession, 15000, 15000, 30000, 30000);

    HINTERNET hConnect = WinHttpConnect(hSession, host, uc.nPort, 0);
    if (!hConnect) { WinHttpCloseHandle(hSession); return -1; }

    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hRequest = WinHttpOpenRequest(hConnect, L"GET", path, nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!hRequest) { WinHttpCloseHandle(hConnect); WinHttpCloseHandle(hSession); return -1; }

    std::wstring auth = L"apikey: " + anonKey + L"\r\nAuthorization: Bearer " + anonKey;
    WinHttpAddRequestHeaders(hRequest, auth.c_str(), (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD);

    int result = -1;
    if (WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                           WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
        WinHttpReceiveResponse(hRequest, nullptr)) {

        DWORD code = 0, sz = sizeof(code);
        WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &code, &sz, WINHTTP_NO_HEADER_INDEX);
        outStatus = code;

        if (code >= 200 && code < 300) {
            FILE* f = nullptr;
            if (_wfopen_s(&f, tmpPath.c_str(), L"wb") == 0 && f) {
                std::vector<char> buf(64 * 1024);
                unsigned long long total = 0;
                bool complete = false, giveUp = false;
                for (;;) {
                    DWORD n = 0;
                    if (!WinHttpReadData(hRequest, buf.data(), (DWORD)buf.size(), &n)) break;   // 도중에 끊겼다
                    if (n == 0) { complete = true; break; }                                    // 본문 끝
                    total += n;
                    // 행이 말한 크기보다 길면 어차피 다른 파일이다. 끝까지 받지 않는다.
                    if (total > maxBytes) { giveUp = true; break; }
                    if (fwrite(buf.data(), 1, n, f) != n) { giveUp = true; break; }
                }
                if (fclose(f) != 0) giveUp = true;
                if (giveUp) result = 0;
                else if (complete) result = 1;
                if (result != 1) DeleteFileW(tmpPath.c_str());
            } else {
                result = 0;   // 임시 파일을 못 만든다. 네트워크 탓이 아니다
            }
        } else if (code >= 400 && code < 500 && code != 408 && code != 429) {
            result = 0;       // "그런 파일 없다 / 못 준다" 는 답을 받았다
        }
    }

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return result;
}

// 파일의 SHA-256 이 (expectSize 가 0 이 아니면 크기도) 기대와 같은가.
static bool FileMatches(const std::wstring& path, const std::wstring& hashHex,
                        unsigned long long expectSize) {
    std::string hex;
    unsigned long long size = 0;
    if (!Sha256File(path, hex, size)) return false;
    if (expectSize != 0 && size != expectSize) return false;
    return _wcsicmp(Utf8ToWide(hex).c_str(), hashHex.c_str()) == 0;
}

// 받아서, 확인하고, 맞을 때만 localPath 에 놓는다. 돌려주는 값은 DownloadToFile 과
// 같다 (확인에서 떨어지면 0).
// storagePath 는 SplitStoragePath 를 통과한 값이어야 한다 - URL 에 그대로 붙인다.
static int FetchVerified(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                         const std::wstring& storagePath, const std::wstring& hashHex,
                         unsigned long long expectSize, const std::wstring& localPath) {
    std::wstring url = supabaseUrl + L"/storage/v1/object/authenticated/content/" + storagePath;
    std::wstring tmp = localPath + L".tmp";

    unsigned long status = 0;
    int got = DownloadToFile(url, anonKey, tmp,
                             expectSize ? expectSize : (unsigned long long)kMaxContentBytes,
                             status);
    if (got != 1) {
        DbgEvent(L"enterprise: download %s (HTTP %lu) - %s",
                 got == 0 ? L"refused" : L"did not complete", status,
                 OneLine(storagePath, 110).c_str());
        return got;
    }
    if (!FileMatches(tmp, hashHex, expectSize)) {
        DeleteFileW(tmp.c_str());
        DbgEvent(L"enterprise: downloaded file does not match file_size/file_hash - discarded (%s)",
                 OneLine(storagePath, 110).c_str());
        return 0;
    }
    if (!MoveFileExW(tmp.c_str(), localPath.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DWORD err = GetLastError();
        DeleteFileW(tmp.c_str());
        DbgEvent(L"enterprise: could not move the verified file into place (error %lu)", err);
        return 0;
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Download content file
// ---------------------------------------------------------------------------
bool DownloadContent(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                     const std::wstring& storagePath, const std::wstring& localPath) {
    // 동기화는 이 함수를 거치지 않는다 (행의 file_size 까지 아는 FetchVerified 를 직접
    // 부른다). 밖에서 부르는 쪽을 위해 남겨 두되, 경로를 그대로 URL 에 붙이던 예전
    // 모양으로 두지는 않는다: 이름이 곧 해시이므로 그것과 대조한다.
    std::wstring org, hash, ext;
    if (!SplitStoragePath(storagePath, org, hash, ext)) {
        DbgEvent(L"enterprise: download refused - '%s' is not <org>/<sha256>.<ext>",
                 OneLine(storagePath).c_str());
        return false;
    }
    return FetchVerified(supabaseUrl, anonKey, storagePath, hash, 0, localPath) == 1;
}

// ---------------------------------------------------------------------------
// Sync enterprise content
// ---------------------------------------------------------------------------
// 동기화는 한 번에 하나. 켤 때의 작업 스레드와 등록 창의 단추가 겹칠 수 있고,
// 둘이 같은 임시 파일에 쓰면 안 된다.
static std::mutex s_syncMx;

// Last synced paths (s_pathMx 가 지킨다 - 쓰는 쪽과 읽는 쪽이 다른 스레드일 수 있다)
static std::mutex   s_pathMx;
static std::wstring s_centerPath;
static std::wstring s_bannerPath;

EnterpriseSync SyncEnterpriseContentEx(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                                       const std::wstring& orgId,
                                       std::wstring& outCenter, std::wstring& outBanner) {
    outCenter.clear();
    outBanner.clear();
    std::lock_guard<std::mutex> syncLock(s_syncMx);

    ContentManifest manifest;
    if (!FetchManifest(supabaseUrl, anonKey, orgId, manifest)) return EnterpriseSync::RequestFailed;

    std::wstring dir = GetEnterpriseContentDir();
    std::wstring center, banner;

    for (const auto& item : manifest.items) {
        std::wstring& slot = (item.displayPos == L"center") ? center : banner;
        if (!slot.empty()) continue;      // 이 자리는 더 새 행이 이미 채웠다

        std::wstring localPath = dir + L"\\" + item.localName;

        // 이미 받아 둔 파일은 크기와 SHA-256 이 둘 다 맞을 때만 다시 쓴다. 예전에는
        // 크기만 봤고, 그래서 오류 본문이나 잘린 파일이 한 번 저장되면 크기가
        // 우연히 맞는 한 계속 쓰였다.
        if (GetFileAttributesW(localPath.c_str()) != INVALID_FILE_ATTRIBUTES &&
            FileMatches(localPath, item.fileHash, (unsigned long long)item.fileSize)) {
            slot = localPath;
            continue;
        }

        int got = FetchVerified(supabaseUrl, anonKey, item.storagePath, item.fileHash,
                                (unsigned long long)item.fileSize, localPath);
        if (got == 1) {
            slot = localPath;
        } else if (got < 0) {
            // 목록은 받았는데 파일을 받다가 서버에 닿지 못했다. 이걸 "그 자리에 쓸
            // 것이 없다" 로 읽으면 회선이 잠깐 끊긴 PC 가 잠금 화면을 비운다. 전체를
            // 실패로 돌려 부르는 쪽이 아무것도 바꾸지 않게 한다.
            return EnterpriseSync::RequestFailed;
        }
        // got == 0: 파일이 없거나 행과 다르다. 그 자리는 비워 둔다 (이유는 위에서 기록했다).
    }

    {
        std::lock_guard<std::mutex> lock(s_pathMx);
        s_centerPath = center;
        s_bannerPath = banner;
    }
    outCenter = center;
    outBanner = banner;
    return (center.empty() && banner.empty()) ? EnterpriseSync::NoContent : EnterpriseSync::Ready;
}

bool SyncEnterpriseContent(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                           const std::wstring& orgId) {
    std::wstring center, banner;
    return SyncEnterpriseContentEx(supabaseUrl, anonKey, orgId, center, banner) == EnterpriseSync::Ready;
}

std::wstring GetEnterpriseCenterPath() {
    std::lock_guard<std::mutex> lock(s_pathMx);
    return s_centerPath;
}

std::wstring GetEnterpriseBannerPath() {
    std::lock_guard<std::mutex> lock(s_pathMx);
    return s_bannerPath;
}
