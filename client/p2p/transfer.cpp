// transfer.cpp - P2P file transfer via TCP
#include "transfer.h"
#include "../enterprise/supabase.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <fstream>

static HANDLE s_hServerThread = nullptr;
static HANDLE s_hServerStop = nullptr;
static uint16_t s_serverPort = 0;
static std::wstring s_contentDir;

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

// ---------------------------------------------------------------------------
// TCP Server (seeder): serves files from contentDir
// Protocol: client sends "GET filename\n", server sends "SIZE\n" then raw bytes
// ---------------------------------------------------------------------------
static DWORD WINAPI HandleClient(LPVOID param) {
    SOCKET client = (SOCKET)(UINT_PTR)param;
    char buf[512];
    int r = recv(client, buf, sizeof(buf) - 1, 0);
    if (r > 0) {
        buf[r] = 0;
        // Parse "GET filename\n"
        if (strncmp(buf, "GET ", 4) == 0) {
            char* nl = strchr(buf + 4, '\n');
            if (nl) *nl = 0;
            std::wstring filename = ToWide(buf + 4);
            std::wstring path = s_contentDir + L"\\" + filename;

            FILE* f = nullptr;
            _wfopen_s(&f, path.c_str(), L"rb");
            if (f) {
                fseek(f, 0, SEEK_END);
                long size = ftell(f);
                fseek(f, 0, SEEK_SET);

                char sizeStr[32];
                snprintf(sizeStr, sizeof(sizeStr), "%ld\n", size);
                send(client, sizeStr, (int)strlen(sizeStr), 0);

                char fbuf[8192];
                size_t read;
                while ((read = fread(fbuf, 1, sizeof(fbuf), f)) > 0) {
                    send(client, fbuf, (int)read, 0);
                }
                fclose(f);
            } else {
                send(client, "0\n", 2, 0); // file not found
            }
        }
    }
    closesocket(client);
    return 0;
}

static DWORD WINAPI ServerThread(LPVOID) {
    SOCKET listenSock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listenSock == INVALID_SOCKET) return 1;

    BOOL reuse = TRUE;
    setsockopt(listenSock, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse, sizeof(reuse));

    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(s_serverPort);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(listenSock, (sockaddr*)&addr, sizeof(addr)) != 0) {
        closesocket(listenSock); return 1;
    }
    listen(listenSock, 5);

    // Non-blocking for clean shutdown
    u_long nonblock = 1;
    ioctlsocket(listenSock, FIONBIO, &nonblock);

    while (WaitForSingleObject(s_hServerStop, 200) != WAIT_OBJECT_0) {
        sockaddr_in client = {};
        int clientLen = sizeof(client);
        SOCKET cs = accept(listenSock, (sockaddr*)&client, &clientLen);
        if (cs != INVALID_SOCKET) {
            CloseHandle(CreateThread(nullptr, 0, HandleClient, (LPVOID)(UINT_PTR)cs, 0, nullptr));
        }
    }

    closesocket(listenSock);
    return 0;
}

void StartP2PServer(uint16_t port, const std::wstring& contentDir) {
    if (s_hServerThread) return;
    s_serverPort = port;
    s_contentDir = contentDir;
    s_hServerStop = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    s_hServerThread = CreateThread(nullptr, 0, ServerThread, nullptr, 0, nullptr);
}

void StopP2PServer() {
    if (!s_hServerThread) return;
    SetEvent(s_hServerStop);
    WaitForSingleObject(s_hServerThread, 5000);
    CloseHandle(s_hServerThread); CloseHandle(s_hServerStop);
    s_hServerThread = nullptr; s_hServerStop = nullptr;
}

// ---------------------------------------------------------------------------
// Download from a specific peer
// ---------------------------------------------------------------------------
bool DownloadFromPeer(const std::wstring& peerIp, uint16_t peerPort,
                      const std::wstring& filename, const std::wstring& localPath) {
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return false;

    DWORD timeout = 10000;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (char*)&timeout, sizeof(timeout));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (char*)&timeout, sizeof(timeout));

    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(peerPort);
    std::string ipStr = ToUtf8(peerIp);
    inet_pton(AF_INET, ipStr.c_str(), &addr.sin_addr);

    if (connect(sock, (sockaddr*)&addr, sizeof(addr)) != 0) {
        closesocket(sock); return false;
    }

    // Send request
    std::string req = "GET " + ToUtf8(filename) + "\n";
    send(sock, req.c_str(), (int)req.size(), 0);

    // Read size
    char sizeBuf[32] = {};
    int idx = 0;
    while (idx < 31) {
        char c;
        if (recv(sock, &c, 1, 0) != 1) { closesocket(sock); return false; }
        if (c == '\n') break;
        sizeBuf[idx++] = c;
    }
    long fileSize = atol(sizeBuf);
    if (fileSize <= 0) { closesocket(sock); return false; }

    // Read file data
    std::wstring tmpPath = localPath + L".p2p.tmp";
    FILE* f = nullptr;
    _wfopen_s(&f, tmpPath.c_str(), L"wb");
    if (!f) { closesocket(sock); return false; }

    long totalRead = 0;
    char buf[8192];
    while (totalRead < fileSize) {
        int toRead = (int)min((long)sizeof(buf), fileSize - totalRead);
        int r = recv(sock, buf, toRead, 0);
        if (r <= 0) break;
        fwrite(buf, 1, r, f);
        totalRead += r;
    }
    fclose(f);
    closesocket(sock);

    if (totalRead == fileSize) {
        DeleteFileW(localPath.c_str());
        return MoveFileW(tmpPath.c_str(), localPath.c_str()) != 0;
    }
    DeleteFileW(tmpPath.c_str());
    return false;
}

// ---------------------------------------------------------------------------
// P2P download with server fallback
// ---------------------------------------------------------------------------
bool P2PDownloadFile(const std::wstring& filename, const std::wstring& localPath,
                     const std::wstring& supabaseUrl, const std::wstring& anonKey,
                     const std::wstring& storagePath) {
    // Try peers first
    auto peers = GetActivePeers();
    for (auto& peer : peers) {
        if (DownloadFromPeer(peer.ip, peer.tcpPort, filename, localPath))
            return true;
    }

    // Fallback to server
    return DownloadContent(supabaseUrl, anonKey, storagePath, localPath);
}
