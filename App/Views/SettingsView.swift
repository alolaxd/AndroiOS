import SwiftUI

/// Per-VM configuration. Changes apply on the next boot.
struct SettingsView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var engine: AndroiOSEngine
    @Environment(\.dismiss) private var dismiss
    @State var vm: VMConfiguration
    @State private var newHost = "5555"
    @State private var newGuest = "5555"
    @State private var extraArgsText = ""
    private let caps = DeviceCapabilities.current

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $vm.name)
                TextField("Description", text: $vm.osDescription)
                LabeledContent("Boot", value: vm.bootOrderNote)
            }
            Section {
                Stepper(value: $vm.ramMB, in: 1024...caps.maxGuestRAMMB, step: 256) {
                    LabeledContent("RAM", value: String(format: "%.2f GB", Double(vm.ramMB) / 1024))
                }
                if let warn = caps.ramWarning(forGuestMB: vm.ramMB) { Text(warn).font(.caption).foregroundStyle(.orange) }
                Stepper(value: $vm.cpus, in: 1...max(1, min(6, caps.cores))) {
                    LabeledContent("CPU cores", value: "\(vm.cpus)")
                }
                LabeledContent("Architecture", value: "AArch64 guest on \(caps.machine) (TCG JIT)")
                LabeledContent("Device RAM", value: String(format: "%.1f GB", caps.physicalMemoryGB))
            } header: { Text("Hardware") } footer: {
                Text("Each vCPU runs on its own host thread (multi-threaded TCG). Leave a core for the GPU and UI threads.")
            }
            Section("Display") {
                Picker("Graphics", selection: $vm.gpu) { ForEach(VMConfiguration.GPU.allCases) { Text($0.label).tag($0) } }
                Picker("Resolution", selection: resolutionBinding) {
                    ForEach(Self.resolutions, id: \.self) { r in Text(r.replacingOccurrences(of: "x", with: "×")).tag(r) }
                    Text("Match device").tag("device")
                }
                if vm.boot == .uefi {
                    Picker("Android layout", selection: $vm.layout) { ForEach(VMConfiguration.Layout.allCases) { Text($0.label).tag($0) } }
                    Text("\(vm.layout.label) layout: \(vm.lcdDensity) dpi. The tablet layout needs an AndroiOS image from v0.3.1 or later; older ones always use the phone layout.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Frame rate", selection: $vm.targetFPS) { Text("30").tag(30); Text("60").tag(60); Text("120 (ProMotion)").tag(120) }
                Text("Lower resolutions are much faster: the guest CPU renders Android's UI through TCG.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                Picker("Boot", selection: $vm.boot) { ForEach(VMConfiguration.Boot.allCases) { Text($0.label).tag($0) } }
                if vm.boot == .uefi {
                    LabeledContent("NVRAM", value: vm.efiVars ?? "none")
                } else {
                    LabeledContent("Kernel", value: vm.kernel)
                    LabeledContent("Initramfs", value: vm.initrd ?? "none")
                }
                ForEach(vm.boot == .uefi ? vm.disks : [vm.disk].compactMap { $0 }, id: \.self) { disk in
                    if let img = DiskImage(url: store.bundle(for: vm).appendingPathComponent(disk)) {
                        LabeledContent(disk, value: "\(StorageHelper.format(img.allocatedSize)) of \(StorageHelper.format(img.virtualSize)) (\(img.format.rawValue))")
                    } else {
                        LabeledContent(disk, value: "missing").foregroundStyle(.red)
                    }
                }
                Picker("Touch input", selection: $vm.touchDevice) { Text("USB tablet").tag("tablet"); Text("virtio multitouch").tag("multitouch") }
                Picker("Sound card", selection: $vm.soundDevice) { Text("AC97").tag("ac97"); Text("virtio-sound").tag("virtio"); Text("Intel HDA").tag("hda") }
            }
            Section {
                Toggle("Internet access", isOn: $vm.network)
                ForEach(vm.portForwards) { f in Text("\(f.proto.rawValue) host:\(f.hostPort) → guest:\(f.guestPort)") }
                    .onDelete { vm.portForwards.remove(atOffsets: $0) }
                HStack {
                    TextField("host", text: $newHost).keyboardType(.numberPad)
                    Image(systemName: "arrow.right")
                    TextField("guest", text: $newGuest).keyboardType(.numberPad)
                    Button("Add") {
                        if let h = Int(newHost), let g = Int(newGuest) { vm.portForwards.append(PortForward(hostPort: h, guestPort: g)) }
                    }
                }.disabled(!vm.network)
                if let err = NetworkManager.validate(vm.portForwards) { Text(err).font(.caption).foregroundStyle(.red) }
            } header: { Text("Network") } footer: { Text("Usermode NAT (SLIRP). Forward 5555 to reach the guest's ADB over the network.") }
            Section("Android") {
                LabeledContent("Guest", value: vm.osDescription)
                if vm.boot == .kernel {
                Toggle("Waydroid: Android renders on the GPU (experimental)", isOn: $vm.androidGPURendering)
                    .disabled(vm.gpu != .virgl)
                Text(vm.androidGPURendering
                     ? "Android draws with Mesa virgl on the Apple GPU. Known issue: the home screen currently shows black."
                     : "Android draws with SwiftShader on the emulated CPU; the compositor still runs on the Apple GPU.")
                    .font(.caption).foregroundStyle(vm.androidGPURendering ? .orange : .secondary)
                }
                Toggle("Audio", isOn: $vm.audio)
                if !vm.audio {
                    Text("Android's SystemUI crashes without an audio device (AudioManager returns no recording configs). Keep audio on for Android guests.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if vm.boot == .uefi {
                    Toggle("Install apps from AndroiOS", isOn: $vm.appInstalls)
                    Text("Lets the menu install APKs from Files and F-Droid. Runs Android's ADB service, reachable only from inside AndroiOS on this device (localhost). Needs an AndroiOS Android image from v0.4 or later.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("To update LineageOS, run `sudo waydroid upgrade` in the serial console with internet access on.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Advanced") {
                if vm.boot == .kernel {
                    TextField("Kernel command line", text: $vm.kernelArgs, axis: .vertical).font(.system(.caption, design: .monospaced))
                }
                TextField("Extra QEMU arguments (one per line)", text: $extraArgsText, axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                if vm.resumeFromSnapshot {
                    Button("Discard saved state", role: .destructive) {
                        vm.resumeFromSnapshot = false
                        try? FileManager.default.removeItem(at: SnapshotManager.stateURL(store.bundle(for: vm)))
                    }
                }
                if engine.runningVM?.id == vm.id {
                    NavigationLink("Boot log") { ConsoleView(engine: engine).navigationTitle("Serial console") }
                    Text(engine.commandLine).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(vm.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    vm.extraArgs = extraArgsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    store.save(vm); dismiss()
                }.disabled(NetworkManager.validate(vm.portForwards) != nil)
            }
        }
        .onAppear { extraArgsText = vm.extraArgs.joined(separator: "\n") }
    }

    static var resolutions: [String] {
        var r = ["540x960", "720x1280", "1080x1920", "1280x720", "1920x1080"]
        let s = DeviceCapabilities.screenShapedResolution()
        let shaped = "\(s.width)x\(s.height)"
        if !r.contains(shaped) { r.insert(shaped, at: 2) }
        return r
    }

    private var resolutionBinding: Binding<String> {
        Binding(get: { "\(vm.displayWidth)x\(vm.displayHeight)" }, set: { v in
            if v == "device" {
                let b = UIScreen.main.nativeBounds
                vm.displayWidth = Int(min(b.width, b.height)) & ~7
                vm.displayHeight = Int(max(b.width, b.height)) & ~7
            } else {
                let p = v.split(separator: "x").compactMap { Int($0) }
                if p.count == 2 { vm.displayWidth = p[0]; vm.displayHeight = p[1] }
            }
        })
    }
}
