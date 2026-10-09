import SwiftUI

struct ConnectionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Namespace private var glassNamespace

    private var connection: ConnectionController { model.connection }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            // Narrow detail columns drop the extras instead of forcing the window wider.
            ViewThatFits(in: .horizontal) {
                content(showRates: true, showAddress: true)
                content(showRates: false, showAddress: true)
                content(showRates: false, showAddress: false)
            }
            .glassEffect(barGlass, in: .capsule)
        }
        .animation(.smooth(duration: 0.35), value: connection.phase)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func content(showRates: Bool, showAddress: Bool) -> some View {
        HStack(spacing: 14) {
            connectButton
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                subtitle
            }
            Spacer(minLength: 12)
            if showRates, connection.phase == .connected {
                HStack(spacing: 10) {
                    Label(Format.rate(connection.downRate), systemImage: "arrow.down")
                    Label(Format.rate(connection.upRate), systemImage: "arrow.up")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            TunToggle(connection: connection)
            RoutingModeMenu(connection: connection, packs: model.regionPacks) { model.showRegionsSheet = true }
            if showAddress { addressMenu }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
    }

    // MARK: Pieces

    private var connectButton: some View {
        Button { connection.toggle() } label: {
            Image(systemName: "power")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(connection.phase == .off ? Color.primary : Color.white)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(stateColor).interactive(), in: .circle)
        .glassEffectID("connect", in: glassNamespace)
        .disabled(connection.activeServer == nil)
        .help(connection.phase == .connected ? "Disconnect" : "Connect")
        .accessibilityLabel(connection.phase == .connected ? "Disconnect" : "Connect")
    }

    private var title: String {
        connection.activeServer?.name ?? "No server selected"
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
            status("Connected · \(connection.routingMode.title)")
        case .off:
            status(connection.activeServer == nil ? "Double-click a server to connect" : "Off · \(connection.routingMode.title)")
        }
    }

    /// The status line, with what TUN mode is doing; a TUN failure gets its own line.
    @ViewBuilder
    private func status(_ text: String) -> some View {
        let note = connection.tun.statusNote
        Text(note.map { "\(text) · \($0)" } ?? text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
            Divider()
            copy("export http_proxy=http://127.0.0.1:\(port) https_proxy=http://127.0.0.1:\(port) all_proxy=socks5://127.0.0.1:\(port)", label: "Shell export lines")
        } label: {
            Label(connection.localAddress, systemImage: "doc.on.doc")
                .font(.caption.monospaced())
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
