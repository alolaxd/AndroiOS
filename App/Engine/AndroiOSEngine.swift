import Foundation
import IOSurface

/// Swift wrapper around the C engine (Engine-C/AndroiOSEngine.h).
/// One instance per app launch: QEMU's state is process-global.
@MainActor
final class AndroiOSEngine: ObservableObject {
    @Published private(set) var state: VMState = .stopped
    @Published private(set) var console = ""
    @Published private(set) var commandLine = ""
    @Published private(set) var stats = aios_perf_stats_t()
    @Published private(set) var runningVM: VMConfiguration?

    /// Latest guest frame; read by MetalRenderer on the render thread.
    nonisolated let frames = FrameStore()

    private var vmID: Int32 = -1
    private nonisolated let sink = ConsoleSink()
    private var statsTimer: Timer?
    private static let maxConsoleChars = 200_000

    var hasBooted: Bool { vmID >= 0 }
    /// Loopback port forwarded to the guest's adbd, when app installs are on.
    private(set) var adbPort: UInt16?
    var canStart: Bool { !hasBooted }

    func start(_ vm: VMConfiguration, bundle: URL) throws {
        guard canStart else { throw EngineError.alreadyUsed }
        let required: [String?] = vm.boot == .uefi ? [vm.efiVars] + vm.disks.map { $0 } : [vm.kernel, vm.initrd, vm.disk]
        if vm.boot == .uefi, Bundle.main.path(forResource: "edk2-aarch64-code", ofType: "fd") == nil {
            throw EngineError.missingFile("edk2-aarch64-code.fd (app bundle)")
        }
        for name in required.compactMap({ $0 }) {
            // QEMU exit()s on a missing file, which would terminate the app.
            guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent(name).path) else {
                throw EngineError.missingFile(name)
            }
        }
        var config = vm.engineConfig(bundle: bundle)
        if vm.boot == .uefi && vm.appInstalls {
            // ADB for installing apps: a random loopback port each run.
            let port = Int.random(in: 20000...59999)
            config["adb_port"] = port
            adbPort = UInt16(port)
        }
        let json = try JSONSerialization.data(withJSONObject: config)
        vmID = aios_vm_create(String(decoding: json, as: UTF8.self))
        guard vmID >= 0 else { throw EngineError.badConfig }
        commandLine = String(cString: aios_vm_command_line(vmID))
        runningVM = vm

        let ctx = Unmanaged.passRetained(self).toOpaque()   // released in on_exit
        var cb = aios_callbacks_t()
        cb.ctx = ctx
        cb.console = { bytes, len, ctx in
            guard let bytes, let ctx else { return }
            Unmanaged<AndroiOSEngine>.fromOpaque(ctx).takeUnretainedValue()
                .enqueue(Data(bytes: bytes, count: Int(len)))
        }
        cb.on_exit = { status, ctx in
            guard let ctx else { return }
            let engine = Unmanaged<AndroiOSEngine>.fromOpaque(ctx).takeRetainedValue()
            Task { @MainActor in engine.state = .exited(status); engine.statsTimer?.invalidate() }
        }
        cb.frame = { surface, w, h, seq, ctx in
            guard let surface, let ctx else { return }
            Unmanaged<AndroiOSEngine>.fromOpaque(ctx).takeUnretainedValue()
                .frames.publish(surface, width: Int(w), height: Int(h), seq: seq)
        }
        state = .starting
        guard aios_vm_start(vmID, &cb) == 0 else {
            Unmanaged<AndroiOSEngine>.fromOpaque(ctx).release()
            state = .stopped
            throw EngineError.startFailed
        }
        state = .running
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
    }

    /// True only when the app paused the VM because it went to the background;
    /// becoming active again resumes it. A user pause stays paused.
    @Published private(set) var pausedForBackground = false
    /// Set when iOS warned about memory and the guest was shrunk.
    @Published private(set) var memoryNotice: String?

    func pause()  { if aios_vm_pause(vmID) == 0 { state = .paused } }
    func resume() { if aios_vm_resume(vmID) == 0 { state = .running; pausedForBackground = false } }
    func pauseForBackground() {
        guard state == .running else { return }
        pause()
        pausedForBackground = state == .paused
    }

    /// Memory warning: give memory back through virtio-balloon instead of pausing
    /// (a paused VM still holds all its memory, and looks frozen).
    func relieveMemoryPressure() {
        guard state == .running || state == .paused else { return }
        let target = aios_vm_relieve_memory_pressure(vmID)
        memoryNotice = target > 0
            ? "Low memory: Android was shrunk to \(String(format: "%.1f", Double(target) / 1024)) GB."
            : "Low memory: iOS may close AndroiOS. Lower guest RAM in Settings."
    }
    func clearMemoryNotice() { memoryNotice = nil }
    var guestRAMMB: Int { Int(aios_vm_guest_ram_mb(vmID)) }
    func stop()   { _ = aios_vm_stop(vmID) }

    /// Blocking: call from a background task. Throws if the device set can't migrate (virgl).
    nonisolated func saveSnapshot(to url: URL, vmID: Int32) throws {
        var err = [CChar](repeating: 0, count: 512)
        guard aios_vm_save_snapshot(vmID, url.path, &err, Int32(err.count)) == 0 else {
            throw EngineError.snapshot(String(cString: err))
        }
    }
    var currentVMID: Int32 { vmID }
    func markSaving() { state = .saving }
    func markPaused() { state = .paused }

    // MARK: input
    nonisolated func touch(slot: Int, x: Int, y: Int, action: Int32) {
        aios_vm_send_touch(0, Int32(slot), Int32(x), Int32(y), 1, action)
    }
    nonisolated func key(_ code: Int, down: Bool) { aios_vm_send_key(0, Int32(code), down ? 1 : 0) }

    func sendConsole(_ text: String) {
        var bytes = Array(text.utf8)
        bytes.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                _ = aios_vm_console_send(vmID, $0, Int32(buf.count))
            }
        }
    }

    /// Becomes true once the guest has drawn anything; the boot overlay is
    /// only shown before that.
    @Published private(set) var hasFirstFrame = false

    private func refreshStats() {
        stats = aios_vm_get_perf_stats(vmID)
        if !hasFirstFrame, frames.latest() != nil { hasFirstFrame = true }
    }

    // MARK: console
    nonisolated private func enqueue(_ data: Data) {
        if sink.append(data) { Task { @MainActor in self.flush() } }
    }

    private func flush() {
        console += TerminalText.clean(String(decoding: sink.drain(), as: UTF8.self))
        if console.count > Self.maxConsoleChars { console = String(console.suffix(Self.maxConsoleChars * 3 / 4)) }
    }

    enum EngineError: LocalizedError {
        case alreadyUsed, badConfig, startFailed, missingFile(String), snapshot(String)
        var errorDescription: String? {
            switch self {
            case .alreadyUsed: return "QEMU can only run one VM per app launch. Force-quit and relaunch to boot again."
            case .badConfig: return "Invalid VM configuration."
            case .startFailed: return "Could not start the VM thread."
            case .missingFile(let f): return "Missing \(f) in the VM bundle."
            case .snapshot(let e): return "Saving state failed: \(e)"
            }
        }
    }
}

/// Latest IOSurface from the engine, handed to the render thread.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var surface: IOSurfaceRef?
    private(set) var width = 0, height = 0
    private var seq: UInt64 = 0

    func publish(_ s: IOSurfaceRef, width: Int, height: Int, seq: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if surface !== s { surface = s }          // ARC retains the IOSurface
        self.width = width; self.height = height; self.seq = seq
    }

    func latest() -> (IOSurfaceRef, UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let surface else { return nil }
        return (surface, seq)
    }

    var size: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (width, height) }
}

/// Thread-safe byte buffer between the console thread and the main actor.
private final class ConsoleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var flushScheduled = false

    func append(_ d: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if flushScheduled { return false }
        flushScheduled = true
        return true
    }

    func drain() -> Data {
        lock.lock(); defer { lock.unlock() }
        let d = data
        data.removeAll(keepingCapacity: true)
        flushScheduled = false
        return d
    }
}

/// Minimal terminal-output cleanup for a Text view: drops ANSI escapes and CRs.
enum TerminalText {
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|[()][A-Za-z0-9]|[=>78DEHM])")

    static func clean(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        let stripped = ansi.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        return stripped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
    }
}
