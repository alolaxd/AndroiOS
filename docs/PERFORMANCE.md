# Performance

All numbers come from `Engine-C/tests/run-engine-harness.sh`. It runs the guest through
**the same code the iOS app uses**: TCG JIT with split-W^X, `-display ios,gl=es`, virgl →
virglrenderer → libepoxy → ANGLE (Metal) → IOSurface. The host was an Apple-silicon Mac whose
GPU reports as *Apple A18 Pro* (the iPhone 16 Pro chip). **No iPhone measurements exist yet.**
Treat these as an upper bound for an A18 Pro iPhone: phones throttle sooner and have less RAM.

## Measured

| Workload | Result |
|---|---|
| Alpine Linux 6.18, serial console | boots to shell in **7 s** |
| Ubuntu 24.04 guest kernel → userspace | Linux up in **28–38 s** |
| Guest GL renderer string | `virgl (ANGLE (Apple, ANGLE Metal Renderer: Apple A18 Pro))`, OpenGL ES 3.0 Mesa 25.2.8 |
| glmark2-es2 `build` (vbo) | **131 FPS** |
| glmark2-es2 `texture` | **131 FPS** |
| glmark2-es2 `shading` (phong) | **115 FPS** |
| glmark2-es2 `refract` | **77 FPS** |
| glmark2-es2 `terrain` | **67 FPS** |
| glmark2-es2 score | **103** |
| LineageOS 20 (Android 13) boot animation, 720×1280 | **40–54 FPS** delivered to the IOSurface |
| LineageOS 20 boot to Launcher3 resumed | **~4.5 min** (first boot) |
| **LineageOS 23.2 (virtio_arm64) boot animation** | **40–50 FPS** |
| LineageOS 23.2 boot to setup wizard | **~3 min** (later boots), ~5 min (first boot) |
| glmark2 texture scene presented to the IOSurface (UTM stack) | **127–130 FPS** |

What this says:
- **GPU-bound work hits 60+ FPS.** Guest GL runs natively on the Apple GPU. The remaining
  per-call cost is the virgl command stream, which the guest CPU encodes under emulation.
- **CPU-bound work is the limit.** Android's UI thread, ART, SurfaceFlinger and the Wayland
  compositor all run under TCG. During boot all 4 vCPUs sit at ~300% host CPU.

## Knobs that matter (in order)

1. **Resolution**: 540×960 roughly halves per-frame guest CPU work compared with 1080×1920
   (Settings → Display).
2. **vCPUs = performance cores**: MTTCG gives each vCPU its own host thread. More vCPUs than
   P-cores hurts.
3. **`-cpu max,pauth-impdef=on`**: the engine default. Architected pointer authentication (QARMA)
   costs a lot under TCG.
4. **`tb-size=256`**: a 256 MB translation cache avoids re-translating Android's large code footprint.
5. **Thermals**: at `.serious` the display drops to 30 FPS automatically (ThermalMonitor).
   Battery saver forces 30 FPS.

## Known gaps

- **virgl state isn't migratable** in QEMU, so 3D VMs pause in the background rather than snapshotting.
- **Host GLES is 3.0** (ANGLE Metal), so the guest gets OpenGL ES 3.0, not 3.1/3.2.
