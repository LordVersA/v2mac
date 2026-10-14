import SwiftUI
import V2MacCore

/// The running app-update download.
struct AppDownloadProgress: View {
    @Environment(AppModel.self) private var model
    let release: AppRelease

    var body: some View {
        if let step = model.updates.brewStep {
            // `brew` reports no progress the app could read.
            VStack(alignment: .leading, spacing: 4) {
                ProgressView().progressViewStyle(.linear)
                Text(step).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            DownloadProgressView(
                title: "Downloading V2Mac \(release.version)…",
                progress: model.updates.appProgress,
                rate: model.updates.appDownloadRate
            )
        }
    }
}
