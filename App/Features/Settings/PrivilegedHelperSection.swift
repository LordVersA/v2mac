import ServiceManagement
import SwiftUI

struct PrivilegedHelperSection: View {
    @Environment(AppModel.self) private var model
    private let helper = PrivilegedHelperService.shared
    @State private var removing = false

    var body: some View {
        Section {
            if helper.isSupported {
                LabeledContent("Status") { Text(status) }
                if helper.status == .enabled {
                    Button("Remove Helper") {
                        removing = true
                        Task {
                            await model.connection.shutdown()
                            await helper.unregister()
                            removing = false
                        }
                    }
                    .disabled(removing)
                } else if helper.status == .requiresApproval {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                } else {
                    Button("Enable Helper…") { helper.register() }
                }
            } else {
                Text("This build uses the macOS administrator dialog each session. The managed helper requires an Apple-signed build.")
                    .foregroundStyle(.secondary)
            }
            if let error = helper.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Privileged helper")
        } footer: {
            Text("Handles TUN mode, DNS changes, the system proxy and the kill switch. Approve it once in macOS to use it across app restarts. V2Mac never collects your administrator password. Removing it stops the current connection.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { helper.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in helper.refresh() }
    }

    private var status: LocalizedStringKey {
        switch helper.status {
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval in System Settings"
        case .notRegistered: "Not enabled"
        case .notFound: "Helper not found"
        @unknown default: "Unavailable"
        }
    }
}
