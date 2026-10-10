import SwiftUI

struct ConnectionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Namespace private var glassNamespace
    @State private var copied = false

    private var connection: ConnectionController { model.connection }

    var body: some View {
        let tier = tier
        GlassEffectContainer(spacing: 14) {
            content(rates: tier.rates, showAddress: tier.showsAddress)
                // The bar must not ask for the width of the layout it is showing: the split
                // view would then widen the column, a larger layout would fit and ask for
                // more, and the window's layout would never settle (it crashed in narrow windows).
                .frame(minWidth: 0, maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widthChanged(to: $0) }
                .background { rulers }
                .glassEffect(barGlass, in: .capsule)
        }
        .animation(.smooth(duration: 0.35), value: connection.phase)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: Fitting the width

    fileprivate enum RateLayout { case inline, stacked }

    /// What the bar shows, widest first. Narrow detail columns drop the extras instead of
    /// forcing the window wider: the rates stack to save room, then the address gives way,
    /// and the rates go last.
    private enum Tier: CaseIterable {
        case full, stackedRates, stackedRatesNoAddress, addressOnly, minimal

        var rates: RateLayout? {
            switch self {
            case .full: .inline
            case .stackedRates, .stackedRatesNoAddress: .stacked
            case .addressOnly, .minimal: nil
            }
        }

        var showsAddress: Bool {
            switch self {
            case .full, .stackedRates, .addressOnly: true
            case .stackedRatesNoAddress, .minimal: false
            }
        }
    }

    private static let spacing: CGFloat = 14
    private static let buttonWidth: CGFloat = 38
    private static let leadingPadding: CGFloat = 8
    private static let trailingPadding: CGFloat = 16
    private static let minimumGap: CGFloat = 12

    // Measured once and when they change. The bar is laid out a single time and its tier is
    // worked out from these numbers; it used to lay out five complete copies of itself on
    // every pass to see which one fitted, which made resizing the window slow.
    @State private var barWidth: CGFloat = 0
    @State private var pendingWidth: Task<Void, Never>?
    @State private var titleWidth: CGFloat = 120
    @State private var inlineRatesWidth: CGFloat = 150
    @State private var stackedRatesWidth: CGFloat = 72
    @State private var tunWidth: CGFloat = 66
    @State private var routingWidth: CGFloat = 70
    @State private var addressWidth: CGFloat = 132

    /// While a window is being resized the split view lays the column out at its minimum
    /// width for a moment on every step. Following that would tear down and rebuild the
    /// graph, rates and address each time, so a width too small for even the smallest tier
    /// only counts once it has lasted.
    private func widthChanged(to width: CGFloat) {
        pendingWidth?.cancel()
        guard width < self.width(of: .minimal), barWidth >= self.width(of: .minimal) else {
            barWidth = width
            return
        }
        pendingWidth = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { barWidth = width }
        }
    }

    private var tier: Tier {
        Tier.allCases.first { width(of: $0) <= barWidth } ?? .minimal
    }

    private func width(of tier: Tier) -> CGFloat {
        let gap = Self.spacing
        var width = Self.leadingPadding + Self.buttonWidth + gap + titleWidth + gap + Self.minimumGap + gap + tunWidth + Self.trailingPadding
        if !connection.activeIsCustom { width += gap + routingWidth }
        if let rates = tier.rates, connection.phase == .connected {
            width += gap + sparklineWidth(rates) + gap + (rates == .inline ? inlineRatesWidth : stackedRatesWidth)
        }
        if tier.showsAddress { width += gap + addressWidth }
        return width
    }

    private func sparklineWidth(_ rates: RateLayout) -> CGFloat { rates == .inline ? 70 : 48 }

    /// Invisible copies of the pieces whose natural width is not known in advance.
    private var rulers: some View {
        ZStack {
            titleBlock.fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
            // Their width does not depend on the rates (see `RateLabels`), so zero will do.
            RateLabels(down: 0, up: 0, layout: .inline).font(.caption.monospacedDigit()).fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { inlineRatesWidth = $0 }
            RateLabels(down: 0, up: 0, layout: .stacked).font(.caption.monospacedDigit()).fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stackedRatesWidth = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).lineLimit(1)
            subtitle
        }
    }

    private func content(rates: RateLayout?, showAddress: Bool) -> some View {
        HStack(spacing: Self.spacing) {
            connectButton
            titleBlock
            Spacer(minLength: Self.minimumGap)
            if let rates, connection.phase == .connected {
                RateReadout(connection: connection, layout: rates, sparklineWidth: sparklineWidth(rates), spacing: Self.spacing)
            }
            TunToggle(connection: connection)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tunWidth = $0 }
            // A custom config has no mode to pick; the status line says so instead.
            if !connection.activeIsCustom {
                RoutingModeMenu(connection: connection, packs: model.regionPacks) { model.showRegionsSheet = true }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { routingWidth = $0 }
            }
            if showAddress {
                addressMenu
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { addressWidth = $0 }
            }
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, Self.trailingPadding)
        .padding(.vertical, 8)
    }

    // MARK: Pieces

    private var connectButton: some View {
        Button { connection.toggle() } label: {
            Image(systemName: "power")
                .font(.title3.weight(.semibold))
                .foregroundStyle(connection.phase == .off ? Color.primary : Color.white)
                .symbolEffect(.pulse, isActive: isBusy)
                .symbolEffect(.bounce, value: connection.phase == .connected)
                .frame(width: Self.buttonWidth, height: Self.buttonWidth)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(stateColor).interactive(), in: .circle)
        .glassEffectID("connect", in: glassNamespace)
        .disabled(connection.activeServer == nil)
        .help(connection.phase == .connected ? "Disconnect" : "Connect")
        .accessibilityLabel(connection.phase == .connected ? "Disconnect" : "Connect")
    }

    private var isBusy: Bool {
        switch connection.phase {
        case .connecting, .switching: true
        default: false
        }
    }

    private var title: String {
        connection.activeServer?.name ?? "No server selected"
    }

    private var routingTitle: String {
        connection.activeIsCustom ? "Custom routing" : connection.routingMode.title
    }

    @ViewBuilder
    private var subtitle: some View {
        switch connection.phase {
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                FailureActions(connection: connection) { model.openLogs(openWindow) }
            }
        case .connecting:
            status("Connecting…")
        case .switching:
            status("Switching…")
        case .connected:
            switch connection.exit {
            case .known(let exit):
                // The green button and the routing menu already say "connected" and the mode.
                status([exit.flag, exit.place(), exit.ip].compactMap { $0 }.joined(separator: "  "))
                    .help("Where your traffic comes out: \(exit.place() ?? "unknown place"), \(exit.ip)")
            case .failed:
                status("Connected · \(routingTitle)")
                Text("No answer through this server").font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help("The core is running, but a test request through the server got no answer.")
            case .checking, .unknown:
                status("Connected · \(routingTitle)")
            }
        case .off:
            status(connection.activeServer == nil ? "Double-click a server to connect" : "Off · \(routingTitle)")
        }
    }

    /// The status line, with what TUN mode is doing; a TUN failure gets its own line.
    @ViewBuilder
    private func status(_ text: String) -> some View {
        let note = connection.tun.statusNote
        Text(note.map { "\(text) · \($0)" } ?? text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .help(connection.activeIsCustom ? "Routing is managed by this config" : "")
        if let failure = connection.tun.failureMessage {
            Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private var addressMenu: some View {
        let port = connection.port
        return Menu {
            copy("127.0.0.1:\(port)")
            copy("socks5://127.0.0.1:\(port)")
            copy("http://127.0.0.1:\(port)")
            if case .known(let exit) = connection.exit {
                Divider()
                copy(exit.ip, label: "Exit address \(exit.ip)")
            }
            Divider()
            copy("export http_proxy=http://127.0.0.1:\(port) https_proxy=http://127.0.0.1:\(port) all_proxy=socks5://127.0.0.1:\(port)", label: "Shell export lines")
        } label: {
            Label(connection.localAddress, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.monospaced())
                .contentTransition(.symbolEffect(.replace))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Copy the local proxy address")
        .accessibilityLabel("Copy local proxy address")
    }

    private func copy(_ text: String, label: String? = nil) -> some View {
        Button(label ?? text) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        }
    }

    // MARK: State styling

    private var stateColor: Color? {
        switch connection.phase {
        case .connected: .green
        case .connecting, .switching: .orange
        case .failed: .red
        case .off: nil
        }
    }

    private var barGlass: Glass {
        if case .failed = connection.phase { return .regular.tint(.red.opacity(0.22)) }
        return .regular
    }
}

/// The graph and the live rates. On their own so that the once-a-second updates do not
/// re-evaluate the whole bar.
private struct RateReadout: View {
    let connection: ConnectionController
    let layout: ConnectionBar.RateLayout
    let sparklineWidth: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            TrafficSparkline(samples: connection.rateHistory)
                .frame(width: sparklineWidth, height: 26)
            RateLabels(down: connection.downRate, up: connection.upRate, layout: layout)
                .font(.caption.monospacedDigit())
                .contentTransition(.numericText())
                .animation(.smooth, value: connection.downRate)
                .animation(.smooth, value: connection.upRate)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

private struct RateLabels: View {
    let down: Double
    let up: Double
    let layout: ConnectionBar.RateLayout

    var body: some View {
        let down = label(down, systemImage: "arrow.down")
        let up = label(up, systemImage: "arrow.up")
        switch layout {
        case .inline: HStack(spacing: 10) { down; up }
        case .stacked: VStack(alignment: .leading, spacing: 1) { down; up }
        }
    }

    /// Reserves the width of the widest rate, so the graph and its neighbours hold still
    /// while the numbers change.
    private func label(_ rate: Double, systemImage: String) -> some View {
        Label("1,023 KB/s", systemImage: systemImage)
            .hidden()
            .overlay(alignment: .leading) { Label(Format.rate(rate), systemImage: systemImage) }
    }
}
