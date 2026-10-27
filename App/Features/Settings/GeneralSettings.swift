import ServiceManagement
import SwiftUI

struct GeneralSettings: View {
    @AppStorage("reconnectOnLaunch") private var reconnectOnLaunch = true
    @AppStorage("restartOnWakeOrNetwork") private var restartOnWake = true
    @AppStorage("checkAppUpdates") private var checkUpdates = true
    @AppStorage("installAppUpdates") private var installUpdates = true
    @AppStorage("countTraffic") private var countTraffic = true
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            LanguagePicker()
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
            Toggle(isOn: $countTraffic) {
                Text("Count traffic usage")
                Text("Shows this session's traffic in the menu bar panel and the connection bar, and keeps a total.")
            }
            Toggle("Check for app updates", isOn: $checkUpdates)
            Toggle(isOn: $installUpdates) {
                Text("Install updates automatically")
                Text("Downloads a new version in the background and installs it when V2Mac quits.")
            }
            .disabled(!checkUpdates)
            AppUpdateRow()
            PrivilegedHelperSection()
            SecretStorageSection()
            BackupSection()
            DiagnosticsSection()
            ResetSettingsSection(tab: .general)
            ResetSettingsSection(tab: nil)
        }
        .formStyle(.grouped)
        .onAppear { loginEnabled = SMAppService.mainApp.status == .enabled }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = String(localized: "Could not change the login item: \(error.localizedDescription)")
        }
        loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }
}
