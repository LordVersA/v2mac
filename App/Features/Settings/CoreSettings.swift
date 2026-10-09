import SwiftUI
import V2MacCore

struct CoreSettings: View {
    @Environment(AppModel.self) private var model

    private var updates: UpdateService { model.updates }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: updates.coreVersion ?? "Unknown")
                LabeledContent("Source", value: updates.coreIsUpdatedCopy ? "Updated copy" : "Bundled")
                statusRow
            } header: {
                Text("Xray-core")
            } footer: {
                Text("Updates are downloaded through the proxy when it is connected, verified against the published SHA-256, and self-tested before they replace the current core.")
            }
            HStack {
                Button("Check for Update") { Task { await updates.checkCore() } }
                    .disabled(updates.coreStatus == .checking || updates.coreStatus == .installing)
                if case .available(let release) = updates.coreStatus {
                    Button("Install \(release.version)") { Task { await updates.installCore(release) } }
                        .buttonStyle(.borderedProminent)
                }
                Button("Revert to Bundled") { Task { await updates.revertToBundled() } }
                    .disabled(!updates.coreIsUpdatedCopy || updates.coreStatus == .installing)
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: updates.coreStatus)
        .task { await updates.refreshCoreInfo() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch updates.coreStatus {
        case .idle: EmptyView()
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("You have the latest core.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .available(let release):
            LabeledContent("Available", value: release.version + (release.publishedAt.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
        case .installing:
            DownloadProgressView(title: "Downloading core…", progress: updates.coreProgress, rate: updates.coreDownloadRate)
        case .installed(let version):
            Label("Installed \(version).", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        }
    }
}
