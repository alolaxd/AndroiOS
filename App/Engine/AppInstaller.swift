import Foundation

/// Installs Android apps into the running guest over ADB (see ADBClient):
/// APKs picked in Files, or F-Droid (an open-source app store; from there,
/// Aurora Store gives access to Google Play's catalog).
@MainActor
final class AppInstaller: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var progress: Double?
    @Published private(set) var busy = false

    static let fdroidURL = URL(string: "https://f-droid.org/F-Droid.apk")!

    func clearStatus() { if !busy { status = nil } }

    /// `url` from the file importer (security-scoped).
    func installAPK(at url: URL, port: UInt16) {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".apk")
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            status = "Couldn't read \(name): \(error.localizedDescription)"
            return
        }
        run(name: name, apk: tmp, port: port)
    }

    func installFDroid(port: UInt16) {
        busy = true; progress = nil; status = "Downloading F-Droid…"
        Task {
            do {
                let (file, response) = try await URLSession.shared.download(from: Self.fdroidURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let apk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".apk")
                try FileManager.default.moveItem(at: file, to: apk)
                busy = false
                run(name: "F-Droid", apk: apk, port: port)
            } catch {
                busy = false
                status = "Couldn't download F-Droid: \(error.localizedDescription)"
            }
        }
    }

    private func run(name: String, apk: URL, port: UInt16) {
        busy = true; progress = 0; status = "Installing \(name)…"
        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: apk) }
            let result: String
            do {
                let adb = try Self.connect(port: port)
                let out = try adb.install(apk: apk) { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
                result = out.contains("Success")
                    ? "Installed \(name). Find it in Android's app drawer."
                    : "Android couldn't install \(name): \(Self.reason(out))"
            } catch {
                result = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                self?.busy = false; self?.progress = nil; self?.status = result
            }
        }
    }

    /// adbd starts late in boot, and early on it can accept a connection but not
    /// answer yet: retry until a test command runs, for up to about a minute.
    nonisolated private static func connect(port: UInt16) throws -> ADBClient {
        var last: Error = ADBClient.ADBError.timeout
        for _ in 0..<12 {
            do {
                let adb = try ADBClient(port: port, timeout: 5)
                if try adb.exec("echo ok").contains("ok") { return adb }
            } catch { last = error }
            Thread.sleep(forTimeInterval: 2)
        }
        throw last
    }

    /// "Failure [INSTALL_FAILED_NO_MATCHING_ABIS: ...]" → readable text.
    nonisolated private static func reason(_ out: String) -> String {
        if out.contains("NO_MATCHING_ABIS") { return "it has no ARM64 version (this Android runs 64-bit ARM apps only)." }
        if out.contains("OLDER_SDK") { return "it needs a newer Android version." }
        if out.contains("INSUFFICIENT_STORAGE") { return "Android is out of storage." }
        if out.contains("INVALID_APK") || out.contains("PARSE_FAILED") { return "the file isn't a valid APK (split APKs/XAPKs aren't supported; use an app store inside Android)." }
        return out.isEmpty ? "no response" : out
    }
}
