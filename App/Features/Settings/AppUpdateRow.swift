import SwiftUI

struct AppUpdateRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            switch model.updates.appStatus {
            case .available(let release):
                Label("V2Mac \(release.version) is available.", systemImage: "arrow.down.circle.fill")
                Link("Release Notes", destination: release.pageURL)
                Spacer()
                Button("Update Now") { Task { await model.updates.installApp(release) } }
                    .controlSize(.small)
            case .installing(let release):
                AppDownloadProgress(release: release)
            case .installFailed(let release, let message):
                Text("Update failed: \(message)").font(.caption).foregroundStyle(.secondary)
                Link("View Release", destination: release.pageURL)
                Spacer()
                Button("Try Again") { Task { await model.updates.installApp(release) } }
                    .controlSize(.small)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .upToDate:
                Label("V2Mac is up to date.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .unavailable(let message):
                Text(message).font(.caption).foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
            if model.updates.availableAppUpdate == nil {
                Spacer()
                Button("Check Now") { Task { await model.updates.checkApp(manual: true) } }
                    .controlSize(.small)
            }
        }
    }
}
