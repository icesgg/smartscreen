# SmartScreen - Project Summary

## Overview
SmartScreen is a Windows 11 application that uses Bluetooth proximity detection to automatically lock/unlock the screen when the user leaves or returns to their desk. It combines a BT proximity monitor with a customizable screen saver, supporting both personal and enterprise use cases.

Proximity is measured from BLE signal strength with a companion iOS app;
see `docs/PROXIMITY.md` for the design and the measurements behind it.

**Repository**: https://github.com/icesgg/smartscreen
**Landing Page**: https://icesgg.github.io/smartscreen/

---

## Core Features

### 1. Bluetooth Proximity Detection
- **BLE RSSI + 1-D Kalman filter**: physical signal strength decides near/far.
  (The original RFCOMM-latency detector reached 30-50 m and could not find a desk.)
- **Companion iOS app (SSBeacon) is required**: an iPhone stops advertising when
  locked, so the app keeps a signal alive from the pocket.
- **Two paths, chosen automatically**:
  - *Advertisement*: app advertises, PC scans. Works on every adapter tested.
    Median update 1.7 s.
  - *GATT connection*: PC is the peripheral, app connects and reports its own
    connection RSSI at 1 Hz. Needs an adapter that really supports the BLE
    peripheral role - most USB dongles do not.
- **IRK address resolution**: the phone's address rotates every ~15 min and
  carries no name, so advertisements are matched by re-deriving the address
  hash from the phone's IRK.
- **Latency probe retained as a last resort** only when no BLE signal has ever
  been seen in the session.

See `docs/PROXIMITY.md` for the design, the measurements and the adapter
compatibility results.

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
|   +-- bluetooth.h/cpp      # Classic BT probe (fallback), reconnect, enumeration
|   +-- ble_rssi.h/cpp       # BLE advertisement scanner, Kalman filter, IRK resolution
|   +-- ble_gatt.h/cpp       # BLE GATT server (PC as peripheral) for the 1 Hz path
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
+-- ios/SSBeacon/            # Companion iOS app (Swift, build on a Mac)
|   +-- SSBeaconApp.swift    # Advertises, and connects when the PC allows it
|   +-- README.md            # Xcode setup (needs both BLE background modes)
|
+-- tools/                   # Standalone diagnostics, built separately
|   +-- btcheck.cpp          # Adapter capability report
|   +-- advscan.cpp          # Run on a second PC to see if this one advertises
|
+-- docs/                    # GitHub Pages (copy of web/) + design notes
|   +-- PROJECT_SUMMARY.md
|   +-- PROXIMITY.md         # Proximity detection design and measurements
|   +-- index.html
|   +-- dashboard.html
|
+-- supabase/
|   +-- schema.sql           # Database schema + RLS policies
|
+-- images/                  # Default local images (optional)
+-- CMakeLists.txt           # Build configuration
+-- do_build.bat             # Build script (vcvarsall + cmake + nmake)
+-- build.bat                # Older build script
+-- build_run.bat            # Build via VS Developer Command Prompt
```

---

## Configuration Parameters

Set in the settings window, or in `%APPDATA%\SmartScreen\config.ini` for the
ones with no UI. Thresholds must be measured per adapter and per desk -
`dist/README.txt` §4 has the procedure.

| Key | Default | Description |
|-----|---------|-------------|
| `nearRssiThreshold` | -65 dBm | Advertisement path threshold. The "신호 강도" box |
| `gattRssiThreshold` | -55 dBm | GATT path threshold (phone-measured, different scale) |
| `bleLostMeansFar` | 1 | Signal lost = user away. Turn off only when running without the app |
| `bleTimeoutSec` | 90 | Silence this long counts as lost |
| `bleIrk` | (none) | Phone's identity key. Belongs to the phone, copyable between PCs |
| `bleGattServer` | 1 | Offer the GATT path at all |
| `bleGattEncrypt` | 0 | Require link encryption (needs a per-PC LE bond) |
| `gattSeen` | 0 | Set once the app has connected; afterwards no connection means absence |
| `bleDebugLog` | 0 | Log every advertisement to `ble_scan_log.csv`. For tuning only |
| `keepAliveSec` | 5 | Grace before FAR on the latency path |
| `idleCountdownSec` | 20 | Idle time before the black screen |
| `unlockDelaySec` | 0 | Delay before an unlock is allowed |

Diagnostics land next to the config: `events.log` (state changes, locks, GATT
lifecycle - always on), `gatt_rssi_log.csv`, `ble_scan_log.csv`.

---

## State Machine

```
                    RSSI >= threshold
[FAR] ──────────────────────────────> [NEAR]
  |   <──────────────────────────────   |
  |     RSSI < threshold, or            |
  |     no packet for bleTimeoutSec     |
  |                                     |
  | FAR transition                      | NEAR: suppress idle countdown
  v                                     |
[BLACK SCREEN]                          |
  |   <── NEAR + unlock delay ─────────+
  |   <── mouse/keyboard (immediate)
  |   <── "Release" button (immediate)
  v
[NEAR] (screen unlocked)
```

Locking is suppressed for 5 s after any input: someone typing is present
whatever the radio says.

---

## Detection Flow

```
Start monitoring
  +-- start GATT server (PC as peripheral); may fail on adapters without the role
  +-- start advertisement scanner (always)
  +-- load IRK from config
  +-- worker thread wakes on every packet, and at least every 2 s

Each judgement, in order of preference:
  1. GATT link healthy      -> use the RSSI the phone reported (1 Hz)
  2. companion expected but -> absent; lock
     not connected
  3. advertisement matched  -> use scanned RSSI
     (IRK, else service UUID when no IRK is set)
  4. nothing                -> Classic RFCOMM latency probe, throttled to 20 s
                               while the GATT server waits for a client
```

The phone is matched by resolving its rotating address with the IRK. The
companion app's service UUID is shared by every install, so it is used only to
bootstrap a PC that has no IRK yet.

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
do_build.bat
```
Or via Developer Command Prompt:
```batch
mkdir build && cd build
cmake .. -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
nmake
```

### Linked Libraries
ws2_32, bthprops, user32, gdi32, comctl32, shell32, gdiplus, comdlg32, winhttp, mfplat, mf, mfplay, mfuuid, ole32, propsys, windowsapp (WinRT), bcrypt

The CRT is linked statically so a test PC needs no VC++ redistributable.

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
| 2026-09-21 | Proximity | RFCOMM latency -> BLE RSSI + Kalman; IRK address resolution |
| 2026-09-21 | Companion | iOS app (SSBeacon); iPhone stops advertising when locked |
| 2026-09-21 | GATT | PC as BLE peripheral, app reports connection RSSI at 1 Hz |
| 2026-09-22 | Adapters | Peripheral role unreliable on USB dongles; advertisement path made primary |
| 2026-09-22 | Dual role | App advertises and connects, so any adapter works |
| 2026-09-22 | Tooling | BtCheck, AdvScan, event log; measured defaults |

---

## Key Technical Decisions

1. **BLE RSSI over Classic BT latency** (reversed 2026-09-21): the original
   reasoning - that a rotating BLE address makes an iPhone untrackable - was
   right about the address and wrong about the conclusion. The address is
   resolvable with the phone's IRK, and RFCOMM latency never worked as a
   distance measure because Classic BT carries 30-50 m. Classic pairing is
   still what puts the phone in the device list.

2. **Dual-socket Classic probe** (now fallback only): socket 1 keeps the link
   alive so the iPhone shows "Connected", socket 2 measures latency without
   disturbing it. Used only when no BLE signal has been seen all session.

3. **A companion app is required, not optional**: an iPhone stops advertising
   when it locks, and a silent phone is indistinguishable from an absent one.
   An app holding the `bluetooth-peripheral` background mode keeps advertising
   from a locked phone in a pocket.

4. **The advertisement path carries the product**: the 1 Hz GATT path needs the
   PC to act as a BLE peripheral, and of four adapters tested only a laptop's
   internal Intel radio actually did - two dongles claimed support and did not
   deliver. Scanning works everywhere, so the app does both roles and the PC
   takes whichever it can get.

5. **FAR = instant lock**: Instead of waiting for idle countdown after FAR, the black screen activates immediately on FAR transition. The delay setting controls how long before unlock is allowed.

6. **Supabase over custom backend**: Zero server code needed. Auth, database, storage, and REST API are all provided by Supabase. The admin dashboard is a static HTML file.

7. **P2P for enterprise**: After the first client downloads content from Supabase, subsequent clients on the same LAN download from peers via TCP. This minimizes server bandwidth and works behind corporate firewalls.
