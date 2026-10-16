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
            CustomRulesSection()
        }
        .formStyle(.grouped)
    }
}

/// Spec 8.6: the user's own rules, edited as text and applied with one button,
/// so typing does not restart the core on every key.
private struct CustomRulesSection: View {
    typealias List = RuleList

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("customRulesProxy") private var proxy = ""
    @AppStorage("customRulesDirect") private var direct = ""
    @AppStorage("customRulesBlock") private var block = ""
    // The rule builder sets this to the list it wrote, so its rules are on screen afterwards.
    @AppStorage(List.shownKey) private var list = List.proxy
    @State private var drafts: [List: String] = [:]

    private func saved(_ list: List) -> String {
        switch list {
        case .proxy: proxy
        case .direct: direct
        case .block: block
        }
    }

    private var changed: Bool { List.allCases.contains { drafts[$0, default: saved($0)] != saved($0) } }

    var body: some View {
        let text = Binding { drafts[list, default: saved(list)] } set: { drafts[list] = $0 }
        let invalid = RuleMatchers(parsing: text.wrappedValue).invalid
        Section {
            Picker("Send to", selection: $list) {
                ForEach(List.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextEditor(text: text)
                .font(.body.monospaced())
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
            if !invalid.isEmpty {
                Label(invalid.count > 3 ? "Skipped, not a rule: \(invalid.prefix(3).joined(separator: ", ")) and \(invalid.count - 3) more" : "Skipped, not a rule: \(invalid.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Rule Builder…", systemImage: "wand.and.stars") { model.openRuleBuilder(openWindow) }
                Spacer()
                Button("Revert") { drafts = [:] }.disabled(!changed)
                Button("Apply") {
                    for (list, value) in drafts { UserDefaults.standard.set(value, forKey: list.key) }
                    drafts = [:]
                    model.connection.reconnectIfRunning()
                }
                .disabled(!changed)
                .keyboardShortcut(.defaultAction)
            }
        } header: {
            Text("Custom rules")
        } footer: {
            Text("""
            One rule per line. Checked before the mode's own rules: Block first, then Proxy, then Direct. \
            Direct mode uses only the Block list. Accepts domains (example.com also matches its subdomains), \
            IP addresses and ranges (10.0.0.0/8), geosite:… and geoip:… tags, Xray prefixes (full:, keyword:, regexp:, ext:), \
            Clash rules (DOMAIN-SUFFIX,example.com) and hosts or Adblock lists. Full configs keep their own routing.
            """)
            .foregroundStyle(.secondary)
        }
        // The rule builder saves straight to the lists; show what it wrote.
        .onChange(of: proxy) { drafts[.proxy] = nil }
        .onChange(of: direct) { drafts[.direct] = nil }
        .onChange(of: block) { drafts[.block] = nil }
    }
}
