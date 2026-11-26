import Foundation
import UIKit
import os

/// What this device can give the guest. RAM figures are what iOS will let the
/// process use, which depends on the increased-memory-limit entitlement.
struct DeviceCapabilities {
    let machine: String           // e.g. "iPhone15,2"
    let physicalMemory: UInt64
    let cores: Int
    let performanceCores: Int

    static let current = DeviceCapabilities()

    private init() {
        var u = utsname(); uname(&u)
        machine = withUnsafeBytes(of: &u.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        physicalMemory = ProcessInfo.processInfo.physicalMemory
        cores = ProcessInfo.processInfo.activeProcessorCount
        var p: Int32 = 0; var len = MemoryLayout<Int32>.size
        performanceCores = sysctlbyname("hw.perflevel0.physicalcpu", &p, &len, nil, 0) == 0 ? Int(p) : max(2, cores / 2)
    }

    /// Bytes the process may still allocate before jetsam (iOS 13+).
    var availableMemory: UInt64 { UInt64(os_proc_available_memory()) }

    var physicalMemoryGB: Double { Double(physicalMemory) / 1_073_741_824 }

    /// A13 (iPhone 11) or newer: iPhone12,x / iPad >= 8th gen.
    var isSupported: Bool {
        guard let major = Int(machine.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return true }  // simulator / Mac
        if machine.hasPrefix("iPhone") { return major >= 12 }
        if machine.hasPrefix("iPad") { return major >= 11 }
        return true
    }

    /// Total memory iOS lets this app use (available + current footprint), in MB.
    /// On 8 GB iPhones it's ~3.5 GB without the increased-memory-limit
    /// entitlement and ~6 GB with it, so it also shows whether GetMoreRAM worked.
    var processMemoryLimitMB: Int { Int(aios_process_memory_limit_mb()) }

    /// Rough check: limit well under half of physical RAM means the
    /// increased-memory-limit entitlement isn't active.
    var memoryEntitlementLikelyActive: Bool {
        let limit = processMemoryLimitMB
        return limit == 0 || Double(limit) > physicalMemoryGB * 1024 * 0.6
    }

    /// Memory kept for QEMU, the JIT buffer, virgl/ANGLE and the UI. The safe
    /// amount holds even if Android touches all of its RAM; the minimum relies on
    /// the engine's memory watchdog shrinking Android (virtio-balloon) in time.
    static let safeReserveMB = 1536
    static let minReserveMB = 896

    /// Guest RAM that fits with the safe reserve. 1–4 GB.
    var defaultGuestRAMMB: Int {
        let limit = processMemoryLimitMB
        guard limit > 0 else { return 2048 }      // simulator / Mac
        return max(1024, min(4096, (limit - Self.safeReserveMB) / 256 * 256))
    }

    /// Up to the minimum reserve (e.g. ~1.75 GB instead of ~1.25 GB on a 4 GB iPad).
    var maxGuestRAMMB: Int {
        let limit = processMemoryLimitMB
        guard limit > 0 else { return 8192 }
        return max(1024, (limit - Self.minReserveMB) / 256 * 256)
    }

    /// Reserve to request from the engine for `guestMB`: what's left under the
    /// limit, between the minimum and safe reserves.
    func reserveMB(forGuestMB guestMB: Int) -> Int {
        let limit = processMemoryLimitMB
        guard limit > 0 else { return Self.safeReserveMB }
        return min(Self.safeReserveMB, max(Self.minReserveMB, limit - guestMB))
    }

    /// Leave efficiency cores to iOS, the GPU thread and audio.
    var defaultCPUs: Int { max(1, min(4, performanceCores)) }

    /// This screen's shape in portrait, scaled so the short side is `shortSide`
    /// pixels (multiples of 8). iPad 10: 1080×1552.
    static func screenShapedResolution(shortSide: Int = 1080) -> (width: Int, height: Int) {
        let b = UIScreen.main.nativeBounds
        let short = min(b.width, b.height), long = max(b.width, b.height)
        guard short > 0 else { return (shortSide, shortSide * 16 / 9) }
        return (shortSide & ~7, Int((CGFloat(shortSide) * long / short).rounded()) & ~7)
    }
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Warning when guest RAM plus VM overhead exceeds what iOS lets the app use.
    func ramWarning(forGuestMB mb: Int) -> String? {
        let limit = processMemoryLimitMB
        if limit > 0, mb + Self.safeReserveMB > limit {
            return "More than the safe amount for this device (iOS lets AndroiOS use \(String(format: "%.1f", Double(limit) / 1024)) GB in total). AndroiOS watches memory and shrinks Android when iOS runs low, which can close background Android apps; very heavy apps may still get AndroiOS closed."
        }
        return nil
    }
}
