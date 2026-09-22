// irk.h - 아이폰 IRK(Identity Resolving Key) 가져오기
//
// 아이폰은 잠기면 이름 없이, 15분마다 바뀌는 랜덤 주소로만 광고한다.
// 그 주소를 "내 폰"으로 풀어내려면 LE 본딩 때 교환된 IRK가 필요하다.
// Windows는 이 키를
//   HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys\<어댑터>\<기기>
// 에 두는데, 이 하위 키는 관리자도 못 읽고 SYSTEM만 읽을 수 있다.
//
// 그래서 3단으로 동작한다:
//   1) 사용자가 버튼을 누르면  -> 자기 자신을 관리자 권한으로 다시 띄운다 (--import-irk)
//   2) 관리자 인스턴스가       -> SYSTEM으로 도는 1회성 예약 작업을 만들어 (--dump-irk)
//   3) SYSTEM 인스턴스가       -> 레지스트리를 덤프하고, 관리자 인스턴스가 골라서 config에 저장
//
// 키 값은 config.ini 밖으로 나가지 않는다. 덤프 파일은 읽는 즉시 지운다.
#pragma once

#include <string>

// 현재 프로세스가 관리자 권한인지
bool IsElevated();

// [3단계] SYSTEM으로 실행되어 레지스트리의 IRK를 outPath에 덤프한다.
// 형식: 한 줄에 "<기기주소 12hex>=<IRK 32hex>"
// 반환: 덤프한 항목 수 (프로세스 종료 코드로도 쓴다)
int DumpIrkFromRegistry(const std::wstring& outPath);

// [2단계] 관리자 권한으로 실행되어 SYSTEM 작업을 돌리고, 대상 기기의 IRK를 config에 저장한다.
// targetName: 고른 블루투스 기기 이름 (예: "iPhone"). 후보가 여럿일 때 고르는 데 쓴다.
// outMessage: 사용자에게 보여줄 결과 문구
// 반환: 저장 성공 여부
bool ImportIrkElevated(const std::wstring& targetName, std::wstring& outMessage);

// [1단계] 관리자 권한으로 자기 자신을 다시 띄워 IRK 가져오기를 실행하고 끝날 때까지 기다린다.
// 이미 관리자면 바로 ImportIrkElevated를 부른다.
// 반환: 저장 성공 여부
bool RequestIrkImport(const std::wstring& targetName, std::wstring& outMessage);
