/*
 * AndroiOSEngine — public C API exposed to Swift.
 *
 * Drives QEMU.framework in-process. Graphics path when "gpu" is "virgl":
 *   guest GLES (Mesa virgl) → virtio-gpu → virglrenderer → libepoxy
 *     → ANGLE (GLES on Metal) → IOSurface → host MTKView
 */
#ifndef ANDROIOS_ENGINE_H
#define ANDROIOS_ENGINE_H

#include <stdint.h>
#include <stdbool.h>
#include <IOSurface/IOSurfaceRef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    AIOS_STOPPED = 0,
    AIOS_STARTING,
    AIOS_RUNNING,
    AIOS_PAUSED,
    AIOS_SAVING,
    AIOS_ERROR,
} aios_state_t;

typedef enum {
    AIOS_JIT_AVAILABLE = 0,           /* debugger attached; on TXM devices it prepares regions */
    AIOS_JIT_NO_MAPPING,              /* mmap failed */
    AIOS_JIT_NOT_EXECUTABLE,          /* no debugger attached (CS_DEBUGGED unset) */
    AIOS_JIT_NEEDS_UNIVERSAL_SCRIPT,  /* iOS 26+ TXM device: debugger did not answer brk #0xf00d */
} aios_jit_status_t;

/* Whether QEMU's JIT can run. Never executes code. On iOS 26+ TXM devices it
 * test-prepares one page via StikDebug's universal.js handshake. */
aios_jit_status_t aios_jit_probe(void);

/* ---- callbacks (all invoked on engine threads, never the main thread) ---- */
typedef void (*aios_console_callback)(const char *bytes, int len, void *ctx);
typedef void (*aios_exit_callback)(int status, void *ctx);
/* New frame in `surface` (BGRA). Same surface until the resolution changes. */
typedef void (*aios_frame_callback)(IOSurfaceRef surface, int width, int height,
                                    uint64_t seq, void *ctx);
/* Interleaved native-endian s16 PCM. */
typedef void (*aios_audio_callback)(const int16_t *samples, int frames,
                                    int sample_rate, int channels, void *ctx);

typedef struct {
    aios_console_callback console;
    aios_exit_callback on_exit;
    aios_frame_callback frame;     /* optional */
    aios_audio_callback audio;     /* optional */
    void *ctx;
} aios_callbacks_t;

/*
 * Create the VM from a JSON config. Keys:
 *   "kernel", "initrd", "dtb", "append", "bios", "disk"   (paths / strings)
 *   "disks" (array of paths, boot order = array order)
 *   "efi_code", "efi_vars" (UEFI pflash: edk2 code read-only, NVRAM vars writable)
 *   "ram_mb" (default 1024), "cpus" (default 1)
 *   "gpu": "virgl" (ANGLE/Metal 3D) | "2d" | "none" (default "none")
 *   "display_width", "display_height" (guest resolution, default 1080x1920)
 *   "network" (bool, default false) and "port_forwards" (["tcp::5555-:5555", ...])
 *   "audio" (bool, default false: guest sound → AVAudioEngine)
 *   "sound_device": "virtio" (default) | "ac97" | "hda"
 *   "touch_device": "multitouch" (default, virtio) | "tablet" (USB tablet + keyboard)
 *   "restore_from" (path written by aios_vm_save_snapshot)
 *   "firmware_dir" (-L), "extra_args" (array of strings, appended verbatim)
 * This build uses TCG's native JIT backend; it cannot run without JIT.
 * Returns a VM id >= 0, or -1. Only one VM per process (QEMU limitation).
 */
int aios_vm_create(const char *config_json);
int aios_vm_start(int vm_id, const aios_callbacks_t *callbacks);
int aios_vm_pause(int vm_id);
int aios_vm_resume(int vm_id);
int aios_vm_stop(int vm_id);
aios_state_t aios_vm_get_state(int vm_id);
/* Guest RAM actually configured (may be lower than requested: see memory budget). */
long aios_vm_guest_ram_mb(int vm_id);
/* Memory warning: shrink the guest by 512 MB through virtio-balloon (min 1 GB).
 * Returns the new target in MB, or -1. Frees host memory; the VM keeps running. */
long aios_vm_relieve_memory_pressure(int vm_id);
/* What iOS lets this process use in total (available + current footprint), MB.
 * ~3.5 GB on 8 GB iPhones without increased-memory-limit, ~6 GB with it. */
long aios_process_memory_limit_mb(void);

/* Save full VM state to `path` (pauses the guest). 0 on success. The device
 * set must be migratable: virgl ("gpu":"virgl") is not, so this fails there. */
int aios_vm_save_snapshot(int vm_id, const char *path, char *err, int err_len);

/* ---- input --------------------------------------------------------------- */
enum { AIOS_TOUCH_DOWN = 0, AIOS_TOUCH_MOVE = 1, AIOS_TOUCH_UP = 2, AIOS_TOUCH_CANCEL = 3 };
/* x/y in guest display pixels; slot 0-9. */
void aios_vm_send_touch(int vm_id, int slot, int x, int y, int pressure, int action);
/* Linux evdev keycode (KEY_*). */
void aios_vm_send_key(int vm_id, int keycode, int down);
/* Bytes to the guest serial console. */
int aios_vm_console_send(int vm_id, const char *bytes, int len);

/* ---- audio pull (for AVAudioSourceNode's render block; lock-free SPSC) ---- */
/* Fills `frames` stereo float frames into left/right; returns frames that were
 * real audio (the rest is zero-filled). Real-time safe. */
int aios_audio_read(float *left, float *right, int frames);
int aios_audio_sample_rate(void);   /* 0 until the guest opens a stream */

/* ---- info ---------------------------------------------------------------- */
typedef struct {
    double fps;                 /* guest frames delivered per second */
    double cpu_percent;         /* process CPU, 100 = one core */
    uint64_t ram_used_bytes;    /* process physical footprint */
    double thermal_pressure;    /* 0..1, filled in by the app */
} aios_perf_stats_t;
aios_perf_stats_t aios_vm_get_perf_stats(int vm_id);

const char *aios_vm_command_line(int vm_id);

#ifdef __cplusplus
}
#endif

#endif /* ANDROIOS_ENGINE_H */
