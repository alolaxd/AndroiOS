import Foundation

/// Detects whether this process can JIT (i.e. a debugger such as StikDebug
/// attached and set CS_DEBUGGED). The probe mirrors what QEMU's TCG does on
/// iOS: an RW page plus an RX alias from mach_vm_remap.
enum JITStatus: Equatable {
    case available
    case notEnabled          // no debugger attached: TCG cannot run
    case mappingFailed       // the VM system refused the mapping itself

    var isAvailable: Bool { self == .available }
}

enum JITManager {
    static func probe() -> JITStatus {
        switch aios_jit_probe() {
        case AIOS_JIT_AVAILABLE: return .available
        case AIOS_JIT_NO_MAPPING: return .mappingFailed
        default: return .notEnabled
        }
    }
}
