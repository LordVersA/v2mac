import SwiftUI
import V2MacCore

/// Settings → WARP (spec 9.10).
struct WarpSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("warpExit") private var warpExit = false
    @State private var license = ""

    private var warp: WarpService { model.warp }

    var body: some View {
        Form {
            if let account = warp.account {
                Section {
                    LabeledContent("Plan", value: plan(account))
                    if account.premiumData > 0 {
                        LabeledContent("WARP+ data", value: account.premiumData.formatted(.byteCount(style: .file)))
                    }
                    LabeledContent("Device ID") { Text(account.deviceID).textSelection(.enabled) }
                    if !account.license.isEmpty {
                        LabeledContent("License key") { Text(account.license).textSelection(.enabled) }
                    }
                    HStack {
                        Button("Refresh") { Task { await warp.refresh() } }
                        CopyButton("Copy License Key") { account.license }.disabled(account.license.isEmpty)
                        Spacer()
                        Button("Remove Device", role: .destructive) {
                            warpExit = false
                            Task { await warp.remove() }
                        }
                    }
                } header: {
                    Text("Cloudflare WARP")
                } footer: {
                    note("The license key joins another device to this account; keep it private.")
                }
                Section {
                    TextField("License key", text: $license, prompt: Text(verbatim: "xxxxxxxx-xxxxxxxx-xxxxxxxx"))
                    Button("Apply Key") { Task { await warp.setLicense(license); if warp.errorMessage == nil { license = "" } } }
                        .disabled(license.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("WARP+")
                } footer: {
                    note("Enter the license key of a WARP+ account to use its plan on this device.")
                }
                Section {
                    Toggle("Send traffic out through WARP", isOn: $warpExit)
                    Button("Add WARP to Servers") {
                        Task { if let id = await warp.addToServers() { model.sidebarSelection = .group(id) } }
                    }
                } header: {
                    Text("Use")
                } footer: {
                    note("With WARP as the exit, traffic goes through your server and then WARP, so sites see a Cloudflare address. It does not apply to full Xray configs, and some servers block WARP. As a server of its own, WARP connects directly over MASQUE.")
                }
            } else {
                Section {
                    Button("Register a WARP Device") { Task { await warp.register() } }
                } header: {
                    Text("Cloudflare WARP")
                } footer: {
                    note("Registers a free WARP device with Cloudflare over MASQUE. By registering you accept [Cloudflare's terms](https://www.cloudflare.com/application/terms/). While connected, Cloudflare is asked through the proxy.")
                }
            }
            if warp.isBusy {
                HStack { ProgressView().controlSize(.small); Text("Asking Cloudflare…") }
            }
            if let message = warp.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            ResetSettingsSection(tab: .warp)
        }
        .formStyle(.grouped)
        .disabled(warp.isBusy)
        .onChange(of: warpExit) { model.connection.reconnectIfRunning() }
    }

    private func plan(_ account: WarpAccount) -> String {
        switch account.accountType.lowercased() {
        case "free", "": String(localized: "Free")
        case "limited": String(localized: "WARP+")
        case "unlimited": String(localized: "WARP+ Unlimited")
        case "team": String(localized: "Zero Trust")
        default: account.accountType
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
