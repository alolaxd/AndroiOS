import SwiftUI

/// Debug HUD: guest frames/s (frames the guest actually produced), host
/// presents/s, CPU, memory and thermal state.
struct PerformanceOverlay: View {
    let stats: aios_perf_stats_t
    let hostFPS: Double
    let thermal: ThermalMonitor
    let target: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("guest", String(format: "%.0f fps", stats.fps), color: fpsColor)
            row("display", String(format: "%.0f fps (target %d)", hostFPS, target))
            row("cpu", String(format: "%.0f%%", stats.cpu_percent))
            row("ram", StorageHelper.format(stats.ram_used_bytes))
            row("avail", StorageHelper.format(DeviceCapabilities.current.availableMemory))
            row("thermal", thermal.label, color: thermal.pressure > 0.5 ? .orange : .white)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(6)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }

    private var fpsColor: Color {
        switch stats.fps {
        case 50...: return .green
        case 25..<50: return .yellow
        default: return .red
        }
    }

    private func row(_ k: String, _ v: String, color: Color = .white) -> some View {
        HStack(spacing: 6) {
            Text(k).foregroundStyle(.gray).frame(width: 46, alignment: .leading)
            Text(v).foregroundStyle(color)
        }
    }
}
