import SwiftUI
import V2MacCore

/// Mode picker shared by the connection bar and the menu bar panel.
///
/// Takes its objects explicitly: it is placed inside `glassEffect` content, which does not
/// receive custom environment objects.
struct RoutingModeMenu: View {
    let connection: ConnectionController
    let packs: RegionPackService
    var onManageRegions: () -> Void = {}

    var body: some View {
        Menu {
            ForEach(RoutingMode.allCases) { mode in
                Button {
                    connection.setRoutingMode(mode)
                } label: {
                    if connection.routingMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
                .disabled(mode == .bypassRegions && !packs.hasUsablePack)
            }
            Divider()
            Button("Manage Regions…") { onManageRegions() }
        } label: {
            Text(connection.routingMode.title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(packs.hasUsablePack ? "Routing mode" : "Enable a region pack to use Bypass Regions")
    }
}

/// TUN mode switch shared by the connection bar and the menu bar panel.
struct TunToggle: View {
    let connection: ConnectionController
    var showsLabel = true

    var body: some View {
        if connection.tun.needsAccess {
            HStack(spacing: 6) {
                if showsLabel { Text("TUN").font(.caption) }
                Button("Give Access") { connection.connectActive() }
                    .controlSize(.small)
            }
            .fixedSize()
            .help("The administrator prompt was closed. Click to ask for access again.")
        } else {
            toggle
        }
    }

    private var toggle: some View {
        Toggle(isOn: Binding(
            get: { connection.tun.isEnabled },
            set: { on in connection.setTunEnabled(on) }
        )) {
            if showsLabel { Text("TUN").font(.caption) }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
        .help("TUN mode: route all traffic on this Mac through the proxy. Requires the privileged helper or macOS administrator access.")
        .accessibilityLabel("TUN mode")
    }
}

/// System proxy switch shared by the connection bar and the menu bar panel, with the badge.
struct SystemProxyToggle: View {
    let connection: ConnectionController
    var showsLabel = true

    var body: some View {
        HStack(spacing: 6) {
            if showsLabel { Text("Proxy").font(.caption) }
            SystemProxyBadge(connection: connection)
            Toggle("System proxy", isOn: Binding(
                get: { connection.systemProxy.isEnabled },
                set: { on in connection.setSystemProxyEnabled(on) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .fixedSize()
        .help("Set the system proxy to V2Mac while connected. The dot is green when the system proxy is V2Mac, red when it is something else, and grey when none is set.")
    }
}

/// Where the system's proxy settings point (spec 9.9): green at this app's port, red at
/// something else, grey when nothing is set. It looks again every two seconds while shown.
struct SystemProxyBadge: View {
    let connection: ConnectionController

    var body: some View {
        let state = connection.systemProxy.status
        let label: LocalizedStringKey = state == .ours ? "System proxy is V2Mac" : (state == .other ? "System proxy is something else" : "No system proxy")
        Circle()
            .fill(state == .ours ? Color.green : (state == .other ? Color.red : Color.secondary.opacity(0.5)))
            .frame(width: 7, height: 7)
            .accessibilityLabel(label)
            .task(id: connection.port) {
                while !Task.isCancelled {
                    connection.systemProxy.refresh(port: connection.port)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }
}

/// The kill switch keeps blocking while no connection is up: after a failure, or left from a
/// session that ended unexpectedly. Says so, with the way out.
struct KillSwitchNotice: View {
    let connection: ConnectionController

    var body: some View {
        HStack(spacing: 8) {
            Label("Kill switch is blocking all traffic", systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            Button("Allow Traffic") { connection.disconnect() }
                .controlSize(.small)
                .help("Lift the kill switch until the next connection")
        }
    }
}
