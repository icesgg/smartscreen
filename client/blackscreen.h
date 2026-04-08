// blackscreen.h - Black screen window, image loading, activation
#pragma once
#include "common.h"

void LoadBlackScreenImages();
void FreeBlackScreenImages();
void ActivateBlackScreen();
void DeactivateBlackScreen();
void RegisterBlackScreenClasses(HINSTANCE hInst);

// BlackScreen window class names
#define BLACKSCREEN_CLASS L"BSBlackWnd"
#define BANNER_CLASS      L"BSBannerWnd"
