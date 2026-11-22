import Foundation
import Combine

/// Publishes ProcessInfo.thermalState and the frame rate the UI should target.
@MainActor
final class ThermalMonitor: ObservableObject {
    @Published private(set) var state = ProcessInfo.processInfo.thermalState
    @Published var batterySaver = false

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state = ProcessInfo.processInfo.thermalState }
        }
    }

    /// .serious/.critical or battery saver → 30 FPS; otherwise the VM's target.
    func frameRate(target: Int) -> Int {
        if batterySaver { return 30 }
        switch state {
        case .serious, .critical: return 30
        default: return target
        }
    }

    var pressure: Double {
        switch state {
        case .nominal: return 0
        case .fair: return 0.33
        case .serious: return 0.66
        case .critical: return 1
        @unknown default: return 0
        }
    }

    var label: String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious — throttled to 30 FPS"
        case .critical: return "Critical — throttled to 30 FPS"
        @unknown default: return "Unknown"
        }
    }
}
