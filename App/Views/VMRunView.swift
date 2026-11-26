import SwiftUI
import UniformTypeIdentifiers

/// Full-screen running VM: Android display, nav overlay, HUD and a control menu.
struct VMRunView: View {
    let vm: VMConfiguration
    @EnvironmentObject private var engine: AndroiOSEngine
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var thermal: ThermalMonitor
    @Environment(\.dismiss) private var dismiss

    @AppStorage("showPerfOverlay") private var showPerf = true
    @State private var showKeyboard = false
    @State private var showMenu = false
    @State private var showConsole = false
    @State private var hostFPS: Double = 0
    @State private var error: String?
    @State private var audio = AudioBridge()
    @StateObject private var installer = AppInstaller()
    @State private var pickingAPK = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if vm.gpu == .none || showConsole {
                ConsoleView(engine: engine)
            } else {
                VMDisplayView(engine: engine, preferredFPS: thermal.frameRate(target: vm.targetFPS), hostFPS: $hostFPS)
                    .ignoresSafeArea()
                GuestKeyboardField(engine: engine, active: $showKeyboard).frame(width: 1, height: 1).opacity(0.01)
                OnScreenControls(engine: engine, showKeyboard: $showKeyboard, showMenu: $showMenu)
            }
            if showPerf {
                PerformanceOverlay(stats: engine.stats, hostFPS: hostFPS, thermal: thermal, target: vm.targetFPS)
                    .padding(.top, 4).padding(.leading, 6)
            }
            // Only until the guest's first frame. Android redraws only when something
            // changes, so 0 FPS on a static screen is normal; showing the overlay then
            // made it flicker, and inserting it above the display cancelled touches.
            if engine.state == .starting || (engine.state == .running && !engine.hasFirstFrame && vm.gpu != .none && !showConsole) {
                bootingBadge
            }
            if let status = installer.status {
                VStack(spacing: 6) {
                    Text(status).font(.footnote)
                    if let p = installer.progress { ProgressView(value: p).frame(width: 180) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.25), lineWidth: 0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)
                .onTapGesture { installer.clearStatus() }
                .task(id: installer.busy) {
                    guard !installer.busy else { return }
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    installer.clearStatus()
                }
            }
            if let notice = engine.memoryNotice {
                Text(notice)
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.25), lineWidth: 0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, showPerf ? 110 : 12)
                    .onTapGesture { engine.clearMemoryNotice() }
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        engine.clearMemoryNotice()
                    }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .confirmationDialog(vm.name, isPresented: $showMenu, titleVisibility: .visible) { menu }
        .fileImporter(isPresented: $pickingAPK,
                      allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data]) { r in
            if case .success(let url) = r, let port = engine.adbPort { installer.installAPK(at: url, port: port) }
        }
        .alert("Can't start VM", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil; dismiss() }
        } message: { Text(error ?? "") }
        .onAppear(perform: boot)
        .onDisappear { audio.stop() }
        .onChange(of: engine.state) { s in
            if case .exited = s { audio.stop() }
        }
    }

    private var bootingBadge: some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("Booting \(vm.name)… first boot can take several minutes").font(.footnote).foregroundStyle(.white)
            Button("Show boot log") { showConsole = true }.font(.footnote)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var menu: some View {
        switch engine.state {
        case .running: Button("Pause") { engine.pause() }
        case .paused: Button("Resume") { engine.resume() }
        default: EmptyView()
        }
        if engine.state == .running, let port = engine.adbPort, !installer.busy {
            Button("Install app from Files (APK)…") { pickingAPK = true }
            Button("Install F-Droid (app store)") { installer.installFDroid(port: port) }
        }
        if vm.gpu != .none { Button(showConsole ? "Show display" : "Show serial console") { showConsole.toggle() } }
        Button(showPerf ? "Hide performance HUD" : "Show performance HUD") { showPerf.toggle() }
        Button(thermal.batterySaver ? "Battery saver: off" : "Battery saver: 30 FPS") { thermal.batterySaver.toggle() }
        if engine.state.isActive { Button("Power off", role: .destructive) { engine.stop() } }
        if case .exited = engine.state { Button("Close") { dismiss() } }
    }

    private func boot() {
        guard engine.canStart else {
            if engine.runningVM?.id != vm.id {
                error = AndroiOSEngine.EngineError.alreadyUsed.errorDescription
            }
            return
        }
        do {
            if vm.audio { audio.start() }
            try engine.start(vm, bundle: store.bundle(for: vm))
            var v = vm
            SnapshotManager.consumeResume(&v, store: store)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
