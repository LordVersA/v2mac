import AppKit
import SwiftUI

struct SecretStorageSection: View {
    @Environment(AppModel.self) private var model
    private let secrets = SecretStore.shared

    var body: some View {
        Section {
            Toggle("Store secrets in Apple Keychain", isOn: Binding(get: { secrets.usesKeychain }, set: { setKeychain($0) }))
            if secrets.hasLegacyAdministratorPassword {
                Text("An older version saved an administrator password. V2Mac no longer reads or uses it. Remove the old Keychain entry; macOS may ask for permission.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Remove old administrator password from Keychain…") {
                    do { try secrets.removeLegacyAdministratorPassword() }
                    catch { /* SecretStore exposes the cleanup error. */ }
                }
            }
            if let error = secrets.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Try Again") {
                    do {
                        try secrets.retryRead()
                        model.warp.reloadSavedAccount()
                    } catch { /* SecretStore keeps the error visible. */ }
                }
            }
        } header: {
            Text("Secret storage")
        } footer: {
            Text("Off by default. The local proxy password and WARP credentials are encrypted in a file with a key stored on this Mac. Apps running as your user can decrypt it. Keychain adds macOS access controls and may ask for your login password, including after app updates. V2Mac never collects or stores your administrator password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setKeychain(_ enabled: Bool) {
        if enabled {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.icon = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
            alert.messageText = String(localized: "Use Apple Keychain?")
            alert.informativeText = String(localized: "V2Mac will move the local proxy password and WARP credentials to your login Keychain and recover older copies of those secrets. macOS may ask for your login password next, and may ask again after app updates. Enter it only in the macOS Keychain dialog. Cancel to keep using the encrypted local file.")
            alert.addButton(withTitle: String(localized: "Continue"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let previous = secrets.usesKeychain
        defer {
            if secrets.usesKeychain != previous {
                model.warp.reloadSavedAccount()
                model.connection.reconnectIfRunning()
            }
        }
        do {
            try secrets.setUsesKeychain(enabled)
        } catch { /* SecretStore exposes the error beside the switch. */ }
    }
}
