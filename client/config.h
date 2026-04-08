// config.h - Configuration persistence (JSON-based)
#pragma once
#include "common.h"

struct AppConfig {
    BTH_ADDR btAddress = 0;
    DWORD nearLatencyMs = 200;
    DWORD keepAliveSec = 5;
    DWORD scanIntervalSec = 2;
    int idleCountdownSec = 20;
    bool unlockAuto = true;
    int unlockDelaySec = 0;
    std::wstring centerImagePath;
    std::wstring bannerImagePath;
    // Enterprise
    std::wstring orgId;
    std::wstring serverUrl;
    bool enterpriseRegistered = false;
};

std::wstring GetConfigDir();
bool LoadAppConfig(AppConfig& cfg);
void SaveAppConfig(const AppConfig& cfg);
