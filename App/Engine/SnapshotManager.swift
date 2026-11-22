import UIKit

/// Background handling. iOS suspends apps ~30 s after backgrounding, so:
///  • migratable device sets (2D / headless): save full state to the bundle and
///    resume from it on the next launch (QEMU -incoming file:…);
///  • virgl (3D) is not migratable in QEMU, so the guest is only paused, and is
///    lost if iOS terminates the app while suspended.
@MainActor
enum SnapshotManager {
    nonisolated static func stateURL(_ bundle: URL) -> URL { bundle.appendingPathComponent("snapshot.state") }

    static func handleBackground(engine: AndroiOSEngine, store: VMStore) {
        guard var vm = engine.runningVM, engine.state == .running || engine.state == .paused else { return }
        guard vm.gpu != .virgl else { engine.pause(); return }

        let bundle = store.bundle(for: vm)
        let id = engine.currentVMID
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Save VM state") {
            UIApplication.shared.endBackgroundTask(task)
        }
        engine.markSaving()
        Task.detached {
            var ok = true
            do { try engine.saveSnapshot(to: stateURL(bundle), vmID: id) } catch { ok = false }
            await MainActor.run {
                engine.markPaused()
                vm.resumeFromSnapshot = ok
                store.save(vm)
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }

    /// After a successful resume the state file is stale; drop the flag.
    static func consumeResume(_ vm: inout VMConfiguration, store: VMStore) {
        guard vm.resumeFromSnapshot else { return }
        vm.resumeFromSnapshot = false
        store.save(vm)
    }
}
