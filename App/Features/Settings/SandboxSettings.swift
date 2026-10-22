import SwiftUI
import V2MacCore

/// Settings → Sandbox (spec 12.11): the VM's memory cap and Remove.
struct SandboxSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sandboxRAMCapMB") private var ramCapMB = 2048
    @State private var confirmRemove = false
    @State private var usage: Int64 = 0

    private var sandbox: SandboxService { model.sandbox }
    /// Up to half of the Mac's memory, in 1 GB steps from 2 GB.
    private var ramChoices: [Int] {
        let half = Int(ProcessInfo.processInfo.physicalMemory >> 20) / 2
        return Array(stride(from: 2048, through: max(2048, half), by: 1024))
    }

    var body: some View {
        Form {
            Section {
                Picker("Memory limit", selection: $ramCapMB) {
                    ForEach(ramChoices, id: \.self) { Text(Int64($0) << 20, format: .byteCount(style: .memory)).tag($0) }
                }
                .onChange(of: ramCapMB) { sandbox.ramCapChanged() }
            } header: {
                Text("Resources")
            } footer: {
                note("The sandbox starts when you open it and stops 5 minutes after its last window closes. A new limit applies from its next start.")
            }
            Section {
                LabeledContent("Disk space used", value: usage.formatted(.byteCount(style: .file)))
                Button("Remove Sandbox…", role: .destructive) { confirmRemove = true }
                    .disabled(sandbox.phase != .installed && usage == 0)
            } header: {
                Text("Storage")
            } footer: {
                note("Removing deletes the sandbox, every mini VM with its data, and the sandbox apps. It can be downloaded again later.")
            }
            ResetSettingsSection(tab: .sandbox)
        }
        .formStyle(.grouped)
        .task(id: sandbox.phase) { usage = sandbox.diskUsage() }
        .confirmationDialog("Remove the sandbox?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    await sandbox.remove()
                    usage = sandbox.diskUsage()
                }
            }
        } message: {
            Text("Every mini VM and its data will be deleted.")
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
