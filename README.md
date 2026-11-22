# AndroiOS

Run Android (LineageOS 23.2 / Android 16) on an iPhone or iPad. AndroiOS is a sideloaded
SwiftUI app that runs an AArch64 VM **in-process** with QEMU's JIT (TCG). Android's
OpenGL ES rendering runs on the **Apple GPU**:

```
Android (HWUI/SurfaceFlinger, GLES) ─► Mesa virgl ─► virtio-gpu ─► QEMU
   ─► virglrenderer ─► libepoxy ─► ANGLE (GLES on Metal) ─► Apple GPU
   ─► IOSurface ─► MTKView
```

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
- Audio: AC97 → QEMU `ios` audiodev → app callback
- Boot animation at 40–50 FPS; GPU benchmark (glmark2) 103–130 FPS

The iOS app builds for device and simulator. It **has not yet run on a real iPhone.**

## Quick start
```sh
git clone --recursive <this repo> && cd AndroiOS
Scripts/build-all.sh          # WebKit ANGLE + engine + app → build/AndroiOS.ipa
Guest/fetch-lineage.sh        # LineageOS 23.2 VM (verified attestation) → Guest/build/lineage/
```
Easiest: `Scripts/build-ipa.sh --with-guest` produces `build/AndroiOS-LineageOS.ipa` (~1 GB)
with LineageOS 23.2 inside. On first launch, the setup wizard's **Use built-in LineageOS 23.2**
copies the disks into the app's storage and creates the VM.

On the device:
1. Sideload `AndroiOS-LineageOS.ipa`, or `AndroiOS.ipa` (10 MB) and copy `efi_vars.fd`,
   `vda.qcow2` and `vdb.qcow2` into AndroiOS's Documents yourself.
2. Apply the memory entitlements with GetMoreRAM, TrollStore, or a paid developer profile.
3. Enable JIT with StikDebug, then boot.

## Layout
| Path | What |
|---|---|
| `App/` | SwiftUI app: VM manager, setup wizard, Metal display, touch/keyboard, audio, settings |
| `Engine-C/AndroiOSEngine.{h,m}` | C API: lifecycle, UEFI/disks, display/input/audio callbacks, snapshots, perf |
| `Engine-C/build-angle.sh` | WebKit ANGLE (UTM's pin) → `EGL.framework`, `GLESv2.framework` |
| `Engine-C/build-ios.sh` | glib, pixman, libslirp, UTM libepoxy + virglrenderer, QEMU → `QEMU.framework` |
| `Engine-C/ios-patches/` | QEMU 9.2.4 patches: in-process dylib, iOS JIT, IOSurface display, audio, input |
| `Engine-C/tests/` | macOS harness (`run-engine-harness.sh`) plus GL checks |
| `Guest/fetch-lineage.sh` | Fetches and verifies the LineageOS VM |
| `Guest/build-guest.sh` | Alternative guest: Ubuntu + Waydroid (see docs/BUILDING.md) |

## Important Context
Almost all of this app's code was made by Claude. Claude wrote the code, ironed everything out, but the design decisions, ideas, architecture choices, and direction were all mine. I guided the implementation, decided how things should work, and shaped the end result.


## License
QEMU is GPL-2.0; the patches and code linked into `QEMU.framework` are GPL-2.0-or-later.
virglrenderer and libepoxy are MIT, ANGLE is BSD-3-Clause, and LineageOS is under its
own licenses.
