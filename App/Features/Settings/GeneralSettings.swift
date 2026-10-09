import ServiceManagement
import SwiftUI

struct GeneralSettings: View {
    @AppStorage("reconnectOnLaunch") private var reconnectOnLaunch = true
    @AppStorage("restartOnWakeOrNetwork") private var restartOnWake = true
    @AppStorage("checkAppUpdates") private var checkUpdates = true
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: { setLogin($0) }))
            if SMAppService.mainApp.status == .requiresApproval {
                HStack {
                    Text("Approve V2Mac in System Settings → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Toggle("Reconnect on launch", isOn: $reconnectOnLaunch)
            Toggle("Restart core after sleep or network change", isOn: $restartOnWake)
            Toggle("Check for app updates", isOn: $checkUpdates)
            AppUpdateRow()
            DiagnosticsSection()
        }
        .formStyle(.grouped)
        .onAppear { loginEnabled = SMAppService.mainApp.status == .enabled }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change the login item: \(error.localizedDescription)"
        }
        loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }
}
