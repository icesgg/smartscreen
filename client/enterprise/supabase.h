// supabase.h - Enterprise: Supabase REST API client (WinHTTP)
#pragma once
#include "../common.h"
#include <string>
#include <vector>

struct ContentItem {
    std::wstring id;
    std::wstring filename;
    std::wstring storagePath;
    std::wstring fileHash;      // sha256
    int64_t      fileSize;
    std::wstring contentType;   // "image" or "video"
    std::wstring displayPos;    // "center" or "banner"
    int          version;
};

struct ContentManifest {
    std::wstring orgId;
    int          maxVersion;
    std::vector<ContentItem> items;
};

// Fetch content manifest from Supabase
bool FetchManifest(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                   const std::wstring& orgId, ContentManifest& outManifest);

// Download a file from Supabase Storage
bool DownloadContent(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                     const std::wstring& storagePath, const std::wstring& localPath);

// Get enterprise content directory
std::wstring GetEnterpriseContentDir();

// Check and download new content if available
bool SyncEnterpriseContent(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                           const std::wstring& orgId);
