import SwiftUI
import V2MacCore

/// The running app-update download.
struct AppDownloadProgress: View {
    @Environment(AppModel.self) private var model
    let release: AppRelease

    var body: some View {
        DownloadProgressView(
            title: "Downloading V2Mac \(release.version)…",
            progress: model.updates.appProgress,
            rate: model.updates.appDownloadRate
        )
    }
}
