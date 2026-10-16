import SwiftUI
import UniformTypeIdentifiers
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

/// Spec 8.6: the user's own rules, one ordered list checked top to bottom. Edits are kept as a
/// draft and applied with one button, so typing does not restart the core on every key.
private struct CustomRulesSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("customRuleList") private var stored = "[]"
    @AppStorage("blockQUIC") private var blockQUIC = false
    @State private var draft: [CustomRule]?
    @State private var editing: CustomRule?
    @State private var importing = false
    @State private var importNote: String?

    private var rules: [CustomRule] { draft ?? CustomRule.decode(stored) }

    private func change(_ update: (inout [CustomRule]) -> Void) {
        var copy = rules
        update(&copy)
        draft = copy
    }

    var body: some View {
        Section {
            if rules.isEmpty {
                Text("No rules yet. Every connection follows the routing mode.").foregroundStyle(.secondary)
            }
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                CustomRuleRow(rule: rule, enabled: Binding { rule.enabled } set: { on in change { $0[index].enabled = on } }) {
                    editing = rule
                }
                .contextMenu {
                    Button("Edit…") { editing = rule }
                    Button("Move Up") { change { $0.swapAt(index, index - 1) } }.disabled(index == 0)
                    Button("Move Down") { change { $0.swapAt(index, index + 1) } }.disabled(index == rules.count - 1)
                    Divider()
                    Button("Delete", role: .destructive) { change { $0.remove(at: index) } }
                }
            }
            .onMove { from, to in change { $0.move(fromOffsets: from, toOffset: to) } }
            if let importNote {
                Label(importNote, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            HStack {
                Button("Add Rule", systemImage: "plus") {
                    let rule = CustomRule(name: String(localized: "New rule"), action: .proxy)
                    change { $0.append(rule) }
                    editing = rule
                }
                Button("Rule Builder…", systemImage: "wand.and.stars") { model.openRuleBuilder(openWindow) }
                Button("Import Proxifier Profile…") { importing = true }
                Spacer()
                Button("Revert") { draft = nil; importNote = nil }.disabled(draft == nil)
                Button("Apply") {
                    if let draft { stored = CustomRule.encode(draft) }
                    draft = nil
                    model.connection.reconnectIfRunning()
                }
                .disabled(draft == nil)
                .keyboardShortcut(.defaultAction)
            }
        } header: {
            Text("Custom rules")
        } footer: {
            Text("""
            Checked from the top, before the mode's own rules; the first rule that matches decides. Drag to reorder. \
            A rule with apps and hosts needs both. Direct mode uses only Block rules. Local names (localhost, *.local) \
            always go direct. Full configs keep their own routing.
            """)
            .foregroundStyle(.secondary)
        }
        // The rule builder saves straight to the list; show what it wrote.
        .onChange(of: stored) { draft = nil }
        .sheet(item: $editing) { rule in
            CustomRuleEditor(rule: rule) { updated in
                change { list in
                    if let index = list.firstIndex(where: { $0.id == updated.id }) { list[index] = updated }
                }
            } onDelete: {
                change { $0.removeAll { $0.id == rule.id } }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ppx") ?? .xml, .xml]) { result in
            importProfile(result)
        }
        Section {
            Toggle("Block QUIC (UDP 443)", isOn: $blockQUIC)
                .onChange(of: blockQUIC) { model.connection.reconnectIfRunning() }
        } footer: {
            Text("Browsers then fall back to TCP, so their host names reach the rules above.")
                .foregroundStyle(.secondary)
        }
    }

    private func importProfile(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let profile = try ProxifierProfile(data: Data(contentsOf: url))
            change { $0 += profile.rules }
            if profile.blockQUIC { blockQUIC = true }
            importNote = profile.skipped.isEmpty
                ? String(localized: "Imported \(profile.rules.count) rules. Check them and click Apply.")
                : String(localized: "Imported \(profile.rules.count) rules. Skipped, they use another proxy or a chain: \(profile.skipped.joined(separator: ", ")).")
        } catch {
            importNote = String(localized: "Could not read the profile: \(error.localizedDescription)")
        }
    }
}

private struct CustomRuleRow: View {
    let rule: CustomRule
    @Binding var enabled: Bool
    let edit: () -> Void

    var body: some View {
        let list = RuleList(rule.action)
        let hosts = RuleMatchers(parsing: rule.hosts)
        let apps = rule.apps.split(whereSeparator: { $0.isNewline || $0 == ";" }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        HStack {
            Toggle(rule.name, isOn: $enabled).labelsHidden()
            Image(systemName: list.symbol).foregroundStyle(list.tint)
            VStack(alignment: .leading) {
                Text(rule.name)
                Text("\(list.title) · Apps: \(apps) · Hosts: \(hosts.domains.count + hosts.ips.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer()
            if !hosts.invalid.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help(Text("Skipped, not a rule: \(hosts.invalid.joined(separator: ", "))"))
            }
            Button("Edit…", action: edit)
        }
    }
}

private struct CustomRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: CustomRule
    let save: (CustomRule) -> Void
    let onDelete: () -> Void

    init(rule: CustomRule, save: @escaping (CustomRule) -> Void, onDelete: @escaping () -> Void) {
        _rule = State(initialValue: rule)
        self.save = save
        self.onDelete = onDelete
    }

    var body: some View {
        let invalid = RuleMatchers(parsing: rule.hosts).invalid
        Form {
            TextField("Name", text: $rule.name)
            Picker("Send to", selection: $rule.action) {
                ForEach(RuleList.allCases) { Text($0.title).tag($0.action) }
            }
            .pickerStyle(.segmented)
            Section {
                TextEditor(text: $rule.apps)
                    .font(.body.monospaced())
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Apps")
            } footer: {
                Text("One per line: Spotify.app, com.spotify.client, *discord*, a process name (curl) or a full path. Empty means every app.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $rule.hosts)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                if !invalid.isEmpty {
                    Label("Skipped, not a rule: \(invalid.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Hosts")
            } footer: {
                Text("""
                One per line. Domains (example.com also matches its subdomains), *word* keywords, IP addresses, \
                ranges (10.0.0.0/8 or 10.0.0.1-10.0.0.9), geosite:… and geoip:… tags, Xray prefixes (full:, keyword:, regexp:, ext:), \
                Clash rules and hosts or Adblock lists. Empty means every host.
                """)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete Rule", role: .destructive) { onDelete(); dismiss() }
            }
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { save(rule); dismiss() } }
        }
    }
}
