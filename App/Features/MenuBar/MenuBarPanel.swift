import SwiftData
import SwiftUI

struct MenuBarIcon: View {
    let phase: ConnectionController.Phase
    /// The exit country, shown as two letters beside the icon while connected.
    var countryCode: String?
    @AppStorage("menuBarCountry") private var showsCountry = true

    var body: some View {
        if phase == .connected, showsCountry, let countryCode, let image = MenuBarBadge.image(code: countryCode) {
            Image(nsImage: image).accessibilityLabel("V2Mac, connected, exit in \(countryCode)")
        } else {
            glyph
        }
    }

    @ViewBuilder
    private var glyph: some View {
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

/// The connected glyph with the exit country in a green capsule over its lower edge. It is drawn
/// into one image, since a menu bar label lays out nothing but a plain image and plain text. The
/// badge has a colour, so this cannot be a template image: the glyph is drawn in black and in
/// white, and the one that suits the menu bar is picked each time the image is drawn.
@MainActor
enum MenuBarBadge {
    private static var cache: [String: NSImage] = [:]
    private static let size = CGSize(width: 26, height: 22)
    private static let green = Color(red: 0.16, green: 0.74, blue: 0.33)

    static func image(code: String) -> NSImage? {
        if let cached = cache[code] { return cached }
        guard let onLight = render(code, glyph: .black), let onDark = render(code, glyph: .white) else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            (dark == .darkAqua || dark == .vibrantDark ? onDark : onLight).draw(in: rect)
            return true
        }
        cache[code] = image
        return image
    }

    private static func render(_ code: String, glyph: Color) -> NSImage? {
        let renderer = ImageRenderer(content:
            ZStack(alignment: .bottom) {
                Image("MenuBarGlyphFilled")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(glyph)
                    .frame(height: 15)
                    .frame(maxHeight: .infinity, alignment: .top)
                // A clear ring, so the badge reads as sitting on the glyph, not merged with it.
                Capsule()
                    .frame(width: 24, height: 12)
                    .blendMode(.destinationOut)
                Text(code)
                    .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 10)
                    .background(green, in: Capsule())
                    .padding(.bottom, 1)
            }
            .compositingGroup()
            .frame(width: size.width, height: size.height)
        )
        renderer.scale = 3
        return renderer.nsImage
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
    private func switchCandidates(active: Profile?) -> [Profile] {
        guard let active else { return [] }
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
        // Each scans every profile, so once per update is enough.
        let active = activeProfile
        let candidates = switchCandidates(active: active)
        VStack(alignment: .leading, spacing: 12) {
            header
            if let server = connection.activeServer {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(serverDetail(server, profile: active)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if connection.phase == .connected {
                switch connection.exit {
                case .known(let exit):
                    HStack(spacing: 6) {
                        if let flag = exit.flag { Text(flag) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(exit.place() ?? "Unknown place").font(.callout)
                            Text(exit.ip).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        CopyButton("Copy exit address") { exit.ip }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Copy exit address")
                    }
                case .failed:
                    Label("No answer through this server", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                case .checking:
                    Text("Checking where traffic comes out…").font(.caption).foregroundStyle(.secondary)
                case .unknown:
                    EmptyView()
                }
                PanelRates(connection: connection)
            }

            if !candidates.isEmpty {
                Divider()
                Text("Switch Server").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { profile in
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
                CopyButton("Copy local proxy address") { connection.localAddress }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy address")
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
        .animation(.smooth(duration: 0.35), value: connection.phase)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                connection.phase == .off || isFailed ? connection.connectActive() : connection.disconnect()
            } label: {
                Image(systemName: "power")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(connection.phase == .off ? Color.primary : Color.white)
                    .symbolEffect(.pulse, isActive: isBusy)
                    .symbolEffect(.bounce, value: connection.phase == .connected)
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

    private func serverDetail(_ server: ActiveServer, profile: Profile?) -> String {
        var parts: [String] = []
        if !server.groupName.isEmpty { parts.append(server.groupName) }
        if let p = profile, p.delayState == .ok, let ms = p.delayMs { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }
}

/// The live rates. On their own so that the once-a-second updates do not re-evaluate the whole panel.
private struct PanelRates: View {
    let connection: ConnectionController

    var body: some View {
        HStack(spacing: 14) {
            Label(Format.rate(connection.downRate), systemImage: "arrow.down")
            Label(Format.rate(connection.upRate), systemImage: "arrow.up")
        }
        .font(.caption.monospacedDigit())
        .contentTransition(.numericText())
        .animation(.smooth, value: connection.downRate)
        .animation(.smooth, value: connection.upRate)
        .foregroundStyle(.secondary)
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
                    .animation(.smooth(duration: 0.3), value: isActive)
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
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
