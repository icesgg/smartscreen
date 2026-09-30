// publish.cpp - 새 버전을 서버에 올린다 (관리자용)
//
// 배포 묶음에 넣지 않는다. 이걸 가진 사람이 모든 PC 에 실행 파일을 밀어 넣을
// 수 있으므로, release_admins 에 든 계정으로 로그인해야만 동작한다.
// 표와 정책은 supabase/releases.sql, 설계 배경은 docs/UPDATE.md.
//
//   Publish.exe <url> <anonkey> <SmartScreen.exe> [--notes "..."] [--channel stable|beta] [--force]
//                         로그인(브라우저) -> 해시 -> Storage 업로드 -> anon 으로 다시
//                         내려받아 해시 대조 -> releases 행 upsert
//   Publish.exe --list <url> <anonkey>
//   Publish.exe --deactivate <url> <anonkey> <version>
//                         행을 끄는 것뿐이다. 이미 받은 PC 는 그대로다
//   Publish.exe --selftest
//   Publish.exe --version   이 exe 가 컴파일된 버전 (release.ps1 이 빌드가 새것인지 확인하는 데 쓴다)
//
// 버전은 이 exe 가 컴파일될 때의 client/version.h 다. 올리는 SmartScreen.exe 도
// 같은 빌드에서 나와야 한다 - 그래서 publish.bat 가 build\ 의 둘을 짝지어 부른다.
//
// wmain 인 이유: 배포 메모에 한글이 들어온다. char** argv 는 시스템 코드페이지
// (CP949)라 그대로 JSON 에 넣으면 UTF-8 이 아닌 바이트가 서버로 가고, Postgres 가
// 거절하거나 모든 PC 화면에 깨진 글자가 뜬다.
#include "../client/enterprise/auth.h"
#include "../client/version.h"
#include "../client/relver.h"

#include <winsock2.h>
#include <windows.h>
#include <clocale>
#include <cstdio>
#include <string>
#include <vector>

// JSON 문자열 리터럴로. 배포 메모에 따옴표·줄바꿈이 들어온다.
static std::string JsonQuote(const std::string& s) {
    std::string o = "\"";
    for (unsigned char c : s) {
        switch (c) {
        case '"':  o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n";  break;
        case '\r': o += "\\r";  break;
        case '\t': o += "\\t";  break;
        default:
            if (c < 0x20) { char b[8]; sprintf_s(b, "\\u%04x", c); o += b; }
            else o += (char)c;
        }
    }
    return o + "\"";
}

static std::wstring ErrOf(const std::string& body, unsigned long st) {
    for (const char* k : { "message", "msg", "error_description", "error" }) {
        std::string v;
        if (JsonGetString(body, k, v) && !v.empty()) return Utf8ToWide(v);
    }
    wchar_t b[64]; swprintf_s(b, L"HTTP %lu", st);
    return b;
}

static std::vector<std::wstring> Hdr(const std::wstring& key, const std::wstring& bearer,
                                     const wchar_t* extra = nullptr) {
    std::vector<std::wstring> h = { L"apikey: " + key, L"Authorization: Bearer " + bearer };
    if (extra) h.push_back(extra);
    return h;
}

// 로그인한 계정이 release_admins 에 있나. 없으면 아래 쓰기가 RLS 로 거절되는데,
// 그 오류는 "new row violates row-level security policy" 라 무엇을 해야 하는지
// 말해 주지 않는다. --deactivate 도 같다: 자격이 없으면 PATCH 가 0 행에 닿고
// 204 로 "성공" 한다.
static bool IsReleaseAdmin(const std::wstring& url, const std::wstring& key, const AuthSession& s) {
    unsigned long st = 0; std::string body;
    if (!SupabaseHttp(L"GET", url + L"/rest/v1/release_admins?select=user_id",
                      Hdr(key, s.accessToken), std::string(), st, body) || st < 200 || st >= 300) {
        printf("  [FAIL] release_admins 조회: %ls\n         supabase/releases.sql 을 아직 안 돌렸을 수 있다\n",
               ErrOf(body, st).c_str());
        return false;
    }
    if (body.find("\"user_id\"") == std::string::npos) {
        printf("  [FAIL] 이 계정은 release_admins 에 없다.\n"
               "         Supabase SQL Editor 에서:\n"
               "         insert into release_admins (user_id) select id from auth.users where email = '%ls';\n",
               s.email.c_str());
        return false;
    }
    printf("  [OK] release_admins 에 있다\n");
    return true;
}

// 이 exe 가 컴파일된 버전과 저장소의 client/version.h 가 같은지.
//
// do_build.bat 는 앱이 떠 있으면 링크에서 실패한다 (SmartScreen.exe 를 못 연다). 그러면
// Publish.exe 와 SmartScreen.exe 가 둘 다 낡은 채로 남고, 그대로 publish.bat 를 돌리면
// version.h 는 1.1.1 인데 서버에는 1.1.0 이 "다시" 올라간다. 실제로 그랬다 (2026-09-30).
// build\ 에서 실행될 때 ..\client\version.h 를 읽어 대조한다. 파일이 없으면(다른 곳에서
// 실행) 볼 수 없으니 넘어간다.
static bool VersionHeaderMatches(std::wstring& outHeaderVer) {
    outHeaderVer.clear();
    wchar_t self[MAX_PATH]; GetModuleFileNameW(nullptr, self, MAX_PATH);
    std::wstring dir(self); dir = dir.substr(0, dir.find_last_of(L"\\/"));
    std::wstring path = dir + L"\\..\\client\\version.h";
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return true;
    char buf[4096] = {};
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    std::string s(buf, n);
    const char* keys[3] = { "#define SS_VERSION_MAJOR ", "#define SS_VERSION_MINOR ", "#define SS_VERSION_PATCH " };
    int v[3] = { -1, -1, -1 };
    for (int i = 0; i < 3; ++i) {
        size_t p = s.find(keys[i]);
        if (p != std::string::npos) v[i] = atoi(s.c_str() + p + strlen(keys[i]));
    }
    if (v[0] < 0 || v[1] < 0 || v[2] < 0) return true;      // 모양이 달라 못 읽는다
    wchar_t b[64]; swprintf_s(b, L"%d.%d.%d", v[0], v[1], v[2]);
    outHeaderVer = b;
    return v[0] == SS_VERSION_MAJOR && v[1] == SS_VERSION_MINOR && v[2] == SS_VERSION_PATCH;
}

static int SelfTest() {
    int fail = 0;
    auto check = [&](bool ok, const char* what) {
        printf("  [%s] %s\n", ok ? "OK" : "FAIL", what);
        if (!ok) ++fail;
    };
    printf("SHA-256\n");
    {
        std::string hex;
        check(Sha256Bytes("abc", 3, hex) &&
              hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
              "FIPS 180-2 시험값 \"abc\"");
        check(Sha256Bytes("", 0, hex) &&
              hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
              "빈 입력");
    }
    printf("버전 비교 (client/relver.h)\n");
    {
        SemVer a{}, b{};
        check(ParseSemVer(L"1.10.0", a) && ParseSemVer(L"1.9.0", b) && CmpSemVer(a, b) > 0,
              "1.10.0 > 1.9.0 (문자열 비교였다면 반대)");
        check(ParseSemVer(SS_VERSION_STR, a), "version.h 의 값이 a.b.c 꼴");
        check(!ParseSemVer(L"1.2", a) && !ParseSemVer(L"1.2.3-beta", a) && !ParseSemVer(L" 1.2.3", a) &&
              !ParseSemVer(L"+1.2.3", a) && !ParseSemVer(L"1. 2.3", a) && !ParseSemVer(L"1.+2.3", a) &&
              !ParseSemVer(L"1..3", a) && !ParseSemVer(L"1.2.3.", a) && !ParseSemVer(L"1.2.3.4", a),
              "두 자리·접미사·공백·부호·빈 자리·네 자리를 거절");
        check(ParseSemVer(L"01.2.3", a) && a.major == 1 && ParseSemVer(L"1.10.0", a) && a.minor == 10,
              "앞의 0 과 두 자리 수를 숫자로 읽는다");
        SemVer n{};
        check(ParseSemVerA(SS_VERSION_STR_A, n) && ParseSemVer(SS_VERSION_STR, a) && CmpSemVer(n, a) == 0,
              "좁은 문자열과 넓은 문자열이 같은 값");
    }
    printf("JSON 메모 왕복\n");
    {
        std::string notes = WideToUtf8(L"1줄 \"따옴표\" \\ 역슬래시\n2줄\t탭 한글");
        std::string body = "{\"notes\":" + JsonQuote(notes) + "}";
        std::string back;
        check(JsonGetString(body, "notes", back) && back == notes, "따옴표·역슬래시·줄바꿈·한글이 그대로");
        std::wstring w = Utf8ToWide(back);
        check(w.find(L"한글") != std::wstring::npos, "UTF-8 로 갔다가 돌아와도 한글이 살아 있다");
    }
    printf("\n%s\n", fail == 0 ? "전부 통과" : "실패 있음");
    return fail == 0 ? 0 : 1;
}

static int List(const std::wstring& url, const std::wstring& key) {
    unsigned long st = 0; std::string body;
    if (!SupabaseHttp(L"GET", url + L"/rest/v1/releases?select=version,channel,size,active,published_at,notes&order=published_at.desc",
                      Hdr(key, key), std::string(), st, body)) {
        printf("  [FAIL] 서버에 닿지 않는다\n"); return 1;
    }
    if (st < 200 || st >= 300) { printf("  [FAIL] %ls\n  %s\n", ErrOf(body, st).c_str(), body.c_str()); return 1; }
    printf("releases (anon 으로 보이는 것 = PC 들이 보는 것)\n");
    // 객체 단위로 자른다. 메모 안의 중괄호는 문자열 안이므로 아래 스캐너가 건너뛴다.
    int depth = 0; bool inStr = false; size_t start = 0; int n = 0;
    for (size_t i = 0; i < body.size(); ++i) {
        char c = body[i];
        if (inStr) { if (c == '\\') { ++i; continue; } if (c == '"') inStr = false; continue; }
        if (c == '"') { inStr = true; continue; }
        if (c == '{') { if (depth == 0) start = i; ++depth; }
        else if (c == '}' && depth > 0 && --depth == 0) {
            std::string o = body.substr(start, i - start + 1);
            std::string v, ch, at, notes; long long size = 0;
            JsonGetString(o, "version", v); JsonGetString(o, "channel", ch);
            JsonGetString(o, "published_at", at); JsonGetString(o, "notes", notes);
            JsonGetNumber(o, "size", size);
            bool active = o.find("\"active\":true") != std::string::npos;
            printf("  %-10s %-7s %8lld B  %s  %s\n    %s\n", v.c_str(), ch.c_str(), size,
                   active ? "on " : "off", at.substr(0, 19).c_str(), notes.c_str());
            ++n;
        }
    }
    if (n == 0) printf("  (없음)\n");
    printf("이 빌드: %s\n", SS_VERSION_STR_A);
    return 0;
}

static int Deactivate(const std::wstring& url, const std::wstring& key, const std::wstring& ver) {
    SemVer sv{};
    if (!ParseSemVer(ver, sv)) { printf("  [FAIL] 버전이 a.b.c 꼴이 아니다: %ls\n", ver.c_str()); return 2; }

    AuthSession s; std::wstring err;
    printf("로그인 (브라우저)\n");
    if (!SignInWithGoogle(url, key, s, err)) { printf("  [FAIL] %ls\n", err.c_str()); return 1; }
    printf("  [OK] %ls\n", s.email.c_str());
    if (!IsReleaseAdmin(url, key, s)) return 1;

    // 바뀐 행을 돌려받아야 한다. 필터에 맞는 행이 없으면 PATCH 는 204 로 "성공" 하는데,
    // 이 명령은 잘못 올린 빌드를 급히 내리는 용도라 거짓 OK 가 실패보다 나쁘다.
    unsigned long st = 0; std::string body;
    if (!SupabaseHttp(L"PATCH", url + L"/rest/v1/releases?version=eq." + ver,
                      { L"apikey: " + key, L"Authorization: Bearer " + s.accessToken,
                        L"Content-Type: application/json", L"Prefer: return=representation" },
                      "{\"active\":false}", st, body) || st < 200 || st >= 300) {
        printf("  [FAIL] %ls\n", ErrOf(body, st).c_str()); return 1;
    }
    std::string got;
    bool inactive = body.find("\"active\":false") != std::string::npos ||
                    body.find("\"active\": false") != std::string::npos;
    if (!JsonGetString(body, "version", got) || Utf8ToWide(got) != ver || !inactive) {
        printf("  [FAIL] %ls 라는 행이 없다 (또는 바꿀 권한이 없다). --list 로 확인하라\n", ver.c_str());
        return 1;
    }
    printf("  [OK] %ls 를 껐다. 이미 받은 PC 는 그대로다 - 되돌리려면 더 높은 버전을 올려라\n", ver.c_str());
    return 0;
}

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    // printf 의 %ls 는 현재 로캘로 변환한다. 기본 "C" 로캘은 한글에서 멈추고 그 뒤
    // (줄바꿈까지)를 버린다 - 오류 문구가 "[FAIL] " 로 끝나 보인다.
    setlocale(LC_ALL, ".UTF8");

    if (argc > 1 && wcscmp(argv[1], L"--version") == 0)  { printf("%s\n", SS_VERSION_STR_A); return 0; }
    if (argc > 1 && wcscmp(argv[1], L"--selftest") == 0) return SelfTest();
    if (argc > 3 && wcscmp(argv[1], L"--list") == 0)     return List(argv[2], argv[3]);
    if (argc > 4 && wcscmp(argv[1], L"--deactivate") == 0) return Deactivate(argv[2], argv[3], argv[4]);
    // 위에 안 걸린 --옵션이 첫 인자면 인자가 모자란 것이다. 아래로 흘려 보내면 url 자리에
    // "--deactivate" 가 들어가고, 오류 문구가 anon key 를 그대로 찍는다.
    bool badFlag = (argc > 1 && (argv[1][0] == L'-' || argv[1][0] == L'/'));

    if (argc < 4 || badFlag) {
        printf("Publish.exe <url> <anonkey> <SmartScreen.exe> [--notes \"...\"] [--channel stable|beta] [--force]\n"
               "Publish.exe --list <url> <anonkey>\n"
               "Publish.exe --deactivate <url> <anonkey> <version>\n"
               "Publish.exe --selftest\n");
        return 2;
    }

    std::wstring url = argv[1], key = argv[2], exe = argv[3];
    std::wstring wnotes, wchannel = L"stable";
    bool force = false;
    for (int i = 4; i < argc; ++i) {
        if (wcscmp(argv[i], L"--notes") == 0 && i + 1 < argc) wnotes = argv[++i];
        else if (wcscmp(argv[i], L"--channel") == 0 && i + 1 < argc) wchannel = argv[++i];
        else if (wcscmp(argv[i], L"--force") == 0) force = true;
        else { printf("모르는 인자: %ls\n", argv[i]); return 2; }
    }
    if (wchannel != L"stable" && wchannel != L"beta") { printf("channel 은 stable 또는 beta\n"); return 2; }
    // PC 화면에는 첫 줄만 보이고 그것도 잘라 보인다. 너무 긴 메모는 실수다.
    if (wnotes.size() > 1000) { printf("메모가 %zu자다. 1000자 아래로 줄여라\n", wnotes.size()); return 2; }
    const std::string notes = WideToUtf8(wnotes), channel = WideToUtf8(wchannel);

    const std::string ver = SS_VERSION_STR_A;
    SemVer sv{};
    if (!ParseSemVerA(ver, sv)) { printf("[FAIL] version.h 의 값이 a.b.c 꼴이 아니다: %s\n", ver.c_str()); return 1; }
    {
        std::wstring hv;
        if (!VersionHeaderMatches(hv)) {
            printf("[FAIL] client/version.h 는 %ls 인데 이 Publish.exe 는 %s 로 빌드됐다.\n"
                   "       빌드가 낡았다. 앱을 끄고 (앱이 떠 있으면 링크가 실패한다) do_build.bat 를 다시 돌려라.\n",
                   hv.c_str(), ver.c_str());
            return 1;
        }
    }

    printf("올릴 것\n");
    std::string sha; unsigned long long size = 0;
    if (!Sha256File(exe, sha, size)) { printf("  [FAIL] 파일을 읽지 못했다: %ls\n", exe.c_str()); return 1; }
    printf("  파일    %ls\n  크기    %llu bytes\n  SHA-256 %s\n  버전    %s (%s)\n",
           exe.c_str(), size, sha.c_str(), ver.c_str(), channel.c_str());
    if (size < 100 * 1024) { printf("  [FAIL] 100 KB 도 안 된다. 진짜 SmartScreen.exe 인가?\n"); return 1; }

    printf("로그인 (브라우저가 열린다)\n");
    AuthSession s; std::wstring err;
    if (!SignInWithGoogle(url, key, s, err)) { printf("  [FAIL] %ls\n", err.c_str()); return 1; }
    printf("  [OK] %ls\n", s.email.c_str());
    if (!IsReleaseAdmin(url, key, s)) return 1;

    // 같은 버전이 이미 있으면: 같은 파일이면 행만 다시 쓰고, 다른 파일이면 멈춘다.
    // 버전을 안 올리고 exe 만 바꿔 올리면, 이미 받은 PC 와 아직 안 받은 PC 가 같은
    // 버전 번호로 다른 바이너리를 돌리게 된다. 이 확인 자체가 실패하면 진행하지
    // 않는다 - 확인 못 한 채로 덮어쓰는 것이 이 검사가 막으려는 바로 그 일이다.
    unsigned long st = 0; std::string body;
    std::wstring wver = Utf8ToWide(ver);
    if (!SupabaseHttp(L"GET", url + L"/rest/v1/releases?version=eq." + wver + L"&select=sha256",
                      Hdr(key, s.accessToken), std::string(), st, body) || st < 200 || st >= 300) {
        printf("  [FAIL] 기존 행 확인: %ls\n", ErrOf(body, st).c_str());
        return 1;
    }
    {
        std::string old;
        if (JsonGetString(body, "sha256", old)) {
            if (_stricmp(old.c_str(), sha.c_str()) == 0) {
                printf("  [..] %s 는 이미 같은 파일로 올라가 있다. 행만 갱신한다\n", ver.c_str());
            } else if (!force) {
                printf("  [FAIL] %s 가 이미 다른 파일로 올라가 있다 (sha %s...).\n"
                       "         client/version.h 를 올려서 다시 빌드하라. 정말 덮어쓰려면 --force\n",
                       ver.c_str(), old.substr(0, 12).c_str());
                return 1;
            } else {
                printf("  [!!] %s 를 --force 로 덮어쓴다. 이 버전을 승인한 조직들은 이제 다른 바이너리를 받는다\n", ver.c_str());
            }
        }
    }

    // Storage 업로드
    std::string bytes;
    {
        FILE* f = nullptr;
        if (_wfopen_s(&f, exe.c_str(), L"rb") != 0 || !f) { printf("  [FAIL] 파일 열기\n"); return 1; }
        bytes.resize((size_t)size);
        size_t n = fread(&bytes[0], 1, bytes.size(), f);
        fclose(f);
        if (n != bytes.size()) { printf("  [FAIL] 파일 읽기\n"); return 1; }
    }
    std::wstring storagePath = wver + L"/SmartScreen.exe";
    printf("Storage 업로드  releases/%ls\n", storagePath.c_str());
    if (!SupabaseHttp(L"POST", url + L"/storage/v1/object/releases/" + storagePath,
                      { L"apikey: " + key, L"Authorization: Bearer " + s.accessToken,
                        L"Content-Type: application/octet-stream", L"x-upsert: true" },
                      bytes, st, body) || st < 200 || st >= 300) {
        printf("  [FAIL] %ls\n  %s\n", ErrOf(body, st).c_str(), body.substr(0, 300).c_str());
        return 1;
    }
    printf("  [OK]\n");

    // PC 가 받는 길 그대로 - anon 키만으로 - 다시 내려받아 해시를 본다. 이게 통과하면
    // 버킷 정책과 파일 둘 다 맞는 것이고, 실패하면 PC 들이 실패하기 전에 여기서 안다.
    printf("anon 으로 다시 내려받아 대조\n");
    std::string back;
    if (!SupabaseHttp(L"GET", url + L"/storage/v1/object/authenticated/releases/" + storagePath,
                      Hdr(key, key), std::string(), st, back) || st < 200 || st >= 300) {
        printf("  [FAIL] anon 으로 못 받는다 (%ls). releases 버킷 select 정책을 보라\n", ErrOf(back, st).c_str());
        return 1;
    }
    std::string sha2;
    Sha256Bytes(back.data(), back.size(), sha2);
    if (back.size() != bytes.size() || sha2 != sha) {
        printf("  [FAIL] 받은 것이 다르다 (%zu bytes, sha %s...)\n", back.size(), sha2.substr(0, 12).c_str());
        return 1;
    }
    printf("  [OK] %zu bytes, 해시 일치\n", back.size());

    // 행 upsert. 같은 version 이 있으면 덮어쓴다 (merge-duplicates). 없으면 409 가 난다.
    std::string row = "{\"version\":" + JsonQuote(ver) +
                      ",\"channel\":" + JsonQuote(channel) +
                      ",\"storage_path\":" + JsonQuote(WideToUtf8(storagePath)) +
                      ",\"sha256\":" + JsonQuote(sha) +
                      ",\"size\":" + std::to_string(size) +
                      ",\"notes\":" + JsonQuote(notes) +
                      ",\"active\":true}";
    printf("releases 행\n");
    if (!SupabaseHttp(L"POST", url + L"/rest/v1/releases",
                      { L"apikey: " + key, L"Authorization: Bearer " + s.accessToken,
                        L"Content-Type: application/json",
                        L"Prefer: resolution=merge-duplicates,return=representation" },
                      row, st, body) || st < 200 || st >= 300) {
        printf("  [FAIL] %ls\n  %s\n", ErrOf(body, st).c_str(), body.substr(0, 300).c_str());
        return 1;
    }
    std::string gotSha;
    if (!JsonGetString(body, "sha256", gotSha) || _stricmp(gotSha.c_str(), sha.c_str()) != 0) {
        printf("  [FAIL] 행이 돌아왔는데 해시가 다르다:\n  %s\n", body.substr(0, 300).c_str());
        return 1;
    }
    printf("  [OK] %s 게시됨 (%s)\n", ver.c_str(), channel.c_str());
    printf("\n이제 PC 들이 한 시간 안에 알아챈다 (간단 창의 버전 단추를 누르면 바로).\n"
           "기업 PC 는 관리자가 대시보드에서 이 버전을 승인해야 받는다.\n");
    return 0;
}
