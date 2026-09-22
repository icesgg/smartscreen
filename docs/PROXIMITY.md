# Proximity Detection Design

How SmartScreen decides whether the user is at the desk, why it is built this
way, and what was measured. Written after replacing the original
latency-based detector (2026-09-21/22).

---

## The problem with the original approach

The first detector measured how long a Classic Bluetooth RFCOMM connection
took to establish, every 2 seconds, and called the user "near" below a
latency threshold.

It did not work as a proximity signal. Classic BT reaches 30-50 m, so the
latency barely changed between sitting at the desk and standing in another
room. The near/far boundary landed anywhere between 30 and 50 m depending on
walls and orientation, which is not a desk.

The replacement measures physical signal strength (RSSI, dBm) and smooths it
with a 1-D Kalman filter. RSSI falls off predictably with distance and body
shadowing, so a threshold can separate "at the desk" from "left the room".

---

## What an iPhone will and will not tell you

Three iOS behaviours shape the entire design. All three were confirmed by
measurement, not assumed.

**It does not put its name in advertisements.** Matching on a device name
never fires. Over a 2.5-minute scan, 231 distinct addresses were seen and
only three carried a name; none was the phone.

**Its address rotates.** The advertised address is a Resolvable Private
Address that changes roughly every 15 minutes, so a stored address matches
nothing. Resolving it requires the phone's IRK (see below).

**It stops advertising when locked.** This is the decisive one. With the
screen off, the phone went silent: over 10 minutes of a locked phone lying
next to the receiver, zero advertisements were resolved, while other Apple
devices in the room were heard continuously. A phone that is silent cannot
be distinguished from a phone that left.

That last point is why a companion app is not optional. An iOS app holding
the `bluetooth-peripheral` background mode keeps advertising while the phone
is locked; two third-party BLE apps tested (nRF Connect, LightBlue) did not,
which is what made the constraint look like an iOS limitation at first.

---

## Identifying the phone: IRK

The phone's advertised address is generated from its Identity Resolving Key:

```
ah(IRK, prand) = AES-128(IRK, 0…0 ‖ prand)   // low 24 bits == address hash
```

Windows receives the IRK when an LE bond is created and stores it under
`HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys\<adapter>\<device>`,
readable only as SYSTEM. `client/ble_rssi.cpp` re-derives the hash for each
random address with bcrypt and accepts the ones that match.

Two properties matter for deployment:

- The IRK belongs to the **phone**, not the PC. The same value works on every
  PC, so it can be copied rather than re-extracted.
- It is the **only** signal that identifies one particular phone. The
  companion app's service UUID is shared by every install of the app, so
  matching on it alone would let a colleague's phone hold the screen open.
  The scanner therefore resolves the address first and falls back to the
  service UUID only when no IRK is configured, which is the bootstrap case on
  a fresh PC.

Extraction is automated behind the "기기 키" button, because the key lives
where only SYSTEM can read it and no amount of user instruction makes that
pleasant. The app relaunches itself elevated (`--import-irk`), the elevated
instance registers a one-shot scheduled task that runs the app once more as
SYSTEM (`--dump-irk`), and that instance walks
`Keys\<adapter>\<device>` and writes every IRK it finds to a temp file. The
elevated instance then correlates those addresses against the paired BLE
devices reported by WinRT, picks the one whose name matches the selected
phone, stores it in config and deletes the temp file. Where exactly one key
exists it is taken without the name check.

Picking the right one matters: a bonded BLE mouse's IRK would resolve just as
well and would then sit on the desk holding the screen open forever.

The user still needs an LE bond to exist at all, which on Windows means
pairing the phone through Phone Link once.

---

## Two paths

The PC prefers whichever is available. Nothing to configure.

| | Advertisement | GATT connection |
|---|---|---|
| Roles | app = peripheral, PC = scanner | PC = peripheral, app = central |
| PC must support | BLE scanning | BLE **peripheral role** |
| Update rate | median 1.7 s, p90 5.8 s, max 20 s | 1 s |
| Identification | IRK | the connection itself |
| Works on | every adapter tested | one of four adapters tested |

**Advertisement path** (`client/ble_rssi.cpp`). The app advertises; the PC
scans and resolves the address. This is the default because scanning works
everywhere.

**GATT connection path** (`client/ble_gatt.cpp`). The PC runs a GATT server
with two characteristics: the PC notifies `TICK`, which wakes the app even
while the phone is locked, and the app writes back the connection RSSI it
measured. A connected LE link is not throttled the way background
advertising is, so this gives a steady 1 Hz.

Why the app has to be the central: CoreBluetooth exposes `readRSSI()` only on
`CBPeripheral`, i.e. from the central side, and WinRT exposes no connection
RSSI at all. If the PC wants a measurement faster than advertising allows,
the phone has to take it, which means the phone connects outward and the PC
must be connectable.

---

## Adapter compatibility

`IsPeripheralRoleSupported` is reported by the driver and cannot be trusted.

| Adapter | Driver | Reports peripheral role | Actually works |
|---|---|---|---|
| Intel Wireless (laptop internal) | Intel, 2019 | yes | **yes** |
| BARROT BT 5.4 USB | Barrot, oem inf | yes | no — advertisement never reached the phone |
| BARROT BT 6.0 USB | Barrot, oem inf | yes | no — phone connected, service absent |
| USB dongle on inbox driver | Microsoft (Generic Bluetooth Radio) | **no** | n/a, honest |

Windows also reported the advertisement as `Started` on the adapters that
were not transmitting, so the PC's own logs cannot settle it either. Two
checks observe the radio from outside and are the only reliable ones:

- the phone connecting (`GATT: linked` in the status bar), or
- `AdvScan.exe` run on a second PC.

`BtCheck.exe` reports the flag and says so.

Because of this, the advertisement path carries the product and the
connection path is a bonus where the hardware allows it. A desktop can use
any Bluetooth 5.x dongle.

---

## Measurements

Phone locked, in a trouser pocket, companion app running.

**GATT path, Intel internal radio**

| | smoothed RSSI |
|---|---|
| seated | −39 … −49 dBm |
| 10 m away | −63 … −76 dBm |

Threshold −55 dBm; screen locked 13 s after standing up, unlocked on return.

**Advertisement path, USB dongle**

| | smoothed RSSI |
|---|---|
| seated | −49 … −61 dBm |
| 10 m away | −69 … −75 dBm |

Threshold −65 dBm. Packet gaps: median 1.7 s, p90 5.8 s, max 19.9 s.

Absolute values are not portable. Antennas differ by 10-20 dB between
adapters, and body shadowing costs another 20-30 dB versus a phone on the
desk. **Re-measure after changing adapter or desk**; the procedure is in
`dist/README.txt` §4.

---

## Filtering and judgement

**Kalman filter** (`KalmanFilter` in `ble_rssi.h`). Process noise is per
*second*, not per sample, so a value arriving after a 30-second gap is
trusted more than one arriving 200 ms after the last. Q=1.0 on the
advertisement path, Q=4.0 on the GATT path where samples are dense enough to
track faster. R=10.0 on both.

`−127 dBm` is Windows' out-of-range marker rather than a measurement and is
discarded before it reaches the filter.

**Hysteresis.** On the GATT path, locking uses the threshold and unlocking
uses threshold+4 dB, so a value sitting on the boundary does not flap.

**Timeout.** No packet for `bleTimeoutSec` (default 90 s) means the signal is
lost. With the companion app advertising this is generous; without it, sparse
system advertisements arrive 30-60 s apart and the timeout is what stops the
gaps from reading as absence. The 90 s also bounds the worst-case detection
time when the phone is switched off rather than carried away.

**Recent input wins.** Locking is suppressed for 5 s after any mouse or
keyboard event. Someone typing is present regardless of what the radio says,
and without this a stale reading could lock the screen out from under them.

**A lost signal means absence** (`bleLostMeansFar`, default on). The
companion app advertises continuously, so silence means the phone left.
Falling back to the latency probe here would reinstate the 30-50 m blind spot
the rewrite set out to remove. Turn it off only when running without the app.

---

## Battery

The GATT path wakes the phone once a second, which is the only meaningful
cost; a connected BLE link on its own is handled by the phone's radio. The PC
therefore sends `TICK` only when it needs an answer:

| PC state | interval |
|---|---|
| input within the last 5 s | none — the input already proves presence |
| idle 5 s … 2 min | 1 s |
| idle over 2 min | 3 s |
| screen locked | 2 s — watching for return |

The advertisement path costs the phone nothing beyond advertising, which it
does regardless.

---

## Radio contention

One antenna serves scanning, advertising and Classic connections, and they
interfere.

The latency probe opened a Classic RFCOMM connection every 2 seconds. An
iPhone refuses those unless a PAN link happens to be up, so on a PC without
one the probe failed and retried continuously, and the BLE advertisement and
the phone's connection attempt lost their slots — the phone could not find a
PC that was, by its own logs, advertising. While the GATT server is up and no
client has connected, the probe now runs at most every 20 s.

An earlier change stopped the advertisement scanner while a companion app was
expected, on the theory that scanning and advertising were competing. It was
reverted: the evidence never supported it, and afterwards a dongle stopped
being discoverable at all.

---

## Bugs found while building this

Recorded because most were invisible without instrumentation.

- The visible threshold edit box was overwritten at creation by a leftover
  hidden control, so typed values were ignored and the default was always
  used.
- `DbgEvent` opened the log denying write access to other threads, so
  concurrent lines vanished — including the ones that would have explained an
  aborted advertisement.
- Windows leaves GATT advertising in `Aborted` if it is restarted too soon
  after a stop, and calling `StartAdvertising` again does nothing; it has to
  be stopped first.
- `lastReceivedTick` was written from the WinRT callback thread and read from
  the scan thread without being atomic.
- Requiring link encryption needs an LE bond, and bonds are per-PC, so moving
  the phone to a second machine silently broke the connection path.
- The companion app re-armed a pending connect to the same PC after a
  disconnect without resuming scanning, so it could never find a different
  one.
- Header order: `config.h` pulls in `winsock2.h` and had to precede the WinRT
  headers, which pull in `windows.h`.
