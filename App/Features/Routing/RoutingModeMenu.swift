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
        if connection.activeIsCustom {
            Text("Managed by this config")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
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
}

/// TUN mode switch shared by the connection bar and the menu bar panel.
struct TunToggle: View {
    let connection: ConnectionController
    var showsLabel = true

    var body: some View {
        Toggle(isOn: Binding(
            get: { connection.tun.isEnabled },
            set: { on in connection.setTunEnabled(on) }
        )) {
            if showsLabel { Text("TUN").font(.caption) }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
        .help("TUN mode: route all traffic on this Mac through the proxy. Asks for an administrator password once each time V2Mac is opened.")
        .accessibilityLabel("TUN mode")
    }
}
