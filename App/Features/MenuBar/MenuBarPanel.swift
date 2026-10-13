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
            header(active: active)
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

            if let group = active?.group, PanelSubscription.hasContent(group) {
                Divider()
                PanelSubscription(group: group)
            }

            if !candidates.isEmpty {
                Divider()
                HStack {
                    Text("Switch Server").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    PanelTestButton(latency: model.latency) { testGroup(of: active) }
                }
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

    private func header(active: Profile?) -> some View {
        HStack(spacing: 12) {
            PowerOrb(phase: connection.phase, isEnabled: connection.activeServer != nil, statusTitle: statusTitle) {
                connection.toggle()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                if case .failed(let message) = connection.phase {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                    FailureActions(connection: connection) { model.openLogs(openWindow) }
                } else if let server = connection.activeServer {
                    Text(server.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(serverDetail(server, profile: active)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No server selected").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Real delay for every server of the active server's group; the list then shows the fastest.
    private func testGroup(of active: Profile?) {
        guard let active else { return }
        let ids = profiles.filter { $0.group?.id == active.group?.id && !$0.isStale }.map(\.id)
        model.testReal(ids)
    }

    private var statusTitle: String {
        switch connection.phase {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .switching: "Switching…"
        case .connected: connection.connectedTitle
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

/// The connect control: a tinted glass button inside a ring. The ring is faint while off, a
/// turning arc while the core starts or switches, and closes into a glowing circle once connected.
private struct PowerOrb: View {
    let phase: ConnectionController.Phase
    let isEnabled: Bool
    let statusTitle: String
    let action: () -> Void

    private var isOn: Bool { phase == .connected }

    private var isBusy: Bool {
        switch phase {
        case .connecting, .switching: true
        default: false
        }
    }

    private var color: Color? {
        switch phase {
        case .connected: .green
        case .connecting, .switching: .orange
        case .failed: .red
        case .off: nil
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color ?? .clear)
                .frame(width: 44, height: 44)
                .blur(radius: 12)
                .phaseAnimator([0.3, 0.65]) { glow, opacity in
                    glow.opacity(isOn ? opacity : 0)
                } animation: { _ in .easeInOut(duration: 1.8) }
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: phase == .off || isBusy ? 0 : 1)
                .stroke(ringStyle, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isBusy {
                TimelineView(.animation) { timeline in
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(ringStyle, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(timeline.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.1) / 1.1 * 360))
                }
                .transition(.opacity)
            }
            Button(action: action) {
                Image(systemName: "power")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(phase == .off ? Color.primary : Color.white)
                    .symbolEffect(.bounce, value: isOn)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(color).interactive(), in: .circle)
            .disabled(!isEnabled)
            .accessibilityLabel(phase == .off ? "Connect" : "Disconnect")
            .accessibilityValue(statusTitle)
        }
        .frame(width: 58, height: 58)
        .animation(.smooth(duration: 0.6), value: phase)
    }

    private var ringStyle: AnyShapeStyle {
        guard let color else { return AnyShapeStyle(.clear) }
        return AnyShapeStyle(color.gradient)
    }
}

/// Usage, expiry and the provider's links of the active server's subscription.
private struct PanelSubscription: View {
    let group: ServerGroup

    static func hasContent(_ group: ServerGroup) -> Bool {
        group.usedBytes != nil || group.expiresAt != nil || group.supportURL != nil || group.webPageURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Subscription").foregroundStyle(.secondary)
                Spacer()
                if let expires = group.expiresAt { expiry(expires) }
            }
            .font(.caption)
            if let used = group.usedBytes {
                let total = group.totalBytes ?? 0
                let fraction = total > 0 ? min(Double(used) / Double(total), 1) : 0
                if total > 0 {
                    Gauge(value: fraction) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(fraction >= 0.9 ? .red : (fraction >= 0.75 ? .orange : .accentColor))
                }
                HStack {
                    Text(total > 0 ? "\(Format.bytes(used)) of \(Format.bytes(total))" : "\(Format.bytes(used)) used")
                    Spacer()
                    if total > 0 { Text("\(Format.bytes(max(total - used, 0))) left").foregroundStyle(.secondary) }
                }
                .font(.caption.monospacedDigit())
                .accessibilityElement(children: .combine)
            }
            if group.supportURL != nil || group.webPageURL != nil {
                HStack(spacing: 8) {
                    if let url = group.supportURL.flatMap(URL.init(string:)) {
                        link("Support", systemImage: "bubble.left", url: url)
                    }
                    if let url = group.webPageURL.flatMap(URL.init(string:)) {
                        link("Account", systemImage: "person.crop.circle", url: url)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func expiry(_ date: Date) -> some View {
        let state = Format.expiry(date, long: false)
        return Label(state.text, systemImage: state.isWarning ? "exclamationmark.circle" : "calendar")
            .labelStyle(CompactLabelStyle())
            .foregroundStyle(state.isExpired ? Color.red : (state.isWarning ? Color.orange : Color.secondary))
            .help("Expires \(date.formatted(date: .long, time: .omitted))")
    }

    private func link(_ title: String, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
                .labelStyle(CompactLabelStyle())
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
                .contentShape(.capsule)
        }
        .accessibilityLabel("Open \(title.lowercased()) page")
    }
}

/// Starts a real delay test of the active group, and shows its progress with a way to stop it.
private struct PanelTestButton: View {
    let latency: LatencyService
    let start: () -> Void

    var body: some View {
        if latency.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("\(latency.completed)/\(latency.total)").monospacedDigit().foregroundStyle(.secondary)
                Button("Stop") { latency.cancel() }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        } else {
            Button("Test", systemImage: "speedometer", action: start)
                .font(.caption)
                .buttonStyle(.borderless)
                .help("Test the delay of every server in this group")
        }
    }
}

/// The graph and the live rates. On their own so that the once-a-second updates do not
/// re-evaluate the whole panel.
private struct PanelRates: View {
    let connection: ConnectionController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TrafficSparkline(samples: connection.rateHistory)
                .frame(height: 34)
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
