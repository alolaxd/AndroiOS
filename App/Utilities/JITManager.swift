import Foundation

/// Whether QEMU's JIT can run in this process. The probe never executes code:
/// on iOS 26+ devices with TXM (A15 and later) it asks the attached debugger
/// to prepare one page through StikDebug's universal.js handshake.
enum JITStatus: Equatable {
    case available
    case notEnabled              // no debugger attached (CS_DEBUGGED unset)
    case needsUniversalScript    // iOS 26+ TXM device: debugger didn't answer brk #0xf00d
    case mappingFailed           // mmap of a test page failed

    var isAvailable: Bool { self == .available }
}

enum JITManager {
    static func probe() -> JITStatus {
        switch aios_jit_probe() {
        case AIOS_JIT_AVAILABLE: return .available
        case AIOS_JIT_NO_MAPPING: return .mappingFailed
        case AIOS_JIT_NEEDS_UNIVERSAL_SCRIPT: return .needsUniversalScript
        default: return .notEnabled
        }
    }
}
