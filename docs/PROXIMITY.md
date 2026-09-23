# Proximity Detection Design

How SmartScreen decides whether the user is at the desk, why it is built this
way, and what was measured. Written after replacing the original
latency-based detector (2026-09-21/22), and again after replacing the IRK
with a token the phone serves (2026-09-23).

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
nothing. Working out which phone it is takes a connection, or its IRK;
both are below.

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

## Identifying the phone

A locked phone advertises a rotating Resolvable Private Address and
nothing else, so the packet alone never says which phone it is. Two
mechanisms answer that: a token the phone serves over GATT, which is how
it works now, and the IRK, which is what it replaced and is still carried
where a bond happens to exist.

A shorter walk-through of the same mechanism, in Korean, is in
[IDENTIFICATION.md](IDENTIFICATION.md).

### The phone serves a token

`ios/SSBeacon` publishes a GATT service (`7A1C0020`) holding a 16-byte
value generated once at install, in a read-only characteristic
(`7A1C0021`). The PC connects as a central, reads it, compares it with
the value stored at registration, and disconnects
(`client/ble_ident.cpp`).

Measured: a locked, **unpaired** iPhone with the app in the background
accepts the connection, serves discovery, and returns the token. No bond
and no registry are involved, which is the entire point — the IRK route
below needs an LE bond, and on Windows that means setting up Phone Link
once.

Confirmed end to end on a second machine (2026-09-23). A desktop was
registered, the stored IRK was then deleted, and with the phone locked
the scanner kept it bound and held NEAR on the token alone. Binding took
2313 ms — a connect, a discovery and a read — which against a fifteen
minute address rotation is under a third of a percent of the radio's
time.

The characteristic carries its value inline rather than answering a
delegate callback, so CoreBluetooth serves it from its own cache without
waking the app. That is what makes the read dependable while the phone
is locked, and it costs no battery.

The connection is for identity only. RSSI still comes from
advertisements: WinRT exposes no connection RSSI, and CoreBluetooth's
`readRSSI()` is central-side only, so a phone acting as a peripheral
cannot measure it either. The link is dropped as soon as the token is
read, because holding it open can stop the phone advertising.

Registration requires the app to be **in the foreground**, where iOS
still puts the name and service UUID in the packet. Registering from a
locked phone would mean choosing a candidate blind, and the candidate
could be a colleague's.

The phone hosts this service under a different UUID from the one the PC
hosts for the connection path. With one UUID for both, the app's own
central scan finds a neighbouring phone and tries to treat it as a PC.

### Narrowing the candidates

Connecting to every unknown address in range would be slow and rude, so
candidates are filtered first, by the shape of Apple's overflow area.

A backgrounded iOS app's service UUIDs move into manufacturer data type
`0x01` as a 128-bit field. One advertised UUID lights exactly one bit,
giving a 17-byte payload with a popcount of one. Over a capture of 4048
addresses, 954 carried a type `0x01` message but only 13 had that shape;
the rest were 24-byte `01 09 20 22 …` messages with 41 to 75 bits set,
which the length alone rejects.

The bit is learned by observation. Apple's hash is never computed, and
does not need to be known. What the bit is **not** is an identity:

- it moves when the advertised UUID changes — observed 116 → 85 → 31,
  the last when the app switched from advertising `7A1C0010` to
  `7A1C0020`
- it survived a phone reboot, so it is not per-boot either; yet it did
  move once between days for reasons still unknown
- a neighbouring phone was observed setting the same bit, connected to,
  and rejected by the token read

So it is a filter that keeps the candidate list short, and one that
heals itself: when it goes stale the scanner widens to any single-bit
advertiser and relearns the bit from whichever one answers with the
right token. Anything weaker than ten dB below the threshold is skipped
— a phone that far away cannot hold the screen open anyway.

Probing runs on its own thread. A connection attempt takes seconds and
can take twenty, which is far too long to spend in a scan callback.

### IRK, the earlier route

Windows receives the phone's IRK when an LE bond is created and stores it
under
`HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys\<adapter>\<device>`,
readable only as SYSTEM. `client/ble_rssi.cpp` re-derives
`ah(IRK, prand) = AES-128(IRK, 0…0 ‖ prand)` with bcrypt for each random
address and accepts the ones whose low 24 bits match.

The IRK belongs to the **phone**, not the PC, so the same value works on
every PC and can be copied rather than re-extracted. It also keeps
working after the bond that produced it is deleted, because it lives in
config from then on.

Extraction is automated behind the "기기 키" button: the app relaunches
itself elevated (`--import-irk`), that instance registers a one-shot
scheduled task running the app as SYSTEM (`--dump-irk`), which walks
`Keys\<adapter>\<device>` and writes every IRK it finds to a temp file.
The elevated instance correlates those addresses against the paired BLE
devices reported by WinRT, picks the one whose name matches the selected
phone, stores it and deletes the temp file. Where exactly one key exists
it is taken without the name check.

Picking the right one matters: a bonded BLE mouse's IRK resolves just as
well and would then sit on the desk holding the screen open forever.

This path still runs, and still runs first when an IRK is configured. It
is no longer the way in, because no amount of automation removes the
pairing step it depends on.

### Choosing the target

The device list offers paired devices, which contradicts a design whose
point is not needing a pairing. A registered phone therefore heads the
list and is selected by default. Choosing it turns off address and name
matching entirely, so a paired device that happens to advertise cannot
feed the same filter, and skips the RFCOMM probe, which has no address
to reach.

This was not hypothetical. With the phone unpaired and absent from the
list, the target silently became a pair of Bluetooth headphones.

---

## Two paths

The PC prefers whichever is available. Nothing to configure.

| | Advertisement | GATT connection |
|---|---|---|
| Roles | app = peripheral, PC = scanner | PC = peripheral, app = central |
| PC must support | BLE scanning | BLE **peripheral role** |
| Update rate | median 1.7 s, p90 5.8 s, max 20 s | 1 s |
| Identification | a token read over GATT | the connection itself |
| Works on | every adapter tested | one of four adapters tested |

**Advertisement path** (`client/ble_rssi.cpp`). The app advertises; the PC
scans, and confirms which advertiser is the phone by reading its token.
This is the default because scanning works everywhere.

**Losing the connection is not absence.** Once the app has connected, a
dropped GATT link is a hint that the user left, but only a hint: if the
scanner can still hear the phone, the advertisement path decides. Absence
requires both to be quiet. Treating the drop alone as absence blanked the
screen while the phone was a metre away and audible at −46 dBm, because
the app had briefly dropped its link. What must **not** be used as a
fallback here is the latency probe, which reaches 30-50 m.

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

Phone locked and the companion app running throughout. In the first two
runs the phone was in a trouser pocket; in the third it stayed wherever
it is normally kept, which is the condition that matters — see the
warning at the end of this section.

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

Packet gaps: median 1.7 s, p90 5.8 s, max 19.9 s.

Those two are the original runs and their thresholds are superseded by
the ones below. They are kept because the spread between them and the
later runs is the argument for measuring per desk.

**Both paths, Intel internal radio, second desk (2026-09-23)**

Two minutes seated, two away, one back, twice, with the walk at either
end excluded. Smoothed values:

| run | path | seated n | seated | away n | away |
|---|---|---|---|---|---|
| 07:56 | advertisement | 295 | −59 … −47 | 50 | −76 … **−61** |
| 08:24 | advertisement | 202 | **−63** … −44 | 58 | −79 … −69 |
| 08:24 | GATT | 115 | **−62** … −45 | 49 | −73 … **−66** |

Each run on its own separates cleanly, and each suggests a different
threshold — the second advertisement run puts the boundary six dB lower
than the first. Taken together the two runs overlap: seated reaches −63
and away reaches −61.

### Two samples below is a lock

There is no *time* grace period on the BLE paths, and there should not be:
the smoothed value does not move between packets, so waiting on a clock
adds delay without adding evidence. `keepAliveSec` still applies only to
the latency path.

Counting *samples* is a different question, because the second packet is
new evidence. The state machine requires two consecutive new samples
below the threshold before it moves to FAR:

```c
if (sampleTick != belowSampleTick) { if (belowCount == 0) belowFirstTick = now; ++belowCount; }
goFar = (belowCount >= 2) || (now - belowFirstTick) >= BELOW_SAMPLE_CAP_MS;
```

`sampleTick` is the arrival time of the packet or report that produced the
reading, so re-judging the same smoothed value does not count twice. That
distinction is the whole point: the scan loop also wakes on a timer, and
counting loop iterations would reinstate exactly the time delay the
paragraph above rejects.

The wait has to be bounded. A phone that goes quiet while its owner walks
away may never deliver a second sample, and the receive timeout is 90 s;
without a cap a real departure could hold the screen open for a minute and
a half. `BELOW_SAMPLE_CAP_MS` is 6 s, just past the measured p90 packet gap
of 5.8 s, so nine times in ten the second sample decides and the cap never
binds. When it does bind, six seconds of silence is itself weak evidence of
distance.

Measured over every below-threshold run in the accumulated logs at −64:

| path | runs | one sample only, now ignored | two or more | cap expiry |
|---|---|---|---|---|
| advertisement | 114 | **35** | 74 | 5 |
| GATT | 23 | **4** | 19 | 0 |

So about a third of advertisement-path locks were one unlucky packet. The
price is a median 1.7 s of extra delay on a real departure, and at most
six.

The cost on a real departure was measured directly, in a walk-away test on
the laptop at −64. The smoothed GATT value fell from −53 to −66 over four
seconds and stayed there; the first below-threshold sample landed at
17:38:37.8 and the second 2.0 s behind it, so the rule moves that lock to
17:38:39.8. The screen blanked on a departure that had happened, two
seconds later than before.

What this does **not** fix is the shape of the seated distribution. A run
of two is common wherever a run of one is, so **the threshold still has to
sit below the lowest seated reading**. The rule buys a margin against
single unlucky packets and nothing more; it is not a substitute for
measuring.

| run | path | lowest seated |
|---|---|---|
| 07:56 | advertisement | −59 |
| 08:24 | advertisement | **−63** |
| 08:24 | GATT | −62 |

**Both thresholds are −64**: below every seated reading measured, while
every away stretch is caught within five to nine seconds, with four dB
of slack before detection starts to slow. The hysteresis then asks for
−60 to return to NEAR, above the best away sample of either path, so the
state does not bounce back.

−60 had been set from the first run alone, where seated bottomed out at
−59. The second run reached −63. Nothing in the first run's percentiles
hinted at it; only measuring twice found it.

A desktop later ran at −55 and blanked while its user sat still: seated
had reached −56, one dB past the line.

So: measure twice, and compare the *minimum* of seated against the
*maximum* of away. Percentiles and averages both hide the one sample
that does the damage.

### Re-measuring

Absolute values are not portable: two runs at the same desk, minutes
apart, disagreed by six dB, and the earlier USB-dongle figures by more
than ten. Antennas differ by 10-20 dB between adapters, and body
shadowing costs another 20-30 dB versus a phone on the desk.
**Re-measure after changing adapter, desk, or where the phone is kept,
and measure twice.** Repeat the procedure above, then compare the lowest
seated reading against the highest away reading. Averages and
percentiles both hide the one sample that blanks the screen.
`ble_scan_log.csv` and `gatt_rssi_log.csv` hold what is needed when
`bleDebugLog=1`.

`tools/rssi-threshold.ps1` does the arithmetic. Given the segment times it
reads both logs, trims the walk off either end, and replays the actual FAR
rule over the samples, so what it reports is the highest threshold at which
the seated run would not have locked — not a percentile. It defaults to the
last session, which matters: both logs are appended to across runs, so the
same clock time occurs in them many times over.

The two paths track each other closely: matched within two seconds, the
GATT reading is a median 2 dB stronger than the advertisement reading
(p5 −4, p95 +8, n=245). Measuring one and borrowing the other is
defensible for a first guess, which is where −60 came from, but the
borrowing is what left the GATT threshold unverified for a day.

---

## Filtering and judgement

**Kalman filter** (`KalmanFilter` in `ble_rssi.h`). Process noise is per
*second*, not per sample, so a value arriving after a 30-second gap is
trusted more than one arriving 200 ms after the last. Q=1.0 on the
advertisement path, Q=4.0 on the GATT path where samples are dense enough to
track faster. R=10.0 on both.

`−127 dBm` is Windows' out-of-range marker rather than a measurement and is
discarded before it reaches the filter.

**Hysteresis.** Locking uses the threshold and unlocking uses
threshold+4 dB, so a value sitting on the boundary does not flap. Only
the GATT path had this at first; the advertisement path compared straight
against the threshold, and once the seated distribution's lower tail
reached it, a decibel of noise flipped the verdict.

**The log records the threshold that decided.** State transitions print
the effective value — hysteresis applied — next to the configured one.
Printing only the setting hides the 4 dB and makes a verdict impossible
to reproduce from the log afterwards.

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
- `LoadAppConfig` returned whether a Classic address was stored rather than
  whether a config was read, and its caller applied every other setting
  inside that `if`. A registered phone has no Classic address, so the whole
  configuration was about to be discarded on startup.
- `GattDeviceService` is `IClosable`. Left open, Windows holds the LE
  connection, and after a handful of probes every later connection returns
  `Unreachable`.
- `ConnectionStatus` and `GattSession` are not usable as a gate: a discovery
  that succeeded reported `Disconnected` and `Closed` throughout, because
  Windows connects only for the duration of the operation.

Three of these were dormant until link encryption was turned off. Without
it the companion app never connected, so the code that runs once it has —
the GATT threshold, the absence rule, the config flag — had never
executed and had never been shown to be wrong. Turning on a path that
has never run is not a small change.

**Wrong guesses, recorded so they are not made again.** An hour went
into a fault where BLE scanning kept working while every outgoing
connection returned `Unreachable`. It was blamed in turn on contention
with A2DP headphones, on a stale bond against a rotating address, on the
service-handle leak above, and on a bond left on the phone. Each was
plausible, each was wrong, and disconnecting, unpairing and restarting
the radio changed nothing. A reboot cleared it. A radio toggle reloads
the driver; it does not reset the controller. Worth reaching for earlier
than it was.

The overflow bit was also assumed to change on reboot, from a single
observation of it moving overnight. It does not: it survived a reboot
and moved when the advertised UUID changed. The conclusion drawn from
the wrong reason — that it cannot serve as an identity — happened to
hold.
