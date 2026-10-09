import SwiftUI
import V2MacCore

struct ProxySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("proxyPort") private var port = 10808
    @AppStorage("allowLAN") private var allowLAN = false
    @AppStorage("proxyUsername") private var username = ""
    @AppStorage("proxyPassword") private var password = ""
    @State private var portText = ""
    @State private var pending: Task<Void, Never>?

    private var lanAddress: String? { SystemInfo.lanAddress() }
    private var portValid: Bool { (1024...65535).contains(Int(portText) ?? 0) }

    var body: some View {
        Form {
            Section {
                TextField("Port", text: $portText)
                    .onSubmit(commitPort)
                    .frame(maxWidth: 200)
                if !portValid {
                    Text("Enter a port between 1024 and 65535.").font(.caption).foregroundStyle(.red)
                }
            }
            Section("Local network") {
                Toggle("Allow connections from LAN", isOn: $allowLAN)
                    .onChange(of: allowLAN) { restartSoon() }
                if allowLAN {
                    Text("Other devices can use \(lanAddress ?? "this Mac's address"):\(port)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                TextField("Username", text: $username)
                    .onChange(of: username) { restartSoon() }
                SecureField("Password", text: $password)
                    .onChange(of: password) { restartSoon() }
                if allowLAN && !(Prefs.inbound.hasCredentials) {
                    Label("Anyone on your network can use this proxy. Set a username and password.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(port) }
        .onDisappear { commitPort() }
    }

    private func commitPort() {
        guard portValid, let value = Int(portText), value != port else { return }
        port = value
        restartSoon()
    }

    /// Typing credentials fires many changes; restart once after they settle.
    private func restartSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            model.connection.reconnectIfRunning()
        }
    }
}
