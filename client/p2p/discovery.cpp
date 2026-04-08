// discovery.cpp - P2P peer discovery via UDP broadcast on LAN
#include "discovery.h"
#include <winsock2.h>
#include <ws2tcpip.h>

static constexpr uint16_t UDP_PORT = 49152;
static constexpr DWORD BROADCAST_INTERVAL_MS = 30000; // 30s
static constexpr DWORD PEER_TTL_MS = 90000;           // 90s without hearing = remove

static HANDLE s_hThread = nullptr;
static HANDLE s_hStopEvent = nullptr;
static std::mutex s_peerMutex;
static std::vector<PeerInfo> s_peers;
static std::wstring s_orgId;
static int s_contentVersion = 0;
static uint16_t s_tcpPort = 0;

// Get local IP (first non-loopback IPv4)
static std::string GetLocalIP() {
    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) != 0) return "0.0.0.0";
    addrinfo hints = {}, *res = nullptr;
    hints.ai_family = AF_INET;
    if (getaddrinfo(hostname, nullptr, &hints, &res) != 0) return "0.0.0.0";
    std::string ip = "0.0.0.0";
    for (auto* p = res; p; p = p->ai_next) {
        sockaddr_in* sin = (sockaddr_in*)p->ai_addr;
        char buf[32];
        inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
        if (strcmp(buf, "127.0.0.1") != 0) { ip = buf; break; }
    }
    freeaddrinfo(res);
    return ip;
}

static std::string ToUtf8(const std::wstring& w) {
    if (w.empty()) return "";
    int len = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string s(len, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], len, nullptr, nullptr);
    if (!s.empty() && s.back() == 0) s.pop_back();
    return s;
}

static std::wstring ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    std::wstring w(len, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], len);
    if (!w.empty() && w.back() == 0) w.pop_back();
    return w;
}

static DWORD WINAPI DiscoveryThread(LPVOID) {
    // Create UDP socket
    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) return 1;

    // Enable broadcast
    BOOL bcast = TRUE;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, (char*)&bcast, sizeof(bcast));

    // Allow address reuse
    BOOL reuse = TRUE;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse, sizeof(reuse));

    // Bind to listen
    sockaddr_in bindAddr = {};
    bindAddr.sin_family = AF_INET;
    bindAddr.sin_port = htons(UDP_PORT);
    bindAddr.sin_addr.s_addr = INADDR_ANY;
    bind(sock, (sockaddr*)&bindAddr, sizeof(bindAddr));

    // Non-blocking
    u_long nonblock = 1;
    ioctlsocket(sock, FIONBIO, &nonblock);

    std::string localIP = GetLocalIP();
    ULONGLONG lastBroadcast = 0;

    while (WaitForSingleObject(s_hStopEvent, 500) != WAIT_OBJECT_0) {
        ULONGLONG now = GetTickCount64();

        // Broadcast announcement every 30s
        if (now - lastBroadcast >= BROADCAST_INTERVAL_MS) {
            lastBroadcast = now;
            // Format: "SS|orgId|version|ip|tcpPort"
            char msg[512];
            snprintf(msg, sizeof(msg), "SS|%s|%d|%s|%d",
                ToUtf8(s_orgId).c_str(), s_contentVersion, localIP.c_str(), s_tcpPort);

            sockaddr_in dest = {};
            dest.sin_family = AF_INET;
            dest.sin_port = htons(UDP_PORT);
            dest.sin_addr.s_addr = INADDR_BROADCAST;
            sendto(sock, msg, (int)strlen(msg), 0, (sockaddr*)&dest, sizeof(dest));
        }

        // Receive announcements
        char buf[512];
        sockaddr_in from = {};
        int fromLen = sizeof(from);
        int received = recvfrom(sock, buf, sizeof(buf) - 1, 0, (sockaddr*)&from, &fromLen);
        if (received > 0) {
            buf[received] = 0;
            // Parse: "SS|orgId|version|ip|tcpPort"
            if (strncmp(buf, "SS|", 3) == 0) {
                char pOrgId[128] = {}, pIp[32] = {};
                int pVer = 0, pPort = 0;
                if (sscanf_s(buf + 3, "%[^|]|%d|%[^|]|%d", pOrgId, (unsigned)sizeof(pOrgId),
                    &pVer, pIp, (unsigned)sizeof(pIp), &pPort) >= 4) {
                    // Skip self
                    if (std::string(pIp) != localIP || pPort != s_tcpPort) {
                        std::lock_guard<std::mutex> lock(s_peerMutex);
                        bool found = false;
                        for (auto& peer : s_peers) {
                            std::string peerIp = ToUtf8(peer.ip);
                            if (peerIp == pIp && peer.tcpPort == pPort) {
                                peer.contentVersion = pVer;
                                peer.lastSeen = now;
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            s_peers.push_back({ ToWide(pIp), (uint16_t)pPort,
                                ToWide(pOrgId), pVer, now });
                        }
                    }
                }
            }
        }

        // Prune stale peers
        {
            std::lock_guard<std::mutex> lock(s_peerMutex);
            s_peers.erase(std::remove_if(s_peers.begin(), s_peers.end(),
                [now](const PeerInfo& p) { return (now - p.lastSeen) > PEER_TTL_MS; }),
                s_peers.end());
        }
    }

    closesocket(sock);
    return 0;
}

void StartP2PDiscovery(const std::wstring& orgId, int contentVersion, uint16_t tcpPort) {
    if (s_hThread) return;
    s_orgId = orgId;
    s_contentVersion = contentVersion;
    s_tcpPort = tcpPort;
    s_hStopEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    s_hThread = CreateThread(nullptr, 0, DiscoveryThread, nullptr, 0, nullptr);
}

void StopP2PDiscovery() {
    if (!s_hThread) return;
    SetEvent(s_hStopEvent);
    WaitForSingleObject(s_hThread, 5000);
    CloseHandle(s_hThread); CloseHandle(s_hStopEvent);
    s_hThread = nullptr; s_hStopEvent = nullptr;
    std::lock_guard<std::mutex> lock(s_peerMutex);
    s_peers.clear();
}

void UpdateP2PVersion(int newVersion) {
    s_contentVersion = newVersion;
}

std::vector<PeerInfo> GetActivePeers() {
    std::lock_guard<std::mutex> lock(s_peerMutex);
    return s_peers;
}
