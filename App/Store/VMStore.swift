import Foundation
import UIKit

/// Owns the VM bundles on disk: Documents/VMs/<uuid>/{vm.json, kernel, initrd, disk, state, thumbnail}.
@MainActor
final class VMStore: ObservableObject {
    @Published private(set) var vms: [VMConfiguration] = []

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VMs")
    }

    init() { reload() }

    func bundle(for vm: VMConfiguration) -> URL { Self.root.appendingPathComponent(vm.id.uuidString) }
    func thumbnailURL(for vm: VMConfiguration) -> URL { bundle(for: vm).appendingPathComponent("thumbnail.png") }

    func reload() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        vms = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("vm.json")) else { return nil }
            return try? JSONDecoder().decode(VMConfiguration.self, from: data)
        }.sorted { $0.name < $1.name }
    }

    func save(_ vm: VMConfiguration) {
        let dir = bundle(for: vm)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(vm) { try? data.write(to: dir.appendingPathComponent("vm.json"), options: .atomic) }
        reload()
    }

    /// Creates a VM bundle, moving or copying the given guest files into it.
    func create(_ vm: VMConfiguration, importing files: [URL], move: Bool) throws {
        var vm = vm
        let dir = bundle(for: vm)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for src in files {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            if move { try FileManager.default.moveItem(at: src, to: dst) } else { try FileManager.default.copyItem(at: src, to: dst) }
        }
        vm.assignBootFiles(from: (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        save(vm)
    }

    /// Copies more files into an existing bundle without touching its config.
    func importFiles(_ files: [URL], into vm: VMConfiguration) throws {
        let dir = bundle(for: vm)
        for src in files {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
        }
        objectWillChange.send()
    }

    // MARK: Built-in guest (shipped inside the app by Scripts/build-ipa.sh --with-guest)

    /// Read-only copy of the LineageOS VM inside the app bundle, if this build has one.
    static var bundledGuest: URL? {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Guest/LineageOS")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("vda.qcow2").path) ? dir : nil
    }

    /// Creates a VM from the bundled LineageOS files. The bundle is read-only, so the
    /// disks are copied into Documents (APFS clones them, so this is near-instant).
    func installBundledGuest() async throws -> VMConfiguration {
        guard let src = Self.bundledGuest else { throw CocoaError(.fileNoSuchFile) }
        var vm = VMConfiguration()
        vm.name = "LineageOS"
        vm.osDescription = "LineageOS 23.2 (Android 16), virtio_arm64only"
        vm.boot = .uefi
        vm.efiVars = "efi_vars.fd"
        vm.disks = ["vda.qcow2", "vdb.qcow2"]
        vm.soundDevice = "ac97"
        vm.touchDevice = "tablet"
        vm.gpu = .virgl
        vm.ramMB = DeviceCapabilities.current.defaultGuestRAMMB
        vm.cpus = DeviceCapabilities.current.defaultCPUs
        let dir = bundle(for: vm)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["efi_vars.fd", "vda.qcow2", "vdb.qcow2"] {
                let dst = dir.appendingPathComponent(name)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src.appendingPathComponent(name), to: dst)
                // Bundle files are read-only; the VM must be able to write its disks.
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dst.path)
            }
        }.value
        StorageHelper.excludeFromBackup(dir)
        save(vm)
        return vm
    }

    func clone(_ vm: VMConfiguration) throws {
        var copy = vm
        copy.id = UUID()
        copy.name = vm.name + " copy"
        copy.resumeFromSnapshot = false
        try FileManager.default.copyItem(at: bundle(for: vm), to: bundle(for: copy))   // APFS clones: instant
        try? FileManager.default.removeItem(at: SnapshotManager.stateURL(bundle(for: copy)))
        save(copy)
    }

    func delete(_ vm: VMConfiguration) {
        try? FileManager.default.removeItem(at: bundle(for: vm))
        reload()
    }

    func saveThumbnail(_ image: UIImage, for vm: VMConfiguration) {
        try? image.pngData()?.write(to: thumbnailURL(for: vm), options: .atomic)
        objectWillChange.send()
    }

    func diskUsage(of vm: VMConfiguration) -> UInt64 { StorageHelper.allocatedSize(of: bundle(for: vm)) }
}

extension VMConfiguration {
    /// Picks the boot layout from the files present: a UTM-style UEFI VM
    /// (efi_vars.fd + vda/vdb.qcow2) or a direct-boot kernel/initrd/disk.
    mutating func assignBootFiles(from names: [String]) {
        let lower = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        if let vars = lower["efi_vars.fd"] {
            boot = .uefi
            efiVars = vars
            soundDevice = "ac97"; touchDevice = "tablet"
            disks = names.filter { $0.lowercased().hasSuffix(".qcow2") }.sorted()
            return
        }
        boot = .kernel
        if let k = ["vmlinuz", "image", "vmlinuz-virt", "kernel"].compactMap({ lower[$0] }).first
            ?? names.first(where: { $0.lowercased().hasPrefix("vmlinuz") }) { kernel = k }
        initrd = ["initrd.img", "initrd", "initramfs", "initramfs-virt", "initrd.gz"].compactMap { lower[$0] }.first
            ?? names.first(where: { $0.lowercased().hasPrefix("initrd") })
        disk = names.first { [".qcow2", ".img", ".raw"].contains(where: $0.lowercased().hasSuffix) && !$0.lowercased().hasPrefix("initrd") }
        soundDevice = "virtio"; touchDevice = "multitouch"
        osDescription = "Waydroid (LineageOS 20) on Ubuntu 24.04"
    }
}
