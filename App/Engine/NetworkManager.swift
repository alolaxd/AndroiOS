import Foundation

/// SLIRP usermode NAT: the guest reaches the internet through the app's own
/// sockets (no raw sockets, works in the iOS sandbox). DNS is forwarded to the
/// host resolver by libslirp at 10.0.2.3. Port forwards expose guest services
/// (e.g. ADB on 5555) on the iPhone's loopback / LAN address.
enum NetworkManager {
    static let adb = PortForward(proto: .tcp, hostPort: 5555, guestPort: 5555)

    static func validate(_ forwards: [PortForward]) -> String? {
        var seen = Set<String>()
        for f in forwards {
            guard (1...65535).contains(f.hostPort), (1...65535).contains(f.guestPort) else {
                return "Ports must be between 1 and 65535."
            }
            if f.hostPort < 1024 { return "Host port \(f.hostPort) is privileged; iOS apps can only bind ports ≥ 1024." }
            let key = "\(f.proto.rawValue):\(f.hostPort)"
            if !seen.insert(key).inserted { return "Host port \(f.hostPort)/\(f.proto.rawValue) is forwarded twice." }
        }
        return nil
    }
}
