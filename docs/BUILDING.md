# Building AndroiOS

## Requirements
- macOS on Apple silicon with Xcode (tested: Xcode 27.2, iOS SDK 27.2) and its **Metal
  Toolchain** component: `xcodebuild -downloadComponent MetalToolchain`. ANGLE compiles Metal shaders.
- Homebrew: `pkg-config`, `xcodegen`, `qemu` (QEMU is used only to *provision* the guest image under HVF).
- About 40 GB of free disk: ANGLE's checkout alone is 12 GB.
- The scripts set `DEVELOPER_DIR=/Applications/Xcode.app/...` if `xcode-select` points at the CLT.
  Meson, ninja, distlib and PyYAML go into a private venv at `Engine-C/build/venv`.

## 1. Engine (per platform: `device`, `simulator`, `macos`)
```sh
git submodule update --init                       # QEMU v9.2.4
Engine-C/build-angle.sh --platform=device         # ANGLE (Metal) → libEGL/libGLESv2 frameworks
Engine-C/build-ios.sh   --platform=device         # glib, pixman, libslirp, libepoxy, virglrenderer, QEMU
```
Output in `Engine-C/build/device/`: `QEMU.framework`, `libEGL.framework`, `libGLESv2.framework`.
The `macos` platform builds the same engine as dylibs for the test harness.

## 2. App
```sh
xcodegen generate             # AndroiOS.xcodeproj from project.yml
Scripts/build-ipa.sh          # → build/AndroiOS.ipa, ad-hoc signed, entitlements + get-task-allow
```
`Scripts/build-all.sh` runs steps 1 and 2. `Scripts/sign-ipa.sh <ipa> [identity]` re-signs an IPA.

## 3. Guest image
```sh
Guest/fetch-lineage.sh        # LineageOS 23.2 (Android 16) VM, recommended
# alternative: Ubuntu + Waydroid (LineageOS 20), slower and with a compositor in between:
Guest/build-guest.sh          # → Guest/build/{vmlinuz, initrd.img, androios.qcow2}  (~10 min, ~6 GB)
```
This boots the Ubuntu 24.04 arm64 cloud image under HVF and provisions it with cloud-init
(`Guest/cloud-init/user-data`):
- Mesa (virgl), `cage`, `seatd`, `glmark2-es2-drm`, `linux-modules-extra` (binder);
- Waydroid plus `waydroid init`, which downloads LineageOS 20 (Android 13) images;
- autologin on tty1 → `cage -- waydroid show-full-ui` (`androios.mode=android`);
- `androios-gpu.service`, which points Waydroid at the virgl render node on each boot;
- `androios-bench.service` (`androios.mode=bench`) and boot-progress markers on the serial console.

The script checks every component and fails loudly if any is missing.

## 4. Testing without a device
```sh
Engine-C/tests/run-engine-harness.sh config.json [seconds] [expect] [send]
#   AIOS_FRAME_PNG=out.png   save the guest display (every 30 s, and at exit)
#   AIOS_FRAME_SERIES=1      keep one PNG per 30 s
#   AIOS_SWIPE=1             drive the touchscreen with swipes after `expect`
#   AIOS_UNTIL=marker        stop when the serial console prints `marker`
```
The config takes the same JSON keys as the app's engine (see `Engine-C/AndroiOSEngine.h`).

## Patches
| Patch | Why |
|---|---|
| `qemu-ios-library` | Emulator as a dylib (`qemu_ios_main`) and BQL-safe host entry points. iOS has no `fork`/`exec`. |
| `qemu-ios-mmap-jit` | iOS lacks `pthread_jit_write_protect_np`, so TCG must use split-W^X (`mach_vm_remap`). |
| `qemu-ios-metal-display` | `-display ios[,gl=es]`: scanout → IOSurface (GL blit through ANGLE's IOSurface pbuffer). Also multitouch/key injection and the ANGLE EGL display on Apple. |
| `qemu-ios-audio` | `-audiodev ios`: real-time-paced PCM callback to the app. |
| `qemu-ios-no-fork`, `qemu-ios-block-statfs` | iOS build fixes. |

## Status

| Piece | State |
|---|---|
| QEMU TCG JIT in-process (split-W^X) | ✅ verified (harness) |
| GPU: Android GLES → Mesa virgl → UTM virglrenderer → UTM libepoxy → WebKit ANGLE → Metal | ✅ verified: LineageOS 23.2 renders with text |
| IOSurface display → Metal | ✅ verified |
| Touch (USB tablet), audio (AC97), network (SLIRP) | ✅ touch/audio verified; ADB over SLIRP works |
| iOS app | builds for device and simulator; **not yet run on hardware** |

History: the first GPU stack (upstream virglrenderer 1.1.1, Chromium ANGLE, patched
libepoxy) rendered Android with **no text**. Switching to UTM's pinned components fixed it.
UTM's virglrenderer carries Apple/ANGLE fixes, among them integer vertex attributes on
ANGLE/Apple, which Skia's glyph rendering relies on.

Guest note: Android formats the PERSIST partition without a filesystem label, so GRUB's
`grubenv` options (e.g. `android_insecure_adb`) are ignored until you label it or set them
in `grub.cfg` on the EFI partition.
