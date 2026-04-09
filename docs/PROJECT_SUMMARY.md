# SmartScreen - Project Summary

## Overview
SmartScreen is a Windows 11 application that uses Bluetooth proximity detection to automatically lock/unlock the screen when the user leaves or returns to their desk. It combines a BT proximity monitor with a customizable screen saver, supporting both personal and enterprise use cases.

**Repository**: https://github.com/icesgg/smartscreen
**Landing Page**: https://icesgg.github.io/smartscreen/

---

## Core Features

### 1. Bluetooth Proximity Detection
- **Dual-socket RFCOMM approach**:
  - Socket 1 (SerialPort): Persistent connection keeps iPhone showing "Connected"
  - Socket 2 (OBEX Push): Connect/close every 2 seconds for latency measurement
- **Paired device only**: Uses Classic BT address (never changes), not BLE (address rotates)
- **Auto-reconnect**: When iPhone returns to range, connection re-establishes automatically
- **Warmup period**: 2 minutes after reconnect, latency threshold is relaxed

### 2. Screen Saver (Black Screen)
- **Activation**: Triggers immediately when device transitions to FAR
- **Deactivation**:
  - BT NEAR return: After configurable delay (0-300 seconds)
  - Mouse/keyboard: After configurable delay
  - "Release" button: Immediate
- **Content display**:
  - Center image (1024x768) or video
  - Banner popup (300x400, right-top corner)
  - Supports PNG, JPG, BMP images and MP4/AVI/WMV/MKV video
  - Video playback via Windows Media Foundation (MFPlay), auto-loops

### 3. User Interface
- **Settings Window**: Full configuration panel (hidden by default after first setup)
- **Overlay Widget**: Semi-transparent (50%), draggable, always-on-top
  - Shows state: NEAR / FAR / LOCKED
  - Buttons: Exit, Lock, Settings
  - Lock/unlock time info after deactivation
- **30-minute Timeline Chart**: FAR events marked with red triangles
- **ListView**: Real-time probe log with latency, signal, distance, state

### 4. Configuration
- **Persistence**: INI-based config file at `%APPDATA%\SmartScreen\config.ini`
- **Auto-start**: Saved device auto-connects on launch
- **Settings saved**: BT address, latency threshold, timeout, interval, idle time, unlock mode/delay, image paths

---

## Architecture

```
SmartScreen.exe (Win32 C++17, MSVC)
|
+-- client/
|   +-- main.cpp            # UI, overlay, worker thread, WinMain
|   +-- common.h            # Shared types, constants, inline helpers
|   +-- globals.cpp          # Global variable definitions
|   +-- config.h/cpp         # INI config persistence
|   +-- bluetooth.h/cpp      # Dual-socket BT probe, reconnect, enumeration
|   +-- blackscreen.h/cpp    # Screen saver, image/video loading, activation
|   +-- enterprise/
|   |   +-- supabase.h/cpp   # WinHTTP REST client for Supabase API
|   +-- p2p/
|   |   +-- discovery.h/cpp  # UDP broadcast peer discovery (port 49152)
|   |   +-- transfer.h/cpp   # TCP file transfer (peer-first, server fallback)
|   +-- video/
|       +-- player.h/cpp     # Media Foundation (MFPlay) video playback
|
+-- web/
|   +-- index.html           # Landing page (marketing/features/pricing)
|   +-- dashboard.html       # Admin dashboard (Supabase-powered SPA)
|
+-- docs/                    # GitHub Pages (copy of web/)
|   +-- index.html
|   +-- dashboard.html
|
+-- supabase/
|   +-- schema.sql           # Database schema + RLS policies
|
+-- images/                  # Default local images (optional)
+-- CMakeLists.txt           # Build configuration
+-- build.bat                # Build script
+-- build_run.bat            # Build via VS Developer Command Prompt
```

---

## Configuration Parameters

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| Near <= | 85 ms | 50-5000 | Latency threshold for NEAR state |
| Timeout | 5 sec | 5-300 | Keep-alive before FAR transition |
| Interval | 2 sec | 1-60 | Probe interval |
| Idle | 20 sec | 5-600 | Idle countdown before black screen |
| Unlock | Auto/Manual | - | Auto: mouse/KB unlocks after delay. Manual: same behavior |
| Delay | 20 sec | 0-300 | Lock duration before unlock is allowed |

---

## State Machine

```
                    latency <= Near
[FAR] ──────────────────────────────> [NEAR]
  |   <──────────────────────────────   |
  |     timeout expired                 |
  |                                     |
  | FAR transition                      | NEAR: suppress idle countdown
  v                                     |
[BLACK SCREEN]                          |
  |   <── BT NEAR + delay elapsed ─────+
  |   <── mouse/keyboard + delay elapsed
  |   <── "Release" button (immediate)
  v
[NEAR] (screen unlocked)
```

---

## Bluetooth Connection Flow

```
1. Start monitoring
   +-- Select paired device from combo box
   +-- Create persistent socket (SerialPort)
   +-- Start worker thread (2-second loop)

2. Each probe cycle:
   +-- Check if persistent socket alive (recv peek)
   +-- If alive: measure latency via Socket 2 (OBEX Push connect/close)
   +-- If dead: re-establish persistent socket
   +-- Post result to UI thread

3. Reconnection (after device leaves and returns):
   +-- Socket dies -> consecutive failures increase
   +-- Device returns -> connect succeeds -> warmup starts
   +-- Persistent socket re-established
   +-- iPhone shows "Connected" in Bluetooth settings

4. Manual reconnect button:
   +-- Bluetooth Inquiry (5 sec radio scan)
   +-- BluetoothAuthenticateDeviceEx (re-auth)
   +-- Enable HFP/A2DP profiles
```

---

## Enterprise Edition

### SaaS Backend (Supabase)
- **Auth**: Email/password + Google OAuth
- **Database**: PostgreSQL with Row-Level Security
  - `orgs`: Organization management
  - `contents`: Uploaded images/videos metadata
  - `org_members`: User-org membership with roles
- **Storage**: Supabase Storage bucket for content files
- **Auto-trigger**: New org creator auto-added as admin member

### Admin Dashboard (web/dashboard.html)
- Single-page app using Supabase JS SDK v2
- Google login + email/password login
- Upload images/videos with SHA-256 hash
- Content list with type/position badges
- Delete content with storage cleanup
- Copy Org ID for employee client setup

### P2P Content Distribution
- **Discovery**: UDP broadcast on port 49152 every 30 seconds
  - Announcement format: `SS|orgId|version|ip|tcpPort`
  - Peer TTL: 90 seconds
- **Transfer**: TCP file server
  - Protocol: `GET filename\n` -> `SIZE\n` -> raw bytes
  - Download priority: LAN peers first, Supabase server fallback
  - Atomic file writes (.tmp -> rename)

### Content Flow
```
Admin uploads image/video via web dashboard
    |
    v
Supabase Storage + Database record
    |
    v
First employee PC downloads from Supabase (WinHTTP)
    |
    v
P2P: Other PCs discover via UDP, download via TCP
    (no further server access needed)
```

---

## Landing Page (web/index.html)
- Hero: "When your phone moves away, screen auto-locks"
- 6 feature cards: BT detection, auto-lock, smart unlock, custom screen, timeline, auto-reconnect
- 3-step how-to: Install -> Select device -> Auto-protection
- Enterprise section: P2P diagram + feature list
- Pricing: Personal (free) / Enterprise (contact)
- Hosted on GitHub Pages: https://icesgg.github.io/smartscreen/

---

## Build Requirements
- Windows 11
- Visual Studio 2022 Community (C++ Desktop workload)
- CMake 3.20+

### Build Commands
```batch
cd c:\work\smartscreen
build.bat
```
Or via Developer Command Prompt:
```batch
mkdir build && cd build
cmake .. -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
nmake
```

### Linked Libraries
ws2_32, bthprops, user32, gdi32, comctl32, shell32, gdiplus, comdlg32, winhttp, mfplat, mf, mfplay, mfuuid, ole32, propsys

---

## Development History

| Date | Phase | Changes |
|------|-------|---------|
| 2026-04-06 | Initial | BLE RSSI monitor -> Classic BT RFCOMM -> Dual-socket approach |
| 2026-04-06 | BT | Auto-reconnect, warmup period, persistent socket |
| 2026-04-06 | Screen | BlackScreen integration, idle detection hooks |
| 2026-04-06 | UI | Overlay widget, settings/user screen separation |
| 2026-04-06 | Images | GDI+ image loading, center + banner layout |
| 2026-04-07 | Lock | Manual lock, unlock delay, lock/unlock time display |
| 2026-04-07 | GitHub | Repository created, GitHub CLI setup |
| 2026-04-08 | Modular | Split into 6 modules (common, config, bluetooth, blackscreen, globals, main) |
| 2026-04-08 | Personal | Image file picker (Browse), config persistence (INI) |
| 2026-04-08 | Enterprise | Supabase schema, admin dashboard, WinHTTP client |
| 2026-04-08 | P2P | UDP discovery + TCP transfer modules |
| 2026-04-08 | Video | Media Foundation (MFPlay) video playback |
| 2026-04-08 | Web | Landing page, GitHub Pages deployment |
| 2026-04-09 | Auth | Google OAuth login for admin dashboard |
| 2026-04-09 | Fixes | FAR instant activation, unlock delay for both modes |

---

## Key Technical Decisions

1. **Classic BT over BLE**: iPhone rotates BLE MAC address every ~15 minutes, making tracking impossible. Classic BT address is permanent for paired devices.

2. **Dual-socket approach**: Socket 1 keeps the BT link alive (iPhone shows "Connected"), Socket 2 measures latency without disrupting the connection. This solved the iPhone disconnection flicker issue.

3. **Latency-based proximity**: RFCOMM connection latency correlates roughly with distance when the BT link is active. ~80ms = very close, ~200ms = nearby, timeout = far away.

4. **FAR = instant lock**: Instead of waiting for idle countdown after FAR, the black screen activates immediately on FAR transition. The delay setting controls how long before unlock is allowed.

5. **Supabase over custom backend**: Zero server code needed. Auth, database, storage, and REST API are all provided by Supabase. The admin dashboard is a static HTML file.

6. **P2P for enterprise**: After the first client downloads content from Supabase, subsequent clients on the same LAN download from peers via TCP. This minimizes server bandwidth and works behind corporate firewalls.
