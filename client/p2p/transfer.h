// transfer.h - P2P file transfer via TCP
#pragma once
#include "../common.h"
#include "discovery.h"
#include <string>

// Start TCP file server (seeder) on given port
void StartP2PServer(uint16_t port, const std::wstring& contentDir);
void StopP2PServer();

// Download a file from a peer (returns true if successful)
bool DownloadFromPeer(const std::wstring& peerIp, uint16_t peerPort,
                      const std::wstring& filename, const std::wstring& localPath);

// Try downloading from any available peer, fallback to server
bool P2PDownloadFile(const std::wstring& filename, const std::wstring& localPath,
                     const std::wstring& supabaseUrl, const std::wstring& anonKey,
                     const std::wstring& storagePath);
