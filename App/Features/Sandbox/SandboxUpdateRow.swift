import SwiftUI

/// The sandbox's Update Now (Settings → Sandbox and the menu bar), as `AppUpdateRow` is the app's.
struct SandboxUpdateRow: View {
    @Environment(AppModel.self) private var model

    private var sandbox: SandboxService { model.sandbox }

    var body: some View {
        HStack {
            if case .downloading = sandbox.phase {
                DownloadProgressView(title: "Downloading the Secure Sandbox (beta)…", progress: sandbox.progress, rate: sandbox.downloadRate)
            } else {
                if case .failed(let message) = sandbox.phase {
                    Text("Update failed: \(message)").font(.caption).foregroundStyle(.secondary)
                } else if let version = sandbox.pin?.version {
                    Label("Secure Sandbox (beta) \(version) is available.", systemImage: "arrow.down.circle.fill")
                } else {
                    Label("A Secure Sandbox (beta) update is available.", systemImage: "arrow.down.circle.fill")
                }
                Spacer()
                Button("Update Now") { sandbox.update() }
                    .controlSize(.small)
            }
        }
        .animation(.default, value: sandbox.phase)
    }
}
