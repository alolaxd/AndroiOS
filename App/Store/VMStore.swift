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
