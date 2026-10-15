import SwiftUI
import V2MacCore

/// Saves an administrator account in the keychain, so the root helper (TUN mode, the system
/// proxy, the kill switch) starts without the system's prompt. The password is tried before it
/// is kept.
struct AdminAccessSection: View {
    @State private var saved = Prefs.adminAccount?.user
    @State private var user = NSUserName()
    @State private var password = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        Section {
            if let saved {
                LabeledContent("Administrator password") {
                    HStack {
                        Text("Saved for \(saved)").foregroundStyle(.secondary)
                        Button("Forget") {
                            Prefs.setAdminAccount(nil)
                            self.saved = nil
                        }
                    }
                }
            } else {
                TextField("Account name", text: $user)
                SecureField("Administrator password", text: $password)
                    .onSubmit(save)
                HStack {
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    if checking { ProgressView().controlSize(.small) }
                    Button("Save", action: save)
                        .disabled(user.isEmpty || password.isEmpty || checking)
                }
            }
        } header: {
            Text("Administrator access")
        } footer: {
            Text("TUN mode, the system proxy and the kill switch need administrator access once each time V2Mac opens. With the password saved here, V2Mac uses it instead of asking. It is kept encrypted in your keychain; anyone who can use your Mac account can then let V2Mac act as administrator.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard !user.isEmpty, !password.isEmpty, !checking else { return }
        checking = true
        error = nil
        let account = (user: user, password: password)
        Task {
            let result = await TunController.osascript(
                TunHelper.appleScript(command: "/usr/bin/true", prompt: "", user: account.user, password: account.password)
            )
            checking = false
            switch result {
            case .started:
                Prefs.setAdminAccount(account)
                password = ""
                saved = account.user
            case .failed(let message) where message.contains("-60007"):
                error = String(localized: "The account name or password is not right.")
            case .failed(let message):
                error = message
            case .cancelled:
                break
            }
        }
    }
}
