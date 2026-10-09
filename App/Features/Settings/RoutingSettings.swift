import SwiftUI
import V2MacCore

struct RoutingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var connection = model.connection
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
        }
        .formStyle(.grouped)
    }
}
