import SwiftUI

/// Disk images and files in each VM bundle, plus free space. Lets you import
/// more files (Files app) or remove ones you don't need.
struct StorageManagerView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss
    @State private var importingInto: VMConfiguration?
    @State private var refresh = 0

    var body: some View {
        List {
            Section("Device") {
                LabeledContent("Free space", value: StorageHelper.format(StorageHelper.availableBytes))
                LabeledContent("Used by VMs", value: StorageHelper.format(StorageHelper.allocatedSize(of: VMStore.root)))
            }
            ForEach(store.vms) { vm in
                Section(vm.name) {
                    ForEach(files(of: vm), id: \.self) { url in
                        HStack {
                            Image(systemName: icon(for: url))
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).font(.callout)
                                if let d = DiskImage(url: url), d.format == .qcow2 {
                                    Text("qcow2 · \(StorageHelper.format(d.virtualSize)) virtual · \(StorageHelper.format(d.clusterSize ?? 0)) clusters")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(StorageHelper.format(StorageHelper.allocatedSize(of: url))).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            if !["vm.json"].contains(url.lastPathComponent) {
                                Button("Delete", role: .destructive) { try? FileManager.default.removeItem(at: url); refresh += 1 }
                            }
                        }
                    }
                    Button("Import files…") { importingInto = vm }
                }
            }
        }
        .id(refresh)
        .navigationTitle("Storage")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .fileImporter(isPresented: .constant(importingInto != nil), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let vm = importingInto, case .success(let urls) = result else { importingInto = nil; return }
            try? store.importFiles(urls, into: vm)
            importingInto = nil
            refresh += 1
        }
    }

    private func files(of vm: VMConfiguration) -> [URL] {
        let dir = store.bundle(for: vm)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "qcow2", "img", "raw": return "internaldrive"
        case "json": return "doc.text"
        case "state": return "clock.arrow.circlepath"
        case "png": return "photo"
        default: return "cpu"
        }
    }
}
