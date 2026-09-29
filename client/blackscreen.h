// blackscreen.h - Black screen window, image loading, activation
#pragma once
#include "common.h"

void LoadBlackScreenImages();
void FreeBlackScreenImages();
void ActivateBlackScreen();
void DeactivateBlackScreen();

// 이 세션이 원격(RDP/터미널 서비스)으로 표시되고 있는지.
// RDP 계열만 안다 - blackscreen.cpp 의 정의에 있는 단서 참고.
bool IsRemoteSession();
void RegisterBlackScreenClasses(HINSTANCE hInst);

// BlackScreen window class names
#define BLACKSCREEN_CLASS L"BSBlackWnd"
#define BANNER_CLASS      L"BSBannerWnd"
