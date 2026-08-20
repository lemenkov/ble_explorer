<!--
SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# BLE Explorer

A playful window into the invisible radio world around you: scan for Bluetooth
LE devices, pick one, and hunt it by ear (Geiger-counter clicks that speed up as
you close in) and by eye (the whole screen goes blue-cold → red-hot). Built for
curiosity, not utility — the limitations of BLE (hidden names, rotating
addresses, un-connectable gadgets) become part of what's interesting to see.

This grew out of a `bleak` proof-of-concept (`ble-explorer.py`) that validated
the core signal logic on firefly. This is the phone-in-hand presentation layer.

## What's here

This is **source only** — the `lib/` tree, `pubspec.yaml`, and a manifest
snippet. It is not a full Flutter project (no `android/`, `ios/`, Gradle, etc.),
because those are generated per-machine by `flutter create`. Drop these files
into a fresh project as below.

```
lib/
  main.dart                 app entry + theme
  scan_screen.dart          screen 1: the radar / device picker
  hunt_screen.dart          screen 2: the blue→red + Geiger hunt
  ble/
    rssi_smoother.dart      EMA — smoothing is mandatory, not polish
    click_engine.dart       synthesised click + variable-rate scheduler
    ble_labels.dart         SIG company-id + service-uuid decoding
pubspec.yaml
android_manifest_snippet.xml
```

## Build & run

```bash
# 1. Scaffold a fresh project skeleton
flutter create --org net.lemenkov --project-name ble_explorer ble_explorer
cd ble_explorer

# 2. Overlay these files: replace pubspec.yaml and drop in lib/
#    (copy pubspec.yaml, lib/, android_manifest_snippet.xml from this bundle)

# 3. Merge the manifest permissions
#    Edit android/app/src/main/AndroidManifest.xml:
#      - add  xmlns:tools="http://schemas.android.com/tools"  to <manifest>
#      - paste the <uses-permission> block from android_manifest_snippet.xml
#        above <application>

# 4. minSdk: flutter_blue_plus needs API 21+. In android/app/build.gradle(.kts)
#    set  minSdk = 21  (Flutter's default flutter.minSdkVersion is usually fine).

# 5. Fetch deps and run on a real phone (BLE does NOT work in emulators)
flutter pub get
flutter run
```

iOS extra step (only if you build for iOS): add usage strings to
`ios/Runner/Info.plist` — `NSBluetoothAlwaysUsageDescription` and, for older
targets, `NSBluetoothPeripheralUsageDescription`.

## How it decides the signal source (automatically)

1. **Advertisement scan** — always available. Filtered to the picked device's
   remote id. Sparse and slow: cadence is however often the device chooses to
   advertise (could be one packet every few seconds).
2. **GATT `readRssi()`** — tried in parallel. If the device lets us connect, we
   poll it ~3×/sec for a smooth, fast signal and stop leaning on advertisements.
   If it refuses (many third-party gadgets do) or the link drops, we fall back.

The source chip on the hunt screen shows which one is live
(`live · GATT · fast` vs `advertisement · slow`) so the experience is honest
about its own quality.

## Knobs worth tuning

- `RssiSmoother.alpha` (`ble/rssi_smoother.dart`) — higher is snappier but
  jumpier. 0.25 is a starting point.
- `_farDbm` / `_nearDbm` (`hunt_screen.dart`) — the dBm window mapped onto the
  blue→red gradient and the click cadence. Calibrate to your phone's radio.
- `_minIntervalMs` / `_maxIntervalMs` / `_floor` (`ble/click_engine.dart`) —
  the click cadence envelope.

## Known limitations (by design, not bugs)

- **RSSI is a coarse proximity proxy.** A device in a metal drawer 2 m away can
  read the same as one 15 m away in open air. Trust the *trend* as you move, not
  any absolute number.
- **Rotating-address devices** (phones, Apple gear, some wearables) change their
  BLE identity every ~15 min *and* usually suppress their name — the lock can be
  lost mid-hunt. Your own hardware (ESP32, r4sGate) and simple static-address
  gadgets are rock-solid by comparison.
- **Public-vs-random address type** isn't cleanly exposed by flutter_blue_plus on
  Android; the picker uses a soft heuristic (no name advertised → possibly
  hiding). True address-type detection needs a platform channel — see roadmap.

## Picker controls (v0.2 — the crowded-room fixes)

The device list used to reorder on every advertisement packet (raw RSSI swings
~10 dBm), which made it impossible to land on a target in a busy place. Now:

- **Named vs Anonymous groups.** Devices that advertise (or that we resolved) a
  name sit in a top section; the anonymous churn (Apple & co.) drops below.
- **Per-device smoothing.** The list sorts on a smoothed RSSI, and in signal
  mode the key is bucketed to 5 dBm, so a row only moves when its signal changes
  meaningfully — no more micro-reshuffle.
- **Sort toggle** (app bar): *signal* (strongest first, bucketed/stable) or
  *name* (alphabetical, rock-steady — best for finding a specific device).
- **Freeze** (pause icon): stops all reordering so you can tap without the row
  moving. New devices append at the bottom; data still updates underneath.
- **Identify** (badge icon on anonymous *connectable* rows): connects, reads the
  GAP Device Name characteristic (0x2A00), caches it, and the device jumps up to
  the Named group. Connects are serialized (one at a time).
- **Auto-identify** (search icon, off by default): works through connectable
  anonymous devices in the background. Failures are remembered so it won't
  hammer a device that refused.

**Honest expectation for Identify:** the devices that crowd the list are mostly
Apple/phones, and those are the *least* likely to yield — they advertise as
non-connectable or reject connections, and even when reachable they rotate their
address and rarely expose a useful name. Identify mostly wins for peripherals and
DIY gear (ESP32 that keeps its name in GATT). The grouping + sort + freeze is
what actually solves "I can't find my target," not Identify.

## Roadmap / next slices

- Address-type detection via a small Android platform channel
  (`BluetoothDevice.getAddressType()`, API 35+) → a real "trackable vs rotating"
  badge in the picker.
- Calibration screen: hold the phone at arm's length from the target, tap to set
  "this is red," so the gradient means the same thing on every device.
- A haptic option (vibration pulses mirroring the clicks) for silent hunting.
- Ambient "radar" home view: all devices as proximity blobs, sortable/animated —
  the amusement-first visualiser, decoupled from picking one target.

_Assisted-by: Claude_
