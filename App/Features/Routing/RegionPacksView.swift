import SwiftUI
import V2MacCore

/// Enable, update and remove region packs. Reused by the Settings window later.
struct RegionPacksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bypass Regions").font(.headline)
            Text("Traffic to an enabled region goes direct; everything else uses the proxy. Rule files are downloaded when you enable a region.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(model.regionPacks.packs) { pack in
                    PackRow(pack: pack)
                    if pack.id != model.regionPacks.packs.last?.id { Divider() }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct PackRow: View {
    @Environment(AppModel.self) private var model
    let pack: RegionPackDefinition

    private var service: RegionPackService { model.regionPacks }
    private var enabled: Bool { service.enabledIDs.contains(pack.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.name).font(.body.weight(.medium))
                statusLine
                Text(pack.attribution).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if service.status(pack) == .installing {
                ProgressView().controlSize(.small)
            } else {
                if enabled {
                    Button("Update Now") { Task { await service.updateNow(pack) } }
                        .controlSize(.small)
                }
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { on in
                        if on { Task { await service.enable(pack) } } else { service.disable(pack) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch service.status(pack) {
        case .notInstalled:
            Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
        case .installing:
            Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        case .installed(let date):
            Text(date.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Installed")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }
}
