// ble_ident.h - 연결로 폰의 신원을 확인한다 (IRK 없이)
//
// 잠긴 아이폰의 광고에는 이름도 서비스 UUID도 실리지 않고 주기적으로 바뀌는
// 랜덤 주소만 남는다. IRK로 그 주소를 푸는 방법은 PC마다 LE 본딩을 요구해서
// (Windows에서는 사실상 Phone Link 설정) 데스크톱 배포의 최대 장벽이었다.
//
// 대신 폰이 신원 서비스를 올리고, PC가 central로 붙어 토큰을 읽는다.
// 본딩도 레지스트리도 필요 없다. 실측: 잠기고 페어링 안 된 아이폰에서 성공.
//
// 연결은 신원 확인용으로만 쓰고 바로 끊는다. RSSI는 계속 광고에서 온다
// (WinRT는 연결 RSSI를 주지 않고, CoreBluetooth의 readRSSI()는 central 전용이라
//  peripheral인 폰이 쓸 수 없다).
#pragma once

#include <windows.h>
#include <string>

// 탐색 결과. 실패를 둘로 가르는 것이 핵심이다 -
// "붙었는데 우리 서비스가 없다"는 확정이고, "못 붙었다"는 다시 해볼 일이다.
// 둘을 같이 취급하면 아닌 게 확실한 기기를 계속 다시 찌르면서
// 정작 맞는 기기에 쓸 시도를 낭비한다.
enum class ProbeOutcome {
    Token,        // 토큰을 읽었다 (우리 것인지는 호출자가 대조한다)
    NotOurs,      // 붙었지만 신원 서비스가 없다 - 남의 기기
    Unreachable,  // 붙지 못했다 - 일시적일 수 있다
};

// 한 주소에 붙어 신원 토큰을 읽는다. 블로킹, 보통 1~3초, 최악 25초 (5+10+5+5).
// why에는 사유가 들어간다 (이벤트 로그용). elapsedMs는 실제 걸린 시간.
ProbeOutcome ReadPhoneToken(uint64_t addr, bool randomAddr,
                            std::wstring& tokenHex, std::wstring& why,
                            DWORD* elapsedMs = nullptr);

// ReadPhoneToken 과 같은 일을 짧게 사는 도우미 프로세스에서 한다. 결과와 why 의 글자는
// ReadPhoneToken 그대로이고, elapsedMs 는 도우미 안에서 잰 ReadPhoneToken 시간이다
// (로그의 숫자가 예전과 견줄 수 있게). 도우미가 답하지 못하면 Unreachable 이고 why 는
// "helper timeout" / "helper output", elapsedMs 는 이쪽에서 잰 시간이다.
//
// 왜: 데스크톱 로그(2026-10-15)에서 오래 돈 프로세스의 탐색이 40분 동안 여러 주소에서
// 모두 80~110ms 만에 Unreachable 이었다 - 폰까지 가지도 않고 이 PC 의 스택이 거절했다.
// 블루투스를 껐다 켜도 그대로였고, 앱을 다시 켜자 첫 시도에 묶였다. 프로세스 안의 무엇이
// 그렇게 만드는지는 아직 모른다. 탐색마다 새 프로세스를 쓰면 무엇이 쌓이든 그 프로세스와
// 함께 OS 가 거둔다.
//
// 도우미를 띄우지 못하면 이 프로세스 안에서 ReadPhoneToken 을 부른다 (로그에 한 번 남긴다).
// abortEvent 가 신호되면 도는 도우미를 바로 끊고 Unreachable "helper stopped" 를 준다 -
// 앱이 끝날 때 프로버 스레드를 30초씩 붙잡지 않게.
ProbeOutcome ReadPhoneTokenIsolated(uint64_t addr, bool randomAddr,
                                    std::wstring& tokenHex, std::wstring& why,
                                    DWORD* elapsedMs = nullptr, HANDLE abortEvent = nullptr);

// 도우미 쪽: SmartScreen.exe --read-token <주소 16진 12자리> <r|p>
// wWinMain 이 다른 무엇보다 먼저 부르고, 돌려준 값으로 프로세스를 끝낸다.
// stdout 에 UTF-8 한 줄을 쓴다:
//   "TOKEN <hex> <ms>" (0) | "NOTOURS <why> <ms>" (2) | "UNREACHABLE <why> <ms>" (3)
// 인자가 조금이라도 다르면 아무것도 쓰지 않고 64. events.log 와 config.ini 는 건드리지 않는다.
int ReadTokenHelperMain(int argc, wchar_t** argv);

// 등록: 앱을 화면에 띄운 폰을 찾아 토큰을 읽는다.
// 포그라운드에서는 iOS가 이름과 서비스 UUID를 광고에 그대로 실으므로 후보가
// 모호하지 않다. 잠긴 폰으로 등록하면 남의 폰을 집을 위험이 있어 일부러 이 조건을 쓴다.
// 가장 신호가 센 것 하나만 시도한다.
bool RegisterPhone(int scanSec, std::wstring& tokenHex, std::wstring& why);
