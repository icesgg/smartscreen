// version.h - 이 빌드의 버전. 업데이트 판정의 기준값이다 (client/update.h).
//
// 새 버전을 내놓을 때 여기 세 숫자만 올린다. Publish.exe 도 이 헤더로 빌드되므로
// 서버에 적히는 버전과 exe 가 자기라고 믿는 버전이 같은 빌드에서 나온다 -
// make_dist.bat 가 exe 들을 손으로 복사하지 않는 것과 같은 이유다.
//
// 버전 비교는 client/relver.h 에 있다. 세 자리 숫자를 그대로 비교하므로
// "1.10.0" 은 "1.9.0" 보다 새 버전이다 (문자열 비교였다면 반대가 된다).
#pragma once

#define SS_VERSION_MAJOR 1
#define SS_VERSION_MINOR 1
#define SS_VERSION_PATCH 7

// 아래는 위 세 숫자를 "1.1.0" 과 L"1.1.0" 으로 만드는 매크로 배관이다.
// 두 단계로 나눈 이유: # 와 ## 의 인자는 먹기 전에 펼쳐지지 않는다.
#define SS_STRINGIZE_(x) #x
#define SS_STRINGIZE(x)  SS_STRINGIZE_(x)
#define SS_WIDEN_(s)     L ## s
#define SS_WIDEN(s)      SS_WIDEN_(s)

#define SS_VERSION_STR_A SS_STRINGIZE(SS_VERSION_MAJOR) "." \
                         SS_STRINGIZE(SS_VERSION_MINOR) "." \
                         SS_STRINGIZE(SS_VERSION_PATCH)
#define SS_VERSION_STR   SS_WIDEN(SS_STRINGIZE(SS_VERSION_MAJOR)) L"." \
                         SS_WIDEN(SS_STRINGIZE(SS_VERSION_MINOR)) L"." \
                         SS_WIDEN(SS_STRINGIZE(SS_VERSION_PATCH))
