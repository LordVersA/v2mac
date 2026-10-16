import SwiftUI
import V2MacCore

/// Spec 8.6, simple mode: what made connections on the left, Proxy and Direct columns on the right.
/// Entries move by drag and drop or with the buttons; a move saves the list and, after a short
/// pause, restarts a running core.
struct SimpleRuleEditor: View {
    @Environment(AppModel.self) private var model
    @AppStorage("customRuleList") private var stored = "[]"
    @State private var selection: Set<String> = []
    @State private var applyTask: Task<Void, Never>?

    private var rules: [CustomRule] { CustomRule.decode(stored) }

    var body: some View {
        let rules = rules
        HStack(spacing: 12) {
            SeenPane(rules: rules, selection: $selection, move: move)
                .frame(minWidth: 300)
            RuleColumn(action: .proxy, entries: SimpleRules.entries(rules, action: .proxy), selection: $selection, move: move)
            RuleColumn(action: .direct, entries: SimpleRules.entries(rules, action: .direct), selection: $selection, move: move)
        }
        .padding(12)
        .onAppear { model.connection.watcher.isWatching = true }
        .onDisappear { model.connection.watcher.isWatching = false }
    }

    /// Moves `ids`, and the whole selection when a dragged entry is part of it.
    private func move(_ ids: [String], to action: CustomRule.Action?) {
        let ids = ids.flatMap { $0.split(separator: "\n").map(String.init) }
        let all = ids.contains(where: selection.contains) ? selection.union(ids) : Set(ids)
        let entries = all.compactMap(RuleEntry.init(id:))
        guard !entries.isEmpty else { return }
        withAnimation(.snappy) {
            stored = CustomRule.encode(SimpleRules.move(entries, to: action, in: rules))
            selection.subtract(all)
        }
        applyTask?.cancel()
        applyTask = Task {
            // A run of drags restarts the core once.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            model.connection.reconnectIfRunning()
        }
    }
}

/// One Proxy or Direct column: a drop target listing the entries of that action's rules.
private struct RuleColumn: View {
    @Environment(AppModel.self) private var model
    let action: CustomRule.Action
    let entries: [RuleEntry]
    @Binding var selection: Set<String>
    let move: ([String], CustomRule.Action?) -> Void
    @State private var isTargeted = false

    private var other: CustomRule.Action { action == .proxy ? .direct : .proxy }
    private var list: RuleList { RuleList(action) }

    var body: some View {
        let selected = entries.map(\.id).filter(selection.contains)
        VStack(alignment: .leading, spacing: 8) {
            header
            let apps = SeenGroup.column(entries.filter { $0.kind == .app })
            let sites = SeenGroup.column(entries.filter { $0.kind == .host })
            List(selection: $selection) {
                if !apps.isEmpty { Section("Apps") { ForEach(apps) { group in columnRow(group) } } }
                if !sites.isEmpty { Section("Sites") { ForEach(sites) { group in columnRow(group) } } }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("Drop apps or sites here", systemImage: list.symbol)
                        .foregroundStyle(.secondary)
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                move(ids, action)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(list.tint, lineWidth: 2)
                    .opacity(isTargeted ? 1 : 0)
                    .animation(.snappy, value: isTargeted)
            }
            HStack {
                Button("To \(RuleList(other).title)", systemImage: action == .proxy ? "arrow.right" : "arrow.left") { move(selected, other) }
                    .disabled(selected.isEmpty)
                    .help("Move the selected entries")
                Button("All to \(RuleList(other).title)") { move(entries.map(\.id), other) }
                    .disabled(entries.isEmpty)
                Spacer()
                Button("Remove", systemImage: "minus") { move(selected, nil) }
                    .labelStyle(.iconOnly)
                    .disabled(selected.isEmpty)
                    .help("Remove the selected entries from the rules")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private func columnRow(_ group: SeenGroup) -> some View {
        if group.members.count == 1, let entry = group.members.first?.entry {
            entryRow(entry, ids: [entry.id])
        } else {
            DisclosureGroup {
                ForEach(group.members) { entryRow($0.entry, ids: [$0.id]) }
            } label: {
                entryRow(group.entry, ids: group.members.map(\.id), count: group.members.count)
            }
        }
    }

    private func entryRow(_ entry: RuleEntry, ids: [String], count: Int? = nil) -> some View {
        EntryRow(entry: entry, count: count)
            .tag(ids.count == 1 ? ids[0] : "group:" + entry.id)
            .draggable(ids.joined(separator: "\n"))
            .contextMenu {
                Button("Move to \(RuleList(other).title)") { move(ids, other) }
                Button("Remove", role: .destructive) { move(ids, nil) }
            }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: list.symbol).foregroundStyle(list.tint)
            Text(list.title).font(.headline)
            Spacer()
            if action == .proxy {
                if case .known(let exit) = model.connection.exit {
                    Text([exit.flag, exit.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }].compactMap { $0 }.joined(separator: " "))
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.connection.isRunning ? "Checking…" : "Not connected").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// What made connections while the editor was open, grouped by name, with a hint for the rest.
private struct SeenPane: View {
    @Environment(AppModel.self) private var model
    let rules: [CustomRule]
    @Binding var selection: Set<String>
    let move: ([String], CustomRule.Action?) -> Void
    @State private var isTargeted = false

    var body: some View {
        let watcher = model.connection.watcher
        let apps = SeenGroup.apps(watcher.apps.values, rules: rules)
        let sites = SeenGroup.sites(watcher.hosts.values, rules: rules)
        let selected = Array(selection)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
                Text("Connections").font(.headline)
                Spacer()
                Button("Clear", systemImage: "trash") { watcher.clear() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Clear the list")
            }
            List(selection: $selection) {
                if !apps.isEmpty { Section("Apps") { ForEach(apps) { SeenGroupRow(group: $0, move: move) } } }
                if !sites.isEmpty { Section("Sites") { ForEach(sites) { SeenGroupRow(group: $0, move: move) } } }
            }
            .overlay {
                if apps.isEmpty && sites.isEmpty {
                    ContentUnavailableView {
                        Label(model.connection.isRunning ? "Waiting for connections" : "Not connected", systemImage: "hourglass")
                    } description: {
                        Text(model.connection.isRunning ? "Apps and sites appear here as they connect." : "Connect to see which apps and sites connect.")
                    }
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                move(ids, nil)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary, lineWidth: 2).opacity(isTargeted ? 1 : 0)
            }
            Label("App or site not listed? Open it and wait a few seconds for it to appear.", systemImage: "lightbulb")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("To Proxy", systemImage: "arrow.right") { move(selected, .proxy) }
                Button("To Direct", systemImage: "arrow.right") { move(selected, .direct) }
            }
            .controlSize(.small)
            .disabled(selected.isEmpty)
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
    var id: String { entry.id }
    var count: Int { members.reduce(0) { $0 + $1.count } }

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
    static func column(_ entries: [RuleEntry]) -> [SeenGroup] {
        let members = entries.map { (Member(entry: $0, count: 0, column: nil), brand(of: $0)) }
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

private struct SeenGroupRow: View {
    let group: SeenGroup
    let move: ([String], CustomRule.Action?) -> Void

    var body: some View {
        if group.members.count == 1, let member = group.members.first {
            row(member.entry, count: member.count, column: member.column)
        } else {
            DisclosureGroup {
                ForEach(group.members) { row($0.entry, count: $0.count, column: $0.column) }
            } label: {
                let columns = Set(group.members.map(\.column))
                row(group.entry, count: group.count, column: columns.count == 1 ? columns.first ?? nil : nil)
            }
        }
    }

    private func row(_ entry: RuleEntry, count: Int, column: CustomRule.Action?) -> some View {
        HStack {
            EntryRow(entry: entry, count: count)
            if let column {
                // Already covered by a rule: shown, but marked with where it goes.
                Image(systemName: RuleList(column).symbol)
                    .foregroundStyle(RuleList(column).tint)
                    .help(Text("Goes to \(RuleList(column).title) by a rule"))
            }
        }
        .tag(entry.id)
        .draggable(entry.id)
        .contextMenu {
            Button("Send to Proxy") { move([entry.id], .proxy) }
            Button("Send Direct") { move([entry.id], .direct) }
        }
    }
}

/// An app with its icon and name, or a site; a `*word*` group shows as a pattern.
struct EntryRow: View {
    let entry: RuleEntry
    let count: Int?

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18, height: 18)
            Text(title).lineLimit(1).truncationMode(.middle)
            // Only a seen group's row is a new pattern; a rule's own `*word*` entry is just text.
            if count != nil, entry.text.hasPrefix("*") {
                Text("group").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: .capsule)
            }
            Spacer(minLength: 4)
            if let count { Text(count, format: .number).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .help(entry.text)
    }

    private var title: String {
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
