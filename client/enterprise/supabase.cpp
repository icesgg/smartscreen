// supabase.cpp - Enterprise: Supabase REST API client via WinHTTP
#include "supabase.h"
#include "../config.h"
#include <winhttp.h>
#include <fstream>
#include <sstream>

#pragma comment(lib, "winhttp.lib")

// ---------------------------------------------------------------------------
// Simple WinHTTP GET request
// ---------------------------------------------------------------------------
static bool HttpGet(const std::wstring& url, const std::wstring& authHeader,
                    std::string& outBody) {
    outBody.clear();

    // Parse URL
    URL_COMPONENTS uc = {}; uc.dwStructSize = sizeof(uc);
    wchar_t host[256] = {}, path[2048] = {};
    uc.lpszHostName = host; uc.dwHostNameLength = _countof(host);
    uc.lpszUrlPath = path; uc.dwUrlPathLength = _countof(path);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return false;

    HINTERNET hSession = WinHttpOpen(L"SmartScreen/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return false;

    HINTERNET hConnect = WinHttpConnect(hSession, host, uc.nPort, 0);
    if (!hConnect) { WinHttpCloseHandle(hSession); return false; }

    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hRequest = WinHttpOpenRequest(hConnect, L"GET", path, nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!hRequest) { WinHttpCloseHandle(hConnect); WinHttpCloseHandle(hSession); return false; }

    // Add auth header
    if (!authHeader.empty()) {
        WinHttpAddRequestHeaders(hRequest, authHeader.c_str(), -1, WINHTTP_ADDREQ_FLAG_ADD);
    }

    bool ok = false;
    if (WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                           WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
        WinHttpReceiveResponse(hRequest, nullptr)) {
        DWORD bytesRead = 0;
        char buf[4096];
        while (WinHttpReadData(hRequest, buf, sizeof(buf), &bytesRead) && bytesRead > 0) {
            outBody.append(buf, bytesRead);
        }
        ok = true;
    }

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return ok;
}

// ---------------------------------------------------------------------------
// Download file via WinHTTP
// ---------------------------------------------------------------------------
static bool HttpDownloadFile(const std::wstring& url, const std::wstring& authHeader,
                             const std::wstring& localPath) {
    URL_COMPONENTS uc = {}; uc.dwStructSize = sizeof(uc);
    wchar_t host[256] = {}, path[2048] = {};
    uc.lpszHostName = host; uc.dwHostNameLength = _countof(host);
    uc.lpszUrlPath = path; uc.dwUrlPathLength = _countof(path);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return false;

    HINTERNET hSession = WinHttpOpen(L"SmartScreen/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return false;

    HINTERNET hConnect = WinHttpConnect(hSession, host, uc.nPort, 0);
    if (!hConnect) { WinHttpCloseHandle(hSession); return false; }

    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hRequest = WinHttpOpenRequest(hConnect, L"GET", path, nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!hRequest) { WinHttpCloseHandle(hConnect); WinHttpCloseHandle(hSession); return false; }

    if (!authHeader.empty())
        WinHttpAddRequestHeaders(hRequest, authHeader.c_str(), -1, WINHTTP_ADDREQ_FLAG_ADD);

    bool ok = false;
    if (WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                           WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
        WinHttpReceiveResponse(hRequest, nullptr)) {

        // Write to temp file, then rename
        std::wstring tmpPath = localPath + L".tmp";
        FILE* f = nullptr;
        _wfopen_s(&f, tmpPath.c_str(), L"wb");
        if (f) {
            DWORD bytesRead = 0;
            char buf[8192];
            while (WinHttpReadData(hRequest, buf, sizeof(buf), &bytesRead) && bytesRead > 0) {
                fwrite(buf, 1, bytesRead, f);
            }
            fclose(f);
            DeleteFileW(localPath.c_str());
            ok = MoveFileW(tmpPath.c_str(), localPath.c_str()) != 0;
            if (!ok) DeleteFileW(tmpPath.c_str());
        }
    }

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return ok;
}

// ---------------------------------------------------------------------------
// Simple JSON value extractor (no library, just basic parsing)
// ---------------------------------------------------------------------------
static std::string ExtractJsonStr(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\":\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return "";
    pos += needle.size();
    auto end = json.find("\"", pos);
    if (end == std::string::npos) return "";
    return json.substr(pos, end - pos);
}

static int ExtractJsonInt(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\":";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return 0;
    pos += needle.size();
    return atoi(json.c_str() + pos);
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
// Enterprise content directory
// ---------------------------------------------------------------------------
std::wstring GetEnterpriseContentDir() {
    std::wstring dir = GetConfigDir() + L"\\enterprise_content";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

// ---------------------------------------------------------------------------
// Fetch manifest
// ---------------------------------------------------------------------------
bool FetchManifest(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                   const std::wstring& orgId, ContentManifest& out) {
    out.items.clear();
    out.orgId = orgId;
    out.maxVersion = 0;

    // GET /rest/v1/contents?org_id=eq.{orgId}&active=eq.true&select=*
    std::wstring url = supabaseUrl + L"/rest/v1/contents?org_id=eq." + orgId + L"&active=eq.true&select=*";
    std::wstring auth = L"apikey: " + anonKey + L"\r\nAuthorization: Bearer " + anonKey;

    std::string body;
    if (!HttpGet(url, auth, body)) return false;

    // Parse JSON array (simple approach: split by },{)
    // Each item: {"id":"...","filename":"...","storage_path":"...","file_hash":"...","file_size":...,"content_type":"...","display_position":"...","version":...}
    size_t pos = 0;
    while (true) {
        auto start = body.find("{", pos);
        if (start == std::string::npos) break;
        auto end = body.find("}", start);
        if (end == std::string::npos) break;
        std::string obj = body.substr(start, end - start + 1);

        ContentItem ci;
        ci.id = ToWide(ExtractJsonStr(obj, "id"));
        ci.filename = ToWide(ExtractJsonStr(obj, "filename"));
        ci.storagePath = ToWide(ExtractJsonStr(obj, "storage_path"));
        ci.fileHash = ToWide(ExtractJsonStr(obj, "file_hash"));
        ci.fileSize = ExtractJsonInt(obj, "file_size");
        ci.contentType = ToWide(ExtractJsonStr(obj, "content_type"));
        ci.displayPos = ToWide(ExtractJsonStr(obj, "display_position"));
        ci.version = ExtractJsonInt(obj, "version");

        if (!ci.filename.empty()) {
            out.items.push_back(ci);
            if (ci.version > out.maxVersion) out.maxVersion = ci.version;
        }
        pos = end + 1;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Download content file
// ---------------------------------------------------------------------------
bool DownloadContent(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                     const std::wstring& storagePath, const std::wstring& localPath) {
    std::wstring url = supabaseUrl + L"/storage/v1/object/authenticated/content/" + storagePath;
    std::wstring auth = L"apikey: " + anonKey + L"\r\nAuthorization: Bearer " + anonKey;
    return HttpDownloadFile(url, auth, localPath);
}

// ---------------------------------------------------------------------------
// Sync enterprise content
// ---------------------------------------------------------------------------
// Last synced paths
static std::wstring s_centerPath;
static std::wstring s_bannerPath;

bool SyncEnterpriseContent(const std::wstring& supabaseUrl, const std::wstring& anonKey,
                           const std::wstring& orgId) {
    ContentManifest manifest;
    if (!FetchManifest(supabaseUrl, anonKey, orgId, manifest)) return false;
    if (manifest.items.empty()) return false;

    std::wstring dir = GetEnterpriseContentDir();
    s_centerPath.clear();
    s_bannerPath.clear();

    for (auto& item : manifest.items) {
        std::wstring localPath = dir + L"\\" + item.filename;

        // Check if already downloaded (by size)
        WIN32_FILE_ATTRIBUTE_DATA fad;
        if (GetFileAttributesExW(localPath.c_str(), GetFileExInfoStandard, &fad)) {
            LARGE_INTEGER li;
            li.LowPart = fad.nFileSizeLow;
            li.HighPart = fad.nFileSizeHigh;
            if (li.QuadPart == item.fileSize) {
                // Already have it, just record path
                if (item.displayPos == L"center") s_centerPath = localPath;
                else if (item.displayPos == L"banner") s_bannerPath = localPath;
                continue;
            }
        }

        // Download from server
        if (DownloadContent(supabaseUrl, anonKey, item.storagePath, localPath)) {
            if (item.displayPos == L"center") s_centerPath = localPath;
            else if (item.displayPos == L"banner") s_bannerPath = localPath;
        }
    }
    return true;
}

std::wstring GetEnterpriseCenterPath() { return s_centerPath; }
std::wstring GetEnterpriseBannerPath() { return s_bannerPath; }
