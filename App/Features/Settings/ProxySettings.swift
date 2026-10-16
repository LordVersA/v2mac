import SwiftUI
import V2MacCore

struct ProxySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("proxyPort") private var port = Prefs.defaultPort
    @AppStorage("allowLAN") private var allowLAN = false
    @AppStorage("proxyUsername") private var username = ""
    @State private var password = Prefs.proxyPassword
    @State private var passwordError: String?
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
            Section {
                HStack {
                    Toggle("Set as system proxy", isOn: Binding(
                        get: { model.connection.systemProxy.isEnabled },
                        set: { on in model.connection.setSystemProxyEnabled(on) }
                    ))
                    Spacer()
                    SystemProxyBadge(connection: model.connection)
                    Text(systemProxyStatus).font(.caption).foregroundStyle(.secondary)
                }
                if let failure = model.connection.systemProxy.failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("System proxy")
            } footer: {
                note("While V2Mac is connected, the web, secure web and SOCKS proxies of every network service point at 127.0.0.1:\(String(port)), and they are turned off again when you disconnect or quit. Apps that follow the system settings, such as Safari, then use the connection. Changing them needs administrator access once each time V2Mac opens.")
            }
            Section {
                TextField("Username", text: $username)
                    .onChange(of: username) { restartSoon() }
                SecureField("Password", text: $password)
                    .onChange(of: password) {
                        do {
                            try Prefs.setProxyPassword(password)
                            passwordError = nil
                            restartSoon()
                        } catch { passwordError = error.localizedDescription }
                    }
                if let passwordError { Text(passwordError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Authentication")
            } footer: {
                note("Optional. When both are set, every app and device must send them to use the proxy; browsers ask for them once. Choose how secrets are stored in General settings.")
            }
            Section("Local network") {
                Toggle("Allow connections from LAN", isOn: $allowLAN)
                    .onChange(of: allowLAN) { restartSoon() }
                if allowLAN {
                    Text("Other devices can use \(lanAddress ?? String(localized: "this Mac's address")):\(String(port))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if allowLAN && !(Prefs.inbound.hasCredentials) {
                    Label("Anyone on your network can use this proxy. Set a username and password.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: allowLAN)
        .animation(.default, value: portValid)
        .animation(.default, value: username.isEmpty || password.isEmpty)
        .onAppear {
            portText = String(port)
            password = Prefs.proxyPassword
        }
        .onChange(of: SecretStore.shared.usesKeychain) { password = Prefs.proxyPassword }
        .onDisappear { commitPort() }
    }

    private var systemProxyStatus: LocalizedStringKey {
        switch model.connection.systemProxy.status {
        case .ours: "Set to V2Mac"
        case .other: "Set to something else"
        case .none: "Not set"
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
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
