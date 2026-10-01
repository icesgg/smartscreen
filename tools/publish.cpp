// publish.cpp - 새 버전을 서버에 올린다 (관리자용)
//
// 배포 묶음에 넣지 않는다. 이걸 가진 사람이 모든 PC 에 실행 파일을 밀어 넣을
// 수 있으므로, release_admins 에 든 계정으로 로그인해야만 동작한다.
// 표와 정책은 supabase/releases.sql (Mac 표는 supabase/mac_releases.sql), 설계 배경은
// docs/UPDATE.md 와 docs/MAC.md.
//
//   Publish.exe <url> <anonkey> <SmartScreen.exe> [--notes "..."] [--channel stable|beta] [--force]
//                         로그인(브라우저) -> 해시 -> Storage 업로드 -> anon 으로 다시
//                         내려받아 해시 대조 -> releases 행 upsert
//   Publish.exe <url> <anonkey> --platform mac --file <SmartScreen-mac.zip> [--notes "..."] [--channel stable|beta] [--force]
//                         같은 흐름으로 Mac 판(CI 가 만든 zip)을 mac_releases 에 올린다.
//                         로그인 전에 zip 안의 Info.plist 를 풀어 번호와 번들 id 를 본다
//   Publish.exe --list <url> <anonkey> [--platform windows|mac]
//   Publish.exe --deactivate <url> <anonkey> <version> [--platform windows|mac]
//                         행을 끄는 것뿐이다. 이미 받은 PC 는 그대로다
//   Publish.exe --selftest
//   Publish.exe --version   이 exe 가 컴파일된 버전 (release.ps1 이 빌드가 새것인지 확인하는 데 쓴다)
//
// --platform 을 안 주면 windows 다 - 예전과 똑같이 돈다.
//
// 버전은 이 exe 가 컴파일될 때의 client/version.h 다. 올리는 SmartScreen.exe 도
// 같은 빌드에서 나와야 한다 - 그래서 publish.bat 가 build\ 의 둘을 짝지어 부른다.
// Mac zip 은 이 PC 에서 빌드하지 않는다 (CI 의 macOS 러너가 같은 version.h 로 만든다).
// 그래서 짝이 맞는지는 zip 안의 Info.plist 로 본다 (CheckMacZip).
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
#include <cstdint>
#include <cstdio>
#include <cstring>
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

// ---------------------------------------------------------------------------
// 플랫폼: 어느 표에, 버킷의 어느 경로에 올리나
// ---------------------------------------------------------------------------
// Mac 판은 releases 가 아니라 mac_releases 에 올린다. 이미 깔린 Windows 1.1.x 는 자기
// 채널의 켜진 releases 행을 플랫폼을 묻지 않고 전부 SmartScreen.exe 로 받는다 (그 조회는
// 깔린 exe 안에 박혀 있어 고칠 수 없다). 같은 표에 Mac zip 이 들어가면 해시까지 맞으므로
// Windows PC 들이 zip 을 자기 exe 자리에 놓고, 실행에 실패하고, 화면을 지키는 프로그램이
// 없어진다. 버전 번호도 두 판이 같다 (client/version.h 하나) - 기본키가 version 이라 한
// 표에는 둘이 같이 들어가지도 못한다. 버킷은 같은 'releases' 이고 Mac 은 mac/ 아래다
// (버킷의 쓰기 정책은 release_admins 만 보고 경로는 안 본다).
struct Platform {
    bool           mac;
    const wchar_t* table;      // PostgREST 표 이름
};
static const Platform kWindows = { false, L"releases" };
static const Platform kMac     = { true,  L"mac_releases" };

static bool ParsePlatform(const wchar_t* v, const Platform*& out) {
    if (_wcsicmp(v, L"windows") == 0) { out = &kWindows; return true; }
    if (_wcsicmp(v, L"mac") == 0)     { out = &kMac;     return true; }
    return false;
}

// 버킷 안의 경로. 서버의 check 와 모양이 같아야 한다 (supabase/mac_releases.sql):
//   releases.storage_path      ^[0-9]+\.[0-9]+\.[0-9]+/SmartScreen\.exe$
//   mac_releases.storage_path  ^mac/[0-9]+\.[0-9]+\.[0-9]+/SmartScreen-mac\.zip$
static std::wstring StoragePathFor(const Platform& p, const std::wstring& ver) {
    return p.mac ? L"mac/" + ver + L"/SmartScreen-mac.zip" : ver + L"/SmartScreen.exe";
}

// PC 가 행의 경로를 받는 규칙 (client/update.cpp 의 ValidStoragePath, Mac 앱도 같다).
// 여기서 만든 경로가 이걸 통과하지 못하면 모든 PC 가 그 행을 "malformed" 로 건너뛴다.
static bool ClientAcceptsPath(const std::wstring& p) {
    if (p.empty() || p.size() > 200) return false;
    if (p.front() == L'/' || p.find(L"..") != std::wstring::npos) return false;
    for (wchar_t c : p) {
        bool ok = (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
                  c == L'.' || c == L'_' || c == L'-' || c == L'/';
        if (!ok) return false;
    }
    return true;
}

// 표가 없을 때 PostgREST 가 주는 코드 (예전 판은 Postgres 의 42P01 을 그대로 준다).
// Mac 표는 마이그레이션을 따로 돌려야 생기므로, 그때는 무엇을 돌리라고 말한다.
static bool TableMissing(const std::string& body) {
    return body.find("PGRST205") != std::string::npos || body.find("42P01") != std::string::npos;
}

static void MacTableHint(const Platform& p, const std::string& body) {
    if (p.mac && TableMissing(body))
        printf("         mac_releases 표가 없다. supabase/mac_releases.sql 을 SQL Editor 에서 돌려라\n");
}

// ---------------------------------------------------------------------------
// Mac zip 들여다보기
// ---------------------------------------------------------------------------
// 올리기 전에 zip 안의 Info.plist 를 직접 풀어 번호와 번들 id 를 본다. Windows 쪽은
// version.h 와 이 exe 의 번호를 대조해 낡은 빌드를 막는다 (VersionHeaderMatches) - Mac
// zip 은 이 PC 가 아니라 CI 가 만든 것이라 같은 확인을 zip 안에서 한다. 다른 번호의 zip 이
// 올라가면 모든 Mac 이 그걸 받아 풀고, 적용기가 "버전이 다르다" 로 거절하고, 예전 앱을 다시
// 띄운다 - Mac 마다 한 번씩. 보고(release.ps1 이 본 VERSION 파일)가 아니라 결과물을 본다.
//
// Windows 에는 deflate 를 푸는 API 가 없어서 작은 inflate 를 둔다 (RFC 1951; zlib 의
// contrib/puff 와 같은 구조). 푸는 것은 Info.plist 한 파일(몇 KB)뿐이다. 모양이 이상하면
// 전부 "거절" 쪽으로 끝난다 - 여기서 틀려도 올라가지 않을 뿐, 잘못 올라가지는 않는다.
namespace {

struct InflateState {
    const unsigned char* in = nullptr;
    size_t inLen = 0, inPos = 0;
    uint32_t bitBuf = 0;
    int bitCnt = 0;
    bool eof = false;               // 입력이 모자랐다 - 결과를 믿지 않는다
    std::string out;
    size_t outMax = 0;
};

const int kMaxBits = 15;            // deflate 부호의 최대 길이

struct Huff {
    short count[kMaxBits + 1];      // 길이마다 부호 개수
    short symbol[288];              // 부호 순서대로 늘어선 기호
};

int InfBits(InflateState& s, int need) {
    uint32_t val = s.bitBuf;
    while (s.bitCnt < need) {
        if (s.inPos >= s.inLen) { s.eof = true; return 0; }
        val |= (uint32_t)s.in[s.inPos++] << s.bitCnt;
        s.bitCnt += 8;
    }
    s.bitBuf = val >> need;
    s.bitCnt -= need;
    return (int)(val & ((1u << need) - 1));
}

int InfStored(InflateState& s) {
    s.bitBuf = 0; s.bitCnt = 0;                     // 바이트 경계로
    if (s.inPos + 4 > s.inLen) return 2;
    unsigned len  = s.in[s.inPos] | (s.in[s.inPos + 1] << 8);
    unsigned nlen = s.in[s.inPos + 2] | (s.in[s.inPos + 3] << 8);
    s.inPos += 4;
    if ((len ^ 0xFFFFu) != nlen) return -2;
    if (s.inPos + len > s.inLen) return 2;
    if (s.out.size() + len > s.outMax) return 1;
    s.out.append((const char*)s.in + s.inPos, len);
    s.inPos += len;
    return 0;
}

int InfDecode(InflateState& s, const Huff& h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len <= kMaxBits; ++len) {
        code |= InfBits(s, 1);
        if (s.eof) return -10;
        int count = h.count[len];
        if (code - count < first) return h.symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    return -10;                                     // 없는 부호
}

// 길이 목록으로 정규 허프만 표를 만든다. 0 = 완전한 부호, 양수 = 덜 찬 부호, 음수 = 넘친 부호.
int InfConstruct(Huff& h, const short* length, int n) {
    for (int len = 0; len <= kMaxBits; ++len) h.count[len] = 0;
    for (int sym = 0; sym < n; ++sym) h.count[length[sym]]++;
    if (h.count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= kMaxBits; ++len) {
        left <<= 1;
        left -= h.count[len];
        if (left < 0) return left;
    }
    short offs[kMaxBits + 1];
    offs[1] = 0;
    for (int len = 1; len < kMaxBits; ++len) offs[len + 1] = (short)(offs[len] + h.count[len]);
    for (int sym = 0; sym < n; ++sym)
        if (length[sym] != 0) h.symbol[offs[length[sym]]++] = (short)sym;
    return left;
}

int InfCodes(InflateState& s, const Huff& lencode, const Huff& distcode) {
    static const short lens[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    static const short lext[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
    static const short dists[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                     257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                     8193, 12289, 16385, 24577 };
    static const short dext[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
    int symbol;
    do {
        symbol = InfDecode(s, lencode);
        if (symbol < 0) return symbol;
        if (symbol < 256) {
            if (s.out.size() >= s.outMax) return 1;
            s.out.push_back((char)symbol);
        } else if (symbol > 256) {
            symbol -= 257;
            if (symbol >= 29) return -10;
            int len = lens[symbol] + InfBits(s, lext[symbol]);
            int ds = InfDecode(s, distcode);
            if (ds < 0) return ds;
            if (ds >= 30) return -10;
            size_t dist = (size_t)(dists[ds] + InfBits(s, dext[ds]));
            if (s.eof) return 2;
            if (dist > s.out.size()) return -11;    // 쓰기 전 자리를 가리킨다
            if (s.out.size() + (size_t)len > s.outMax) return 1;
            for (int k = 0; k < len; ++k) s.out.push_back(s.out[s.out.size() - dist]);
        }
        if (s.eof) return 2;
    } while (symbol != 256);                        // 256 = 블록 끝
    return 0;
}

int InfFixed(InflateState& s) {
    Huff lencode, distcode;
    short lengths[288];
    int sym = 0;
    for (; sym < 144; ++sym) lengths[sym] = 8;
    for (; sym < 256; ++sym) lengths[sym] = 9;
    for (; sym < 280; ++sym) lengths[sym] = 7;
    for (; sym < 288; ++sym) lengths[sym] = 8;
    InfConstruct(lencode, lengths, 288);
    for (sym = 0; sym < 30; ++sym) lengths[sym] = 5;
    InfConstruct(distcode, lengths, 30);
    return InfCodes(s, lencode, distcode);
}

int InfDynamic(InflateState& s) {
    static const short order[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    short lengths[286 + 30];
    Huff lencode, distcode;
    int nlen  = InfBits(s, 5) + 257;
    int ndist = InfBits(s, 5) + 1;
    int ncode = InfBits(s, 4) + 4;
    if (s.eof) return 2;
    if (nlen > 286 || ndist > 30) return -3;
    int index = 0;
    for (; index < ncode; ++index) lengths[order[index]] = (short)InfBits(s, 3);
    for (; index < 19; ++index) lengths[order[index]] = 0;
    if (s.eof) return 2;
    if (InfConstruct(lencode, lengths, 19) != 0) return -4;     // 길이 부호는 꽉 차야 한다
    index = 0;
    while (index < nlen + ndist) {
        int symbol = InfDecode(s, lencode);
        if (symbol < 0) return symbol;
        if (symbol < 16) {
            lengths[index++] = (short)symbol;
        } else {
            short len = 0;
            if (symbol == 16) {
                if (index == 0) return -5;
                len = lengths[index - 1];
                symbol = 3 + InfBits(s, 2);
            } else if (symbol == 17) {
                symbol = 3 + InfBits(s, 3);
            } else {
                symbol = 11 + InfBits(s, 7);
            }
            if (s.eof) return 2;
            if (index + symbol > nlen + ndist) return -6;
            while (symbol--) lengths[index++] = len;
        }
    }
    if (lengths[256] == 0) return -9;                           // 블록 끝 부호가 없다
    int err = InfConstruct(lencode, lengths, nlen);
    if (err && (err < 0 || nlen != lencode.count[0] + lencode.count[1])) return -7;
    err = InfConstruct(distcode, lengths + nlen, ndist);
    if (err && (err < 0 || ndist != distcode.count[0] + distcode.count[1])) return -8;
    return InfCodes(s, lencode, distcode);
}

// raw deflate (zip 의 압축 방식 8) 를 푼다. outMax 를 넘기면 실패다.
bool Inflate(const unsigned char* in, size_t inLen, size_t outMax, std::string& out) {
    InflateState s;
    s.in = in; s.inLen = inLen; s.outMax = outMax;
    int last;
    do {
        last = InfBits(s, 1);
        int type = InfBits(s, 2);
        if (s.eof) return false;
        int err = type == 0 ? InfStored(s) : type == 1 ? InfFixed(s) : type == 2 ? InfDynamic(s) : -1;
        if (err != 0) return false;
    } while (!last);
    out.swap(s.out);
    return true;
}

uint32_t Crc32(const void* data, size_t n) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    const unsigned char* p = (const unsigned char*)data;
    for (size_t i = 0; i < n; ++i) c = table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

uint16_t Rd16(const std::string& b, size_t p) {
    return (uint16_t)((unsigned char)b[p] | ((unsigned char)b[p + 1] << 8));
}
uint32_t Rd32(const std::string& b, size_t p) {
    return (uint32_t)(unsigned char)b[p] | ((uint32_t)(unsigned char)b[p + 1] << 8) |
           ((uint32_t)(unsigned char)b[p + 2] << 16) | ((uint32_t)(unsigned char)b[p + 3] << 24);
}

struct ZipEntry {
    std::string name;
    uint16_t method = 0;
    uint32_t crc = 0, csize = 0, usize = 0, localOff = 0;
};

// 중앙 디렉터리를 읽는다. 크기는 로컬 헤더가 아니라 여기 것을 믿는다 - ditto 같은 도구는
// 로컬 헤더에 0 을 적고 데이터 뒤의 서술자(data descriptor)에 진짜 값을 둔다.
bool ZipCentralDir(const std::string& z, std::vector<ZipEntry>& out, std::string& why) {
    out.clear();
    if (z.size() < 22) { why = "zip 이 너무 짧다"; return false; }
    size_t minPos = z.size() > 22 + 65535 ? z.size() - 22 - 65535 : 0;   // 끝 표지 + 주석(최대 64 KB)
    size_t eocd = std::string::npos;
    for (size_t p = z.size() - 22; ; --p) {
        if (Rd32(z, p) == 0x06054b50) { eocd = p; break; }
        if (p == minPos) break;
    }
    if (eocd == std::string::npos) { why = "zip 끝 표지(EOCD)가 없다"; return false; }
    uint16_t count = Rd16(z, eocd + 10);
    uint32_t cdSize = Rd32(z, eocd + 12), cdOff = Rd32(z, eocd + 16);
    if (count == 0xFFFF || cdSize == 0xFFFFFFFFu || cdOff == 0xFFFFFFFFu) { why = "zip64 는 읽지 못한다"; return false; }
    if ((uint64_t)cdOff + cdSize > eocd) { why = "중앙 디렉터리 위치가 이상하다"; return false; }
    size_t p = cdOff;
    for (unsigned i = 0; i < count; ++i) {
        if (p + 46 > eocd || Rd32(z, p) != 0x02014b50) { why = "중앙 디렉터리 항목이 이상하다"; return false; }
        ZipEntry e;
        e.method = Rd16(z, p + 10);
        e.crc = Rd32(z, p + 16); e.csize = Rd32(z, p + 20); e.usize = Rd32(z, p + 24);
        size_t nlen = Rd16(z, p + 28), xlen = Rd16(z, p + 30), clen = Rd16(z, p + 32);
        e.localOff = Rd32(z, p + 42);
        if (p + 46 + nlen + xlen + clen > eocd) { why = "중앙 디렉터리 항목이 끝 표지를 넘는다"; return false; }
        e.name.assign(z, p + 46, nlen);
        out.push_back(e);
        p += 46 + nlen + xlen + clen;
    }
    return true;
}

bool ZipExtract(const std::string& z, const ZipEntry& e, size_t maxOut, std::string& out, std::string& why) {
    size_t lh = e.localOff;
    if ((uint64_t)lh + 30 > z.size() || Rd32(z, lh) != 0x04034b50) { why = "로컬 헤더가 이상하다"; return false; }
    size_t data = lh + 30 + Rd16(z, lh + 26) + Rd16(z, lh + 28);
    if ((uint64_t)data + e.csize > z.size()) { why = "데이터가 zip 밖으로 나간다"; return false; }
    if (e.usize > maxOut) { why = "풀면 너무 크다"; return false; }
    if (e.method == 0) {
        if (e.csize != e.usize) { why = "저장된 항목의 크기가 서로 다르다"; return false; }
        out.assign(z, data, e.csize);
    } else if (e.method == 8) {
        if (!Inflate((const unsigned char*)z.data() + data, e.csize, maxOut, out)) { why = "deflate 를 풀지 못했다"; return false; }
    } else {
        why = "압축 방식 " + std::to_string(e.method) + " 은 읽지 못한다";
        return false;
    }
    if (out.size() != e.usize || Crc32(out.data(), out.size()) != e.crc) {
        why = "풀린 내용의 크기나 CRC 가 zip 의 기록과 다르다";
        return false;
    }
    return true;
}

// <key>K</key> 바로 다음의 <string>V</string>. build_app.sh 의 Info.plist 는 XML 이다
// (sed 로 번호를 넣고 plutil -lint 로 보기만 한다).
bool PlistString(const std::string& xml, const char* key, std::string& out) {
    out.clear();
    std::string k = std::string("<key>") + key + "</key>";
    size_t p = xml.find(k);
    if (p == std::string::npos) return false;
    p += k.size();
    while (p < xml.size() && (xml[p] == ' ' || xml[p] == '\t' || xml[p] == '\r' || xml[p] == '\n')) ++p;
    if (xml.compare(p, 8, "<string>") != 0) return false;
    p += 8;
    size_t e = xml.find("</string>", p);
    if (e == std::string::npos) return false;
    out = xml.substr(p, e - p);
    return true;
}

// 이진 plist (bplist00) 의 맨 위 dict 에서 문자열 값 하나. build_app.sh 는 Info.plist 를 XML 로
// 만들고 PlistBuddy 로 아이콘 키를 더한다 - PlistBuddy 는 원래 형식을 지키는 것으로 알지만 이
// PC 에서는 CI 의 결과물을 미리 볼 수 없다. 형식 하나 때문에 게시가 막히지 않게 둘 다 읽는다.
// 키와 값은 ASCII 다 (UTF-16 문자열은 ASCII 밖의 글자를 '?' 로 읽는다 - 같다고 나오지 않는다).
bool BplistString(const std::string& b, const char* key, std::string& out) {
    out.clear();
    if (b.size() < 8 + 32 || b.compare(0, 8, "bplist00") != 0) return false;
    const size_t t = b.size() - 32;                         // 끝의 32 바이트가 trailer
    const unsigned offSize = (unsigned char)b[t + 6], refSize = (unsigned char)b[t + 7];
    auto be = [&](uint64_t p, unsigned n, uint64_t& v) -> bool {
        if (n == 0 || n > 8 || p + n > b.size()) return false;
        v = 0;
        for (unsigned i = 0; i < n; ++i) v = (v << 8) | (unsigned char)b[(size_t)p + i];
        return true;
    };
    uint64_t numObj = 0, top = 0, tableOff = 0;
    if (!be(t + 8, 8, numObj) || !be(t + 16, 8, top) || !be(t + 24, 8, tableOff)) return false;
    if (offSize == 0 || offSize > 8 || refSize == 0 || refSize > 8) return false;
    if (numObj == 0 || numObj > 100000 || top >= numObj || tableOff < 8 || tableOff + numObj * offSize > t) return false;
    auto objOff = [&](uint64_t ref, uint64_t& o) -> bool {
        return ref < numObj && be(tableOff + ref * offSize, offSize, o) && o >= 8 && o < tableOff;
    };
    // 길이는 표지의 아래 4 비트. 0xF 면 바로 뒤의 정수 객체(0x1n, 2^n 바이트)가 길이다.
    auto count = [&](uint64_t& o, uint64_t& n) -> bool {
        unsigned info = (unsigned char)b[(size_t)o] & 0x0F;
        ++o;
        if (info != 0x0F) { n = info; return true; }
        if (o >= tableOff) return false;
        unsigned char m = (unsigned char)b[(size_t)o];
        if ((m >> 4) != 0x1 || (m & 0x0F) > 3) return false;
        unsigned bytes = 1u << (m & 0x0F);
        ++o;
        if (!be(o, bytes, n)) return false;
        o += bytes;
        return true;
    };
    auto str = [&](uint64_t ref, std::string& s) -> bool {
        uint64_t o = 0, n = 0;
        if (!objOff(ref, o)) return false;
        unsigned type = (unsigned char)b[(size_t)o] >> 4;
        if (!count(o, n)) return false;
        if (type == 0x5) {                                  // ASCII
            if (n > tableOff || o + n > tableOff) return false;
            s.assign(b, (size_t)o, (size_t)n);
            return true;
        }
        if (type == 0x6) {                                  // UTF-16BE
            if (n > tableOff || o + 2 * n > tableOff) return false;
            s.clear();
            for (uint64_t i = 0; i < n; ++i) {
                unsigned c = ((unsigned char)b[(size_t)(o + 2 * i)] << 8) | (unsigned char)b[(size_t)(o + 2 * i + 1)];
                s += (c < 0x80 ? (char)c : '?');
            }
            return true;
        }
        return false;
    };
    uint64_t o = 0, n = 0;
    if (!objOff(top, o) || ((unsigned char)b[(size_t)o] >> 4) != 0xD) return false;   // 맨 위는 dict
    if (!count(o, n) || n > numObj || o + 2 * n * refSize > tableOff) return false;
    for (uint64_t i = 0; i < n; ++i) {
        uint64_t kr = 0, vr = 0;
        if (!be(o + i * refSize, refSize, kr) || !be(o + (n + i) * refSize, refSize, vr)) return false;
        std::string k;
        if (str(kr, k) && k == key) return str(vr, out);
    }
    return false;
}

const char kMacPlistPath[] = "SmartScreen.app/Contents/Info.plist";
const char kMacExePath[]   = "SmartScreen.app/Contents/MacOS/SmartScreen";
const char kMacBundleId[]  = "com.icesgg.smartscreen";

// build_app.sh 가 만드는 zip: 맨 위에 SmartScreen.app (와 설치 안내.txt). Mac 의 적용기도
// 풀린 자리의 SmartScreen.app 을 찾는다. 번들 id 와 번호가 이 빌드와 같아야 한다.
bool CheckMacZip(const std::string& z, const std::string& ver, std::string& why) {
    if (z.size() < 4 || z.compare(0, 4, "PK\x03\x04", 4) != 0) { why = "zip 이 아니다 (PK 로 시작하지 않는다)"; return false; }
    std::vector<ZipEntry> ents;
    if (!ZipCentralDir(z, ents, why)) return false;
    const ZipEntry* plist = nullptr;
    bool haveExe = false;
    for (const ZipEntry& e : ents) {
        if (e.name == kMacPlistPath) plist = &e;
        else if (e.name == kMacExePath && e.usize > 0) haveExe = true;
    }
    if (!plist || !haveExe) {
        why = std::string("zip 맨 위에 ") + kMacPlistPath + " / " + kMacExePath + " 가 없다";
        return false;
    }
    std::string xml;
    if (!ZipExtract(z, *plist, 1 << 20, xml, why)) { why = "Info.plist: " + why; return false; }
    const bool binary = xml.compare(0, 8, "bplist00") == 0;
    auto get = [&](const char* k, std::string& v) { return binary ? BplistString(xml, k, v) : PlistString(xml, k, v); };
    std::string id, sv;
    if (!get("CFBundleIdentifier", id) || id != kMacBundleId) {
        why = "Info.plist 의 CFBundleIdentifier 가 " + std::string(kMacBundleId) + " 가 아니다 ('" + id + "')";
        return false;
    }
    if (!get("CFBundleShortVersionString", sv) || sv != ver) {
        why = "zip 안의 앱은 '" + sv + "' 이다. 이 Publish.exe 는 " + ver +
              " 다 - CI 가 다른 커밋을 빌드했거나 다른 zip 이다";
        return false;
    }
    return true;
}

// 아래는 --selftest 만 쓴다.
std::string HexBytes(const char* hex) {
    std::string o;
    for (size_t i = 0; hex[i] && hex[i + 1]; i += 2) {
        auto nib = [](char c) { return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10; };
        o += (char)((nib(hex[i]) << 4) | nib(hex[i + 1]));
    }
    return o;
}

struct TestEntry { const char* name; unsigned method; std::string data; std::string plain; uint32_t crcXor; };

std::string MakeTestZip(const std::vector<TestEntry>& es) {
    auto w16 = [](std::string& b, unsigned v) { b += (char)(v & 0xFF); b += (char)((v >> 8) & 0xFF); };
    auto w32 = [](std::string& b, uint32_t v) { for (int i = 0; i < 4; ++i) b += (char)((v >> (8 * i)) & 0xFF); };
    std::string z, cd;
    for (const TestEntry& e : es) {
        uint32_t off = (uint32_t)z.size();
        uint32_t crc = Crc32(e.plain.data(), e.plain.size()) ^ e.crcXor;
        unsigned nlen = (unsigned)strlen(e.name);
        w32(z, 0x04034b50); w16(z, 20); w16(z, 0); w16(z, e.method); w16(z, 0); w16(z, 0);
        w32(z, crc); w32(z, (uint32_t)e.data.size()); w32(z, (uint32_t)e.plain.size());
        w16(z, nlen); w16(z, 0); z += e.name; z += e.data;
        w32(cd, 0x02014b50); w16(cd, 20); w16(cd, 20); w16(cd, 0); w16(cd, e.method); w16(cd, 0); w16(cd, 0);
        w32(cd, crc); w32(cd, (uint32_t)e.data.size()); w32(cd, (uint32_t)e.plain.size());
        w16(cd, nlen); w16(cd, 0); w16(cd, 0); w16(cd, 0); w16(cd, 0); w32(cd, 0); w32(cd, off);
        cd += e.name;
    }
    uint32_t cdOff = (uint32_t)z.size();
    z += cd;
    w32(z, 0x06054b50); w16(z, 0); w16(z, 0); w16(z, (unsigned)es.size()); w16(z, (unsigned)es.size());
    w32(z, (uint32_t)cd.size()); w32(z, cdOff); w16(z, 0);
    return z;
}

// zlib (raw deflate, level 9) 이 만든 시험값. 동적 허프만 블록이다.
const char kSamplePlist[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n"
    "\t<key>CFBundleExecutable</key>\n\t<string>SmartScreen</string>\n"
    "\t<key>CFBundleIdentifier</key>\n\t<string>com.icesgg.smartscreen</string>\n"
    "\t<key>CFBundleShortVersionString</key>\n\t<string>1.2.3</string>\n"
    "\t<key>CFBundleVersion</key>\n\t<string>1.2.3</string>\n</dict>\n</plist>\n";
const char kSamplePlistDeflate[] =
    "85903d0fc220108667fb2b1a76c1eae24069a2b18933ea5ee16c89140c5053ffbdfd5a6ca2aeefbdcf93bba3"
    "595bebf809ce2b6b5294e0158ac1082b952953743ee5cb2dca58441f5af9f0d9eb52a94460d182dee1c5f6f9"
    "ae3152c3a105d184e2aa81923eefc63eb84ec7785db8c0850330944cd90c3e4a3041dd14b8392c6c8d95005f"
    "96d8f71effd3c32bebc265dc960f8db92fc16bbcf9864fe41f8692f17e4a86efb0e80d";
const uint32_t kSamplePlistCrc = 0x689027a0u;
// 고정 허프만 블록: "SmartScreen SmartScreen SmartScreen\n"
const char kFixedDeflate[] = "0bce4d2c2a094e2e4a4dcd5308c6cee60200";
// Python plistlib 이 만든 이진 plist: CFBundleIdentifier, CFBundleShortVersionString=1.2.3,
// CFBundleExecutable, LSUIElement=true, 한글 NSBluetoothAlwaysUsageDescription (UTF-16).
const char kSampleBplist[] =
    "62706c6973743030d50102030405060708090a5f1012434642756e646c6545786563757461626c655f101243"
    "4642756e646c654964656e7469666965725f101a434642756e646c6553686f727456657273696f6e53747269"
    "6e675b4c535549456c656d656e745f10214e53426c7565746f6f7468416c7761797355736167654465736372"
    "697074696f6e5b536d61727453637265656e5f1016636f6d2e6963657367672e736d61727473637265656e55"
    "312e322e33096cc790b9ac0020be44c6c0c7440020c54cc544cc44b824ace00813283d5a668a96afb5b60000"
    "000000000101000000000000000b000000000000000000000000000000cf";

} // namespace

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
    printf("저장 경로 (서버의 check, PC 의 ValidStoragePath)\n");
    {
        check(StoragePathFor(kWindows, L"1.2.3") == L"1.2.3/SmartScreen.exe", "Windows: <버전>/SmartScreen.exe");
        check(StoragePathFor(kMac, L"1.2.3") == L"mac/1.2.3/SmartScreen-mac.zip", "Mac: mac/<버전>/SmartScreen-mac.zip");
        check(ClientAcceptsPath(StoragePathFor(kWindows, L"1.10.0")) && ClientAcceptsPath(StoragePathFor(kMac, L"1.10.0")),
              "두 경로 모두 PC 가 받는 모양 (허용 글자, 200자 이하, '..' 없음)");
        const Platform* p = nullptr;
        check(ParsePlatform(L"mac", p) && p->mac && ParsePlatform(L"Windows", p) && !p->mac && !ParsePlatform(L"linux", p),
              "--platform 은 windows / mac 만");
    }
    printf("Mac zip 들여다보기 (inflate, zip, Info.plist)\n");
    {
        std::string out;
        const unsigned char stored[] = { 0x01, 0x03, 0x00, 0xFC, 0xFF, 'a', 'b', 'c' };
        check(Inflate(stored, sizeof(stored), 1024, out) && out == "abc", "저장 블록");
        std::string fixedIn = HexBytes(kFixedDeflate);
        check(Inflate((const unsigned char*)fixedIn.data(), fixedIn.size(), 1024, out) &&
              out == "SmartScreen SmartScreen SmartScreen\n", "고정 허프만 블록");
        std::string dyn = HexBytes(kSamplePlistDeflate);
        check(Inflate((const unsigned char*)dyn.data(), dyn.size(), 4096, out) && out == kSamplePlist,
              "동적 허프만 블록 (zlib 이 만든 것)");
        check(Crc32(kSamplePlist, strlen(kSamplePlist)) == kSamplePlistCrc && Crc32("", 0) == 0, "CRC-32");
        check(!Inflate((const unsigned char*)dyn.data(), dyn.size() / 2, 4096, out) &&
              !Inflate((const unsigned char*)dyn.data(), dyn.size(), 100, out),
              "잘린 입력과 상한을 넘는 출력은 실패");

        const std::string plain(kSamplePlist), bin(16, 'x');
        std::string why;
        std::string good = MakeTestZip({ { kMacPlistPath, 8, dyn, plain, 0 }, { kMacExePath, 0, bin, bin, 0 } });
        check(CheckMacZip(good, "1.2.3", why), "번호와 번들 id 가 맞는 zip 을 받는다");
        check(!CheckMacZip(good, "1.2.4", why), "다른 번호의 zip 은 거절");
        std::string noExe = MakeTestZip({ { kMacPlistPath, 8, dyn, plain, 0 } });
        check(!CheckMacZip(noExe, "1.2.3", why), "실행 파일이 없는 zip 은 거절");
        std::string badCrc = MakeTestZip({ { kMacPlistPath, 0, plain, plain, 1 }, { kMacExePath, 0, bin, bin, 0 } });
        check(!CheckMacZip(badCrc, "1.2.3", why), "CRC 가 다른 항목은 거절");
        std::string plain2 = plain;
        size_t at = plain2.find("com.icesgg.smartscreen");
        if (at != std::string::npos) plain2[at] = 'C';
        std::string otherId = MakeTestZip({ { kMacPlistPath, 0, plain2, plain2, 0 }, { kMacExePath, 0, bin, bin, 0 } });
        check(!CheckMacZip(otherId, "1.2.3", why), "번들 id 가 다른 앱은 거절");
        check(!CheckMacZip(std::string("MZ") + good.substr(2), "1.2.3", why), "PK 로 시작하지 않으면 거절");
        std::string bp = HexBytes(kSampleBplist), v1, v2, v3;
        check(BplistString(bp, "CFBundleShortVersionString", v1) && v1 == "1.2.3" &&
              BplistString(bp, "CFBundleIdentifier", v2) && v2 == kMacBundleId &&
              !BplistString(bp, "CFBundleVersion", v3) && !BplistString(bp.substr(0, bp.size() - 1), "CFBundleIdentifier", v3),
              "이진 plist 도 읽는다 (없는 키, 잘린 파일은 실패)");
        std::string binZip = MakeTestZip({ { kMacPlistPath, 0, bp, bp, 0 }, { kMacExePath, 0, bin, bin, 0 } });
        check(CheckMacZip(binZip, "1.2.3", why) && !CheckMacZip(binZip, "1.2.4", why), "이진 Info.plist 의 zip 도 같은 판정");
    }
    printf("\n%s\n", fail == 0 ? "전부 통과" : "실패 있음");
    return fail == 0 ? 0 : 1;
}

static int List(const std::wstring& url, const std::wstring& key, const Platform& P) {
    unsigned long st = 0; std::string body;
    if (!SupabaseHttp(L"GET", url + L"/rest/v1/" + P.table + L"?select=version,channel,size,active,published_at,notes&order=published_at.desc",
                      Hdr(key, key), std::string(), st, body)) {
        printf("  [FAIL] 서버에 닿지 않는다\n"); return 1;
    }
    if (st < 200 || st >= 300) {
        printf("  [FAIL] %ls\n  %s\n", ErrOf(body, st).c_str(), body.c_str());
        MacTableHint(P, body);
        return 1;
    }
    if (P.mac) printf("mac_releases (anon 으로 보이는 것 = Mac 들이 보는 것)\n");
    else       printf("releases (anon 으로 보이는 것 = PC 들이 보는 것)\n");
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

static int Deactivate(const std::wstring& url, const std::wstring& key, const std::wstring& ver, const Platform& P) {
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
    if (!SupabaseHttp(L"PATCH", url + L"/rest/v1/" + P.table + L"?version=eq." + ver,
                      { L"apikey: " + key, L"Authorization: Bearer " + s.accessToken,
                        L"Content-Type: application/json", L"Prefer: return=representation" },
                      "{\"active\":false}", st, body) || st < 200 || st >= 300) {
        printf("  [FAIL] %ls\n", ErrOf(body, st).c_str());
        MacTableHint(P, body);
        return 1;
    }
    std::string got;
    bool inactive = body.find("\"active\":false") != std::string::npos ||
                    body.find("\"active\": false") != std::string::npos;
    if (!JsonGetString(body, "version", got) || Utf8ToWide(got) != ver || !inactive) {
        printf("  [FAIL] %ls 라는 행이 없다 (또는 바꿀 권한이 없다). --list%s 로 확인하라\n",
               ver.c_str(), P.mac ? " --platform mac" : "");
        return 1;
    }
    if (P.mac) printf("  [OK] Mac %ls 를 껐다. 이미 받은 Mac 은 그대로다 - 되돌리려면 더 높은 버전을 올려라\n", ver.c_str());
    else       printf("  [OK] %ls 를 껐다. 이미 받은 PC 는 그대로다 - 되돌리려면 더 높은 버전을 올려라\n", ver.c_str());
    return 0;
}

// --list / --deactivate 뒤에 붙는 것: --platform 하나뿐이다. 오타(--platfrom mac)를 조용히
// 넘기면 Windows 표를 보고 Mac 표를 본 줄 알게 된다 - 모르는 인자는 멈춘다.
static bool ParseTailPlatform(int argc, wchar_t** argv, int from, const Platform*& P) {
    P = &kWindows;
    for (int i = from; i < argc; ++i) {
        if (wcscmp(argv[i], L"--platform") == 0 && i + 1 < argc) {
            if (!ParsePlatform(argv[++i], P)) { printf("platform 은 windows 또는 mac\n"); return false; }
        } else {
            printf("모르는 인자: %ls\n", argv[i]);
            return false;
        }
    }
    return true;
}

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    // printf 의 %ls 는 현재 로캘로 변환한다. 기본 "C" 로캘은 한글에서 멈추고 그 뒤
    // (줄바꿈까지)를 버린다 - 오류 문구가 "[FAIL] " 로 끝나 보인다.
    setlocale(LC_ALL, ".UTF8");

    if (argc > 1 && wcscmp(argv[1], L"--version") == 0)  { printf("%s\n", SS_VERSION_STR_A); return 0; }
    if (argc > 1 && wcscmp(argv[1], L"--selftest") == 0) return SelfTest();
    if (argc > 3 && wcscmp(argv[1], L"--list") == 0) {
        const Platform* P = nullptr;
        if (!ParseTailPlatform(argc, argv, 4, P)) return 2;
        return List(argv[2], argv[3], *P);
    }
    if (argc > 4 && wcscmp(argv[1], L"--deactivate") == 0) {
        const Platform* P = nullptr;
        if (!ParseTailPlatform(argc, argv, 5, P)) return 2;
        return Deactivate(argv[2], argv[3], argv[4], *P);
    }
    // 위에 안 걸린 --옵션이 첫 인자면 인자가 모자란 것이다. 아래로 흘려 보내면 url 자리에
    // "--deactivate" 가 들어가고, 오류 문구가 anon key 를 그대로 찍는다.
    bool badFlag = (argc > 1 && (argv[1][0] == L'-' || argv[1][0] == L'/'));

    if (argc < 4 || badFlag) {
        printf("Publish.exe <url> <anonkey> <SmartScreen.exe> [--notes \"...\"] [--channel stable|beta] [--force]\n"
               "Publish.exe <url> <anonkey> --platform mac --file <SmartScreen-mac.zip> [--notes \"...\"] [--channel stable|beta] [--force]\n"
               "Publish.exe --list <url> <anonkey> [--platform windows|mac]\n"
               "Publish.exe --deactivate <url> <anonkey> <version> [--platform windows|mac]\n"
               "Publish.exe --selftest\n");
        return 2;
    }

    std::wstring url = argv[1], key = argv[2], exe;
    std::wstring wnotes, wchannel = L"stable";
    bool force = false, fileFlag = false;
    const Platform* P = &kWindows;
    for (int i = 3; i < argc; ++i) {
        if (wcscmp(argv[i], L"--notes") == 0 && i + 1 < argc) wnotes = argv[++i];
        else if (wcscmp(argv[i], L"--channel") == 0 && i + 1 < argc) wchannel = argv[++i];
        else if (wcscmp(argv[i], L"--force") == 0) force = true;
        else if (wcscmp(argv[i], L"--platform") == 0 && i + 1 < argc) {
            if (!ParsePlatform(argv[++i], P)) { printf("platform 은 windows 또는 mac\n"); return 2; }
        }
        else if (wcscmp(argv[i], L"--file") == 0 && i + 1 < argc) {
            // publish.bat 은 build\SmartScreen.exe 를 자리 인자로 넣는다. 거기에 --file 이 또
            // 오면 어느 것을 올릴지 알 수 없다 - 고르지 않고 멈춘다.
            if (!exe.empty()) { printf("올릴 파일이 둘이다: %ls / %ls\n", exe.c_str(), argv[i + 1]); return 2; }
            exe = argv[++i]; fileFlag = true;
        }
        // 예전 꼴: <url> <anonkey> 바로 다음 자리가 올릴 파일이다.
        else if (i == 3 && argv[i][0] != L'-') exe = argv[i];
        else { printf("모르는 인자: %ls\n", argv[i]); return 2; }
    }
    if (exe.empty()) { printf("올릴 파일이 없다 (<SmartScreen.exe> 또는 --file <파일>)\n"); return 2; }
    // Mac 은 파일을 --file 로만 받는다. 자리 인자(publish.bat 이 넣는 build\SmartScreen.exe)가
    // Mac 으로 올라가는 일이 없게 - 그건 아래 zip 확인에도 걸리지만, 명령의 모양에서 먼저 막는다.
    if (P->mac && !fileFlag) { printf("--platform mac 은 --file <SmartScreen-mac.zip> 으로 파일을 받는다\n"); return 2; }
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
    const std::wstring wver = Utf8ToWide(ver);
    const std::wstring storagePath = StoragePathFor(*P, wver);

    printf("올릴 것\n");
    std::string sha; unsigned long long size = 0;
    if (!Sha256File(exe, sha, size)) { printf("  [FAIL] 파일을 읽지 못했다: %ls\n", exe.c_str()); return 1; }
    printf("  파일    %ls\n  크기    %llu bytes\n  SHA-256 %s\n  버전    %s (%s)\n",
           exe.c_str(), size, sha.c_str(), ver.c_str(), channel.c_str());
    if (P->mac) printf("  플랫폼  Mac (표 mac_releases, releases/%ls)\n", storagePath.c_str());
    if (size < 100 * 1024) {
        if (P->mac) printf("  [FAIL] 100 KB 도 안 된다. 진짜 SmartScreen-mac.zip 인가?\n");
        else        printf("  [FAIL] 100 KB 도 안 된다. 진짜 SmartScreen.exe 인가?\n");
        return 1;
    }

    // 파일을 메모리로 (업로드할 바이트). 로그인 전에 읽어서 모양을 먼저 본다 - 틀린 파일이면
    // 브라우저 로그인까지 갈 것도 없다.
    std::string bytes;
    {
        FILE* f = nullptr;
        if (_wfopen_s(&f, exe.c_str(), L"rb") != 0 || !f) { printf("  [FAIL] 파일 열기\n"); return 1; }
        bytes.resize((size_t)size);
        size_t n = fread(&bytes[0], 1, bytes.size(), f);
        fclose(f);
        if (n != bytes.size()) { printf("  [FAIL] 파일 읽기\n"); return 1; }
    }
    if (P->mac) {
        std::string why;
        if (!CheckMacZip(bytes, ver, why)) { printf("  [FAIL] %s\n", why.c_str()); return 1; }
        printf("  [OK] zip 안의 SmartScreen.app 이 %s %s 다\n", kMacBundleId, ver.c_str());
    } else if (bytes.size() < 2 || bytes[0] != 'M' || bytes[1] != 'Z') {
        // 반대 방향의 실수: Mac zip 을 --platform 없이 주면 releases 에 SmartScreen.exe 로
        // 올라가고, Windows PC 들이 해시가 맞는 zip 을 받아 자기 exe 자리에 놓는다.
        printf("  [FAIL] Windows 실행 파일(MZ)이 아니다. Mac zip 이면 --platform mac --file 로 올려라\n");
        return 1;
    }

    printf("로그인 (브라우저가 열린다)\n");
    AuthSession s; std::wstring err;
    if (!SignInWithGoogle(url, key, s, err)) { printf("  [FAIL] %ls\n", err.c_str()); return 1; }
    printf("  [OK] %ls\n", s.email.c_str());
    if (!IsReleaseAdmin(url, key, s)) return 1;

    // 같은 버전이 이미 있으면: 같은 파일이면 행만 다시 쓰고, 다른 파일이면 멈춘다.
    // 버전을 안 올리고 exe 만 바꿔 올리면, 이미 받은 PC 와 아직 안 받은 PC 가 같은
    // 버전 번호로 다른 바이너리를 돌리게 된다. 이 확인 자체가 실패하면 진행하지
    // 않는다 - 확인 못 한 채로 덮어쓰는 것이 이 검사가 막으려는 바로 그 일이다.
    // (Mac: CI 를 다시 돌리면 같은 커밋이라도 zip 의 바이트가 달라진다 - 서명과 시각.
    //  그래서 한 번 올린 번호는 그 실행의 zip 으로만 다시 올린다.)
    unsigned long st = 0; std::string body;
    if (!SupabaseHttp(L"GET", url + L"/rest/v1/" + P->table + L"?version=eq." + wver + L"&select=sha256",
                      Hdr(key, s.accessToken), std::string(), st, body) || st < 200 || st >= 300) {
        printf("  [FAIL] 기존 행 확인: %ls\n", ErrOf(body, st).c_str());
        MacTableHint(*P, body);
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
    printf("Storage 업로드  releases/%ls\n", storagePath.c_str());
    if (!SupabaseHttp(L"POST", url + L"/storage/v1/object/releases/" + storagePath,
                      { L"apikey: " + key, L"Authorization: Bearer " + s.accessToken,
                        std::wstring(P->mac ? L"Content-Type: application/zip" : L"Content-Type: application/octet-stream"),
                        L"x-upsert: true" },
                      bytes, st, body) || st < 200 || st >= 300) {
        printf("  [FAIL] %ls\n  %s\n", ErrOf(body, st).c_str(), body.substr(0, 300).c_str());
        return 1;
    }
    printf("  [OK]\n");

    // PC 가 받는 길 그대로 - anon 키만으로 - 다시 내려받아 해시를 본다. 이게 통과하면
    // 버킷 정책과 파일 둘 다 맞는 것이고, 실패하면 PC 들이 실패하기 전에 여기서 안다.
    printf("anon 으로 다시 내려받아 대조\n");
    std::string back;
    bool got = SupabaseHttp(L"GET", url + L"/storage/v1/object/authenticated/releases/" + storagePath,
                            Hdr(key, key), std::string(), st, back);
    // SupabaseHttp 는 본문을 끝까지 못 받으면 false 를 준다 (상태는 200 인 채로).
    // 그걸 아래 문구로 보내면 네트워크가 끊긴 것을 버킷 정책 탓으로 읽게 된다.
    if (!got && (st == 0 || (st >= 200 && st < 300))) {
        printf("  [FAIL] 내려받다가 끊겼다 (HTTP %lu, 본문을 끝까지 못 받음). 네트워크 문제다 - 다시 돌려라\n", st);
        return 1;
    }
    if (!got || st < 200 || st >= 300) {
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
    // mac_releases 의 min_macos 는 보내지 않는다 - 서버 기본값('13.0', 배포 대상과 같다).
    std::string row = "{\"version\":" + JsonQuote(ver) +
                      ",\"channel\":" + JsonQuote(channel) +
                      ",\"storage_path\":" + JsonQuote(WideToUtf8(storagePath)) +
                      ",\"sha256\":" + JsonQuote(sha) +
                      ",\"size\":" + std::to_string(size) +
                      ",\"notes\":" + JsonQuote(notes) +
                      ",\"active\":true}";
    printf("%ls 행\n", P->table);
    if (!SupabaseHttp(L"POST", url + L"/rest/v1/" + P->table,
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
    if (P->mac) {
        printf("  [OK] Mac %s 게시됨 (%s)\n", ver.c_str(), channel.c_str());
        printf("\n이제 Mac 들이 한 시간 안에 알아챈다 (간단 창의 버전 단추를 누르면 바로).\n"
               "기업 Mac 은 관리자가 대시보드의 Mac 목록에서 이 버전을 승인해야 받는다.\n");
    } else {
        printf("  [OK] %s 게시됨 (%s)\n", ver.c_str(), channel.c_str());
        printf("\n이제 PC 들이 한 시간 안에 알아챈다 (간단 창의 버전 단추를 누르면 바로).\n"
               "기업 PC 는 관리자가 대시보드에서 이 버전을 승인해야 받는다.\n");
    }
    return 0;
}
