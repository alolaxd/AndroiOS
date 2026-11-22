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
    @State private var baseURL = ""
    @State private var downloadQueue: [String] = []
    @State private var error: String?
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
            Text("AndroiOS runs a full Android (LineageOS via Waydroid) virtual machine on this device. The guest's CPU is emulated with QEMU's JIT and its GPU commands are translated to Metal (virgl → ANGLE).")
                .font(.callout)
        }
        Section("This device") {
            LabeledContent("Model", value: caps.machine)
            LabeledContent("Memory", value: String(format: "%.1f GB", caps.physicalMemoryGB))
            LabeledContent("CPU cores", value: "\(caps.cores) (\(caps.performanceCores) performance)")
            LabeledContent("Free storage", value: StorageHelper.format(StorageHelper.availableBytes))
            if !caps.isSupported { Text("This device is older than A13; expect very low performance.").foregroundStyle(.orange) }
            if StorageHelper.availableBytes < 8 << 30 { Text("At least 8 GB free space is recommended.").foregroundStyle(.orange) }
        }
        Section("You will need") {
            Label("StikDebug, to enable JIT", systemImage: "bolt.fill")
            Label("GetMoreRAM (or TrollStore / paid dev profile) for the memory entitlements", systemImage: "memorychip")
            Label("The guest image built with Guest/build-guest.sh on a Mac", systemImage: "shippingbox")
        }
        Button("Continue") { step = .guest }
    }

    @ViewBuilder private var guest: some View {
        Section {
            Button("Import from Files…", systemImage: "folder") { importing = true }
            ForEach(files, id: \.self) { Text($0.lastPathComponent).font(.caption.monospaced()) }
        } header: { Text("Guest image") } footer: {
            Text("LineageOS: select efi_vars.fd, vda.qcow2 and vdb.qcow2 from the UTM bundle's Data folder (Guest/fetch-lineage.sh). Or the Waydroid guest: vmlinuz, initrd.img, androios.qcow2.")
        }
        Section {
            TextField("https://example.com/androios/", text: $baseURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if downloads.isDownloading || downloads.canResume {
                ProgressView(value: downloads.progress) {
                    Text("\(downloadQueue.first ?? "") — \(StorageHelper.format(UInt64(max(0, downloads.bytesWritten)))) of \(StorageHelper.format(UInt64(max(0, downloads.bytesExpected))))")
                        .font(.caption)
                }
                Button(downloads.isDownloading ? "Pause" : "Resume") {
                    downloads.isDownloading ? downloads.pause() : downloadNext()
                }
            } else {
                Button("Download \(Self.guestFiles.joined(separator: ", "))") {
                    downloadQueue = Self.guestFiles.filter { n in !files.contains { $0.lastPathComponent == n } }
                    downloadNext()
                }.disabled(URL(string: baseURL)?.scheme == nil)
            }
            if let e = downloads.error { Text(e).font(.caption).foregroundStyle(.red) }
        } header: { Text("…or download") } footer: { Text("Downloads resume after interruptions.") }
        Button("Continue") { step = .hardware }.disabled(!hasGuestFiles)
    }

    @ViewBuilder private var hardware: some View {
        Section("Name") { TextField("Name", text: $vm.name) }
        Section {
            Stepper("RAM: \(Double(vm.ramMB) / 1024, specifier: "%.1f") GB", value: $vm.ramMB, in: 1024...caps.maxGuestRAMMB, step: 512)
            if let w = caps.ramWarning(forGuestMB: vm.ramMB) { Text(w).font(.caption).foregroundStyle(.orange) }
            Stepper("CPU cores: \(vm.cpus)", value: $vm.cpus, in: 1...max(1, min(6, caps.cores)))
            Picker("Resolution", selection: $vm.displayHeight) {
                Text("540×960 (fastest)").tag(960)
                Text("720×1280 (balanced)").tag(1280)
                Text("1080×1920 (sharp)").tag(1920)
            }
            .onChange(of: vm.displayHeight) { h in vm.displayWidth = h * 9 / 16 }
        } header: { Text("Hardware") } footer: { Text("Defaults are tuned for this device.") }
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
            downloadNext()
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
