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

// 한 주소에 붙어 신원 토큰을 읽는다. 블로킹, 보통 1~3초, 최악 20초.
// 성공하면 tokenHex에 32자리 hex(16바이트)를 넣고 true.
// why에는 실패 사유가 들어간다 (이벤트 로그용).
bool ReadPhoneToken(uint64_t addr, bool randomAddr,
                    std::wstring& tokenHex, std::wstring& why);

// 등록: 앱을 화면에 띄운 폰을 찾아 토큰을 읽는다.
// 포그라운드에서는 iOS가 이름과 서비스 UUID를 광고에 그대로 실으므로 후보가
// 모호하지 않다. 잠긴 폰으로 등록하면 남의 폰을 집을 위험이 있어 일부러 이 조건을 쓴다.
// 가장 신호가 센 것 하나만 시도한다.
bool RegisterPhone(int scanSec, std::wstring& tokenHex, std::wstring& why);
