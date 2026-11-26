/*
 * Host-side test for the engine: links AndroiOSEngine.m against the macOS
 * build of the same patched QEMU (+ virglrenderer + ANGLE/Metal) and runs a
 * VM through exactly the code path the iOS app uses.
 *
 *   engine-harness <config.json> [seconds] [expect-string] [send-after-expect]
 *
 * Prints perf stats every 5 s and writes the last guest frame to
 * $AIOS_FRAME_PNG (default ./last-frame.png).
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#include <stdatomic.h>
#include "AndroiOSEngine.h"

static atomic_bool exited;
static NSMutableString *output;
static NSLock *lock;
static IOSurfaceRef lastSurface;
static atomic_ullong frames;
static double firstFrameAt;
static NSDate *t0;

static void on_console(const char *bytes, int len, void *ctx) {
    fwrite(bytes, 1, len, stdout); fflush(stdout);
    [lock lock];
    [output appendString:[[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding] ?: @""];
    [lock unlock];
}
static void on_exit_cb(int status, void *ctx) {
    fprintf(stderr, "\n[harness] QEMU exited with status %d\n", status);
    exited = true;
}
static uint64_t lastSeq;
static void on_frame(IOSurfaceRef s, int w, int h, uint64_t seq, void *ctx) {
    if (atomic_fetch_add(&frames, 1) == 0) {
        firstFrameAt = -[t0 timeIntervalSinceNow];
        fprintf(stderr, "\n[harness] first frame %dx%d after %.1fs\n", w, h, firstFrameAt);
    }
    [lock lock];
    lastSeq = seq;
    if (lastSurface != s) {
        if (lastSurface) CFRelease(lastSurface);
        lastSurface = (IOSurfaceRef)CFRetain(s);
    }
    [lock unlock];
}
static atomic_ullong audioFrames;
static _Atomic int audioPeak;          /* loudest sample since the last stats line */
static _Atomic unsigned long long audioNonzero;
static void on_audio(const int16_t *p, int n, int rate, int ch, void *ctx) {
    atomic_fetch_add(&audioFrames, n);
    int peak = 0; unsigned long long nz = 0;
    for (int i = 0; i < n * ch; i++) { int v = abs(p[i]); if (v > peak) peak = v; if (v) nz++; }
    if (peak > atomic_load(&audioPeak)) atomic_store(&audioPeak, peak);
    atomic_fetch_add(&audioNonzero, nz);
}

static void save_png(IOSurfaceRef s, NSString *path) {
    /* The GPU signals the frame's seq on the sync event once it has written the
     * surface (the app waits for this on the GPU); wait for it here. */
    id<MTLSharedEvent> ev = (__bridge id<MTLSharedEvent>)aios_display_sync_event();
    for (int i = 0; ev && ev.signaledValue < lastSeq && i < 1000; i++) usleep(1000);
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(IOSurfaceGetBaseAddress(s), w, h, 8, bpr, cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(cg);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL);
    CGImageDestinationFinalize(dst);
    CFRelease(dst); CGImageRelease(img); CGContextRelease(cg); CGColorSpaceRelease(cs);
    fprintf(stderr, "[harness] wrote %s (%zux%zu)\n", path.UTF8String, w, h);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s config.json [seconds] [expect] [send]\n", argv[0]); return 2; }
        output = [NSMutableString string];
        lock = [NSLock new];
        int seconds = argc > 2 ? atoi(argv[2]) : 60;
        NSString *expect = argc > 3 && argv[3][0] ? @(argv[3]) : nil;
        NSString *send = argc > 4 ? [@(argv[4]) stringByReplacingOccurrencesOfString:@"\\r" withString:@"\r"] : nil;
        NSString *png = NSProcessInfo.processInfo.environment[@"AIOS_FRAME_PNG"] ?: @"last-frame.png";

        fprintf(stderr, "[harness] JIT probe: %d (0 = available)\n", aios_jit_probe());
        NSString *json = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
        int vm = aios_vm_create(json.UTF8String);
        if (vm < 0) { fprintf(stderr, "bad config\n"); return 1; }
        fprintf(stderr, "[harness] cmdline: %s\n", aios_vm_command_line(vm));
        aios_callbacks_t cb = { on_console, on_exit_cb, on_frame, on_audio, NULL };
        t0 = [NSDate date];
        if (aios_vm_start(vm, &cb) != 0) { fprintf(stderr, "start failed\n"); return 1; }

        bool found = false, sent = false;
        double nextStats = 5;
        /* AIOS_SWIPE=1: once `expect` is seen, swipe the touchscreen left/right
         * continuously (multitouch path) so the guest UI keeps animating. */
        bool swipe = NSProcessInfo.processInfo.environment[@"AIOS_SWIPE"] != nil;
        double swipeStart = 0;
        int swipeStep = 0;
        NSDictionary *cfgDict = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        int W = [cfgDict[@"display_width"] intValue] ?: 720, H = [cfgDict[@"display_height"] intValue] ?: 1280;
        while (!exited && -[t0 timeIntervalSinceNow] < seconds) {
            usleep(100000);
            double t = -[t0 timeIntervalSinceNow];
            if (t >= nextStats && ((int)nextStats % 30) == 0) {   /* refresh the PNG every 30 s */
                [lock lock];
                if (lastSurface) save_png(lastSurface, png);
                if (lastSurface && NSProcessInfo.processInfo.environment[@"AIOS_FRAME_SERIES"])
                    save_png(lastSurface, [png stringByReplacingOccurrencesOfString:@".png"
                                         withString:[NSString stringWithFormat:@"-%03d.png", (int)nextStats]]);
                [lock unlock];
            }
            if (t >= nextStats) {
                aios_perf_stats_t st = aios_vm_get_perf_stats(vm);
                fprintf(stderr, "\n[harness] t=%3.0fs fps=%5.1f cpu=%5.0f%% ram=%4llu MB frames=%llu audio_frames=%llu audio_peak=%d audio_nonzero=%llu\n",
                        t, st.fps, st.cpu_percent, st.ram_used_bytes >> 20,
                        (unsigned long long)frames, (unsigned long long)audioFrames,
                        atomic_exchange(&audioPeak, 0), (unsigned long long)audioNonzero);
                nextStats += 5;
            }
            /* AIOS_TAPS="t:x:y,t:x:y": tap guest pixel (x,y) at t seconds (multitouch path). */
            static NSMutableArray *taps;
            if (!taps) {
                taps = [NSMutableArray array];
                for (NSString *e in [NSProcessInfo.processInfo.environment[@"AIOS_TAPS"] ?: @"" componentsSeparatedByString:@","]) {
                    NSArray *p = [e componentsSeparatedByString:@":"];
                    if (p.count == 3) [taps addObject:p];
                }
            }
            if (taps.count && t >= [taps[0][0] doubleValue]) {
                int x = [taps[0][1] intValue], y = [taps[0][2] intValue];
                aios_vm_send_touch(vm, 0, x, y, 1, AIOS_TOUCH_DOWN);
                usleep(80000);
                aios_vm_send_touch(vm, 0, x, y, 1, AIOS_TOUCH_UP);
                fprintf(stderr, "\n[harness] tap (%d,%d) at %.0fs\n", x, y, t);
                [taps removeObjectAtIndex:0];
            }
            /* AIOS_BALLOON_AT=t: simulate an iOS memory warning at t seconds. */
            static bool ballooned;
            NSString *bAt = NSProcessInfo.processInfo.environment[@"AIOS_BALLOON_AT"];
            if (bAt && !ballooned && t >= bAt.doubleValue) {
                ballooned = true;
                long target = aios_vm_relieve_memory_pressure(vm);
                fprintf(stderr, "\n[harness] memory warning -> balloon target %ld MB (guest RAM now %ld MB)\n",
                        target, aios_vm_guest_ram_mb(vm));
            }
            if (swipe && found) {
                if (swipeStart == 0) swipeStart = t;
                /* one swipe = 8 moves over ~0.8 s, alternating direction */
                int phase = swipeStep % 10;
                bool leftToRight = (swipeStep / 10) % 2;
                int x0 = leftToRight ? W / 6 : W * 5 / 6, x1 = leftToRight ? W * 5 / 6 : W / 6;
                int y = H / 2;
                if (phase == 0) aios_vm_send_touch(vm, 0, x0, y, 1, AIOS_TOUCH_DOWN);
                else if (phase < 9) aios_vm_send_touch(vm, 0, x0 + (x1 - x0) * phase / 8, y, 1, AIOS_TOUCH_MOVE);
                else aios_vm_send_touch(vm, 0, x1, y, 1, AIOS_TOUCH_UP);
                swipeStep++;
            }
            /* AIOS_BENCH="start:seconds": from `start`, swipe up/down at the centre
             * (unlock, then open/close the app drawer) and report the frame rate
             * delivered by the display over the window, skipping its first 5 s. */
            static double benchStart = -1, benchLen = 0, benchT0 = 0;
            static unsigned long long benchF0 = 0;
            static int benchStep = 0;
            if (benchStart < 0) {
                NSArray *b = [NSProcessInfo.processInfo.environment[@"AIOS_BENCH"] ?: @"" componentsSeparatedByString:@":"];
                benchStart = b.count == 2 ? [b[0] doubleValue] : 1e9; benchLen = b.count == 2 ? [b[1] doubleValue] : 0;
            }
            if (t >= benchStart && t < benchStart + benchLen) {
                int phase = benchStep % 8;
                bool up = (benchStep / 8) % 2 == 0;
                int x = W / 2, y0 = up ? H * 4 / 5 : H / 5, y1 = up ? H / 5 : H * 4 / 5;
                if (phase == 0) aios_vm_send_touch(vm, 0, x, y0, 1, AIOS_TOUCH_DOWN);
                else if (phase < 6) aios_vm_send_touch(vm, 0, x, y0 + (y1 - y0) * phase / 5, 1, AIOS_TOUCH_MOVE);
                else if (phase == 6) aios_vm_send_touch(vm, 0, x, y1, 1, AIOS_TOUCH_UP);
                benchStep++;
                if (benchT0 == 0 && t >= benchStart + 5) { benchT0 = t; benchF0 = frames; }
            } else if (benchT0 > 0 && t >= benchStart + benchLen) {
                aios_perf_stats_t st = aios_vm_get_perf_stats(vm);
                fprintf(stderr, "\n[bench] %.1f fps over %.0fs (cpu %.0f%%)\n",
                        (frames - benchF0) / (t - benchT0), t - benchT0, st.cpu_percent);
                benchT0 = -1;
                if (NSProcessInfo.processInfo.environment[@"AIOS_BENCH_EXIT"]) break;
            }
            [lock lock]; NSString *snap = [output copy]; [lock unlock];
            NSString *until = NSProcessInfo.processInfo.environment[@"AIOS_UNTIL"];
            if (until && sent && [snap containsString:until]) {
                fprintf(stderr, "\n[harness] saw \"%s\" after %.1fs\n", until.UTF8String, t);
                break;
            }
            if (expect && !found && [snap containsString:expect]) {
                found = true;
                fprintf(stderr, "\n[harness] saw \"%s\" after %.1fs\n", expect.UTF8String, t);
                if (send && !sent) { aios_vm_console_send(vm, send.UTF8String, (int)strlen(send.UTF8String)); sent = true; }
                if (!send && !swipe) break;
            }
        }
        [lock lock];
        if (lastSurface) save_png(lastSurface, png);
        [lock unlock];
        if (!exited) { aios_vm_stop(vm); for (int i = 0; i < 100 && !exited; i++) usleep(100000); }
        fprintf(stderr, "[harness] frames=%llu expect=%s\n", (unsigned long long)frames,
                expect ? (found ? "FOUND" : "MISSING") : "n/a");
        return (expect && !found) ? 1 : 0;
    }
}
