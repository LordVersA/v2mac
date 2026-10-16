import SwiftUI
import V2MacCore

/// Spec 8.6, simple mode: the apps and sites the rules name and the ones that connected while it is
/// open, grouped by name, each with a Proxy | Direct switch. A change saves the list and, after a
/// short pause, restarts a running core.
struct SimpleRuleEditor: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, proxy, direct, block
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .proxy: "Proxy"
            case .direct: "Direct"
            case .block: "Block"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @AppStorage("customRuleList") private var stored = "[]"
    @AppStorage("ruleEditorMode") private var mode = RuleEditorView.Mode.simple
    @State private var selection: Set<String> = []
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var icons = EntryIcons()
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        let rules = CustomRule.decode(stored)
        let groups = SeenGroup.all(rules: rules, watcher: model.connection.watcher)
        let shown = groups.filter(matches)
        VStack(spacing: 0) {
            header
            List(selection: $selection) {
                section("New", systemImage: "sparkles", shown.filter(\.isNew))
                section("Apps", systemImage: "square.grid.2x2", shown.filter { !$0.isNew && $0.entry.kind == .app })
                section("Sites", systemImage: "globe", shown.filter { !$0.isNew && $0.entry.kind == .host })
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label(groups.isEmpty ? "Nothing yet" : "No matches", systemImage: groups.isEmpty ? "hourglass" : "magnifyingglass")
                    } description: {
                        Text(model.connection.isRunning ? "Apps and sites appear here as they connect." : "Connect to see which apps and sites connect.")
                    }
                }
            }
            footer(hidden: SeenGroup.hiddenCount(rules))
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Apps and sites")
        .environment(icons)
        .task { await icons.load() }
        .onAppear { model.connection.watcher.isWatching = true }
        .onDisappear { model.connection.watcher.isWatching = false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            exitLabel
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var exitLabel: some View {
        HStack(spacing: 6) {
            if case .known(let exit) = model.connection.exit {
                Text(exit.flag ?? "🌐")
                Text("Proxy exits in \(exit.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? "")")
            } else {
                Image(systemName: "bolt.horizontal.circle")
                Text(model.connection.isRunning ? "Checking…" : "Not connected")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: .capsule)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, systemImage: String, _ groups: [SeenGroup]) -> some View {
        if !groups.isEmpty {
            Section {
                ForEach(groups) { group in
                    GroupRow(group: group, set: set) { id in
                        model.focusedRule = id
                        mode = .advanced
                    }
                }
            } header: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    private func footer(hidden: Int) -> some View {
        HStack(spacing: 10) {
            if selection.isEmpty {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
                Text("Not listed? Open the app or site and wait a few seconds.")
                    .foregroundStyle(.secondary)
                Spacer()
                if hidden > 0 {
                    Button("\(hidden) address rules in Advanced") { mode = .advanced }
                        .buttonStyle(.link)
                }
            } else {
                Text("\(selection.count) selected").fontWeight(.medium)
                Spacer()
                Button("Deselect") { selection.removeAll() }
                Button("Proxy") { set(Array(selection), .proxy) }.tint(.blue)
                Button("Direct") { set(Array(selection), .direct) }.tint(.green)
                Button("Block") { set(Array(selection), .block) }.tint(.red)
            }
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func matches(_ group: SeenGroup) -> Bool {
        let passes = switch filter {
        case .all: true
        case .proxy: group.state == .proxy
        case .direct: group.state == .direct
        case .block: group.state == .block
        }
        guard passes else { return false }
        return search.isEmpty || group.title.localizedCaseInsensitiveContains(search)
            || group.members.contains { $0.entry.text.localizedCaseInsensitiveContains(search) }
    }

    /// Sends `ids` to `action`; nil hands them back to the routing mode. Group rows carry their members' ids.
    private func set(_ ids: [String], _ action: CustomRule.Action?) {
        let ids = ids.flatMap { $0.split(separator: "\n").map(String.init) }
        let entries = ids.compactMap(RuleEntry.init(id:))
        guard !entries.isEmpty else { return }
        withAnimation(.snappy) {
            stored = CustomRule.encode(SimpleRules.move(entries, to: action, in: CustomRule.decode(stored)))
            selection.removeAll()
        }
        applyTask?.cancel()
        applyTask = Task {
            // A run of changes restarts the core once.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            model.connection.reconnectIfRunning()
        }
    }
}

/// One group, or one app or site, with its switch; a group opens to show its members, indented below it.
private struct GroupRow: View {
    let group: SeenGroup
    let set: ([String], CustomRule.Action?) -> Void
    let showAdvanced: (UUID) -> Void
    @State private var isExpanded = false

    var body: some View {
        if group.members.count == 1, let member = group.members.first {
            EntryLine(entry: member.entry, title: group.title, subtitle: group.subtitle, rule: member.rule.map { ($0.name, $0.id) },
                      state: member.column, tag: group.ids[0], set: set, showAdvanced: showAdvanced)
        } else {
            EntryLine(entry: group.members[0].entry, title: group.title, subtitle: group.subtitle, rule: group.rule,
                      state: group.state, tag: group.ids.joined(separator: "\n"), set: set, showAdvanced: showAdvanced,
                      isExpanded: $isExpanded)
            if isExpanded {
                ForEach(group.members) { member in
                    EntryLine(entry: member.entry, title: SeenGroup.displayName(member.entry), subtitle: nil,
                              rule: member.rule.map { ($0.name, $0.id) }, state: member.column, tag: member.id,
                              set: set, showAdvanced: showAdvanced, indent: 1)
                }
            }
        }
    }
}

private struct EntryLine: View {
    let entry: RuleEntry
    let title: String
    let subtitle: String?
    let rule: (name: String, id: UUID)?
    let state: CustomRule.Action?
    let tag: String
    let set: ([String], CustomRule.Action?) -> Void
    let showAdvanced: (UUID) -> Void
    /// Set for a group's row, which then shows a chevron.
    var isExpanded: Binding<Bool>? = nil
    var indent = 0

    var body: some View {
        HStack(spacing: 10) {
            // One slot on every row, so icons line up whether or not there is a chevron.
            ZStack {
                if let isExpanded {
                    Button {
                        withAnimation(.snappy) { isExpanded.wrappedValue.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                            .frame(width: 16, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded.wrappedValue ? "Collapse" : "Expand")
                }
            }
            .frame(width: 16)
            .padding(.leading, CGFloat(indent) * 26)
            EntryIcon(entry: entry)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let rule { RuleBadge(name: rule.name, action: state) { showAdvanced(rule.id) } }
            RouteSwitch(state: state) { set([tag], $0) }
        }
        .padding(.vertical, 3)
        .tag(tag)
        .contextMenu {
            Button("Proxy") { set([tag], .proxy) }
            Button("Direct") { set([tag], .direct) }
            Button("Block") { set([tag], .block) }
            if state != nil {
                Divider()
                Button("Use the Routing Mode") { set([tag], nil) }
            }
        }
    }
}

/// The rule a row comes from; a click opens Advanced, where the rule is edited.
private struct RuleBadge: View {
    let name: String
    let action: CustomRule.Action?
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        let tint = action.map { RuleList($0).tint } ?? .secondary
        Button(action: open) {
            HStack(spacing: 4) {
                Text(name).lineLimit(1)
                if isHovering { Image(systemName: "arrow.up.forward").transition(.opacity) }
            }
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(isHovering ? 0.24 : 0.12), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 220, alignment: .trailing)
        .help("Go to Advanced")
        .onHover { hovering in withAnimation(.snappy) { isHovering = hovering } }
    }
}

/// Proxy | Direct | Block, the chosen side filled with its colour; choosing it again hands the row back to the mode.
private struct RouteSwitch: View {
    let state: CustomRule.Action?
    let choose: (CustomRule.Action?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CustomRule.Action.allCases, id: \.self) { action in
                let list = RuleList(action)
                let isOn = state == action
                Button { choose(isOn ? nil : action) } label: {
                    Text(list.title)
                        .font(.caption.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(minWidth: 46)
                        .padding(.vertical, 3)
                        .background(isOn ? list.tint : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .animation(.snappy, value: state)
    }
}

private struct EntryIcon: View {
    @Environment(EntryIcons.self) private var icons
    let entry: RuleEntry

    var body: some View {
        Group {
            switch icons.icon(for: entry) {
            case .image(let image): Image(nsImage: image).resizable().scaledToFit()
            case .symbol(let name, let color):
                Image(systemName: name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.15), in: .rect(cornerRadius: 6))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// A group of apps or sites sharing a name; one with a single member is shown as that member.
struct SeenGroup: Identifiable {
    struct Member: Identifiable {
        let entry: RuleEntry
        let count: Int
        let column: CustomRule.Action?
        var rule: CustomRule?
        var id: String { entry.id }
    }

    let entry: RuleEntry
    let members: [Member]
    /// Seen, not yet named by any rule: its row's switch writes `entry` (a group's `*name*`).
    var isNew = false
    var id: String { (isNew ? "new:" : "") + entry.id + (members.first.map { "|" + ($0.column?.rawValue ?? "") } ?? "") }
    var count: Int { members.reduce(0) { $0 + $1.count } }
    var title: String { members.count == 1 ? Self.displayName(members[0].entry) : entry.text.trimmingCharacters(in: CharacterSet(charactersIn: "*")) }
    /// What the row's switch moves.
    var ids: [String] { isNew ? [entry.id] : members.map(\.id) }
    /// The members' common action, nil when they differ or none has one.
    var state: CustomRule.Action? {
        let states = Set(members.map(\.column))
        return states.count == 1 ? states.first ?? nil : nil
    }

    /// The one rule all members come from; with several, the first, named as a count.
    var rule: (name: String, id: UUID)? {
        let rules = members.compactMap(\.rule)
        guard let first = rules.first else { return nil }
        let count = Set(rules.map(\.id)).count
        return (count > 1 ? String(localized: "\(count) rules") : first.name, first.id)
    }

    var subtitle: String? {
        let n = members.count
        if n > 1 { return entry.kind == .app ? String(localized: "\(n) apps") : String(localized: "\(n) sites") }
        let text = members[0].entry.text
        if isNew, count > 0 { return String(localized: "Connected \(count) times") }
        if entry.kind == .host, ["*.", "+.", ".", "domain:"].contains(where: text.hasPrefix) { return String(localized: "and its subdomains") }
        if entry.kind == .app, text.hasPrefix("/") { return (text as NSString).deletingLastPathComponent }
        return nil
    }

    /// An entry without its pattern marks: `*Books.app*` → Books, `*.mac.com` → mac.com.
    static func displayName(_ entry: RuleEntry) -> String {
        var text = entry.text
        for prefix in ["domain:", "full:", "keyword:", "*.", "+."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        if entry.kind == .app {
            if text.hasPrefix("/") { text = (text as NSString).lastPathComponent }
            if text.lowercased().hasSuffix(".app") { text.removeLast(4) }
        }
        return text.isEmpty ? entry.text : text
    }

    /// IP addresses and ranges: kept out of the simple list, edited in Advanced.
    static func isTechnical(_ entry: RuleEntry) -> Bool {
        entry.kind == .host && (entry.text.first?.isNumber == true || entry.text.contains(":"))
    }

    static func hiddenCount(_ rules: [CustomRule]) -> Int {
        CustomRule.Action.allCases.flatMap { SimpleRules.entries(rules, action: $0) }.filter(isTechnical).count
    }

    /// What connected that no rule covers yet, busiest first, then the rules' apps and sites by name.
    @MainActor static func all(rules: [CustomRule], watcher: ConnectionWatcher) -> [SeenGroup] {
        let ruled = CustomRule.Action.allCases.flatMap { action in
            column(SimpleRules.entries(rules, action: action).filter { !isTechnical($0) }, action: action,
                   sources: SimpleRules.sourceRules(rules, action: action))
        }
        let new = (apps(watcher.apps.values, rules: rules) + sites(watcher.hosts.values, rules: rules)).compactMap(\.unruled)
        return new + ruled.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The members no rule covers, as a new group; nil when every member is covered.
    var unruled: SeenGroup? {
        let left = members.filter { $0.column == nil }
        guard !left.isEmpty else { return nil }
        let entry = left.count == 1 && members.count > 1 ? left[0].entry : entry
        return SeenGroup(entry: entry, members: left, isNew: true)
    }

    static func apps(_ seen: some Collection<ConnectionWatcher.Seen>, rules: [CustomRule]) -> [SeenGroup] {
        let members = seen.map { app in
            let bundleID = Bundle(path: app.id)?.bundleIdentifier ?? ""
            return (Member(entry: RuleEntry(.app, app.id), count: app.count,
                           column: SimpleRules.action(forApp: app.id, bundleID: bundleID, in: rules)),
                    EntryGroups.brand(ofBundleID: bundleID))
        }
        return grouped(members, kind: .app)
    }

    static func sites(_ seen: some Collection<ConnectionWatcher.Seen>, rules: [CustomRule]) -> [SeenGroup] {
        let members = seen.map { host in
            (Member(entry: RuleEntry(.host, host.id), count: host.count, column: SimpleRules.action(forHost: host.id, in: rules)),
             EntryGroups.brand(ofHost: host.id))
        }
        return grouped(members, kind: .host)
    }

    /// One action's rule entries grouped the same way; a group's row stands for its members.
    static func column(_ entries: [RuleEntry], action: CustomRule.Action, sources: [String: CustomRule]) -> [SeenGroup] {
        let members = entries.map { (Member(entry: $0, count: 0, column: action, rule: sources[$0.id]), brand(of: $0)) }
        let keys = EntryGroups.keys(for: Set(members.compactMap(\.1)))
        let byKey = Dictionary(grouping: members) { $0.1.flatMap { keys[$0] } ?? $0.0.entry.text }
        return byKey.map { key, list in
            let entries = list.map(\.0)
            return SeenGroup(entry: entries.count == 1 ? entries[0].entry : RuleEntry(entries[0].entry.kind, key), members: entries)
        }
    }

    /// The name an entry is grouped by: a pattern's word, a domain's name, an app's vendor or name.
    static func brand(of entry: RuleEntry) -> String? {
        var text = entry.text.lowercased()
        if text.count > 2, text.hasPrefix("*"), text.hasSuffix("*") { text = String(text.dropFirst().dropLast()) }
        for prefix in ["*.", "+.", ".", "domain:", "full:", "keyword:"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        // Addresses and ranges stay on their own rows.
        guard entry.kind == .app else { return text.first?.isNumber == true || text.contains(":") ? nil : EntryGroups.brand(ofHost: text) }
        if text.hasPrefix("/") { return Bundle(path: entry.text).flatMap { $0.bundleIdentifier }.flatMap(EntryGroups.brand(ofBundleID:)) ?? (text as NSString).lastPathComponent }
        if text.hasSuffix(".app") { return String(text.dropLast(4)) }
        return EntryGroups.brand(ofBundleID: text) ?? text
    }

    private static func grouped(_ members: [(Member, String?)], kind: RuleEntry.Kind) -> [SeenGroup] {
        let keys = EntryGroups.keys(for: Set(members.compactMap(\.1)))
        let byKey = Dictionary(grouping: members) { $0.1.flatMap { keys[$0] } ?? $0.0.entry.text }
        return byKey.map { key, list in
            let sorted = list.map(\.0).sorted { $0.count > $1.count }
            return SeenGroup(entry: sorted.count == 1 ? sorted[0].entry : RuleEntry(kind, "*\(key)*"), members: sorted)
        }
        .sorted { $0.count > $1.count }
    }
}
