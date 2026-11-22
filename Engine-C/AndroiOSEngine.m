/*
 * AndroiOSEngine — drives QEMU.framework in-process.
 */
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include <pthread.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <mach/task_info.h>
#include <stdatomic.h>
#include "AndroiOSEngine.h"
#include <QEMU/qemu-ios-api.h>

#define CONSOLE_ID "aios-con0"

/* ---------------------------------------------------------------- JIT probe */

/* Private but stable syscall; UTM and other JIT apps use it the same way. */
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_STATUS 0
#define CS_DEBUGGED   0x10000000

extern kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t,
                                   mach_vm_offset_t, int, vm_map_t, mach_vm_address_t,
                                   boolean_t, vm_prot_t *, vm_prot_t *, vm_inherit_t);

static bool process_is_debugged(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return false;
    return (flags & CS_DEBUGGED) != 0;
}

aios_jit_status_t aios_jit_probe(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    /* On device, executing an unsigned page without CS_DEBUGGED is a
     * code-signing kill (SIGKILL, not catchable), so never try blind. */
    if (!process_is_debugged()) return AIOS_JIT_NOT_EXECUTABLE;
#endif
    size_t size = (size_t)getpagesize();
    void *rw = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (rw == MAP_FAILED) return AIOS_JIT_NO_MAPPING;

    mach_vm_address_t rx = 0;
    vm_prot_t cur, max;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &rx, size, 0, VM_FLAGS_ANYWHERE,
                                     mach_task_self(), (mach_vm_address_t)rw, false,
                                     &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) { munmap(rw, size); return AIOS_JIT_NO_MAPPING; }
    if (mprotect((void *)rx, size, PROT_READ | PROT_EXEC) != 0) {
        munmap((void *)rx, size); munmap(rw, size);
        return AIOS_JIT_NOT_EXECUTABLE;
    }
    /* mov w0, #42 ; ret */
    static const uint32_t code[] = { 0x52800540, 0xd65f03c0 };
    memcpy(rw, code, sizeof(code));
    sys_icache_invalidate((void *)rx, sizeof(code));
    int (*fn)(void) = (int (*)(void))(uintptr_t)rx;
    int r = fn();
    munmap((void *)rx, size); munmap(rw, size);
    return r == 42 ? AIOS_JIT_AVAILABLE : AIOS_JIT_NOT_EXECUTABLE;
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
    long ram  = [cfg[@"ram_mb"] longValue] ?: 1024;
    long cpus = [cfg[@"cpus"] longValue] ?: 1;
    NSString *gpu = cfg[@"gpu"] ?: @"none";
    vm.disp_w = [cfg[@"display_width"] intValue] ?: 1080;
    vm.disp_h = [cfg[@"display_height"] intValue] ?: 1920;

    if (cfg[@"firmware_dir"]) [a addObjectsFromArray:@[@"-L", cfg[@"firmware_dir"]]];
    [a addObjectsFromArray:@[
        @"-nodefaults",
        @"-M", @"virt,highmem=on,gic-version=3",
        // pauth-impdef: cheap PAC emulation; the architected QARMA is very slow under TCG.
        @"-cpu", @"max,pauth-impdef=on",
        // split-wx: RW + RX aliases of the code buffer via mach_vm_remap.
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
    if ([cfg[@"network"] boolValue]) {
        NSMutableString *net = [@"user,id=net0" mutableCopy];
        for (NSString *fwd in cfg[@"port_forwards"] ?: @[]) [net appendFormat:@",hostfwd=%@", fwd];
        [a addObjectsFromArray:@[@"-netdev", net, @"-device", @"virtio-net-pci,netdev=net0,romfile="]];
    }
    if ([cfg[@"audio"] boolValue]) {
        // "sound_device": virtio (default) | ac97 | hda — match what the guest kernel drives.
        NSString *snd = cfg[@"sound_device"] ?: @"virtio";
        [a addObjectsFromArray:@[@"-audiodev", @"ios,id=snd0"]];
        if ([snd isEqualToString:@"ac97"])
            [a addObjectsFromArray:@[@"-device", @"AC97,audiodev=snd0"]];
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
    for (id x in cfg[@"extra_args"] ?: @[]) if ([x isKindOfClass:NSString.class]) [a addObject:x];
    return a;
}

int aios_vm_create(const char *config_json) {
    if (vm.created) return -1;
    NSData *d = [NSData dataWithBytes:config_json length:strlen(config_json)];
    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![cfg isKindOfClass:NSDictionary.class]) return -1;
    vm.argv = build_argv(cfg);
    vm.cmdline = strdup([[vm.argv componentsJoinedByString:@" "] UTF8String]);
    for (int i = 0; i < 10; i++) vm.tracking[i] = -1;
    vm.created = true;
    vm.state = AIOS_STOPPED;
    return 0;
}

static void on_frame(void *surface, int w, int h, uint64_t seq, void *ctx) {
    atomic_fetch_add(&vm.frames, 1);
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

static void *qemu_thread(void *unused) {
    int argc = (int)vm.argv.count;
    char **argv = calloc(argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) argv[i] = strdup(vm.argv[i].UTF8String);
    qemu_ios_display_set_callback(on_frame, NULL);
    qemu_ios_audio_set_callback(on_audio, NULL);
    vm.state = AIOS_RUNNING;
    int status = qemu_ios_main(argc, argv);   /* blocks until the guest powers off */
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

static int spawn(void *(*fn)(void *), size_t stack) {
    pthread_attr_t attr; pthread_t t;
    pthread_attr_init(&attr);
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
    if (spawn(qemu_thread, 8 << 20) != 0) { vm.state = AIOS_ERROR; return -1; }
    spawn(console_thread, 512 << 10);
    return 0;
}

int aios_vm_pause(int vm_id)  { if (vm.state != AIOS_RUNNING) return -1; qemu_ios_pause();  vm.state = AIOS_PAUSED;  return 0; }
int aios_vm_resume(int vm_id) { if (vm.state != AIOS_PAUSED)  return -1; qemu_ios_resume(); vm.state = AIOS_RUNNING; return 0; }
int aios_vm_stop(int vm_id)   { if (vm.state != AIOS_RUNNING && vm.state != AIOS_PAUSED) return -1; qemu_ios_request_shutdown(); return 0; }
aios_state_t aios_vm_get_state(int vm_id) { return vm.state; }
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
