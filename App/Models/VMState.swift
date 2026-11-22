import Foundation

enum VMState: Equatable {
    case stopped
    case starting
    case running
    case paused
    case saving
    case exited(Int32)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .paused: return "Paused"
        case .saving: return "Saving state…"
        case .exited(let s): return s == 0 ? "Powered off" : "Exited (\(s))"
        }
    }

    var isActive: Bool {
        switch self {
        case .starting, .running, .paused, .saving: return true
        default: return false
        }
    }
}
