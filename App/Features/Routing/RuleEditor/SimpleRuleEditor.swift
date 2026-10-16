import SwiftUI
import V2MacCore

/// Spec 8.6, simple mode: one list of the apps and sites the rules name and the ones that connected
/// while it is open, grouped by name, each with a Proxy | Direct switch. A change saves the list
/// and, after a short pause, restarts a running core.
struct SimpleRuleEditor: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, new, proxy, direct
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .new: "New"
            case .proxy: "Proxy"
            case .direct: "Direct"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @AppStorage("customRuleList") private var stored = "[]"
    @State private var selection: Set<String> = []
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        let rules = CustomRule.decode(stored)
        let all = items(rules)
        let shown = all.filter(matches)
        let hidden = (SimpleRules.entries(rules, action: .proxy) + SimpleRules.entries(rules, action: .direct)).filter(SeenGroup.isTechnical).count
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                exitLabel
            }
            .padding(12)
            List(selection: $selection) {
                ForEach(shown) { group in GroupRow(group: group, set: set) }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label(all.isEmpty ? "Nothing yet" : "No matches", systemImage: all.isEmpty ? "hourglass" : "magnifyingglass")
                    } description: {
                        Text(model.connection.isRunning ? "Apps and sites appear here as they connect." : "Connect to see which apps and sites connect.")
                    }
                }
            }
            HStack(spacing: 8) {
                Label("App or site not listed? Open it and wait a few seconds for it to appear.", systemImage: "lightbulb")
                    .foregroundStyle(.secondary)
                if hidden > 0 {
                    Text("\(hidden) address rules are in Advanced.").foregroundStyle(.tertiary)
                }
                Spacer()
                if !selection.isEmpty {
                    Text("\(selection.count) selected").foregroundStyle(.secondary)
                    Button("Proxy") { set(Array(selection), .proxy) }
                    Button("Direct") { set(Array(selection), .direct) }
                }
            }
            .font(.callout)
            .padding(12)
        }
        .onAppear { model.connection.watcher.isWatching = true }
        .onDisappear { model.connection.watcher.isWatching = false }
    }

    @ViewBuilder private var exitLabel: some View {
        if case .known(let exit) = model.connection.exit {
            let country = exit.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? ""
            Text("Proxy exits in \([exit.flag, country].compactMap { $0 }.joined(separator: " "))").foregroundStyle(.secondary)
        } else {
            Text(model.connection.isRunning ? "Checking…" : "Not connected").foregroundStyle(.secondary)
        }
    }

    /// The rules' apps and sites, then what connected that no rule covers yet, newest first.
    private func items(_ rules: [CustomRule]) -> [SeenGroup] {
        let ruled = [CustomRule.Action.proxy, .direct].flatMap { action in
            SeenGroup.column(SimpleRules.entries(rules, action: action).filter { !SeenGroup.isTechnical($0) }, action: action)
        }
        let watcher = model.connection.watcher
        let new = (SeenGroup.apps(watcher.apps.values, rules: rules) + SeenGroup.sites(watcher.hosts.values, rules: rules))
            .compactMap { $0.unruled }
        func key(_ group: SeenGroup) -> String { group.title.trimmingCharacters(in: CharacterSet(charactersIn: "*.+")) }
        return new + ruled.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
    }

    private func matches(_ group: SeenGroup) -> Bool {
        let state = group.state
        let passes = switch filter {
        case .all: true
        case .new: group.isNew
        case .proxy: state == .proxy
        case .direct: state == .direct
        }
        return passes && (search.isEmpty || group.members.contains { $0.entry.text.localizedCaseInsensitiveContains(search) }
            || group.entry.text.localizedCaseInsensitiveContains(search))
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

/// Proxy | Direct, the chosen side filled with its colour; choosing it again hands the row back to the mode.
private struct RouteSwitch: View {
    let state: CustomRule.Action?
    let choose: (CustomRule.Action?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach([CustomRule.Action.proxy, .direct], id: \.self) { action in
                let list = RuleList(action)
                let isOn = state == action
                Button { choose(isOn ? nil : action) } label: {
                    Text(list.title)
                        .font(.callout.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 10)
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

/// One group, or one app or site, with its switch; a group opens to show its members.
private struct GroupRow: View {
    let group: SeenGroup
    let set: ([String], CustomRule.Action?) -> Void

    var body: some View {
        if group.members.count == 1, let member = group.members.first {
            row(member.entry, ids: [group.ids[0]], state: member.column, count: member.count, isNew: group.isNew)
        } else {
            DisclosureGroup {
                ForEach(group.members) { member in
                    row(member.entry, ids: [member.id], state: member.column, count: member.count, isNew: group.isNew)
                }
            } label: {
                row(group.entry, ids: group.ids, state: group.state, count: group.members.count, isNew: group.isNew, title: group.title)
            }
        }
    }

    private func row(_ entry: RuleEntry, ids: [String], state: CustomRule.Action?, count: Int, isNew: Bool, title: String? = nil) -> some View {
        let tag = ids.joined(separator: "\n")
        return HStack(spacing: 10) {
            EntryRow(entry: entry, title: title, count: count > 1 ? count : nil)
            if isNew {
                Text("New").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.orange.opacity(0.15), in: .capsule)
            }
            RouteSwitch(state: state) { set([tag], $0) }
        }
        .tag(tag)
        .contextMenu {
            if state != nil { Button("Use the Routing Mode") { set([tag], nil) } }
        }
    }
}

/// A group of seen apps or sites sharing a name; one with a single member is shown as that member.
struct SeenGroup: Identifiable {
    struct Member: Identifiable {
        let entry: RuleEntry
        let count: Int
        let column: CustomRule.Action?
        var id: String { entry.id }
    }

    let entry: RuleEntry
    let members: [Member]
    /// Seen, not yet named by any rule: its row's switch writes `entry` (a group's `*name*`).
    var isNew = false
    var id: String { (isNew ? "new:" : "") + entry.id + (members.first.map { "|" + ($0.column?.rawValue ?? "") } ?? "") }
    var count: Int { members.reduce(0) { $0 + $1.count } }
    var title: String { entry.text.trimmingCharacters(in: CharacterSet(charactersIn: "*")) }
    /// What the row's switch moves.
    var ids: [String] { isNew ? [entry.id] : members.map(\.id) }
    /// The members' common action, nil when they differ or none has one.
    var state: CustomRule.Action? {
        let states = Set(members.map(\.column))
        return states.count == 1 ? states.first ?? nil : nil
    }

    /// The members no rule covers, as a new group; nil when every member is covered.
    var unruled: SeenGroup? {
        let left = members.filter { $0.column == nil }
        guard !left.isEmpty else { return nil }
        let entry = left.count == 1 && members.count > 1 ? left[0].entry : entry
        return SeenGroup(entry: entry, members: left, isNew: true)
    }

    /// IP addresses and ranges: kept out of the simple list, edited in Advanced.
    static func isTechnical(_ entry: RuleEntry) -> Bool {
        entry.kind == .host && (entry.text.first?.isNumber == true || entry.text.contains(":"))
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

    /// A column's entries grouped the same way; a group's row stands for its members.
    static func column(_ entries: [RuleEntry], action: CustomRule.Action) -> [SeenGroup] {
        let members = entries.map { (Member(entry: $0, count: 0, column: action), brand(of: $0)) }
        let keys = EntryGroups.keys(for: Set(members.compactMap(\.1)))
        let byKey = Dictionary(grouping: members) { $0.1.flatMap { keys[$0] } ?? $0.0.entry.text }
        return byKey.map { key, list in
            let entries = list.map(\.0)
            return SeenGroup(entry: entries.count == 1 ? entries[0].entry : RuleEntry(entries[0].entry.kind, key), members: entries)
        }
        .sorted { $0.entry.text.localizedStandardCompare($1.entry.text) == .orderedAscending }
    }

    /// The name an entry is grouped by: a pattern's word, a domain's name, an app's vendor or name.
    private static func brand(of entry: RuleEntry) -> String? {
        var text = entry.text.lowercased()
        if text.hasPrefix("*"), text.hasSuffix("*"), text.count > 2 { return String(text.dropFirst().dropLast()) }
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

/// An app with its icon and name, or a site; a `*word*` group shows as a pattern.
struct EntryRow: View {
    let entry: RuleEntry
    var title: String? = nil
    let count: Int?

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18, height: 18)
            Text(title ?? name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let count { Text(count, format: .number).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .help(entry.text)
    }

    private var name: String {
        guard entry.kind == .app, entry.text.hasPrefix("/") else { return entry.text }
        let name = (entry.text as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The app an entry names, when it is installed: by path, `Name.app` or bundle id.
    private var appPath: String? {
        guard entry.kind == .app else { return nil }
        let text = entry.text
        if text.hasPrefix("/") { return text }
        if text.hasSuffix(".app") {
            return ["/Applications", "/System/Applications", "/Applications/Utilities"].map { $0 + "/" + text }
                .first { FileManager.default.fileExists(atPath: $0) }
        }
        return text.contains(".") ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: text)?.path : nil
    }

    @ViewBuilder private var icon: some View {
        if let path = appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: entry.kind == .app ? "app.dashed" : "globe").foregroundStyle(.secondary)
        }
    }
}
