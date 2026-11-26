<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="AndroiOS app icon">
</p>

<h1 align="center">AndroiOS</h1>

<p align="center">Android on iOS, reimagined.</p>

## Disclaimer
**This app can not be published to the App Store.**
This is because:
1. Apple does not natively allow JIT (and the developer entitlements used to allow increased memory usage) on the App Store.
2. App Store policies state that the app must be closed source, with no public code available for anyone, which this app isn't (GPL-3.0, open source).
   
# Overview
Run Android (LineageOS 22.2 / Android 15 or LineageOS 23.2 / Android 16) on an iPhone or iPad. AndroiOS is a sideloaded
SwiftUI app that runs an AArch64 VM **in-process** with QEMU's JIT (TCG). Android's
OpenGL ES rendering runs on the **Apple GPU**:

```
Android (HWUI/SurfaceFlinger, GLES) ─► Mesa virgl ─► virtio-gpu ─► QEMU
   ─► virglrenderer ─► libepoxy ─► ANGLE ─► Apple GPU
   ─► IOSurface (3 rotating buffers) ─► CAMetalLayer (own render thread, up to 120 Hz)
```

ANGLE currently runs on Apple's OpenGL ES driver (its default on iOS). Its Metal backend, which
UTM uses (`ANGLE_DEFAULT_PLATFORM=metal`), is opt-in for now: Android's GL content renders black
there, so that's being worked on before it becomes the default.

The GPU components are the ones **UTM** ships on iOS: `utmapp/virglrenderer`,
`utmapp/libepoxy`, and ANGLE from `utmapp/WebKit` (Safari's ANGLE), all at UTM's pinned
commits. The guest is the prebuilt LineageOS `virtio_arm64only` VM from
[jqssun/android-lineage-qemu](https://github.com/jqssun/android-lineage-qemu), built for
UTM/QEMU: UEFI → GRUB → Android, Mesa virgl, drm_hwcomposer.

> **Emulation, not virtualization.** iOS gives apps no hypervisor, so every guest
> instruction goes through QEMU's JIT. GPU work runs natively on the Apple GPU; CPU-bound
> Android UI does not reach 60 FPS. See [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Verified (macOS harness running the iOS engine code)
- LineageOS 23.2 boots to setup in about 3–5 minutes, rendered on the Apple GPU with readable text
- Touch via USB tablet: taps dismiss dialogs and advance the setup wizard
- Audio: AC97 (`fixed-volume=on`) → QEMU `ios` audiodev at 48 kHz → app; real (non-silent) samples
- App installs: an APK streamed over ADB installs with `Success`
- Boot animation at 40–50 FPS; GPU benchmark (glmark2) 103–130 FPS

## Android versions
The setup wizard downloads one of two images (from this repo's releases), both LineageOS
`virtio_arm64only` VMs tuned for emulation by `Guest/make-lite.sh`:

| Version | Download | Notes |
|---|---|---|
| **LineageOS 22.2 (Android 15)** (recommended) | 1.0 GB | LineageOS's low-performance VM mode: Android Go low-RAM tuning, 50× system timeouts (no "isn't responding" pop-ups). Best on 4 GB devices like the iPad 10. |
| LineageOS 23.2 (Android 16) | 1.2 GB | Newest, but heavier. Low-performance mode crashes Android 16's SystemUI, so it runs without it. |

Both skip the boot animation. Android 14 and older have no prebuilt QEMU/UTM arm64 image to start from.

**Phone or tablet layout.** Each VM has an *Android layout* setting. Phone gives Android a
360 dp-wide screen (720×1280 at 320 dpi). Tablet gives it 720 dp in this screen's shape
(e.g. 1080×1552 at 240 dpi on an iPad 10), so Android uses its tablet UI. On iPad, new VMs
default to tablet. The app passes the density to QEMU as an SMBIOS string
(`-smbios type=1,sku=<dpi>`); the images' GRUB reads it with its `smbios` module and boots
Android with `androidboot.lcd_density=<dpi>`. Images without that (before v0.3.1) always use 320.

## Installing apps and games
With **Install apps from AndroiOS** on (VM settings, default on), the VM menu can install an APK
from Files, or F-Droid with one tap (from F-Droid, Aurora Store gives access to Google Play's
catalog). AndroiOS talks to Android's ADB service through a port forward bound to 127.0.0.1, so it
is never reachable from the network. Needs an image from v0.4 or later (GRUB reads `adb=1` from
SMBIOS). Only 64-bit ARM apps run, and apps that need Google Play Services may not work.

## Known Issues
- **No sound. Fixed in v0.4.0-alpha.** QEMU's AC97 card starts with its volume muted, and
  Android's audio HAL (ALSA UCM profiles) never unmutes it, so every sample was zero. The card now
  ignores the guest's hardware mixer (`fixed-volume=on`; Android applies volume in software), and
  QEMU mixes at 48 kHz to match the app (it was 44.1 kHz played as 48 kHz).
- **Guest RAM capped at ~1.2 GB on 4 GB iPads.** AndroiOS reserved a fixed 1.5 GB for QEMU, the
  JIT and the GPU. v0.4.0-alpha allows up to the iOS limit minus ~0.9 GB, and a memory watchdog
  shrinks Android (virtio-balloon) whenever iOS has less than ~320 MB left for the app.
- **Display slower than the guest (30–45 FPS shown while Android renders more).** v0.4.0-alpha
  draws on its own thread instead of the main thread, polls GPU fences every 1 ms instead of 10 ms,
  rotates 3 frame buffers, skips refreshes without a new frame and runs at 120 Hz on ProMotion.
  ANGLE's Metal backend (opt-in `angle_backend`) adds GPU-side frame sync, but Android's GL content
  is black there for now, so the default stays ANGLE's OpenGL backend.
- **Very slow setup (1–2 FPS, taps ignored).** The 1–2 FPS on still screens is normal: Android only
  draws when something changes. The setup wizard is heavy under emulation; the Android 15 image runs
  in low-RAM mode, which makes it lighter. The "first launch takes a few minutes" badge no longer
  comes back after Android's first frame, so it doesn't swallow taps (v0.2.2).
- **Freezes at 0 FPS until you pull down Notification Center; crashes during boot. Fixed in v0.2.1-alpha, awaiting on-device confirmation.**
  Cause: memory. Without the increased-memory-limit entitlement an 8 GB iPhone gives an app ~3.5 GB,
  so iOS sent memory warnings, and AndroiOS **paused** the VM on each one (0 FPS, idle CPU); becoming
  active again resumed it. When memory ran out, iOS killed the app. Now memory warnings shrink
  Android through virtio-balloon (returning memory to iOS) without pausing, the default guest RAM
  is based on what iOS actually allows the app, and the setup screen shows that limit and whether
  the memory entitlement is active. QEMU threads also run at user-interactive QoS, as in UTM.
- **App unresponsive after the LineageOS download. Fixed in v0.2.1-alpha.** Download progress
  callbacks ran on the main thread (tens of thousands for 1.2 GB). They now run in the background
  with progress shown 4 times a second, and the wizard continues automatically when the download ends.
- Dark screen / crash at launch with JIT on iOS 26+: fixed in v0.2.0-alpha. Confirmed on an
  iPhone 16 Pro: LineageOS reaches its boot animation.
- SideStore "The file can't be opened": fixed in v0.2.0-alpha (10 MB IPA, in-app LineageOS download).

## JIT on iOS 26+
On iOS 26 and later, devices with the Trusted Execution Monitor (TXM, A15 and newer) only run code
in regions the attached debugger has prepared. AndroiOS:
1. maps QEMU's 256 MB code buffer read+execute (no `MAP_JIT`, no RW→RX flip);
2. asks StikDebug to prepare it: `x0` = address, `x1` = size, `x16` = 1, `brk #0xf00d`
   (a SIGTRAP handler turns a missing debugger into an error message, not a crash);
3. creates a read-write alias with `vm_remap` for QEMU's split-W^X (`tcg_splitwx_diff`);
4. detaches the debugger (`x16` = 0, `brk #0xf00d`) so QEMU's signals no longer stop the process.

The legacy `brk #0x69` handshake is not used; current `universal.js` rejects it. Devices without
TXM, and iOS versions before 26, only need the debugger-attached flag (`CS_DEBUGGED`). Progress is
logged to Console.app under the subsystems `com.androios.engine` and `com.androios.qemu`.

Runs well on real devices as of v0.3.1-alpha (tested on an iPhone 16 Pro, iOS 26+; v0.4.0-alpha not yet tested on a device): JIT works through StikDebug's universal.js script, and Android boots and is usable.

## Quick start
```sh
git clone --recursive <this repo> && cd AndroiOS
Scripts/build-all.sh          # WebKit ANGLE + engine + app → build/AndroiOS.ipa
Guest/fetch-lineage.sh        # LineageOS 23.2 VM (verified attestation) → Guest/build/lineage/
```
On the device:
1. Sideload `AndroiOS.ipa` (10 MB) from the [releases](https://github.com/alolaxd/AndroiOS/releases).
2. Apply the memory entitlements with GetMoreRAM, TrollStore, or a paid developer profile.
   Without them, AndroiOS lowers guest RAM to what iOS allows the app instead of being killed.
3. Enable JIT with StikDebug using the **universal.js** script.
4. In the setup wizard, pick an Android version (LineageOS 22.2 / Android 15 is recommended, ~1 GB) and a phone
   or tablet layout, download it, then boot.
5. To add apps, open the VM menu: **Install app from Files (APK)** or **Install F-Droid**.

`Scripts/build-ipa.sh --with-guest` can still bundle the disks into a ~1 GB IPA for Xcode or
TrollStore installs; SideStore cannot sign IPAs that large.

## Layout
| Path | What |
|---|---|
| `App/` | SwiftUI app: VM manager, setup wizard, Metal display, touch/keyboard, audio, settings, app installer (minimal ADB client) |
| `Engine-C/AndroiOSEngine.{h,m}` | C API: lifecycle, UEFI/disks, display/input/audio callbacks, frame sync, memory watchdog, snapshots, perf |
| `Engine-C/build-angle.sh` | WebKit ANGLE (UTM's pin) → `EGL.framework`, `GLESv2.framework` |
| `Engine-C/build-ios.sh` | glib, pixman, libslirp, UTM libepoxy + virglrenderer, QEMU → `QEMU.framework` |
| `Engine-C/ios-patches/` | QEMU 9.2.4 patches: in-process dylib, iOS JIT, IOSurface display, audio, input |
| `Engine-C/tests/` | macOS harness (`run-engine-harness.sh`) plus GL checks |
| `Guest/fetch-lineage.sh` | Fetches and verifies the LineageOS VM |
| `Guest/make-lite.sh` | Tunes a LineageOS disk for emulation (GRUB: low-perf mode, no boot animation, density from the host) and compresses it |
| `Guest/build-guest.sh` | Alternative guest: Ubuntu + Waydroid (see docs/BUILDING.md) |

## Important Context
**Almost all of this app's code was made by Claude**. Claude wrote the code, ironed everything out, but the design decisions, ideas, architecture choices, and direction were all mine. I guided the implementation, decided how things should work, and shaped the end result. I'm a student, still learning. Expect to see some of my own updates without Claude 🙂


## License
QEMU is GPL-2.0; the patches and code linked into `QEMU.framework` are GPL-2.0-or-later.
virglrenderer and libepoxy are MIT, ANGLE is BSD-3-Clause, and LineageOS is under its
own licenses. The app icon contains the Android robot, which is reproduced or modified from work
created and shared by Google and used according to terms described in the Creative Commons 3.0
Attribution License.
