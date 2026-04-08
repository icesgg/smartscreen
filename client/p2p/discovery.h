// discovery.h - P2P peer discovery via UDP broadcast
#pragma once
#include "../common.h"
#include <string>
#include <vector>
#include <mutex>

struct PeerInfo {
    std::wstring ip;
    uint16_t     tcpPort;
    std::wstring orgId;
    int          contentVersion;
    ULONGLONG    lastSeen;  // GetTickCount64
};

// Start/stop P2P discovery (UDP broadcast + listen)
void StartP2PDiscovery(const std::wstring& orgId, int contentVersion, uint16_t tcpPort);
void StopP2PDiscovery();
void UpdateP2PVersion(int newVersion);

// Get list of active peers
std::vector<PeerInfo> GetActivePeers();
