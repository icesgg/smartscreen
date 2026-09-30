// relver.h - 버전 문자열 "a.b.c" 를 읽고 비교한다.
//
// 헤더 하나짜리인 이유: SmartScreen.exe(client/update.cpp) 와 Publish.exe
// (tools/publish.cpp) 가 같은 규칙으로 비교해야 한다. 한쪽이 문자열 비교를
// 하고 한쪽이 숫자 비교를 하면 "1.10.0" 에서 둘의 판정이 갈린다.
#pragma once
#include <string>
#include <cwchar>
#include <cstdio>

struct SemVer {
    int major = 0, minor = 0, patch = 0;
};

// "1.2.3" 만 받는다: 숫자와 점 두 개, 각 자리 1~9 글자. 앞뒤 공백, 부호, 접미사
// ("1.2.3-beta"), 두 자리("1.2") 는 거절한다 - 서버에 그런 값이 들어가면 모든 PC 가 그
// 행을 조용히 건너뛰게 되므로, 넣는 쪽(Publish.exe)이 먼저 걸러야 한다.
// scanf 를 쓰지 않는 이유: %d 는 앞 공백과 부호를 받아들이고, 그건 서버의 check
// (^[0-9]+\.[0-9]+\.[0-9]+$) 와 다르다. 양쪽이 같은 값을 같은 답으로 판정해야 한다.
template <class CharT>
inline bool ParseSemVerT(const CharT* s, size_t n, SemVer& out) {
    if (n == 0 || n > 29) return false;
    int part[3] = { 0, 0, 0 }; int idx = 0; size_t digits = 0;
    for (size_t i = 0; i < n; ++i) {
        CharT c = s[i];
        if (c >= '0' && c <= '9') {
            if (++digits > 9) return false;
            part[idx] = part[idx] * 10 + (int)(c - '0');
        } else if (c == '.') {
            if (digits == 0 || idx == 2) return false;
            ++idx; digits = 0;
        } else return false;
    }
    if (idx != 2 || digits == 0) return false;
    out.major = part[0]; out.minor = part[1]; out.patch = part[2];
    return true;
}

inline bool ParseSemVer(const std::wstring& s, SemVer& out)  { return ParseSemVerT(s.c_str(), s.size(), out); }
inline bool ParseSemVerA(const std::string& s, SemVer& out)  { return ParseSemVerT(s.c_str(), s.size(), out); }

// x < y 면 음수, 같으면 0, x > y 면 양수
inline int CmpSemVer(const SemVer& x, const SemVer& y) {
    if (x.major != y.major) return x.major < y.major ? -1 : 1;
    if (x.minor != y.minor) return x.minor < y.minor ? -1 : 1;
    if (x.patch != y.patch) return x.patch < y.patch ? -1 : 1;
    return 0;
}
