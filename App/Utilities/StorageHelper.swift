import Foundation

enum StorageHelper {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Free space usable for large files ("important" capacity accounts for purgeable data).
    static var availableBytes: UInt64 {
        let v = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, v?.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    static func allocatedSize(of url: URL) -> UInt64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let f as URL in e {
            total += UInt64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Exclude VM bundles from iCloud backup (multi-GB, reproducible).
    static func excludeFromBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }
}
