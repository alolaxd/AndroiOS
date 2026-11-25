import Foundation

/// A VM's persistent configuration, stored as `vm.json` in its bundle
/// directory (Documents/VMs/<id>/). Paths are file names inside that bundle.
struct VMConfiguration: Codable, Identifiable, Equatable {
    enum GPU: String, Codable, CaseIterable, Identifiable {
        case virgl, twoD = "2d", none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .virgl: return "3D (virgl → ANGLE → Metal)"
            case .twoD: return "2D framebuffer"
            case .none: return "Headless (serial only)"
            }
        }
    }

    var id = UUID()
    var name = "LineageOS"
    var osDescription = "LineageOS (Android), virtio_arm64only"

    enum Boot: String, Codable, CaseIterable, Identifiable {
        case uefi, kernel
        var id: String { rawValue }
        var label: String { self == .uefi ? "UEFI (edk2 → GRUB → Android)" : "Direct kernel boot" }
    }
    var boot: Boot = .uefi

    // UEFI boot: NVRAM vars file + disks (boot order = array order), relative to the bundle.
    var efiVars: String? = "efi_vars.fd"
    var disks: [String] = ["vda.qcow2", "vdb.qcow2"]

    // Direct kernel boot (e.g. the Linux/Waydroid guest from Guest/build-guest.sh).
    var kernel = "vmlinuz"
    var initrd: String? = "initrd.img"
    var disk: String? = nil
    var kernelArgs = "root=LABEL=cloudimg-rootfs rw console=ttyAMA0 quiet loglevel=3 androios.mode=android"

    // Hardware
    var ramMB = 3072
    var cpus = 4

    // Display
    var gpu: GPU = .virgl
    var displayWidth = 720
    var displayHeight = 1280
    var targetFPS = 60
    /// Android layout. Sets the guest's screen density (the AndroiOS images read it
    /// from SMBIOS in GRUB): phone = 360 dp wide, tablet = 720 dp (Android's tablet UI
    /// starts at 600 dp).
    enum Layout: String, Codable, CaseIterable, Identifiable {
        case phone, tablet
        var id: String { rawValue }
        var label: String { self == .phone ? "Phone" : "Tablet" }
        var widthDP: Int { self == .phone ? 360 : 720 }
    }
    var layout: Layout = .phone
    /// dpi that gives `layout.widthDP` across the short side of the guest display.
    var lcdDensity: Int { max(120, min(displayWidth, displayHeight) * 160 / layout.widthDP) }

    // Devices
    var network = true
    var portForwards: [PortForward] = []
    var audio = true
    /// Guest sound card: "ac97" (LineageOS virtio targets), "virtio", "hda".
    var soundDevice = "ac97"
    /// "tablet" (USB tablet: what UTM-targeted Android images expect) or "multitouch" (virtio, 10 points).
    var touchDevice = "tablet"

    /// Waydroid guest only: Android renders on the host GPU instead of SwiftShader.
    var androidGPURendering = false

    // Advanced
    var extraArgs: [String] = []

    /// Set when a state file exists and the next boot should resume from it.
    var resumeFromSnapshot = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VMConfiguration()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? def }
        id = v(.id, d.id); name = v(.name, d.name); osDescription = v(.osDescription, d.osDescription)
        boot = v(.boot, .kernel)   // VMs saved before UEFI support were all kernel-boot
        efiVars = v(.efiVars, d.efiVars); disks = v(.disks, d.disks); soundDevice = v(.soundDevice, "virtio"); touchDevice = v(.touchDevice, "multitouch")
        kernel = v(.kernel, d.kernel); initrd = v(.initrd, d.initrd); disk = v(.disk, d.disk)
        kernelArgs = v(.kernelArgs, d.kernelArgs); ramMB = v(.ramMB, d.ramMB); cpus = v(.cpus, d.cpus)
        gpu = v(.gpu, d.gpu); displayWidth = v(.displayWidth, d.displayWidth); displayHeight = v(.displayHeight, d.displayHeight)
        targetFPS = v(.targetFPS, d.targetFPS); layout = v(.layout, d.layout); network = v(.network, d.network); portForwards = v(.portForwards, d.portForwards)
        audio = v(.audio, d.audio); androidGPURendering = v(.androidGPURendering, d.androidGPURendering)
        extraArgs = v(.extraArgs, d.extraArgs); resumeFromSnapshot = v(.resumeFromSnapshot, d.resumeFromSnapshot)
    }

    var bootOrderNote: String { boot == .uefi ? "UEFI → \(disks.joined(separator: ", "))" : "Direct kernel boot (\(kernel))" }

    func engineConfig(bundle: URL) -> [String: Any] {
        func path(_ name: String?) -> String? {
            guard let name, !name.isEmpty else { return nil }
            return bundle.appendingPathComponent(name).path
        }
        var c: [String: Any] = [
            "ram_mb": ramMB,
            "cpus": cpus,
            "gpu": gpu.rawValue,
            "display_width": displayWidth,
            "display_height": displayHeight,
            "network": network,
            "port_forwards": portForwards.map(\.qemuSpec),
            "audio": audio,
            "sound_device": soundDevice,
            "touch_device": touchDevice,
            "extra_args": extraArgs,
        ]
        if boot == .uefi { c["lcd_density"] = lcdDensity }
        switch boot {
        case .uefi:
            // edk2 firmware ships inside the app bundle.
            c["efi_code"] = Bundle.main.path(forResource: "edk2-aarch64-code", ofType: "fd")
            c["efi_vars"] = path(efiVars)
            c["disks"] = disks.compactMap { path($0) }
        case .kernel:
            c["kernel"] = path(kernel)
            c["initrd"] = path(initrd)
            c["disk"] = path(disk)
            c["append"] = kernelArgs + " androios.gpu=\(androidGPURendering ? "virgl" : "soft")"
        }
        if resumeFromSnapshot, FileManager.default.fileExists(atPath: SnapshotManager.stateURL(bundle).path) {
            c["restore_from"] = SnapshotManager.stateURL(bundle).path
        }
        return c
    }
}

struct PortForward: Codable, Equatable, Identifiable, Hashable {
    enum Proto: String, Codable, CaseIterable { case tcp, udp }
    var id = UUID()
    var proto: Proto = .tcp
    var hostPort: Int
    var guestPort: Int

    var qemuSpec: String { "\(proto.rawValue)::\(hostPort)-:\(guestPort)" }
}
