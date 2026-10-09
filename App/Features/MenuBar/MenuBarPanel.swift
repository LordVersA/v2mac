import SwiftData
import SwiftUI

struct MenuBarIcon: View {
    let phase: ConnectionController.Phase

    var body: some View {
        switch phase {
        case .off, .connecting, .switching:
            Image("MenuBarGlyphOutline").accessibilityLabel("V2Mac, off")
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
                        Button { model.activate(profile) } label: {
                            HStack {
                                Image(systemName: "checkmark")
                                    .opacity(profile.id == connection.activeServer?.id ? 1 : 0)
                                    .frame(width: 14)
                                Text(profile.name).lineLimit(1)
                                Spacer()
                                DelayText(row: ServerRow(profile)).font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
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
                Link(destination: release.pageURL) {
                    Label("Update available: V2Mac \(release.version)", systemImage: "arrow.down.circle.fill")
                }
                .font(.callout)
            }

            Divider()
            HStack {
                Button("Open V2Mac") { model.openMainWindow(openWindow) }
                Button("Settings…") { model.openSettings(openSettings) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
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
            Toggle("", isOn: Binding(
                get: {
                    switch connection.phase {
                    case .connected, .connecting, .switching: true
                    default: false
                    }
                },
                set: { on in on ? connection.connectActive() : connection.disconnect() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Connect")
            .accessibilityValue(statusTitle)
            .disabled(connection.activeServer == nil)
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
