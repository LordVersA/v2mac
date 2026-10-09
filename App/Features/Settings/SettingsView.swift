import ServiceManagement
import SwiftUI
import V2MacCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ProxySettings().tabItem { Label("Proxy", systemImage: "network") }
            RoutingSettings().tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
            SubscriptionSettings().tabItem { Label("Servers", systemImage: "tray.and.arrow.down") }
            CoreSettings().tabItem { Label("Core", systemImage: "cpu") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: General

private struct GeneralSettings: View {
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

/// Percent, size and speed of a running download.
struct DownloadProgressView: View {
    let title: String
    let progress: DownloadProgress?
    let rate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(title)
                Spacer()
                Text(detail).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        guard let progress else { return "Starting…" }
        var parts: [String] = []
        if let fraction = progress.fraction { parts.append("\(Int(fraction * 100))%") }
        if let total = progress.total {
            parts.append("\(Format.megabytes(progress.received)) of \(Format.megabytes(total))")
        } else {
            parts.append(Format.megabytes(progress.received))
        }
        if let rate { parts.append(Format.rate(rate)) }
        return parts.joined(separator: " · ")
    }
}

/// The running app-update download.
struct AppDownloadProgress: View {
    @Environment(AppModel.self) private var model
    let release: AppRelease

    var body: some View {
        DownloadProgressView(
            title: "Downloading V2Mac \(release.version)…",
            progress: model.updates.appProgress,
            rate: model.updates.appDownloadRate
        )
    }
}

private struct AppUpdateRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            switch model.updates.appStatus {
            case .available(let release):
                Label("V2Mac \(release.version) is available.", systemImage: "arrow.down.circle.fill")
                Link("Release Notes", destination: release.pageURL)
                Spacer()
                Button("Update Now") { Task { await model.updates.installApp(release) } }
                    .controlSize(.small)
            case .installing(let release):
                AppDownloadProgress(release: release)
            case .installFailed(let release, let message):
                Text("Update failed: \(message)").font(.caption).foregroundStyle(.secondary)
                Link("View Release", destination: release.pageURL)
                Spacer()
                Button("Try Again") { Task { await model.updates.installApp(release) } }
                    .controlSize(.small)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .upToDate:
                Label("V2Mac is up to date.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .unavailable(let message):
                Text(message).font(.caption).foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
            if model.updates.availableAppUpdate == nil {
                Spacer()
                Button("Check Now") { Task { await model.updates.checkApp(manual: true) } }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: Proxy

private struct ProxySettings: View {
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

// MARK: Routing

private struct RoutingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var connection = model.connection
        Form {
            Picker("Mode", selection: Binding(
                get: { model.connection.routingMode },
                set: { model.connection.setRoutingMode($0) }
            )) {
                ForEach(RoutingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Section("Bypass regions") {
                if model.regionPacks.packs.isEmpty {
                    Text("No region packs are bundled.").foregroundStyle(.secondary)
                }
                ForEach(model.regionPacks.packs) { pack in
                    SettingsPackRow(pack: pack)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsPackRow: View {
    @Environment(AppModel.self) private var model
    let pack: RegionPackDefinition

    @State private var interval: PackUpdateInterval

    init(pack: RegionPackDefinition) {
        self.pack = pack
        _interval = State(initialValue: Prefs.packUpdateInterval(pack.id))
    }

    private var service: RegionPackService { model.regionPacks }
    private var enabled: Bool { service.enabledIDs.contains(pack.id) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                status
            }
            Spacer()
            if service.status(pack) == .installing {
                ProgressView().controlSize(.small)
            } else {
                if enabled {
                    Picker("Auto-update", selection: $interval) {
                        ForEach(PackUpdateInterval.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: interval) { Prefs.setPackUpdateInterval(interval, for: pack.id) }
                    .help("How often this pack updates itself")
                    Button("Update Now") { Task { await service.updateNow(pack) } }
                        .controlSize(.small)
                }
                Toggle(pack.name, isOn: Binding(
                    get: { enabled },
                    set: { on in
                        if on { Task { await service.enable(pack) } } else { service.disable(pack) }
                    }
                ))
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch service.status(pack) {
        case .notInstalled: Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
        case .installing: Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        case .installed(let date):
            Text(date.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Installed")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}

// MARK: Subscriptions

private struct SubscriptionSettings: View {
    @AppStorage("autoUpdateSubscriptions") private var auto = true
    @AppStorage("subscriptionUpdateViaProxy") private var viaProxy = false
    @AppStorage("defaultIntervalHours") private var hours = 12
    @AppStorage("userAgent") private var userAgent = ""
    @AppStorage("latencyURL") private var url = "https://www.gstatic.com/generate_204"
    @AppStorage("latencyTimeout") private var timeout = 8.0
    @AppStorage("latencyConcurrency") private var concurrency = 8
    @AppStorage("speedTestURL") private var speedURL = Prefs.defaultSpeedURL

    var body: some View {
        Form {
            Section {
                Toggle("Auto-update subscriptions", isOn: $auto)
                Picker("Auto-update route", selection: $viaProxy) {
                    Text("Without proxy").tag(false)
                    Text("Via proxy").tag(true)
                }
                .disabled(!auto)
                Stepper("Default interval: \(hours) h", value: $hours, in: 1...168)
                    .disabled(!auto)
                TextField("User-Agent", text: $userAgent, prompt: Text("v2mac/\(Prefs.appVersion)"))
            } header: {
                Text("Subscriptions")
            } footer: {
                Text("The default interval is used when the provider doesn't send one.")
            }

            Section {
                TextField("Test URL", text: $url)
                Stepper("Timeout: \(Int(timeout)) s", value: $timeout, in: 2...30, step: 1)
                Stepper("Concurrency: \(concurrency)", value: $concurrency, in: 1...32)
                TextField("Speed test file", text: $speedURL)
            } header: {
                Text("Server testing")
            } footer: {
                Text("The speed test downloads a large file through each server. It stops as soon as the speed levels off, so the whole file is never fetched.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Core

private struct CoreSettings: View {
    @Environment(AppModel.self) private var model

    private var updates: UpdateService { model.updates }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: updates.coreVersion ?? "…")
                LabeledContent("Source", value: updates.coreIsUpdatedCopy ? "Updated copy" : "Bundled")
                statusRow
            } header: {
                Text("Xray-core")
            } footer: {
                Text("Updates are downloaded through the proxy when it is connected, verified against the published SHA-256, and self-tested before they replace the current core.")
            }
            HStack {
                Button("Check for Update") { Task { await updates.checkCore() } }
                    .disabled(updates.coreStatus == .checking || updates.coreStatus == .installing)
                if case .available(let release) = updates.coreStatus {
                    Button("Install \(release.version)") { Task { await updates.installCore(release) } }
                        .buttonStyle(.borderedProminent)
                }
                Button("Revert to Bundled") { Task { await updates.revertToBundled() } }
                    .disabled(!updates.coreIsUpdatedCopy || updates.coreStatus == .installing)
            }
        }
        .formStyle(.grouped)
        .task { await updates.refreshCoreInfo() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch updates.coreStatus {
        case .idle: EmptyView()
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("You have the latest core.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .available(let release):
            LabeledContent("Available", value: release.version + (release.publishedAt.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
        case .installing:
            DownloadProgressView(title: "Downloading core…", progress: updates.coreProgress, rate: updates.coreDownloadRate)
        case .installed(let version):
            Label("Installed \(version).", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        }
    }
}

// MARK: Advanced

private struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("logLevel") private var level = XrayLogLevel.warning.rawValue
    @AppStorage("logConnections") private var logConnections = false

    var body: some View {
        Section("Diagnostics") {
            Picker("Log level", selection: $level) {
                ForEach([XrayLogLevel.error, .warning, .info, .debug], id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            .onChange(of: level) { model.connection.reconnectIfRunning() }
            Toggle("Log connections", isOn: $logConnections)
                .onChange(of: logConnections) { model.connection.reconnectIfRunning() }
            Button("Show Logs") { model.openLogs(openWindow) }
        }
    }
}

// MARK: About

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("V2Mac").font(.title2.bold())
                    Text("Version \(Prefs.appVersion)").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                HStack(spacing: 4) {
                    Spacer()
                    Text("Made with")
                    Image(systemName: "heart.fill").foregroundStyle(.red).accessibilityLabel("love")
                    Text("by")
                    Link("LordVersa", destination: URL(string: "https://github.com/LordVersA")!)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Xray-core") {
                    Link("github.com/XTLS/Xray-core", destination: URL(string: "https://github.com/XTLS/Xray-core")!)
                }
            } footer: {
                Text("V2Mac is GPL-3.0 software. It bundles Xray-core (MPL-2.0) and v2fly/Loyalsoldier rule data; see THIRD_PARTY.md for licences and attributions.")
            }
        }
        .formStyle(.grouped)
    }
}
