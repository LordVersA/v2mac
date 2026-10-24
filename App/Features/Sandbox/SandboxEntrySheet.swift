import SwiftUI
import V2MacCore

/// The first click on Sandbox (spec 12.11): what it is, what it takes, and Download.
struct SandboxEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var sandbox: SandboxService { model.sandbox }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Secure Sandbox (beta)", systemImage: "shield.lefthalf.filled").font(.title2.bold())
            Text("Run apps in mini VMs, each with its own server. Every app opens as its own Mac app, and nothing it does can reach the internet except through the server you pick for it.")
                .fixedSize(horizontal: false, vertical: true)
            if sandbox.updateAvailable {
                Text("This V2Mac needs a newer sandbox. Update it to open the sandbox; your mini VMs and their data stay.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, verticalSpacing: 6) {
                if let pin = sandbox.pin {
                    GridRow {
                        Text("Download").foregroundStyle(.secondary)
                        Text(pin.size, format: .byteCount(style: .file))
                    }
                }
                GridRow {
                    Text("Memory").foregroundStyle(.secondary)
                    Text("up to \(Int64(Prefs.sandboxRAMCapMB) << 20, format: .byteCount(style: .memory)) while it runs")
                }
            }
            switch sandbox.phase {
            case .downloading(let fraction):
                if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            default:
                EmptyView()
            }
            HStack {
                Spacer()
                if case .downloading = sandbox.phase {
                    Button("Cancel") { sandbox.cancelDownload() }
                } else {
                    Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if sandbox.updateAvailable {
                    Button("Update") { sandbox.update() }
                        .keyboardShortcut(.defaultAction)
                        .disabled({ if case .downloading = sandbox.phase { true } else { false } }())
                } else if sandbox.phase == .installed {
                    Button("Open Sandbox") {
                        dismiss()
                        sandbox.open()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Download") { sandbox.download() }
                        .keyboardShortcut(.defaultAction)
                        .disabled({ if case .downloading = sandbox.phase { true } else { false } }())
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
