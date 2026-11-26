/*
 * AndroiOSEngine — drives QEMU.framework in-process.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <TargetConditionals.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <unistd.h>
#include <errno.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <mach/task_info.h>
#include <stdatomic.h>
#include "AndroiOSEngine.h"
#include <QEMU/qemu-ios-api.h>

#define CONSOLE_ID "aios-con0"

/* ------------------------------------------------------------------- logging */

#include <os/log.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

static os_log_t engine_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.androios.engine", "engine"); });
    return log;
}
#define ELOG(fmt, ...) os_log(engine_log(), fmt, ##__VA_ARGS__)

/* ---------------------------------------------------------------- JIT probe */

/*
 * Never executes anything. (The old probe executed a freshly mapped page:
 * on iOS 26+ TXM devices that page was never prepared by the debugger, so the
 * app was killed at launch whenever JIT was enabled.)
 *
 *  - no CS_DEBUGGED                → JIT not enabled
 *  - iOS 26+ with TXM (A15+)       → test-prepare one RX page through the
 *                                    universal.js handshake (brk #0xf00d, x16=1);
 *                                    fails if StikDebug used another script
 *  - iOS < 26, or no TXM           → CS_DEBUGGED is all TCG needs
 *
 * QEMU itself prepares its code buffer and then detaches the debugger, after
 * which CS_DEBUGGED stays set but no debugger answers; a successful result is
 * therefore cached rather than re-tested.
 */
aios_jit_status_t aios_jit_probe(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    static aios_jit_status_t cached = AIOS_JIT_NOT_EXECUTABLE;
    static bool have_cached = false;
    if (have_cached && cached == AIOS_JIT_AVAILABLE) return cached;

    aios_jit_status_t st;
    if (!qemu_ios_jit_debugged()) {
        st = AIOS_JIT_NOT_EXECUTABLE;
    } else if (qemu_ios_jit_device_has_txm()) {
        size_t size = (size_t)getpagesize();
        void *rx = mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (rx == MAP_FAILED) {
            st = AIOS_JIT_NO_MAPPING;
        } else {
            st = qemu_ios_jit_prepare_region(rx, size) ? AIOS_JIT_AVAILABLE : AIOS_JIT_NEEDS_UNIVERSAL_SCRIPT;
            munmap(rx, size);
        }
    } else {
        st = AIOS_JIT_AVAILABLE;
    }
    ELOG("JIT probe: %{public}s (debugged=%d ios26=%d txm=%d)",
         st == AIOS_JIT_AVAILABLE ? "available" :
         st == AIOS_JIT_NEEDS_UNIVERSAL_SCRIPT ? "debugger did not answer brk #0xf00d (needs universal.js)" :
         st == AIOS_JIT_NO_MAPPING ? "mmap failed" : "not enabled",
         qemu_ios_jit_debugged(), qemu_ios_jit_is_ios26(),
         qemu_ios_jit_debugged() ? qemu_ios_jit_device_has_txm() : -1);
    cached = st; have_cached = true;
    return st;
#else
    return AIOS_JIT_AVAILABLE;   /* simulator / macOS harness: no restrictions */
#endif
}

/* -------------------------------------------------------------- memory budget */

/*
 * Guest RAM is mapped up front and faulted in as the guest touches it, so a
 * guest larger than what iOS lets this process use runs for a while and then
 * gets the app silently jetsam-killed. Without the increased-memory-limit /
 * extended-virtual-addressing entitlements that limit is low, so clamp:
 *   1. to os_proc_available_memory() minus our own overhead
 *      (256 MB TCG code buffer + ~512 MB QEMU, virgl, ANGLE, UI), and
 *   2. to what the address space can actually reserve.
 */
/* `reserve_mb`: memory kept for everything but guest RAM (QEMU, the 256 MB TCG
 * buffer, virgl/ANGLE/Metal, the UI). ~1.5 GB is safe even if the guest touches
 * all of its RAM. Less lets small devices give Android more; the memory watchdog
 * (below) then shrinks the guest before iOS runs out. */
static long guest_ram_budget_mb(long requested_mb, long reserve_mb) {
#if TARGET_OS_IPHONE
    long ram = requested_mb;
    const uint64_t overhead = (uint64_t)reserve_mb << 20;
    uint64_t avail = os_proc_available_memory();
    if (avail > overhead && ((uint64_t)ram << 20) + overhead > avail) {
        long fit = (long)((avail - overhead) >> 20) & ~255L;
        ram = fit < 1024 ? 1024 : fit;
    }
    while (ram > 1024) {
        void *p = mmap(NULL, (size_t)ram << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) { munmap(p, (size_t)ram << 20); break; }
        ram -= 512;
    }
    ELOG("memory: requested %ld MB, available to process %llu MB, guest gets %ld MB%{public}s",
         requested_mb, avail >> 20, ram,
         ram < requested_mb ? " (clamped: memory entitlements probably not active)" : "");
    return ram;
#else
    return requested_mb;
#endif
}

/* ------------------------------------------------------------------ VM state */

static struct {
    bool created;
    _Atomic aios_state_t state;
    NSArray<NSString *> *argv;
    char *cmdline;
    aios_callbacks_t cb;
    _Atomic bool qemu_done;
    int disp_w, disp_h;
    long ram_mb;          /* after the memory-budget clamp */
    long balloon_mb;      /* current balloon target, 0 = none */
    /* touch: per-slot tracking ids, -1 = up */
    int tracking[10];
    int next_tracking_id;
    /* perf */
    _Atomic uint64_t frames;
    uint64_t last_frames;
    double last_wall, last_cpu, fps;
} vm;

static NSString *fmt(NSString *f, ...) NS_FORMAT_FUNCTION(1, 2);
static NSString *fmt(NSString *f, ...) {
    va_list ap; va_start(ap, f);
    NSString *s = [[NSString alloc] initWithFormat:f arguments:ap];
    va_end(ap);
    return s;
}

static NSArray<NSString *> *build_argv(NSDictionary *cfg) {
    NSMutableArray *a = [NSMutableArray arrayWithObject:@"qemu-system-aarch64"];
    long reserve = [cfg[@"ram_reserve_mb"] longValue] ?: 1536;
    long ram  = guest_ram_budget_mb([cfg[@"ram_mb"] longValue] ?: 1024, MAX(768, MIN(1536, reserve)));
    vm.ram_mb = ram;
    long cpus = [cfg[@"cpus"] longValue] ?: 1;
    NSString *gpu = cfg[@"gpu"] ?: @"none";
    vm.disp_w = [cfg[@"display_width"] intValue] ?: 1080;
    vm.disp_h = [cfg[@"display_height"] intValue] ?: 1920;

    if (cfg[@"firmware_dir"]) [a addObjectsFromArray:@[@"-L", cfg[@"firmware_dir"]]];
    [a addObjectsFromArray:@[
        @"-nodefaults",
        @"-M", @"virt,highmem=on,gic-version=3",
        // pauth-impdef: cheap PAC emulation; the architected QARMA is very slow under TCG.
        @"-cpu", cfg[@"cpu"] ?: @"max,pauth-impdef=on",
        // split-wx: RX code buffer (debugger-prepared on iOS 26+ TXM devices) + RW alias.
        // This is how TCG JIT works under iOS W^X once a debugger grants CS_DEBUGGED.
        @"-accel", fmt(@"tcg,thread=%@,split-wx=on,tb-size=256", cpus > 1 ? @"multi" : @"single"),
        @"-m", fmt(@"%ld", ram),
        @"-smp", fmt(@"%ld", cpus),
        @"-monitor", @"none",
        @"-chardev", @"ringbuf,id=" CONSOLE_ID ",size=1048576",
        @"-serial", @"chardev:" CONSOLE_ID,
        @"-device", @"virtio-rng-pci",
        @"-device", @"virtio-balloon-pci,free-page-reporting=on",
    ]];

    if ([gpu isEqualToString:@"virgl"]) {
        // The GPU translation layer: virgl commands → virglrenderer → ANGLE → Metal.
        [a addObjectsFromArray:@[@"-display", @"ios,gl=es",
            @"-device", fmt(@"virtio-gpu-gl-pci,xres=%d,yres=%d", vm.disp_w, vm.disp_h)]];
    } else if ([gpu isEqualToString:@"2d"]) {
        [a addObjectsFromArray:@[@"-display", @"ios",
            @"-device", fmt(@"virtio-gpu-pci,xres=%d,yres=%d", vm.disp_w, vm.disp_h)]];
    } else {
        [a addObjectsFromArray:@[@"-display", @"none"]];
    }
    if (![gpu isEqualToString:@"none"]) {
        // "touch_device": "multitouch" (virtio, 10 points) | "tablet" (USB tablet +
        // keyboard: what UTM-targeted Android images such as LineageOS virtio expect).
        if ([cfg[@"touch_device"] isEqualToString:@"tablet"])
            [a addObjectsFromArray:@[@"-device", @"qemu-xhci,id=xhci",
                                     @"-device", @"usb-tablet,bus=xhci.0", @"-device", @"usb-kbd,bus=xhci.0"]];
        else
            [a addObjectsFromArray:@[@"-device", @"virtio-multitouch-pci", @"-device", @"virtio-keyboard-pci"]];
    }
    int adb_port = [cfg[@"adb_port"] intValue];
    if ([cfg[@"network"] boolValue] || adb_port > 0) {
        // Network off but ADB on: restrict=on keeps the guest offline while the
        // host can still reach the forwarded port.
        NSMutableString *net = [([cfg[@"network"] boolValue] ? @"user,id=net0" : @"user,id=net0,restrict=on") mutableCopy];
        for (NSString *fwd in cfg[@"port_forwards"] ?: @[]) [net appendFormat:@",hostfwd=%@", fwd];
        // ADB for APK installs: loopback only, never reachable from the network.
        if (adb_port > 0) [net appendFormat:@",hostfwd=tcp:127.0.0.1:%d-:5555", adb_port];
        [a addObjectsFromArray:@[@"-netdev", net, @"-device", @"virtio-net-pci,netdev=net0,romfile="]];
    }
    if ([cfg[@"audio"] boolValue]) {
        // "sound_device": virtio (default) | ac97 | hda — match what the guest kernel drives.
        NSString *snd = cfg[@"sound_device"] ?: @"virtio";
        // The app plays 48 kHz stereo, so have QEMU mix to exactly that (its default is
        // 44.1 kHz: audio played ~9% fast and kept running dry). A 5 ms timer delivers
        // smaller, steadier chunks than the 10 ms default.
        [a addObjectsFromArray:@[@"-audiodev",
            @"ios,id=snd0,timer-period=5000,out.frequency=48000,out.channels=2,out.fixed-settings=on"]];
        if ([snd isEqualToString:@"ac97"])
            [a addObjectsFromArray:@[@"-device", @"AC97,audiodev=snd0,fixed-volume=on"]];
        else if ([snd isEqualToString:@"hda"])
            [a addObjectsFromArray:@[@"-device", @"intel-hda", @"-device", @"hda-output,audiodev=snd0"]];
        else
            [a addObjectsFromArray:@[@"-device", @"virtio-sound-pci,audiodev=snd0,streams=1"]];
    }
    // UEFI boot (edk2): read-only code + writable NVRAM vars, both 64 MiB pflash images.
    if (cfg[@"efi_code"]) {
        [a addObjectsFromArray:@[@"-drive", fmt(@"if=pflash,unit=0,format=raw,readonly=on,file=%@", cfg[@"efi_code"])]];
        if (cfg[@"efi_vars"]) {
            // virt's flash banks are exactly 64 MiB. UTM ships a short vars file
            // (the store lives at the start), so zero-extend it in place.
            struct stat st;
            const char *vp = [cfg[@"efi_vars"] fileSystemRepresentation];
            if (stat(vp, &st) == 0 && st.st_size < (64 << 20)) truncate(vp, 64 << 20);
            [a addObjectsFromArray:@[@"-drive", fmt(@"if=pflash,unit=1,format=raw,file=%@", cfg[@"efi_vars"])]];
        }
    }
    if (cfg[@"bios"])   [a addObjectsFromArray:@[@"-bios", cfg[@"bios"]]];
    if (cfg[@"kernel"]) [a addObjectsFromArray:@[@"-kernel", cfg[@"kernel"]]];
    if (cfg[@"initrd"]) [a addObjectsFromArray:@[@"-initrd", cfg[@"initrd"]]];
    if (cfg[@"dtb"])    [a addObjectsFromArray:@[@"-dtb", cfg[@"dtb"]]];
    if (cfg[@"kernel"]) [a addObjectsFromArray:@[@"-append", cfg[@"append"] ?: @"console=ttyAMA0 earlycon"]];
    // Disks: "disk" (single) and/or "disks" (ordered list; boot order = list order).
    NSMutableArray *disks = [NSMutableArray array];
    if (cfg[@"disk"]) [disks addObject:cfg[@"disk"]];
    for (id d in cfg[@"disks"] ?: @[]) if ([d isKindOfClass:NSString.class]) [disks addObject:d];
    [disks enumerateObjectsUsingBlock:^(NSString *d, NSUInteger i, BOOL *stop) {
        // threads AIO (no io_uring on iOS); unmap keeps qcow2 files small.
        [a addObjectsFromArray:@[
            @"-drive", fmt(@"if=none,id=hd%lu,file=%@,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap",
                           (unsigned long)i, d),
            @"-device", fmt(@"virtio-blk-pci,drive=hd%lu,bootindex=%lu", (unsigned long)i, (unsigned long)i)]];
    }];
    if (cfg[@"restore_from"]) [a addObjectsFromArray:@[@"-incoming", fmt(@"file:%@", cfg[@"restore_from"])]];
    // Guest screen density for the AndroiOS images: their GRUB reads the SMBIOS
    // type 1 SKU string and passes it on as androidboot.lcd_density.
    // Read by the AndroiOS images' GRUB: SKU = screen dpi, family = options.
    if ([cfg[@"lcd_density"] intValue] > 0 || adb_port > 0) {
        NSMutableString *smbios = [@"type=1" mutableCopy];
        if ([cfg[@"lcd_density"] intValue] > 0) [smbios appendFormat:@",sku=%d", [cfg[@"lcd_density"] intValue]];
        if (adb_port > 0) [smbios appendString:@",family=adb=1"];
        [a addObjectsFromArray:@[@"-smbios", smbios]];
    }
    for (id x in cfg[@"extra_args"] ?: @[]) if ([x isKindOfClass:NSString.class]) [a addObject:x];
    return a;
}

int aios_vm_create(const char *config_json) {
    // ANGLE backend. With nothing set, WebKit's ANGLE uses its OpenGL backend:
    // Apple's EAGL OpenGL ES driver on iOS, CGL on macOS. That is what renders
    // Android correctly today. "angle_backend": "metal" selects ANGLE's Metal
    // backend (UTM's default, ANGLE_DEFAULT_PLATFORM=metal), which enables
    // GPU-side frame sync (EGL_ANGLE_metal_shared_event_sync), but Android's
    // virgl-rendered GL content currently comes out black there (the CPU-
    // uploaded boot console is fine). Opt-in until that is fixed.
    {
        NSData *d = [NSData dataWithBytes:config_json length:strlen(config_json)];
        NSDictionary *c = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSString *backend = [c isKindOfClass:NSDictionary.class] ? c[@"angle_backend"] : nil;
        if ([backend isKindOfClass:NSString.class] && backend.length)
            setenv("ANGLE_DEFAULT_PLATFORM", backend.UTF8String, 1);
    }
    if (vm.created) return -1;
    NSData *d = [NSData dataWithBytes:config_json length:strlen(config_json)];
    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![cfg isKindOfClass:NSDictionary.class]) return -1;
    vm.argv = build_argv(cfg);
    vm.cmdline = strdup([[vm.argv componentsJoinedByString:@" "] UTF8String]);
    ELOG("VM created: %{public}s", vm.cmdline);
    for (int i = 0; i < 10; i++) vm.tracking[i] = -1;
    vm.created = true;
    vm.state = AIOS_STOPPED;
    return 0;
}

static void on_frame(void *surface, int w, int h, uint64_t seq, void *ctx) {
    if (atomic_fetch_add(&vm.frames, 1) == 0) ELOG("first guest frame %dx%d", w, h);
    if (vm.cb.frame) vm.cb.frame((IOSurfaceRef)surface, w, h, seq, vm.cb.ctx);
}

/* Single-producer (QEMU audio timer) / single-consumer (CoreAudio render)
 * ring of interleaved stereo s16 frames. ~0.68 s at 48 kHz. */
#define RING_FRAMES 32768
static int16_t ring[RING_FRAMES * 2];
static _Atomic uint64_t ring_w, ring_r;
static _Atomic int ring_rate;

static void on_audio(const int16_t *frames, int n, int rate, int ch, void *ctx) {
    atomic_store_explicit(&ring_rate, rate, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ring_w, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ring_r, memory_order_acquire);
    for (int i = 0; i < n; i++) {
        if (w - r >= RING_FRAMES) break;           /* full: drop newest */
        int16_t L = frames[i * ch], R = ch > 1 ? frames[i * ch + 1] : L;
        ring[(w % RING_FRAMES) * 2] = L;
        ring[(w % RING_FRAMES) * 2 + 1] = R;
        w++;
    }
    atomic_store_explicit(&ring_w, w, memory_order_release);
    if (vm.cb.audio) vm.cb.audio(frames, n, rate, ch, vm.cb.ctx);
}

int aios_audio_read(float *left, float *right, int frames) {
    uint64_t r = atomic_load_explicit(&ring_r, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ring_w, memory_order_acquire);
    int avail = (int)MIN((uint64_t)frames, w - r);
    for (int i = 0; i < avail; i++, r++) {
        left[i]  = ring[(r % RING_FRAMES) * 2] / 32768.0f;
        right[i] = ring[(r % RING_FRAMES) * 2 + 1] / 32768.0f;
    }
    for (int i = avail; i < frames; i++) left[i] = right[i] = 0;
    atomic_store_explicit(&ring_r, r, memory_order_release);
    return avail;
}

int aios_audio_sample_rate(void) { return atomic_load_explicit(&ring_rate, memory_order_relaxed); }

/* ---- frame sync: MTLSharedEvent signalled with each frame's seq ---- */
static id<MTLSharedEvent> sync_event;

static void sync_cpu_signal(void *ev, uint64_t value) {
    ((__bridge id<MTLSharedEvent>)ev).signaledValue = value;
}

void *aios_display_sync_event(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (getenv("AIOS_NO_GPU_SYNC")) return;     /* test override: no event at all */
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        sync_event = [dev newSharedEvent];
        if (sync_event) ELOG("frame sync: MTLSharedEvent on %{public}s", dev.name.UTF8String);
    });
    return (__bridge void *)sync_event;
}

static void *qemu_thread(void *unused) {
    int argc = (int)vm.argv.count;
    char **argv = calloc(argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) argv[i] = strdup(vm.argv[i].UTF8String);
    qemu_ios_display_set_callback(on_frame, NULL);
    // NULL with AIOS_NO_GPU_SYNC (test override): QEMU then uses glFinish per
    // frame and the host never waits on the event.
    if (aios_display_sync_event())
        qemu_ios_display_set_sync_event(aios_display_sync_event(), sync_cpu_signal);
    qemu_ios_audio_set_callback(on_audio, NULL);
    vm.state = AIOS_RUNNING;
    ELOG("QEMU thread started (%d args)", argc);
    int status = qemu_ios_main(argc, argv);   /* blocks until the guest powers off */
    ELOG("QEMU exited with status %d", status);
    vm.qemu_done = true;
    vm.state = status == 0 ? AIOS_STOPPED : AIOS_ERROR;
    if (vm.cb.on_exit) vm.cb.on_exit(status, vm.cb.ctx);
    return NULL;
}

static void *console_thread(void *unused) {
    while (!vm.qemu_done) {
        if (vm.state == AIOS_RUNNING || vm.state == AIOS_PAUSED) {
            char *s = qemu_ios_console_read(CONSOLE_ID, 65536);
            if (s) {
                size_t n = strlen(s);
                if (n && vm.cb.console) vm.cb.console(s, (int)n, vm.cb.ctx);
                qemu_ios_free(s);
            }
        }
        usleep(16000);
    }
    return NULL;
}

/* Memory watchdog: iOS closes the app when it runs out of memory, and memory
 * warnings can arrive too late. Twice a second, if iOS has less than ~320 MB
 * left for the app, shrink the guest by 256 MB through virtio-balloon (Android
 * frees memory: caches first, then lmkd closes background apps). Grow it back
 * 256 MB at a time once there is plenty again. */
#define GUEST_MIN_MB 768
static void *memory_thread(void *unused) {
#if TARGET_OS_IPHONE
    double last_shrink = 0;
    while (!vm.qemu_done) {
        usleep(500000);
        if (vm.state != AIOS_RUNNING) continue;
        long avail = (long)(os_proc_available_memory() >> 20);
        long current = vm.balloon_mb ? vm.balloon_mb : vm.ram_mb;
        double now = CFAbsoluteTimeGetCurrent();
        long target = current;
        if (avail < 320 && current > GUEST_MIN_MB && now - last_shrink > 1.5) {
            target = MAX(GUEST_MIN_MB, current - 256);
            last_shrink = now;
        } else if (avail > 1024 && vm.balloon_mb && vm.balloon_mb < vm.ram_mb && now - last_shrink > 30) {
            target = MIN(vm.ram_mb, current + 256);
            last_shrink = now - 20;     /* next step up in >= 10 s */
        }
        if (target != current && qemu_ios_balloon_target_mb(target) == 0) {
            ELOG("memory watchdog: %ld MB left for the app, guest %ld -> %ld MB",
                 avail, current, target);
            vm.balloon_mb = target == vm.ram_mb ? 0 : target;
        }
    }
#endif
    return NULL;
}

static int spawn(void *(*fn)(void *), size_t stack, qos_class_t qos) {
    pthread_attr_t attr; pthread_t t;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, qos, 0);
    pthread_attr_setstacksize(&attr, stack);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int r = pthread_create(&t, &attr, fn, NULL);
    pthread_attr_destroy(&attr);
    return r;
}

int aios_vm_start(int vm_id, const aios_callbacks_t *callbacks) {
    if (vm_id != 0 || !vm.created || vm.state != AIOS_STOPPED || vm.qemu_done) return -1;
    if (callbacks) vm.cb = *callbacks;
    vm.state = AIOS_STARTING;
    // QEMU (main loop + vCPUs, which inherit it) at user-interactive QoS, as UTM
    // does: at default QoS iOS demotes it whenever the UI is idle or the device is hot.
    if (spawn(qemu_thread, 8 << 20, QOS_CLASS_USER_INTERACTIVE) != 0) { vm.state = AIOS_ERROR; return -1; }
    spawn(console_thread, 512 << 10, QOS_CLASS_UTILITY);
    spawn(memory_thread, 256 << 10, QOS_CLASS_UTILITY);
    return 0;
}

int aios_vm_pause(int vm_id)  { if (vm.state != AIOS_RUNNING) return -1; qemu_ios_pause();  vm.state = AIOS_PAUSED;  return 0; }
int aios_vm_resume(int vm_id) { if (vm.state != AIOS_PAUSED)  return -1; qemu_ios_resume(); vm.state = AIOS_RUNNING; return 0; }
int aios_vm_stop(int vm_id)   { if (vm.state != AIOS_RUNNING && vm.state != AIOS_PAUSED) return -1; qemu_ios_request_shutdown(); return 0; }
aios_state_t aios_vm_get_state(int vm_id) { return vm.state; }
long aios_vm_guest_ram_mb(int vm_id) { return vm.balloon_mb ? vm.balloon_mb : vm.ram_mb; }

static uint64_t phys_footprint(void) {
    task_vm_info_data_t info; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) == KERN_SUCCESS
        ? info.phys_footprint : 0;
}

long aios_process_memory_limit_mb(void) {
#if TARGET_OS_IPHONE
    return (long)((os_proc_available_memory() + phys_footprint()) >> 20);
#else
    return 0;
#endif
}

/* Memory warning: shrink the guest 512 MB via virtio-balloon (not below 768 MB).
 * The guest hands pages back and QEMU releases them to iOS. */
long aios_vm_relieve_memory_pressure(int vm_id) {
    if (vm.state != AIOS_RUNNING && vm.state != AIOS_PAUSED) return -1;
    long current = vm.balloon_mb ? vm.balloon_mb : vm.ram_mb;
    long target = current - 512;
    if (target < GUEST_MIN_MB) target = GUEST_MIN_MB;
    if (target >= current) return current;
    int r = qemu_ios_balloon_target_mb(target);
    ELOG("memory warning: balloon %ld -> %ld MB: %{public}s (footprint %llu MB, available %llu MB)",
         current, target, r == 0 ? "requested" : "no balloon / VM not ready",
         phys_footprint() >> 20,
#if TARGET_OS_IPHONE
         (unsigned long long)(os_proc_available_memory() >> 20)
#else
         0ULL
#endif
         );
    if (r == 0) vm.balloon_mb = target;
    return r == 0 ? target : -1;
}
const char *aios_vm_command_line(int vm_id) { return vm.cmdline ?: ""; }

int aios_vm_save_snapshot(int vm_id, const char *path, char *err, int err_len) {
    if (vm.state != AIOS_RUNNING && vm.state != AIOS_PAUSED) return -1;
    aios_state_t prev = vm.state;
    vm.state = AIOS_SAVING;
    int r = qemu_ios_save_state(path, err, err_len);
    vm.state = (r == 0) ? AIOS_PAUSED : prev;
    return r;
}

/* The guest UART (PL011) often accepts only one byte at a time, so input is
 * queued and drip-fed on a serial queue. Gives up if the guest stops reading. */
int aios_vm_console_send(int vm_id, const char *bytes, int len) {
    if (vm.state != AIOS_RUNNING || len <= 0) return -1;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("aios.console.input", DISPATCH_QUEUE_SERIAL); });
    NSData *data = [NSData dataWithBytes:bytes length:len];
    dispatch_async(q, ^{
        const uint8_t *p = data.bytes;
        size_t left = data.length;
        int idle_ms = 0;
        while (left > 0 && !vm.qemu_done && idle_ms < 2000) {
            int n = qemu_ios_console_write(CONSOLE_ID, p, (int)MIN(left, 4096));
            if (n < 0) break;
            if (n == 0) { usleep(1000); idle_ms++; continue; }
            p += n; left -= n; idle_ms = 0;
        }
    });
    return len;
}

/* ------------------------------------------------------------------- input */

void aios_vm_send_touch(int vm_id, int slot, int x, int y, int pressure, int action) {
    if (vm.state != AIOS_RUNNING || slot < 0 || slot >= 10) return;
    if (action == AIOS_TOUCH_DOWN) vm.tracking[slot] = vm.next_tracking_id++ & 0xffff;
    int tid = vm.tracking[slot];
    if (tid < 0) return;
    x = MAX(0, MIN(x, vm.disp_w - 1));
    y = MAX(0, MIN(y, vm.disp_h - 1));
    qemu_ios_send_touch(slot, tid, x, y, vm.disp_w, vm.disp_h, action);
    if (action == AIOS_TOUCH_UP || action == AIOS_TOUCH_CANCEL) vm.tracking[slot] = -1;
}

void aios_vm_send_key(int vm_id, int keycode, int down) {
    if (vm.state != AIOS_RUNNING) return;
    qemu_ios_send_key(keycode, down);
}

/* -------------------------------------------------------------------- perf */

static double now_s(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double cpu_s(void) {
    struct rusage ru; getrusage(RUSAGE_SELF, &ru);
    return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
}

aios_perf_stats_t aios_vm_get_perf_stats(int vm_id) {
    aios_perf_stats_t st = {0};
    double t = now_s(), c = cpu_s();
    uint64_t f = atomic_load(&vm.frames);
    static double last_cpu_pct;
    if (vm.last_wall > 0 && t - vm.last_wall >= 0.25) {
        vm.fps = (f - vm.last_frames) / (t - vm.last_wall);
        last_cpu_pct = 100.0 * (c - vm.last_cpu) / (t - vm.last_wall);
        vm.last_wall = t; vm.last_cpu = c; vm.last_frames = f;
    } else if (vm.last_wall == 0) {
        vm.last_wall = t; vm.last_cpu = c; vm.last_frames = f;
    }
    st.fps = vm.fps;
    st.cpu_percent = last_cpu_pct;
    task_vm_info_data_t info; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) == KERN_SUCCESS)
        st.ram_used_bytes = info.phys_footprint;
    return st;
}
