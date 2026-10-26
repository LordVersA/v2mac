import SwiftUI
import V2MacCore

/// Spec 8.6: the routing mode and region packs. The rules themselves are edited in the Rules window.
struct RoutingSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
            Section {
                Button("Open Rules…", systemImage: "arrow.triangle.branch") { model.openRules(openWindow) }
            } footer: {
                Text("Your rules, Block QUIC and where traffic that matches no rule goes are in the Rules window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ResetSettingsSection(tab: .routing)
        }
        .formStyle(.grouped)
    }
}
