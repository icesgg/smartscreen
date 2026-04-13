// player.cpp - Video playback using Media Foundation IMFPMediaPlayer
#include "player.h"

#include <mfplay.h>
#include <mfapi.h>
#include <mferror.h>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfuuid.lib")

// ---------------------------------------------------------------------------
// MFPlay callback to detect playback end (for looping)
// ---------------------------------------------------------------------------
class MediaPlayerCallback : public IMFPMediaPlayerCallback {
    long m_refCount = 1;
    bool m_ended = false;
    std::wstring m_filePath;
    HWND m_hWnd = nullptr;

public:
    void SetInfo(HWND hWnd, const std::wstring& path) { m_hWnd = hWnd; m_filePath = path; }
    bool HasEnded() const { return m_ended; }
    void ResetEnded() { m_ended = false; }

    // IUnknown
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
        if (riid == IID_IUnknown || riid == __uuidof(IMFPMediaPlayerCallback)) {
            *ppv = this; AddRef(); return S_OK;
        }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&m_refCount); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG c = InterlockedDecrement(&m_refCount);
        if (c == 0) delete this;
        return c;
    }

    // IMFPMediaPlayerCallback
    void STDMETHODCALLTYPE OnMediaPlayerEvent(MFP_EVENT_HEADER* pEventHeader) override {
        if (pEventHeader->eEventType == MFP_EVENT_TYPE_PLAYBACK_ENDED) {
            m_ended = true;
        }
    }
};

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------
static IMFPMediaPlayer* s_player = nullptr;
static MediaPlayerCallback* s_callback = nullptr;
static std::wstring s_currentFile;
static HWND s_videoWnd = nullptr;
static bool s_mfInited = false;

// ---------------------------------------------------------------------------
// Init / Shutdown
// ---------------------------------------------------------------------------
bool VideoInit() {
    if (s_mfInited) return true;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr) && hr != S_FALSE && hr != RPC_E_CHANGED_MODE) return false;
    hr = MFStartup(MF_VERSION);
    s_mfInited = SUCCEEDED(hr);
    return s_mfInited;
}

void VideoShutdown() {
    VideoStop();
    if (s_mfInited) {
        MFShutdown();
        s_mfInited = false;
    }
}

// ---------------------------------------------------------------------------
// Play
// ---------------------------------------------------------------------------
bool VideoPlay(HWND hWnd, const std::wstring& filePath) {
    if (!s_mfInited) return false;
    VideoStop();

    s_callback = new MediaPlayerCallback();
    s_callback->SetInfo(hWnd, filePath);
    s_videoWnd = hWnd;
    s_currentFile = filePath;

    HRESULT hr = MFPCreateMediaPlayer(
        filePath.c_str(),
        FALSE,          // fStartPlayback
        0,              // creationOptions
        s_callback,
        hWnd,
        &s_player);

    if (FAILED(hr) || !s_player) {
        if (s_callback) { s_callback->Release(); s_callback = nullptr; }
        return false;
    }

    // Start playback
    hr = s_player->Play();
    return SUCCEEDED(hr);
}

// ---------------------------------------------------------------------------
// Stop
// ---------------------------------------------------------------------------
void VideoStop() {
    if (s_player) {
        s_player->Stop();
        s_player->Shutdown();
        s_player->Release();
        s_player = nullptr;
    }
    if (s_callback) {
        s_callback->Release();
        s_callback = nullptr;
    }
    s_videoWnd = nullptr;
    s_currentFile.clear();
}

// ---------------------------------------------------------------------------
// Check video extension
// ---------------------------------------------------------------------------
bool IsVideoFile(const std::wstring& path) {
    if (path.empty()) return false;
    auto dot = path.rfind(L'.');
    if (dot == std::wstring::npos) return false;
    std::wstring ext = path.substr(dot);
    // To lowercase
    for (auto& c : ext) c = towlower(c);
    return (ext == L".mp4" || ext == L".avi" || ext == L".wmv" ||
            ext == L".mkv" || ext == L".mov" || ext == L".webm");
}

// ---------------------------------------------------------------------------
// Paint (MFPlay renders to HWND automatically, but we need to handle
// WM_PAINT for the background when video is not covering full area)
// ---------------------------------------------------------------------------
void VideoOnPaint(HWND hWnd) {
    if (s_player) {
        // MFPlay handles rendering. We just validate.
        s_player->UpdateVideo();
    }
}

// ---------------------------------------------------------------------------
// Tick - check if playback ended, restart for looping
// ---------------------------------------------------------------------------
void VideoTick() {
    if (s_callback && s_callback->HasEnded() && !s_currentFile.empty() && s_videoWnd) {
        s_callback->ResetEnded();
        // Seamless loop: destroy and recreate player to avoid black flash
        if (s_player) {
            s_player->Stop();
            s_player->Shutdown();
            s_player->Release();
            s_player = nullptr;
        }
        // Recreate player and start immediately
        HRESULT hr = MFPCreateMediaPlayer(
            s_currentFile.c_str(),
            FALSE, 0, s_callback, s_videoWnd, &s_player);
        if (SUCCEEDED(hr) && s_player) {
            s_player->Play();
        }
    }
}

// ---------------------------------------------------------------------------
// Is playing?
// ---------------------------------------------------------------------------
bool IsVideoPlaying() {
    return s_player != nullptr;
}
