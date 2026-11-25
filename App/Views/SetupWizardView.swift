import SwiftUI
import UniformTypeIdentifiers

/// First-launch flow: compatibility check → get the guest files (import from
/// Files or download) → choose hardware → create the VM.
struct SetupWizardView: View {
    let isFirstRun: Bool
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloads = DownloadManager()

    private enum Step: Int { case welcome, guest, hardware, done }
    @State private var step: Step = .welcome
    @State private var vm = VMConfiguration()
    @State private var files: [URL] = []
    @State private var importing = false
    /// Hosted Android images (see GuestImage; vda.qcow2 is zlib-compressed so each
    /// asset fits GitHub's 2 GB limit; QEMU reads it as-is).
    @State private var guestImage: GuestImage = GuestImage.recommended
    @State private var customURL = false
    @State private var baseURL = GuestImage.recommended.baseURL
    @State private var downloadQueue: [String] = []
    @State private var error: String?
    @State private var installing = false
    private let caps = DeviceCapabilities.current
    private static let guestFiles = ["efi_vars.fd", "vda.qcow2", "vdb.qcow2"]

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .welcome: welcome
                case .guest: guest
                case .hardware: hardware
                case .done: EmptyView()
                }
            }
            .navigationTitle(isFirstRun ? "Welcome to AndroiOS" : "New VM")
            .toolbar {
                if !isFirstRun { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { files.append(contentsOf: urls) }
            }
            .alert("Error", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(isFirstRun)
    }

    // MARK: steps

    @ViewBuilder private var welcome: some View {
        Section {
            Text("AndroiOS runs Android (LineageOS 22.2 / Android 15 or 23.2 / Android 16) in a virtual machine on this device. The guest's CPU is emulated with QEMU's JIT, and Android's graphics run on the Apple GPU (virgl → ANGLE → Metal).")
                .font(.callout)
        }
        Section("This device") {
            LabeledContent("Model", value: caps.machine)
            LabeledContent("Memory", value: String(format: "%.1f GB", caps.physicalMemoryGB))
            if caps.processMemoryLimitMB > 0 {
                LabeledContent("Usable by AndroiOS", value: String(format: "%.1f GB", Double(caps.processMemoryLimitMB) / 1024))
                if !caps.memoryEntitlementLikelyActive {
                    Text("The increased-memory-limit entitlement doesn't look active, so Android gets less RAM. Apply it with GetMoreRAM (or TrollStore / a paid developer profile) and relaunch.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            LabeledContent("CPU cores", value: "\(caps.cores) (\(caps.performanceCores) performance)")
            LabeledContent("Free storage", value: StorageHelper.format(StorageHelper.availableBytes))
            if !caps.isSupported { Text("This device is older than A13; expect very low performance.").foregroundStyle(.orange) }
            if StorageHelper.availableBytes < 8 << 30 { Text("At least 8 GB free space is recommended.").foregroundStyle(.orange) }
        }
        Section("You will need") {
            Label("StikDebug with the universal.js script, to enable JIT", systemImage: "bolt.fill")
            Label("GetMoreRAM (or TrollStore / paid dev profile) for the memory entitlements", systemImage: "memorychip")
            Label("About 3 GB of free storage (Android is downloaded in the next step)", systemImage: "internaldrive")
        }
        Button("Continue") { step = .guest }
    }

    @ViewBuilder private var guest: some View {
        if VMStore.bundledGuest != nil {
            Section {
                Button {
                    installing = true
                    Task {
                        do { _ = try await store.installBundledGuest(); dismiss() }
                        catch { self.error = error.localizedDescription }
                        installing = false
                    }
                } label: {
                    HStack {
                        Label("Use built-in LineageOS 23.2 (Android 16)", systemImage: "shippingbox.fill")
                        Spacer()
                        if installing { ProgressView() }
                    }
                }
                .disabled(installing)
            } header: { Text("Included with this app") } footer: {
                Text("Copies the Android disks into the app's storage (about 2.2 GB on disk) and creates the VM.")
            }
        }
        Section {
            Button("Import from Files…", systemImage: "folder") { importing = true }
            ForEach(files, id: \.self) { Text($0.lastPathComponent).font(.caption.monospaced()) }
        } header: { Text("Guest image") } footer: {
            Text("Already have the files? Select efi_vars.fd, vda.qcow2 and vdb.qcow2 (Guest/fetch-lineage.sh on a Mac).")
        }
        Section {
            Picker("Android version", selection: $guestImage) {
                ForEach(GuestImage.allCases) { g in Text(g.title).tag(g) }
            }
            .disabled(downloads.isDownloading)
            .onChange(of: guestImage) { g in if !customURL { baseURL = g.baseURL } }
            Text(guestImage.note).font(.caption).foregroundStyle(.secondary)
            Toggle("Use a custom download URL", isOn: $customURL).font(.caption)
            if customURL {
                TextField("https://example.com/androios/", text: $baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if downloads.isDownloading || downloads.canResume {
                ProgressView(value: downloads.progress) {
                    Text("\(downloadQueue.first ?? "") — \(StorageHelper.format(UInt64(max(0, downloads.bytesWritten)))) of \(StorageHelper.format(UInt64(max(0, downloads.bytesExpected))))")
                        .font(.caption)
                }
                Button(downloads.isDownloading ? "Pause" : "Resume") {
                    downloads.isDownloading ? downloads.pause() : downloadNext()
                }
            } else {
                Button("Download \(guestImage.shortTitle) (\(guestImage.size))") {
                    downloadQueue = Self.guestFiles.filter { n in !files.contains { $0.lastPathComponent == n } }
                    downloadNext()
                }.disabled(URL(string: baseURL)?.scheme == nil)
            }
            if let e = downloads.error { Text(e).font(.caption).foregroundStyle(.red) }
        } header: { Text("Download Android") } footer: { Text("Downloads Android into the app's storage. Downloads resume after interruptions.") }
        Button("Continue") { step = .hardware }.disabled(!hasGuestFiles)
    }

    @ViewBuilder private var hardware: some View {
        Section("Name") { TextField("Name", text: $vm.name) }
        Section {
            Stepper("RAM: \(Double(vm.ramMB) / 1024, specifier: "%.1f") GB", value: $vm.ramMB, in: 1024...caps.maxGuestRAMMB, step: 512)
            if let w = caps.ramWarning(forGuestMB: vm.ramMB) { Text(w).font(.caption).foregroundStyle(.orange) }
            Stepper("CPU cores: \(vm.cpus)", value: $vm.cpus, in: 1...max(1, min(6, caps.cores)))
            Picker("Resolution", selection: $vm.displayHeight) {
                Text("720×1280 (recommended)").tag(1280)
                Text("1080×1920 (sharper, slower)").tag(1920)
            }
            .onChange(of: vm.displayHeight) { h in vm.displayWidth = h * 9 / 16 }
        } header: { Text("Hardware") } footer: { Text("Defaults are tuned for this device. The downloaded images use a phone layout (320 dpi), sized for these resolutions.") }
        Button("Create VM") { create() }
    }

    // MARK: actions

    private var hasGuestFiles: Bool {
        let names = Set(files.map { $0.lastPathComponent.lowercased() })
        return names.contains { $0.hasPrefix("vmlinuz") || $0 == "image" }
            || (names.contains("efi_vars.fd") && names.contains { $0.hasSuffix(".qcow2") })
    }

    private func downloadNext() {
        guard let name = downloadQueue.first, let base = URL(string: baseURL) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        downloads.start(base.appendingPathComponent(name), to: tmp) { url in
            guard let url else { return }
            files.append(url)
            downloadQueue.removeFirst()
            if downloadQueue.isEmpty {
                if !customURL { vm.name = guestImage.shortTitle; vm.osDescription = guestImage.title }
                if hasGuestFiles { step = .hardware }   // all three files are in: go on
            } else {
                downloadNext()
            }
        }
    }

    private func create() {
        do {
            let downloaded = files.filter { $0.path.hasPrefix(FileManager.default.temporaryDirectory.path) }
            try store.create(vm, importing: files.filter { !downloaded.contains($0) }, move: false)
            if !downloaded.isEmpty { try store.create(vm, importing: downloaded, move: true) }
            StorageHelper.excludeFromBackup(store.bundle(for: vm))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    init(isFirstRun: Bool) {
        self.isFirstRun = isFirstRun
        var v = VMConfiguration()
        v.ramMB = DeviceCapabilities.current.defaultGuestRAMMB
        v.cpus = DeviceCapabilities.current.defaultCPUs
        if let url = Bundle.main.url(forResource: "default-vm", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let tmpl = try? JSONDecoder().decode(VMTemplate.self, from: data) {
            tmpl.apply(to: &v)
        }
        _vm = State(initialValue: v)
    }
}

/// Resources/DefaultVM/default-vm.json: optional overrides for new VMs.
private struct VMTemplate: Decodable {
    var name: String?
    var osDescription: String?
    var kernelArgs: String?
    var gpu: VMConfiguration.GPU?
    var displayWidth: Int?
    var displayHeight: Int?
    var targetFPS: Int?
    var network: Bool?
    var audio: Bool?

    func apply(to v: inout VMConfiguration) {
        if let name { v.name = name }
        if let osDescription { v.osDescription = osDescription }
        if let kernelArgs { v.kernelArgs = kernelArgs }
        if let gpu { v.gpu = gpu }
        if let displayWidth { v.displayWidth = displayWidth }
        if let displayHeight { v.displayHeight = displayHeight }
        if let targetFPS { v.targetFPS = targetFPS }
        if let network { v.network = network }
        if let audio { v.audio = audio }
    }
}

/// Android images hosted on AndroiOS's GitHub releases: the LineageOS
/// virtio_arm64only VMs from jqssun/android-lineage-qemu, tuned for emulation
/// by Guest/make-lite.sh (no boot animation, phone layout; low-performance mode
/// on 22.2).
enum GuestImage: String, CaseIterable, Identifiable {
    case lineage22 = "guest-lineage-22.2-lite"
    case lineage23 = "guest-lineage-23.2-lite"

    var id: String { rawValue }
    var baseURL: String { "https://github.com/alolaxd/AndroiOS/releases/download/\(rawValue)/" }

    var title: String {
        switch self {
        case .lineage22: return "LineageOS 22.2 (Android 15) — recommended"
        case .lineage23: return "LineageOS 23.2 (Android 16)"
        }
    }
    var shortTitle: String {
        switch self {
        case .lineage22: return "LineageOS 22.2"
        case .lineage23: return "LineageOS 23.2"
        }
    }
    var size: String {
        switch self {
        case .lineage22: return "1.0 GB"
        case .lineage23: return "1.2 GB"
        }
    }
    var note: String {
        switch self {
        case .lineage22:
            return "Runs in Android's low-memory mode: no setup wizard, no \"isn't responding\" pop-ups, boots in about 2½ minutes on a fast device. Best for every device, especially 4 GB ones like the iPad 10."
        case .lineage23:
            return "Newest Android, but heavier: it includes the setup wizard and can't use the low-memory mode (it crashes Android 16's system UI)."
        }
    }

    static var recommended: GuestImage { .lineage22 }
}
