import Foundation

/// Minimal ADB client (the wire protocol adbd speaks over TCP), used to install
/// APKs and run shell commands in the guest. It talks to the guest's adbd through
/// a QEMU port forward bound to 127.0.0.1. The AndroiOS images run adbd without
/// authentication when the app asks for it (SMBIOS `adb=1`, see Guest/make-lite.sh),
/// so there is no RSA handshake here.
///
/// Protocol: 24-byte little-endian header (command, arg0, arg1, data length,
/// data checksum, command ^ 0xffffffff) + payload. One stream at a time:
/// OPEN(local, 0, "service\0") → OKAY(remote, local); WRTE/OKAY in both
/// directions, one unacknowledged WRTE at most; CLSE ends the stream.
final class ADBClient {
    enum ADBError: LocalizedError {
        case connect(String), protocolError(String), closed, needsAuth, timeout
        var errorDescription: String? {
            switch self {
            case .connect(let s): return "Couldn't reach Android's ADB service (\(s)). Is Android fully booted?"
            case .protocolError(let s): return "ADB protocol error: \(s)"
            case .closed: return "Android closed the ADB connection."
            case .needsAuth: return "Android asked for ADB authorization. This needs an AndroiOS Android image from v0.4 or later."
            case .timeout: return "Android didn't answer in time."
            }
        }
    }

    private enum Cmd: UInt32 {
        case cnxn = 0x4e584e43, auth = 0x48545541, open = 0x4e45504f, okay = 0x59414b4f,
             clse = 0x45534c43, wrte = 0x45545257
    }

    private let fd: Int32
    private var maxData = 4096
    private var nextLocalID: UInt32 = 1

    /// Connects and completes the CNXN handshake. Blocking: call off the main thread.
    init(port: UInt16, timeout: TimeInterval = 10) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ADBError.connect("socket") }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { close(fd); throw ADBError.connect(String(cString: strerror(errno))) }

        // A_VERSION 0x01000001 (checksums optional), MAX_PAYLOAD 256 KiB.
        try send(.cnxn, 0x0100_0001, 256 * 1024, Data("host::\0".utf8))
        let (cmd, _, arg1, _) = try receive()
        switch cmd {
        case Cmd.cnxn.rawValue: maxData = max(4096, min(Int(arg1), 256 * 1024))
        case Cmd.auth.rawValue: throw ADBError.needsAuth
        default: throw ADBError.protocolError("unexpected reply to CNXN")
        }
    }

    deinit { close(fd) }

    /// Runs `command` with `exec:` (no terminal) and returns its output.
    func exec(_ command: String) throws -> String {
        String(decoding: try execData(command), as: UTF8.self)
    }

    /// Same as exec, returning raw bytes (e.g. `cat` of a binary file).
    func execData(_ command: String) throws -> Data {
        let (local, remote) = try open("exec:\(command)")
        return try readUntilClose(local: local, remote: remote)
    }

    /// Installs an APK by streaming it to `cmd package install -S <size>`.
    /// `progress` gets 0...1. Returns Android's output ("Success" or the failure reason).
    func install(apk url: URL, progress: (Double) -> Void) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        let (local, remote) = try open("exec:cmd package install -S \(size)")
        var sent = 0
        while sent < size {
            let chunk = try handle.read(upToCount: maxData) ?? Data()
            if chunk.isEmpty { break }
            try send(.wrte, local, remote, chunk)
            try waitForOkay(local: local)
            sent += chunk.count
            progress(Double(sent) / Double(max(size, 1)))
        }
        let out = try readUntilClose(local: local, remote: remote)
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: streams

    private func open(_ service: String) throws -> (UInt32, UInt32) {
        let local = nextLocalID; nextLocalID += 1
        try send(.open, local, 0, Data((service + "\0").utf8))
        while true {
            let (cmd, arg0, arg1, _) = try receive()
            if cmd == Cmd.okay.rawValue, arg1 == local { return (local, arg0) }
            if cmd == Cmd.clse.rawValue, arg1 == local {
                throw ADBError.protocolError("Android refused \(service.split(separator: " ").first ?? "")")
            }
        }
    }

    private func waitForOkay(local: UInt32) throws {
        while true {
            let (cmd, _, arg1, _) = try receive()
            if arg1 != local { continue }
            if cmd == Cmd.okay.rawValue { return }
            if cmd == Cmd.clse.rawValue { throw ADBError.closed }
        }
    }

    private func readUntilClose(local: UInt32, remote: UInt32) throws -> Data {
        var out = Data()
        while true {
            let (cmd, _, arg1, data) = try receive()
            if arg1 != local { continue }
            if cmd == Cmd.wrte.rawValue {
                out.append(data)
                try send(.okay, local, remote, Data())
            } else if cmd == Cmd.clse.rawValue {
                try? send(.clse, local, remote, Data())
                return out
            }
        }
    }

    // MARK: wire

    private func send(_ cmd: Cmd, _ arg0: UInt32, _ arg1: UInt32, _ data: Data) throws {
        var header = Data(capacity: 24)
        let checksum = data.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        for v in [cmd.rawValue, arg0, arg1, UInt32(data.count), checksum, cmd.rawValue ^ 0xffff_ffff] {
            withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) }
        }
        #if DEBUG_ADB
        print("> \(String(decoding: withUnsafeBytes(of: cmd.rawValue.littleEndian) { Data($0) }, as: UTF8.self)) \(arg0) \(arg1) len=\(data.count)")
        #endif
        try writeAll(header + data)
    }

    private func receive() throws -> (UInt32, UInt32, UInt32, Data) {
        let h = try readExactly(24)
        func u32(_ i: Int) -> UInt32 { h.subdata(in: i..<i + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        let cmd = u32(0), arg0 = u32(4), arg1 = u32(8), len = Int(u32(12))
        guard u32(20) == cmd ^ 0xffff_ffff, len <= 1 << 20 else { throw ADBError.protocolError("bad header") }
        #if DEBUG_ADB
        print("< \(String(decoding: h.prefix(4), as: UTF8.self)) \(arg0) \(arg1) len=\(len)")
        #endif
        return (cmd, arg0, arg1, len > 0 ? try readExactly(len) : Data())
    }

    private func writeAll(_ d: Data) throws {
        try d.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { throw errno == EAGAIN ? ADBError.timeout : ADBError.closed }
                off += n
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var d = Data(count: count)
        var off = 0
        try d.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            while off < count {
                let n = Darwin.read(fd, buf.baseAddress! + off, count - off)
                if n == 0 { throw ADBError.closed }
                if n < 0 { throw errno == EAGAIN ? ADBError.timeout : ADBError.closed }
                off += n
            }
        }
        return d
    }
}
