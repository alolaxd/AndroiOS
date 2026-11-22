import SwiftUI

/// Root: first-run wizard when there are no VMs, otherwise the VM list.
struct ContentView: View {
    @EnvironmentObject private var store: VMStore

    var body: some View {
        if store.vms.isEmpty {
            SetupWizardView(isFirstRun: true)
        } else {
            NavigationStack { VMManagerView() }
        }
    }
}
