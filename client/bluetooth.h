// bluetooth.h - BT probe, reconnect, enumeration
#pragma once
#include "common.h"

// Dual-socket probe
void DoProbe(BTH_ADDR target, bool& outReachable, DWORD& outLatency, int& outErr);
void CloseProbeSocket();

// Reconnect
bool IsOsConnected(BTH_ADDR target);
void ReconnectDevice(BTH_ADDR target);

// Enumeration
void EnumPaired();
