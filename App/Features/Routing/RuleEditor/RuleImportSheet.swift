import SwiftUI
import UniformTypeIdentifiers
import V2MacCore

/// Review the existing parser's result before appending it to the active rule profile.
struct RuleImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: RuleImport
    let save: () -> Void

    /// Proxifier, Clash, sing-box, v2rayN and Shadowrocket / Surge files.
    static let fileTypes: [UTType] = [.xml, .json, .yaml, .plainText]
        + ["ppx", "yml", "conf", "list"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import \(profile.format.rawValue) rules").font(.title2.weight(.semibold))
            Text("\(profile.rules.count) rules will be added after your existing rules. Existing rules keep their priority.")
                .font(.callout).foregroundStyle(.secondary)
            List(profile.rules.map(CustomRule.init(legacy:))) { rule in
                HStack(spacing: 10) {
                    Image(systemName: RuleList(rule.action).symbol)
                        .foregroundStyle(RuleList(rule.action).tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.name).fontWeight(.medium)
                        Text(rule.apps.isEmpty ? String(localized: "All apps") : rule.apps.replacingOccurrences(of: "\n", with: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(rule.hosts.isEmpty ? String(localized: "All hosts") : rule.hosts.replacingOccurrences(of: "\n", with: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text(rule.enabled ? RuleList(rule.action).title : String(localized: "Disabled"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
            if !profile.skipped.isEmpty {
                Label("Skipped, V2Mac has nothing like them: \(profile.skipped.joined(separator: ", ")).", systemImage: "exclamationmark.triangle")
                    .lineLimit(4)
                    .font(.callout).foregroundStyle(.orange)
            }
            if profile.blockQUIC {
                Label("Block QUIC (UDP 443) will be enabled.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Combined app-and-host rules, disabled rules and address rules are available in Advanced.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.rules.isEmpty && !profile.blockQUIC)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
    }
}
