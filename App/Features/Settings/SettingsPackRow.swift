import SwiftUI
import V2MacCore

struct SettingsPackRow: View {
    @Environment(AppModel.self) private var model
    let pack: RegionPackDefinition

    @State private var interval: PackUpdateInterval

    init(pack: RegionPackDefinition) {
        self.pack = pack
        _interval = State(initialValue: Prefs.packUpdateInterval(pack.id))
    }

    private var service: RegionPackService { model.regionPacks }
    private var enabled: Bool { service.enabledIDs.contains(pack.id) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                status
            }
            Spacer()
            if service.status(pack) == .installing {
                ProgressView().controlSize(.small)
            } else {
                if enabled {
                    Picker("Auto-update", selection: $interval) {
                        ForEach(PackUpdateInterval.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: interval) { Prefs.setPackUpdateInterval(interval, for: pack.id) }
                    .help("How often this pack updates itself")
                    Button("Update Now") { Task { await service.updateNow(pack) } }
                        .controlSize(.small)
                }
                Toggle(pack.name, isOn: Binding(
                    get: { enabled },
                    set: { on in
                        if on { Task { await service.enable(pack) } } else { service.disable(pack) }
                    }
                ))
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch service.status(pack) {
        case .notInstalled: Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
        case .installing: Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        case .installed(let date):
            Text(date.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Installed")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}
