import SwiftData
import SwiftUI
import V2MacCore

/// The selected rule, a built-in's explanation, or Discovered.
struct RulesDetail: View {
    @Environment(AppModel.self) private var model
    let search: String

    var body: some View {
        let store = model.rules
        switch store.selection.count == 1 ? store.selection.first : nil {
        case .rule(let id)?:
            if store.draft.contains(where: { $0.id == id }) {
                RuleEditor(id: id, highlight: search).id(id)
            } else {
                empty
            }
        case .builtIn(let kind)?:
            BuiltInDetail(kind: kind)
        case .discovered?:
            DiscoveredView()
        case nil:
            if store.selectedRuleIDs.count > 1 {
                ContentUnavailableView("\(store.selectedRuleIDs.count) rules selected", systemImage: "square.stack",
                                       description: Text("Drag to reorder, or export them from the ⋯ menu."))
            } else {
                empty
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView("Select a rule", systemImage: "arrow.triangle.branch",
                               description: Text("Rules are checked from the top; the first that matches decides where traffic goes."))
    }
}

/// One rule: name, action and switch; the smart field; the items as tokens grouped by kind; and
/// "Only when", which every item must also meet.
private struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    @Query(sort: \ServerGroup.sortIndex) private var groups: [ServerGroup]
    let id: UUID
    let highlight: String
    @State private var showsOnly = false
    @State private var browsing = false

    private var rule: Rule { model.rules.draft.first { $0.id == id } ?? Rule(name: "", action: .proxy) }

    private func edit(_ change: (inout Rule) -> Void) { model.rules.update(id, undo, change) }

    var body: some View {
        let rule = rule
        Form {
            Section {
                HStack {
                    TextField("Name", text: Binding { rule.name } set: { name in edit { $0.name = name } }, prompt: Text("Rule name"))
                        .font(.title3)
                        .textFieldStyle(.plain)
                    Toggle("On", isOn: Binding { rule.enabled } set: { on in edit { $0.enabled = on } })
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                LabeledContent("Send to") { actionMenu(rule) }
                if case .via(let via) = rule.action {
                    Toggle("If its servers fail, use the current server", isOn: Binding { via.fallsBack } set: { on in
                        edit { var v = via; v.fallsBack = on; $0.action = .via(v) }
                    })
                    .help("Off: this rule's traffic fails until a server answers, and never leaves another way.")
                    if let health = model.connection.viaStatus[via.target] {
                        LabeledContent("Servers answering", value: "\(health.alive) of \(health.total)")
                            .foregroundStyle(health.allFailing ? .orange : .secondary)
                    }
                }
                ForEach(model.ruleWarnings(rule), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
            }
            Section {
                SmartField(ruleID: id) { browsing = true }
                if rule.items.isEmpty {
                    Text(rule.only.isEmpty ? "Add apps, sites, addresses, countries or services. Any of them matching sends the traffic."
                         : "No items: the rule matches all traffic that meets “Only when”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                let groups = Dictionary(grouping: rule.items, by: \.kind.group)
                ForEach(groups.keys.sorted(), id: \.self) { group in
                    LabeledContent {
                        TokenFlow(items: groups[group]!, highlight: highlight) { item, replacement in
                            edit { r in
                                guard let i = r.items.firstIndex(of: item) else { return }
                                if let replacement { r.items[i] = replacement } else { r.items.remove(at: i) }
                            }
                        }
                    } label: {
                        Text(group.title)
                    }
                }
            } header: {
                Text("Matches any of")
            }
            Section(isExpanded: Binding { showsOnly || !rule.only.isEmpty } set: { showsOnly = $0 }) {
                OnlyWhenEditor(rule: rule, edit: edit)
            } header: {
                Text("Only when")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $browsing) {
            BrowseSheet { items in edit { r in r.items += items.filter { !r.items.contains($0) } } }
        }
    }

    /// Proxy · Via ▸ groups, servers · Direct · Block.
    private func actionMenu(_ rule: Rule) -> some View {
        Menu {
            Button("Proxy (connected server)", systemImage: Rule.Action.proxy.symbol) { edit { $0.action = .proxy } }
            Menu("Via") {
                ForEach(groups) { group in
                    Menu(group.name) {
                        Button("Fastest of the group") { setVia(.group(group.id), group.name) }
                        Divider()
                        ForEach(group.profiles.filter { !$0.isStale }.sorted { $0.sortIndex < $1.sortIndex }) { profile in
                            Button(profile.name) { setVia(.server(profile.id), profile.name) }
                        }
                    }
                }
            }
            Button("Direct", systemImage: Rule.Action.direct.symbol) { edit { $0.action = .direct } }
            Button("Block", systemImage: Rule.Action.block.symbol) { edit { $0.action = .block } }
        } label: {
            Label(rule.action.title(model), systemImage: rule.action.symbol).foregroundStyle(rule.action.tint)
        }
        .fixedSize()
    }

    private func setVia(_ target: Rule.Via.Target, _ name: String) {
        edit { rule in
            let fallsBack = if case .via(let old) = rule.action { old.fallsBack } else { false }
            rule.action = .via(.init(target: target, name: name, fallsBack: fallsBack))
        }
    }
}

/// Ports, network, sniffed protocols and apps.
private struct OnlyWhenEditor: View {
    let rule: Rule
    let edit: ((inout Rule) -> Void) -> Void
    @State private var ports = ""
    @State private var app = ""

    var body: some View {
        LabeledContent("Ports") {
            TextField("Ports", text: $ports, prompt: Text("Any, or 443, 8000-8100"))
                .labelsHidden()
                .onSubmit(savePorts)
                .onChange(of: ports) { if ports.isEmpty || Rule.OnlyWhen.validPorts(ports.replacingOccurrences(of: " ", with: "")) { savePorts() } }
                .foregroundStyle(ports.isEmpty || Rule.OnlyWhen.validPorts(ports.replacingOccurrences(of: " ", with: "")) ? .primary : Color.red)
        }
        .onAppear { ports = rule.only.ports }
        Picker("Network", selection: Binding { rule.only.network } set: { n in edit { $0.only.network = n } }) {
            Text("TCP and UDP").tag(Rule.Network?.none)
            Text("TCP").tag(Rule.Network?.some(.tcp))
            Text("UDP").tag(Rule.Network?.some(.udp))
        }
        LabeledContent("Protocol") {
            HStack {
                ForEach(Rule.Sniffed.allCases, id: \.self) { p in
                    Toggle(p.title, isOn: Binding { rule.only.protocols.contains(p) } set: { on in
                        edit { r in if on { r.only.protocols.append(p) } else { r.only.protocols.removeAll { $0 == p } } }
                    })
                    .toggleStyle(.checkbox)
                }
            }
        }
        .help("Recognised by the core from the first bytes of a connection.")
        LabeledContent("Apps") {
            VStack(alignment: .trailing) {
                TokenFlow(items: rule.only.apps.map(Rule.Item.app), highlight: "") { item, _ in
                    edit { $0.only.apps.removeAll { $0 == item.text } }
                }
                TextField("Add app", text: $app, prompt: Text("App name or bundle id"))
                    .labelsHidden()
                    .onSubmit {
                        let entry = app.trimmingCharacters(in: .whitespaces)
                        if !entry.isEmpty { edit { $0.only.apps.append(entry) } }
                        app = ""
                    }
            }
        }
        Text("Every item above must also meet these. Leave them empty to match any port, network, protocol and app.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func savePorts() {
        let value = ports.trimmingCharacters(in: .whitespaces)
        if value != rule.only.ports { edit { $0.only.ports = value } }
    }
}

/// The items as tokens; a click shows the kind menu (domains) or the app's details.
struct TokenFlow: View {
    @Environment(AppModel.self) private var model
    let items: [Rule.Item]
    let highlight: String
    /// The token and its replacement, or nil to remove it.
    let change: (Rule.Item, Rule.Item?) -> Void

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.self) { item in
                Token(item: item, lit: !highlight.isEmpty && item.text.localizedCaseInsensitiveContains(highlight), change: change)
            }
        }
    }
}

private struct Token: View {
    @Environment(AppModel.self) private var model
    let item: Rule.Item
    let lit: Bool
    let change: (Rule.Item, Rule.Item?) -> Void
    @State private var showsApp = false

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(label).lineLimit(1).truncationMode(.middle)
            if item.kind == .app, model.connection.tun.isEnabled {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    .help("In TUN mode app entries match only apps that use the proxy port.")
            }
            Button("Remove", systemImage: "xmark") { change(item, nil) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(lit ? Color.yellow.opacity(0.35) : item.kind == .invalid ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12),
                    in: .capsule)
        .help(Text(item.kind.title))
        .contextMenu { kindMenu }
        .onTapGesture { if item.kind == .app { showsApp = true } }
        .popover(isPresented: $showsApp) { AppTokenPopover(entry: item.text) { change(item, $0) } }
    }

    private var label: String {
        if case .country(let code) = item { return model.ruleCatalog.geo.country(code).map { "\($0.flag) \($0.name)" } ?? code.uppercased() }
        if case .app(let entry) = item { return model.ruleCatalog.apps.appName(for: entry) ?? entry }
        return item.text
    }

    @ViewBuilder private var icon: some View {
        if case .app(let entry) = item, let path = model.ruleCatalog.apps.app(for: entry)?.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 14, height: 14)
        } else {
            Image(systemName: item.kind.symbol).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Read the text as another kind: a domain as a keyword, an exact name, and so on.
    @ViewBuilder private var kindMenu: some View {
        if [.domain, .exact, .keyword, .regex].contains(item.kind) {
            ForEach([Rule.Item.Kind.domain, .exact, .keyword, .regex], id: \.self) { kind in
                Button { if let new = item.changing(to: kind) { change(item, new) } } label: {
                    if kind == item.kind { Label { Text(kind.title) } icon: { Image(systemName: "checkmark") } } else { Text(kind.title) }
                }
                .disabled(item.changing(to: kind) == nil)
            }
            Divider()
        }
        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text, forType: .string) }
        Button("Remove", role: .destructive) { change(item, nil) }
    }
}

extension [InstalledApp] {
    /// The installed app an entry names: a bundle id, `Name.app`, a name or a path.
    func app(for entry: String) -> InstalledApp? {
        let lower = entry.lowercased()
        return first { $0.bundleID.lowercased() == lower || $0.name == lower || $0.name == lower + ".app" || $0.path == entry }
    }

    func appName(for entry: String) -> String? {
        app(for: entry).map { ($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
    }
}

/// An app token's details: which processes on this Mac it matches and the connections seen from it.
/// Widening to a keyword is a deliberate choice.
private struct AppTokenPopover: View {
    @Environment(AppModel.self) private var model
    let entry: String
    let replace: (Rule.Item) -> Void
    @State private var widen = false

    var body: some View {
        let matched = AppMatchers.processes(for: entry, apps: model.ruleCatalog.apps) as [String]
        let seen = model.connection.watcher.apps.values.filter { seen in matched.contains { RuleTester.processMatches($0, seen.id + "/") || RuleTester.processMatches($0, seen.id) } }
        VStack(alignment: .leading, spacing: 10) {
            Text(model.ruleCatalog.apps.appName(for: entry) ?? entry).font(.headline)
            Text(entry).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            Text("Matches on this Mac").font(.subheadline.weight(.semibold))
            if matched.isEmpty {
                Text("Nothing installed or running. The rule is left out until it is.").font(.callout).foregroundStyle(.orange)
            }
            ForEach(matched, id: \.self) { process in
                Label(process.hasSuffix("/") ? String(localized: "\(process) and everything inside") : String(localized: "Any program named \(process)"),
                      systemImage: process.hasSuffix("/") ? "folder" : "terminal")
                    .font(.callout).lineLimit(2)
            }
            if !seen.isEmpty {
                Text("Seen while this window was open").font(.subheadline.weight(.semibold))
                ForEach(seen.prefix(5), id: \.id) { app in
                    Text("\((app.id as NSString).lastPathComponent): \(app.count) connections").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let name = model.ruleCatalog.apps.appName(for: entry), !entry.hasPrefix("*") {
                Divider()
                Toggle("Also match every app with “\(name.lowercased())” in its name", isOn: $widen)
                    .toggleStyle(.checkbox)
                    .onChange(of: widen) { if widen { replace(.app("*\(name.lowercased())*")) } }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Lays tokens out in rows that wrap.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width > 0, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row(y: rows[rows.count - 1].y + rows[rows.count - 1].height + spacing))
            }
            let x = rows[rows.count - 1].width == 0 ? 0 : rows[rows.count - 1].width + spacing
            rows[rows.count - 1].items.append((index, x))
            rows[rows.count - 1].width = x + min(size.width, width)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// What a built-in row does, and where it is set.
private struct BuiltInDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let kind: RulesStore.BuiltIn

    var body: some View {
        Form {
            Section {
                Text(kind.title).font(.title3)
                Text(kind.subtitle(model)).foregroundStyle(.secondary)
                Text(explanation).font(.callout)
            }
            switch kind {
            case .proxyPort:
                Button("Change in Settings → Proxy…") { model.openSettings(openSettings, tab: .proxy) }
            case .mode:
                Picker("Routing mode", selection: Binding { model.connection.routingMode } set: { model.connection.setRoutingMode($0) }) {
                    ForEach(RoutingMode.allCases) { Text($0.title).tag($0) }
                }
                Button("Region packs in Settings → Routing…") { model.openSettings(openSettings, tab: .routing) }
            default:
                EmptyView()
            }
        }
        .formStyle(.grouped)
    }

    private var explanation: LocalizedStringKey {
        switch kind {
        case .localNetwork: "Connections to this Mac, the local network (private addresses) and local names such as printer.local always go direct, before any rule, so a Proxy rule for an app never sends its local traffic to the server."
        case .blockQUIC: "Browsers try QUIC (UDP 443) first. Blocking it makes them use TCP, whose site names the rules can read."
        case .proxyPort: "Apps you set to use V2Mac's proxy port yourself can skip the rules and go one way. While the system proxy is on, every app comes through that port, so this is off."
        case .mode: "The routing mode's own rules come after yours. Bypass Regions sends the region packs' sites and addresses direct; Rules Only sends everything direct."
        case .everythingElse: "Traffic no rule matched goes here. “Follow mode” leaves it to the routing mode, which also replaces a custom config's own fallback."
        }
    }
}
