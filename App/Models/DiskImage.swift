import Foundation

/// Metadata for a disk image in a VM bundle. Reads the qcow2 header directly
/// (big-endian: magic "QFI\xfb", version @4, virtual size @24, cluster bits @20).
struct DiskImage: Identifiable, Equatable {
    enum Format: String { case qcow2, raw }

    var id: String { url.path }
    let url: URL
    let format: Format
    let virtualSize: UInt64      // bytes the guest sees
    let allocatedSize: UInt64    // bytes used on the iOS filesystem
    let clusterSize: UInt64?

    init?(url: URL) {
        guard let attrs = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]),
              let fileSize = attrs.fileSize else { return nil }
        self.url = url
        allocatedSize = UInt64(attrs.totalFileAllocatedSize ?? fileSize)

        let header = (try? FileHandle(forReadingFrom: url))
            .flatMap { h -> Data? in defer { try? h.close() }; return try? h.read(upToCount: 32) } ?? Data()
        if header.count >= 32, header.prefix(4) == Data([0x51, 0x46, 0x49, 0xFB]) {
            format = .qcow2
            virtualSize = header.beUInt64(at: 24)
            clusterSize = 1 << UInt64(header.beUInt32(at: 20))
        } else {
            format = .raw
            virtualSize = UInt64(fileSize)
            clusterSize = nil
        }
    }
}

private extension Data {
    func beUInt64(at o: Int) -> UInt64 { self[o..<o + 8].reduce(0) { $0 << 8 | UInt64($1) } }
    func beUInt32(at o: Int) -> UInt32 { self[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
}
