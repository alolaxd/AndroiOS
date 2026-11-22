import Foundation
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

    /// Defaults from the design doc's device matrix.
    var defaultGuestRAMMB: Int {
        switch physicalMemoryGB {
        case ..<5: return 2048
        case ..<7: return 3072
        default: return 4096
        }
    }

    var maxGuestRAMMB: Int {
        switch physicalMemoryGB {
        case ..<5: return 2560
        case ..<7: return 4096
        case ..<9: return 6144
        default: return 8192
        }
    }

    /// Leave efficiency cores to iOS, the GPU thread and audio.
    var defaultCPUs: Int { max(1, min(4, performanceCores)) }

    /// Warn above 50% of device RAM.
    func ramWarning(forGuestMB mb: Int) -> String? {
        let frac = Double(mb) * 1_048_576 / Double(physicalMemory)
        if frac > 0.5 {
            return "Guest RAM is \(Int(frac * 100))% of this device's memory. Without the increased-memory-limit entitlement (GetMoreRAM, TrollStore or a paid developer profile) iOS will kill the app."
        }
        return nil
    }
}
