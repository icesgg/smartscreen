// player.h - Video playback using Media Foundation (MFPlay)
#pragma once
#include <windows.h>
#include <string>

// Initialize/shutdown Media Foundation
bool VideoInit();
void VideoShutdown();

// Play a video file in the given window (loops continuously)
bool VideoPlay(HWND hWnd, const std::wstring& filePath);

// Stop playback
void VideoStop();

// Check if a file is a video (by extension)
bool IsVideoFile(const std::wstring& path);

// Must be called from WM_PAINT of the video host window
void VideoOnPaint(HWND hWnd);

// Must be called periodically (e.g. from a timer) to check for loop restart
void VideoTick();

// Is video currently playing?
bool IsVideoPlaying();
