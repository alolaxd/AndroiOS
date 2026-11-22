import SwiftUI

@main
struct AndroiOSApp: App {
    @StateObject private var engine = AndroiOSEngine()
    @StateObject private var store = VMStore()
    @StateObject private var thermal = ThermalMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(thermal)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    // Under memory pressure: get the guest's state onto disk (or at least stop it allocating).
                    SnapshotManager.handleBackground(engine: engine, store: store)
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                saveThumbnail()
                SnapshotManager.handleBackground(engine: engine, store: store)
            case .active:
                if engine.state == .paused, engine.runningVM?.gpu == .virgl { engine.resume() }
            default: break
            }
        }
    }

    /// Last frame → VM card thumbnail.
    private func saveThumbnail() {
        guard let vm = engine.runningVM, let (surface, _) = engine.frames.latest() else { return }
        let ci = CIImage(ioSurface: surface)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let img = UIImage(cgImage: cg)
        let size = CGSize(width: 180, height: 180 * img.size.height / max(1, img.size.width))
        let thumb = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        store.saveThumbnail(thumb, for: vm)
    }
}
