import SwiftUI

/// List of VMs with state, OS, disk usage and the last frame as a thumbnail.
struct VMManagerView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var engine: AndroiOSEngine
    @State private var jit = JITManager.probe()
    @State private var running: VMConfiguration?
    @State private var editing: VMConfiguration?
    @State private var creating = false
    @State private var showStorage = false
    @State private var confirmDelete: VMConfiguration?
    @State private var runAnyway = false

    var body: some View {
        List {
            if !jit.isAvailable { Section { JITBanner(status: jit, recheck: { jit = JITManager.probe() }, runAnyway: $runAnyway) } }
            Section {
                ForEach(store.vms) { vm in
                    VMCard(vm: vm, state: engine.runningVM?.id == vm.id ? engine.state : .stopped)
                        .contentShape(Rectangle())
                        .onTapGesture { if jit.isAvailable || runAnyway { running = vm } }
                        .contextMenu {
                            Button("Boot", systemImage: "play.fill") { running = vm }
                                .disabled(!(jit.isAvailable || runAnyway))
                            Button("Settings", systemImage: "slider.horizontal.3") { editing = vm }
                            Button("Clone", systemImage: "plus.square.on.square") { try? store.clone(vm) }
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = vm }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { confirmDelete = vm }
                            Button("Settings") { editing = vm }.tint(.blue)
                        }
                }
            } header: {
                Text("Virtual machines")
            } footer: {
                if engine.hasBooted, case .exited = engine.state {
                    Text("QEMU runs once per launch. Force-quit and reopen AndroiOS to boot again.")
                }
            }
        }
        .navigationTitle("AndroiOS")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { showStorage = true } label: { Image(systemName: "externaldrive") } }
            ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") } }
        }
        .fullScreenCover(item: $running) { vm in VMRunView(vm: vm) }
        .sheet(item: $editing) { vm in NavigationStack { SettingsView(vm: vm) } }
        .sheet(isPresented: $creating) { SetupWizardView(isFirstRun: false) }
        .sheet(isPresented: $showStorage) { NavigationStack { StorageManagerView() } }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")? Its disk image is removed too.",
                            isPresented: .constant(confirmDelete != nil), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let vm = confirmDelete { store.delete(vm) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            jit = JITManager.probe()
        }
    }
}

private struct VMCard: View {
    let vm: VMConfiguration
    let state: VMState
    @EnvironmentObject private var store: VMStore

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                .frame(width: 54, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name).font(.headline)
                Text(vm.osDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Label(state.label, systemImage: state.isActive ? "play.circle.fill" : "stop.circle")
                        .foregroundStyle(state.isActive ? .green : .secondary)
                    Text("·")
                    Text("\(vm.ramMB / 1024) GB · \(vm.cpus) cores · \(StorageHelper.format(store.diskUsage(of: vm)))")
                }
                .font(.caption2)
                if vm.resumeFromSnapshot {
                    Label("Will resume saved state", systemImage: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var thumbnail: some View {
        if let img = UIImage(contentsOfFile: store.thumbnailURL(for: vm).path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack { Color(white: 0.15); Image(systemName: "apps.iphone").font(.title2).foregroundStyle(.gray) }
        }
    }
}

struct JITBanner: View {
    let status: JITStatus
    let recheck: () -> Void
    @Binding var runAnyway: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text(explanation).font(.footnote)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Open **StikDebug** and select AndroiOS.")
                Text("2. Make sure its JIT script is **universal.js** (needed on iOS 26 and later).")
                Text("3. Tap **Enable JIT**. AndroiOS relaunches with JIT.")
                Text("4. Repeat after every force-quit or reboot.")
            }.font(.footnote)
            HStack {
                Button("Re-check", action: recheck).buttonStyle(.borderedProminent)
                if let url = URL(string: "stikjit://"), UIApplication.shared.canOpenURL(url) {
                    Button("Open StikDebug") { UIApplication.shared.open(url) }.buttonStyle(.bordered)
                }
            }
            Toggle("I know what I'm doing — allow boot anyway", isOn: $runAnyway).font(.caption)
            if runAnyway {
                Text("There is no interpreter fallback: without JIT, QEMU cannot start and the app will close when you boot.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var title: String {
        switch status {
        case .needsUniversalScript: return "JIT script not supported"
        case .mappingFailed: return "Could not map JIT memory"
        default: return "JIT not enabled"
        }
    }

    private var explanation: String {
        switch status {
        case .needsUniversalScript:
            return "A debugger is attached, but it didn't prepare executable memory. On iOS 26 and later this device needs StikDebug's universal.js script."
        case .mappingFailed:
            return "iOS refused to map executable memory. Re-enable JIT in StikDebug and try again."
        default:
            return "AndroiOS emulates the guest CPU with a JIT, which iOS only allows while a debugger (StikDebug) is attached."
        }
    }
}
