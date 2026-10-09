import SwiftData
import SwiftUI

struct MenuBarIcon: View {
    let phase: ConnectionController.Phase

    var body: some View {
        switch phase {
        case .off:
            Image("MenuBarGlyphOutline").accessibilityLabel("V2Mac, off")
        case .connecting, .switching:
            Image("MenuBarGlyphOutline")
                .phaseAnimator([0.35, 1.0]) { image, opacity in image.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.7) }
                .accessibilityLabel("V2Mac, connecting")
        case .connected:
            Image("MenuBarGlyphFilled").accessibilityLabel("V2Mac, connected")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("V2Mac, connection failed")
        }
    }
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query private var profiles: [Profile]

    private var connection: ConnectionController { model.connection }

    private var activeProfile: Profile? {
        connection.activeServer.flatMap { server in profiles.first { $0.id == server.id } }
    }

    /// The active server, then the fastest tested servers of its group (up to six rows).
    private var switchCandidates: [Profile] {
        guard let active = activeProfile else { return [] }
        let peers = profiles
            .filter { $0.group?.id == active.group?.id && $0.id != active.id && !$0.isStale }
            .sorted { lhs, rhs in
                let l = lhs.delayState == .ok ? (lhs.delayMs ?? .max) : .max
                let r = rhs.delayState == .ok ? (rhs.delayMs ?? .max) : .max
                return l != r ? l < r : lhs.sortIndex < rhs.sortIndex
            }
        return [active] + peers.prefix(5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let server = connection.activeServer {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(serverDetail(server)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if connection.phase == .connected {
                HStack(spacing: 14) {
                    Label(Format.rate(connection.downRate), systemImage: "arrow.down")
                    Label(Format.rate(connection.upRate), systemImage: "arrow.up")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if !switchCandidates.isEmpty {
                Divider()
                Text("Switch Server").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(switchCandidates) { profile in
                        SwitchRow(profile: profile, isActive: profile.id == connection.activeServer?.id) {
                            model.activate(profile)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("Routing").foregroundStyle(.secondary)
                Spacer()
                RoutingModeMenu(connection: connection, packs: model.regionPacks) {
                    model.showRegionsSheet = true
                    model.openMainWindow(openWindow)
                }
            }
            .font(.callout)

            HStack {
                Text("TUN Mode").foregroundStyle(.secondary)
                if let note = connection.tun.statusNote, !connection.tun.isOn {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TunToggle(connection: connection, showsLabel: false)
            }
            .font(.callout)
            if let failure = connection.tun.failureMessage {
                Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }

            HStack {
                Text(connection.localAddress).font(.callout.monospaced())
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connection.localAddress, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy address")
                .accessibilityLabel("Copy local proxy address")
            }

            if let release = model.updates.availableAppUpdate {
                Divider()
                HStack {
                    if model.updates.isInstallingApp {
                        AppDownloadProgress(release: release)
                    } else {
                        Label("V2Mac \(release.version) is available", systemImage: "arrow.down.circle.fill")
                        Spacer()
                        Button("Update Now") { Task { await model.updates.installApp(release) } }
                            .controlSize(.small)
                    }
                }
                .font(.callout)
            }

            Divider()
            HStack {
                Button("Open V2Mac", systemImage: "macwindow") { model.openMainWindow(openWindow) }
                Button("Settings", systemImage: "gearshape") { model.openSettings(openSettings) }
                    .labelStyle(.iconOnly)
                Spacer()
                Button("Quit", systemImage: "power.circle") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                connection.phase == .off || isFailed ? connection.connectActive() : connection.disconnect()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(connection.phase == .off ? Color.primary : Color.white)
                    .symbolEffect(.pulse, isActive: isBusy)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(stateColor).interactive(), in: .circle)
            .disabled(connection.activeServer == nil)
            .accessibilityLabel(connection.phase == .off ? "Connect" : "Disconnect")
            .accessibilityValue(statusTitle)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                if case .failed(let message) = connection.phase {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                    FailureActions(connection: connection) { model.openLogs(openWindow) }
                } else if connection.activeServer == nil {
                    Text("No server selected").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var isFailed: Bool {
        if case .failed = connection.phase { return true }
        return false
    }

    private var isBusy: Bool {
        switch connection.phase {
        case .connecting, .switching: true
        default: false
        }
    }

    private var stateColor: Color? {
        switch connection.phase {
        case .connected: .green
        case .connecting, .switching: .orange
        case .failed: .red
        case .off: nil
        }
    }

    private var statusTitle: String {
        switch connection.phase {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .switching: "Switching…"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }

    private func serverDetail(_ server: ActiveServer) -> String {
        var parts: [String] = []
        if !server.groupName.isEmpty { parts.append(server.groupName) }
        if let p = activeProfile, p.delayState == .ok, let ms = p.delayMs { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }
}

/// One server in the quick-switch list, with its flag and a hover highlight.
private struct SwitchRow: View {
    let profile: Profile
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let name = ServerName(profile.name)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .opacity(isActive ? 1 : 0)
                    .frame(width: 14)
                if let flag = name.flag { Text(flag) }
                Text(name.title).lineLimit(1)
                Spacer()
                DelayText(row: ServerRow(profile)).font(.caption)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
