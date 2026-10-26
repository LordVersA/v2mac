import SwiftUI
import V2MacCore

/// The rules in the order the core checks them, with a search that also answers where a host, address
/// or app goes, and a filter by action.
struct RulesSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    @Binding var search: String
    @Binding var filter: RulesWindow.Filter
    @State private var answer: SearchAnswer?

    var body: some View {
        @Bindable var store = model.rules
        let query = search.trimmingCharacters(in: .whitespaces)
        let shown = store.draft.filter { filter.admits($0.action) && (query.isEmpty || $0.matches(query)) }
        let reorderable = query.isEmpty && filter == .all
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(RulesWindow.Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            List(selection: $store.selection) {
                if let answer {
                    Section("Where it goes") {
                        SearchAnswerRow(answer: answer)
                            .tag(answer.rule.map(RulesStore.Selection.rule) ?? .builtIn(answer.builtIn ?? .everythingElse))
                    }
                }
                if query.isEmpty, filter == .all {
                    Section("Before your rules") {
                        BuiltInRow(kind: .localNetwork).tag(RulesStore.Selection.builtIn(.localNetwork))
                        BuiltInRow(kind: .blockQUIC).tag(RulesStore.Selection.builtIn(.blockQUIC))
                        BuiltInRow(kind: .proxyPort).tag(RulesStore.Selection.builtIn(.proxyPort))
                    }
                }
                Section {
                    ForEach(shown) { rule in
                        RuleRow(rule: rule, number: (store.draft.firstIndex(of: rule) ?? 0) + 1, highlight: query)
                            .tag(RulesStore.Selection.rule(rule.id))
                            .contextMenu { RuleContextMenu(rule: rule) }
                            .dropDestination(for: RuleItemsTransfer.self) { dropped, _ in
                                store.add(dropped.flatMap(\.items), to: rule.id, undo)
                                return true
                            }
                    }
                    .onMove(perform: reorderable ? { from, to in store.change(undo) { $0.move(fromOffsets: from, toOffset: to) } } : nil)
                } header: {
                    Text("My rules")
                } footer: {
                    if store.draft.isEmpty {
                        Text("No rules yet. Add one with + or start from a template.").font(.caption).foregroundStyle(.secondary)
                    } else if shown.isEmpty {
                        Text("No rule matches.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if query.isEmpty, filter == .all {
                    Section("After your rules") {
                        BuiltInRow(kind: .mode).tag(RulesStore.Selection.builtIn(.mode))
                        BuiltInRow(kind: .everythingElse).tag(RulesStore.Selection.builtIn(.everythingElse))
                    }
                    Section {
                        Label("Discovered (\(model.connection.watcher.uncovered(by: store.draft, catalog: model.ruleCatalog).count))", systemImage: "binoculars")
                            .tag(RulesStore.Selection.discovered)
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { store.delete(store.selectedRuleIDs, undo) }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            answer = await SearchAnswer.find(query, model: model)
        }
    }
}

private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    let rule: Rule
    let number: Int
    let highlight: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
            Circle().fill(rule.action.tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(rule.name.isEmpty ? String(localized: "Untitled") : rule.name).lineLimit(1)
                    if model.rules.isChanged(rule) {
                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.orange).help("Changed, not applied yet")
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer(minLength: 4)
            let warnings = model.ruleWarnings(rule)
            if !warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(warnings.joined(separator: "\n"))
            }
            Toggle("On", isOn: Binding { rule.enabled } set: { on in model.rules.update(rule.id, undo) { $0.enabled = on } })
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .help("#\(number)")
    }

    private var subtitle: String {
        var parts: [String] = []
        if case .via = rule.action { parts.append(rule.action.title(model)) }
        if !highlight.isEmpty, let hit = rule.items.first(where: { $0.text.localizedCaseInsensitiveContains(highlight) }) {
            parts.append(hit.text)
        } else {
            parts.append(rule.itemSummary)
        }
        if !rule.onlySummary.isEmpty { parts.append(rule.onlySummary) }
        return parts.joined(separator: " · ")
    }
}

struct RuleContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    let rule: Rule

    var body: some View {
        Button(rule.enabled ? "Turn Off" : "Turn On") { model.rules.update(rule.id, undo) { $0.enabled.toggle() } }
        Button("Duplicate") { model.rules.duplicate(rule.id, undo) }
        Divider()
        Button("Delete", role: .destructive) {
            let ids = model.rules.selection.contains(.rule(rule.id)) ? model.rules.selectedRuleIDs : [rule.id]
            model.rules.delete(ids, undo)
        }
    }
}

/// A row for a rule the user cannot move or delete.
private struct BuiltInRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("blockQUIC") private var blockQUIC = false
    @AppStorage("unmatchedRoute") private var unmatchedRoute = "mode"
    let kind: RulesStore.BuiltIn

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind == .blockQUIC || kind == .everythingElse ? "slider.horizontal.3" : "lock.fill")
                .font(.caption).foregroundStyle(.tertiary).frame(width: 12)
            Circle().fill(tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).lineLimit(1)
                Text(kind.subtitle(model)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            switch kind {
            case .blockQUIC:
                Toggle("Block QUIC", isOn: $blockQUIC)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .onChange(of: blockQUIC) { model.connection.reconnectIfRunning() }
                    .disabled(model.connection.routingMode == .direct)
            case .everythingElse:
                Picker("Everything else", selection: $unmatchedRoute) {
                    Text("Follow mode").tag("mode")
                    Text("Proxy").tag("proxy")
                    Text("Direct").tag("direct")
                    Text("Block").tag("block")
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(model.connection.routingMode == .direct)
                .onChange(of: unmatchedRoute) { model.connection.reconnectIfRunning() }
            default:
                EmptyView()
            }
        }
    }

    private var tint: Color {
        switch kind {
        case .localNetwork: .green
        case .blockQUIC: .red
        case .proxyPort: .blue
        case .mode, .everythingElse: .secondary
        }
    }
}

extension RulesStore.BuiltIn {
    var title: LocalizedStringKey {
        switch self {
        case .localNetwork: "Local network"
        case .blockQUIC: "Block QUIC"
        case .proxyPort: "Apps using the proxy port"
        case .mode: "Routing mode"
        case .everythingElse: "Everything else"
        }
    }

    @MainActor func subtitle(_ model: AppModel) -> String {
        switch self {
        case .localNetwork: return String(localized: "This Mac, the LAN and local names → Direct")
        case .blockQUIC: return String(localized: "UDP 443, so browsers use TCP and rules see their sites")
        case .proxyPort:
            guard !Prefs.systemProxy else { return String(localized: "Off while the system proxy is on") }
            return switch CustomRule.Action(rawValue: UserDefaults.standard.string(forKey: "proxyClientsRoute") ?? "") {
            case .proxy: String(localized: "→ Proxy, before your rules")
            case .direct: String(localized: "→ Direct, before your rules")
            case .block: String(localized: "→ Block, before your rules")
            case nil: String(localized: "Follow your rules")
            }
        case .mode:
            return switch model.connection.routingMode {
            case .global: String(localized: "Global: no rules of its own")
            case .bypassRegions: String(localized: "Bypass Regions: region sites and addresses → Direct")
            case .rulesOnly: String(localized: "Rules Only: everything else → Direct")
            case .direct: String(localized: "Direct: only Block rules apply")
            }
        case .everythingElse:
            return switch model.connection.routingMode {
            case .global, .bypassRegions: String(localized: "Follow mode: Proxy")
            case .rulesOnly, .direct: String(localized: "Follow mode: Direct")
            }
        }
    }
}

extension Rule {
    /// The window's search: the name or any item.
    func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query) || items.contains { $0.text.localizedCaseInsensitiveContains(query) }
            || only.apps.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension AppModel {
    /// Why a rule may not do what it says, for its badge.
    func ruleWarnings(_ rule: Rule) -> [String] {
        var out: [String] = []
        if case .via(let via) = rule.action {
            if viaName(via.target) == nil {
                out.append(via.fallsBack
                    ? String(localized: "“\(via.name)” is not on this Mac: this rule's traffic uses the current server.")
                    : String(localized: "“\(via.name)” is not on this Mac: this rule's traffic is blocked."))
            }
            if let failing = connection.viaStatus[via.target], failing.allFailing {
                out.append(via.fallsBack
                    ? String(localized: "No server of “\(via.name)” answers: its traffic uses the current server.")
                    : String(localized: "No server of “\(via.name)” answers: its traffic fails until one does."))
            }
        }
        if connection.routingMode == .direct, rule.action != .block {
            out.append(String(localized: "Direct mode applies only Block rules."))
        }
        let invalid = rule.items.filter { $0.kind == .invalid }
        if !invalid.isEmpty { out.append(String(localized: "Not understood, so ignored: \(invalid.map(\.text).joined(separator: ", "))")) }
        if rule.needsApps, connection.tun.isEnabled {
            out.append(String(localized: "In TUN mode app entries match only apps that use the proxy port: the core cannot see which app a TUN connection comes from."))
        }
        if !rule.only.ports.isEmpty, !Rule.OnlyWhen.validPorts(rule.only.ports.replacingOccurrences(of: " ", with: "")) {
            out.append(String(localized: "The ports are not valid, so the rule is left out."))
        }
        return out
    }
}
