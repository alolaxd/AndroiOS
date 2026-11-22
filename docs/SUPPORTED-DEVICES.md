# Supported devices

Requirements: an A13 chip or newer, iOS/iPadOS 16+, JIT through StikDebug (or equivalent), and
the memory entitlements (GetMoreRAM, TrollStore or a paid developer profile).

**None of these devices has been tested yet.** Guest RAM defaults come from
`DeviceCapabilities.swift`. FPS columns are projections from the host measurements in
[PERFORMANCE.md](PERFORMANCE.md), not results.

| Device | Chip | RAM | Default guest RAM | Max guest RAM | Projection |
|---|---|---|---|---|---|
| iPhone 11 | A13 | 4 GB | 2 GB | 2.5 GB | Android at 540×960 only; UI well under 30 FPS |
| iPhone 12 | A14 | 4 GB | 2 GB | 2.5 GB | as above |
| iPhone 13 / 13 mini | A15 | 4 GB | 2 GB | 2.5 GB | tight on RAM for Android 13 |
| iPhone 13 Pro / 14 | A15 | 6 GB | 3 GB | 4 GB | usable at 720×1280 |
| iPhone 14 Pro / 15 | A16 | 6 GB | 3 GB | 4 GB | usable at 720×1280 |
| iPhone 15 Pro / 16 / 16 Pro | A17 Pro / A18 / A18 Pro | 8 GB | 4 GB | 6 GB | closest to the measured host |
| iPad Air 5 / iPad Pro M1–M4 | M-series | 8–16 GB | 4 GB | 6–8 GB | best: more cores, better thermals |

Notes:
- **iPad 8th gen (A12)** is older than A13: it runs, but slowly.
- **JIT on iOS 26+ with newer chips** (TXM-based): debugger-attached JIT changed. Check that
  your StikDebug version supports your iOS version. Without JIT the app cannot boot a VM.
- Guest RAM above 50% of device RAM shows a warning. Without `increased-memory-limit`, iOS
  kills the app at around 3 GB.
