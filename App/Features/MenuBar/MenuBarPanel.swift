import SwiftData
import SwiftUI

struct MenuBarIcon: View {
    let connection: ConnectionController
    @AppStorage("menuBarCountry") private var showsCountry = true
    @AppStorage("menuBarSpeed") private var showsSpeed = false

    private var phase: ConnectionController.Phase { connection.phase }

    /// The exit country, shown as two letters over the icon while connected.
    private var countryCode: String? {
        guard showsCountry, case .known(let exit) = connection.exit else { return nil }
        return exit.countryCode
    }

    var body: some View {
        if phase == .connected, showsSpeed {
            Image(nsImage: MenuBarSpeed.image(code: countryCode, up: connection.upRate, down: connection.downRate))
                .accessibilityLabel("V2Mac, connected, \(Format.steadyRate(connection.downRate)) down, \(Format.steadyRate(connection.upRate)) up")
        } else if phase == .connected, let countryCode, let image = MenuBarBadge.image(code: countryCode) {
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

/// The connected icon (with its badge, when there is one) followed by the upload rate over the
/// download rate. One image again, drawn for the menu bar's appearance; the text column has a
/// fixed width, so the items beside it do not move as the numbers change.
@MainActor
enum MenuBarSpeed {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let textWidth = ceil(("↓ 999.9 MB/s" as NSString).size(withAttributes: [.font: font]).width)

    static func image(code: String?, up: Double, down: Double) -> NSImage {
        let icon = code.flatMap(MenuBarBadge.image(code:)) ?? NSImage(named: "MenuBarGlyphFilled") ?? NSImage()
        let iconSize = icon.isTemplate ? NSSize(width: icon.size.width * 16 / max(icon.size.height, 1), height: 16) : icon.size
        let lines = ["↑ " + Format.steadyRate(up), "↓ " + Format.steadyRate(down)]
        let size = NSSize(width: iconSize.width + 4 + textWidth, height: 22)
        return NSImage(size: size, flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            let color: NSColor = dark == .darkAqua || dark == .vibrantDark ? .white : .black
            let iconRect = NSRect(x: 0, y: (rect.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
            if icon.isTemplate {
                // A template glyph is black; tint it for the bar like the system would.
                NSImage(size: iconSize, flipped: false) { r in
                    icon.draw(in: r)
                    color.set()
                    r.fill(using: .sourceAtop)
                    return true
                }.draw(in: iconRect)
            } else {
                icon.draw(in: iconRect)
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            for (index, line) in lines.enumerated() {
                let text = line as NSString
                let width = text.size(withAttributes: attributes).width
                text.draw(at: NSPoint(x: rect.width - width, y: index == 0 ? 11 : 1), withAttributes: attributes)
            }
            return true
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
        return [active] + peers.prefix(isCompact ? 2 : 5)
    }

    /// The last three other servers a connection came up on, newest first, from any group.
    private func recentServers(active: Profile?) -> [Profile] {
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return connection.recentServerIDs
            .compactMap { byID[$0] }
            .filter { $0.id != active?.id && !$0.isStale }
            .prefix(isCompact ? 2 : 3)
            .map { $0 }
    }

    /// The room below the menu bar on the screen the panel opened on.
    @State private var availableHeight = MenuBarPanel.screenHeight()
    /// On a small display the lists are shorter, so the panel rarely has to scroll.
    private var isCompact: Bool { availableHeight < 860 }

    private static func screenHeight() -> CGFloat {
        #if DEBUG
        // `-debugPanelHeight <points>`: the panel as on a display with that much room.
        let forced = UserDefaults.standard.double(forKey: "debugPanelHeight")
        if forced > 0 { return forced }
        #endif
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        return (screen?.visibleFrame.height ?? 900) - 12
    }

    /// Measured, because a scroll view has no height of its own for the panel's window to take.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // As tall as its content where that fits the screen; on a smaller display it scrolls.
        ScrollView {
            panel.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // `.never`, not `.hidden`: a hidden scroller still keeps its strip, which pushes the cards sideways.
        .scrollIndicators(.never)
        .scrollDisabled(contentHeight <= availableHeight)
        .frame(width: 330, height: contentHeight > 0 ? min(contentHeight, availableHeight) : nil)
        .onAppear { availableHeight = Self.screenHeight() }
    }

    @ViewBuilder
    private var panel: some View {
        // Each scans every profile, so once per update is enough.
        let active = activeProfile
        let recent = recentServers(active: active)
        // A server is listed once: under "Recent" when it is there.
        let candidates = switchCandidates(active: active).filter { candidate in !recent.contains { $0.id == candidate.id } }
        VStack(alignment: .leading, spacing: 10) {
            header(active: active)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

            if connection.killSwitch.isBlocking, connection.phase == .off {
                PanelCard { KillSwitchNotice(connection: connection) }
            }

            if connection.phase == .connected {
                PanelCard {
                    exitRow
                    PanelRates(connection: connection)
                }
            }

            if let group = active?.group, PanelSubscription.hasContent(group) {
                PanelCard { PanelSubscription(group: group) }
            }

            if !recent.isEmpty || !candidates.isEmpty {
                PanelCard {
                    if !recent.isEmpty {
                        PanelSectionTitle(String(localized: "Recent"))
                        rows(recent, showsGroup: true)
                    }
                    if !recent.isEmpty, !candidates.isEmpty { Divider() }
                    if !candidates.isEmpty {
                        HStack(spacing: 5) {
                            if let group = active?.group { GroupDot(color: group.tint) }
                            PanelSectionTitle(active?.group?.displayName ?? String(localized: "Switch Server"))
                            Spacer()
                            PanelTestButton(latency: model.latency) { testGroup(of: active) }
                        }
                        rows(candidates, showsGroup: false)
                    }
                }
            }

            PanelCard {
                HStack {
                    Text("Routing")
                    Spacer()
                    RoutingModeMenu(connection: connection, packs: model.regionPacks) {
                        model.showRegionsSheet = true
                        model.openMainWindow(openWindow)
                    }
                }
                Divider()
                HStack {
                    Text("TUN Mode")
                    if let note = connection.tun.statusNote, !connection.tun.isOn {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    TunToggle(connection: connection, showsLabel: false)
                }
                if let failure = connection.tun.failureMessage {
                    Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
                Divider()
                HStack {
                    Text("System Proxy")
                    Spacer()
                    SystemProxyToggle(connection: connection, showsLabel: false)
                }
                if let failure = connection.systemProxy.failure {
                    Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
                Divider()
                HStack {
                    Text("Local Proxy")
                    Spacer()
                    Text(connection.localAddress).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    CopyButton("Copy local proxy address") { connection.localAddress }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Copy address")
                }
            }
            .font(.callout)

            if let release = model.updates.availableAppUpdate {
                PanelCard {
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
            }

            HStack {
                Button("Open V2Mac", systemImage: "macwindow") { model.openMainWindow(openWindow) }
                Spacer()
                if model.sandbox.pin != nil {
                    Button("Sandbox", systemImage: "shield.lefthalf.filled") {
                        // The entry sheet belongs to the main window.
                        if model.sandbox.phase != .installed { model.openMainWindow(openWindow) }
                        model.sandbox.open()
                    }
                    .labelStyle(.iconOnly)
                    .help("Open the Secure Sandbox")
                }
                Button("Settings", systemImage: "gearshape") { model.openSettings(openSettings) }
                    .labelStyle(.iconOnly)
                    .help("Settings")
                Button("Quit", systemImage: "power.circle") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
                    .help("Quit V2Mac")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 330)
        .animation(.smooth(duration: 0.35), value: connection.phase)
    }

    /// Where traffic comes out, once the exit check has answered.
    @ViewBuilder
    private var exitRow: some View {
        switch connection.exit {
        case .known(let exit):
            HStack(spacing: 8) {
                if let flag = exit.flag { Text(flag).font(.title3) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(exit.place() ?? String(localized: "Unknown place")).font(.callout)
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
    }

    private func rows(_ servers: [Profile], showsGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(servers) { profile in
                SwitchRow(profile: profile, isActive: profile.id == connection.activeServer?.id,
                          group: showsGroup ? profile.group : nil) {
                    model.activate(profile)
                }
            }
        }
        // The hover highlight reaches the card's edge, as in a system menu.
        .padding(.horizontal, -6)
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
        case .off: String(localized: "Off")
        case .connecting: String(localized: "Connecting…")
        case .switching: String(localized: "Switching…")
        case .connected: connection.connectedTitle
        case .failed: String(localized: "Connection failed")
        }
    }

    private func serverDetail(_ server: ActiveServer, profile: Profile?) -> String {
        var parts: [String] = []
        if let group = profile?.group { parts.append(group.displayName) } else if !server.groupName.isEmpty { parts.append(server.groupName) }
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
        // The whole orb is the button, ring included: a click anywhere on it counts.
        Button(action: action) {
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
                Image(systemName: "power")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(phase == .off ? Color.primary : Color.white)
                    .symbolEffect(.bounce, value: isOn)
                    .frame(width: 44, height: 44)
                    // Not interactive glass: it takes the click for itself, and the button misses some.
                    .glassEffect(.regular.tint(color), in: .circle)
            }
            .frame(width: 58, height: 58)
            .contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!isEnabled)
        // Dimmed with no server to connect to, so it reads as unavailable.
        .opacity(isEnabled ? 1 : 0.4)
        .help(isEnabled ? "" : "Select a server first")
        .accessibilityLabel(phase == .off ? "Connect" : "Disconnect")
        .accessibilityValue(statusTitle)
        .animation(.smooth(duration: 0.6), value: phase)
    }

    private var ringStyle: AnyShapeStyle {
        guard let color else { return AnyShapeStyle(.clear) }
        return AnyShapeStyle(color.gradient)
    }
}

/// Presses in a little, in place of the system button look.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
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

    private func link(_ title: LocalizedStringKey, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
                .labelStyle(CompactLabelStyle())
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
                .contentShape(.capsule)
        }
        .accessibilityLabel(title)
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
    @AppStorage("countTraffic") private var countTraffic = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TrafficSparkline(samples: connection.rateHistory)
                .frame(height: 34)
            HStack(spacing: 14) {
                Label(Format.rate(connection.downRate), systemImage: "arrow.down")
                Label(Format.rate(connection.upRate), systemImage: "arrow.up")
                if countTraffic {
                    Spacer()
                    SessionUsageButton(connection: connection)
                }
            }
            .font(.caption.monospacedDigit())
            // No rolling digits: they change every second, and the transition blurs text on the CPU.
            .foregroundStyle(.secondary)
        }
    }
}

/// A translucent rounded group, as the modules of Control Centre: related rows share one.
private struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }
}

private struct PanelSectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.caption).bold().foregroundStyle(.secondary).lineLimit(1)
    }
}

/// One server in the quick-switch lists, with its flag and a hover highlight. A row that can come
/// from any subscription names it on a second line.
private struct SwitchRow: View {
    let profile: Profile
    let isActive: Bool
    var group: ServerGroup?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let name = ServerName(profile.name)
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name.flag ?? "🌐")
                VStack(alignment: .leading, spacing: 0) {
                    Text(name.title).lineLimit(1)
                    if let group {
                        HStack(spacing: 4) {
                            GroupDot(color: group.tint)
                            Text(group.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 6)
                DelayText(row: ServerRow(profile)).font(.caption)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Active")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
