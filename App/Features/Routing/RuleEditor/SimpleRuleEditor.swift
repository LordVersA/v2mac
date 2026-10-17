import SwiftUI
import UniformTypeIdentifiers
import V2MacCore

/// Spec 8.6: saved apps and hosts stay separate from the live discovery inbox.
struct SimpleRuleEditor: View {
    enum Library: String, CaseIterable, Identifiable {
        case apps, hosts, discovered
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .apps: "Apps"
            case .hosts: "Hosts"
            case .discovered: "Discovered"
            }
        }
        var symbol: String {
            switch self {
            case .apps: "square.grid.2x2"
            case .hosts: "globe"
            case .discovered: "tray"
            }
        }
        func contains(_ group: SeenGroup) -> Bool {
            switch self {
            case .apps: !group.isNew && group.entry.kind == .app
            case .hosts: !group.isNew && group.entry.kind == .host
            case .discovered: group.isNew
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("customRuleList") private var stored = "[]"
    @AppStorage("ruleEditorMode") private var mode = RuleEditorView.Mode.simple
    @State private var library = Library.apps
    @State private var selection: Set<String> = []
    @State private var route: CustomRule.Action?
    @State private var search = ""
    @State private var isAdding = false
    @State private var isImporting = false
    @State private var importedProfile: RuleImport?
    @State private var importError: String?
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        let rules = CustomRule.decode(stored)
        let groups = SeenGroup.all(rules: rules, watcher: model.connection.watcher)
        let scoped = groups.filter(library.contains)
        let shown = scoped.filter(matches)
        HStack(spacing: 0) {
            sidebar(groups: groups, hidden: SeenGroup.hiddenCount(rules))
            Divider()
            VStack(spacing: 0) {
                header(count: scoped.count)
                Divider()
                HStack {
                    SearchField(prompt: "Search apps and hosts", text: $search)
                        .frame(maxWidth: .infinity)
                    if library != .discovered {
                        Picker("Route", selection: $route) {
                            Text("All routes").tag(Optional<CustomRule.Action>.none)
                            ForEach(CustomRule.Action.allCases, id: \.self) { action in
                                Text(RuleList(action).title).tag(Optional(action))
                            }
                        }
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                List(selection: $selection) {
                    if library == .discovered {
                        section("Apps", groups: shown.filter { $0.entry.kind == .app })
                        section("Hosts", groups: shown.filter { $0.entry.kind == .host })
                    } else {
                        ForEach(shown) { group in row(group) }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if shown.isEmpty { emptyState(hasItems: !scoped.isEmpty) }
                }
                Divider()
                footer(shown: shown)
            }
            .background(.background)
        }
        .sheet(isPresented: $isAdding) {
            SimpleRuleAddSheet(initialKind: library == .hosts ? .host : .app) { entries, action in
                save(entries, action)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: RuleImportSheet.fileTypes) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                importedProfile = try RuleImport(data: Data(contentsOf: url))
            } catch {
                if (error as NSError).code != NSUserCancelledError { importError = error.localizedDescription }
            }
        }
        .sheet(isPresented: Binding { importedProfile != nil } set: { if !$0 { importedProfile = nil } }) {
            if let profile = importedProfile {
                RuleImportSheet(profile: profile) { importProfile(profile) }
            }
        }
        .alert("Could not import profile", isPresented: Binding { importError != nil } set: { if !$0 { importError = nil } }) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
        .task {
            #if DEBUG
            // `-debugProxifierImport <path>` opens the import review on that file, for `-debugSnapshot`.
            if let path = UserDefaults.standard.string(forKey: "debugProxifierImport") {
                importedProfile = try? RuleImport(data: Data(contentsOf: URL(fileURLWithPath: path)))
            }
            #endif
            await EntryIcons.shared.load()
        }
        .onAppear { model.connection.watcher.watch() }
        .onDisappear { model.connection.watcher.unwatch() }
        .onChange(of: library) { selection.removeAll(); route = nil; search = "" }
        .onChange(of: search) { selection.removeAll() }
        .onChange(of: route) { selection.removeAll() }
        .onChange(of: stored) { selection.removeAll() }
    }

    private func sidebar(groups: [SeenGroup], hidden: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Routing library")
                .font(.headline)
                .padding(20)
            VStack(spacing: 4) {
                ForEach(Library.allCases) { item in
                    if item == .discovered { Divider().padding(.vertical, 10) }
                    Button {
                        library = item
                    } label: {
                        HStack(spacing: 10) {
                            Label(item.title, systemImage: item.symbol)
                            Spacer(minLength: 4)
                            Text(groups.filter(item.contains).count.formatted())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(library == item ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(library == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("Changes save automatically", systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium))
                Text("Host rules take priority over app rules created here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(hidden > 0 ? String(localized: "Advanced · \(hidden) address rules") : String(localized: "Advanced rules")) {
                    mode = .advanced
                }
                .buttonStyle(.link)
                .padding(.top, 4)
            }
            .padding(20)
        }
        .frame(width: 204)
        .background(.bar)
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(library.title).font(.title2.weight(.semibold))
                    Text(count.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(library == .discovered
                     ? "Review recent connections. Choose a route to add them to your library."
                     : "Choose how each group connects. Expand a group to fine-tune its members.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if library == .apps {
                    Text("App rules apply to proxy connections. TUN uses host rules.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Import…", systemImage: "square.and.arrow.down") { isImporting = true }
                    .help("Import rules from Proxifier, Clash, sing-box, v2rayN or Shadowrocket")
                Button("Add…", systemImage: "plus") { isAdding = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, groups: [SeenGroup]) -> some View {
        if !groups.isEmpty {
            Section { ForEach(groups) { group in row(group) } } header: { Text(title) }
        }
    }

    private func row(_ group: SeenGroup) -> some View {
        GroupRow(group: group, set: set) { id in
            model.focusedRule = id
            mode = .advanced
        }
    }

    private func emptyState(hasItems: Bool) -> some View {
        ContentUnavailableView {
            Label(hasItems ? "No matches" : library == .discovered ? "You're all caught up" : "Build your routing library",
                  systemImage: hasItems ? "magnifyingglass" : library.symbol)
        } description: {
            Text(hasItems ? "Try another search or route filter."
                 : library == .discovered ? "New apps and hosts appear here as they connect while this window is open."
                 : "Add apps or hosts yourself, or pick them from Discovered.")
        } actions: {
            if !hasItems && library != .discovered {
                Button("Add…", systemImage: "plus") { isAdding = true }
                Button("Review Discovered") { library = .discovered }
            }
        }
    }

    private func footer(shown: [SeenGroup]) -> some View {
        HStack(spacing: 10) {
            if selection.isEmpty {
                Text(library == .discovered ? "Discovered items use your routing mode until you assign a route." : "Select multiple rows to change their route together.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("\(selection.count) selected").fontWeight(.medium)
                Button("Deselect") { selection.removeAll() }
                Spacer()
                ForEach(CustomRule.Action.allCases, id: \.self) { action in
                    Button(RuleList(action).title) { set(Array(selection), action) }
                        .tint(RuleList(action).tint)
                }
                if library != .discovered {
                    Button("Use Routing Mode") { set(Array(selection), nil) }
                }
            }
            if selection.isEmpty && !shown.isEmpty {
                Button("Select All") { selection = Set(shown.map { $0.ids.joined(separator: "\n") }) }
            }
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func matches(_ group: SeenGroup) -> Bool {
        guard route == nil || group.state == route else { return false }
        return search.isEmpty || group.title.localizedCaseInsensitiveContains(search)
            || group.members.contains { $0.entry.text.localizedCaseInsensitiveContains(search) }
    }

    private func set(_ ids: [String], _ action: CustomRule.Action?) {
        let entries = ids.flatMap { $0.split(separator: "\n").map(String.init) }.compactMap(RuleEntry.init(id:))
        save(entries, action)
    }

    private func importProfile(_ profile: RuleImport) {
        stored = CustomRule.encode(CustomRule.decode(stored) + profile.rules)
        if profile.blockQUIC { UserDefaults.standard.set(true, forKey: "blockQUIC") }
        importedProfile = nil
        selection.removeAll()
        applyTask?.cancel()
        model.connection.reconnectIfRunning()
    }

    private func save(_ entries: [RuleEntry], _ action: CustomRule.Action?) {
        guard !entries.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .snappy) {
            stored = CustomRule.encode(SimpleRules.move(entries, to: action, in: CustomRule.decode(stored)))
            selection.removeAll()
        }
        applyTask?.cancel()
        applyTask = Task {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            // One slot on every row, so icons line up whether or not there is a chevron.
            ZStack {
                if let isExpanded {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy) { isExpanded.wrappedValue.toggle() }
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
                Text(title).fontWeight(indent == 0 ? .medium : .regular).lineLimit(1).truncationMode(.middle).help(entry.text)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let rule { RuleBadge(name: rule.name, action: state) { showAdvanced(rule.id) } }
            RouteSwitch(state: state) { set([tag], $0) }
        }
        .padding(.vertical, 8)
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

/// One explicit route menu keeps long lists quiet and makes returning to the mode discoverable.
private struct RouteSwitch: View {
    let state: CustomRule.Action?
    let choose: (CustomRule.Action?) -> Void

    var body: some View {
        let route = state.map(RuleList.init)
        Menu {
            Button("Use Routing Mode", systemImage: "arrow.triangle.branch") { choose(nil) }
            Divider()
            ForEach(CustomRule.Action.allCases, id: \.self) { action in
                Button {
                    choose(action)
                } label: {
                    Label(RuleList(action).title, systemImage: state == action ? "checkmark" : RuleList(action).symbol)
                }
            }
        } label: {
            Label(route?.title ?? String(localized: "Routing Mode"), systemImage: route?.symbol ?? "arrow.triangle.branch")
                .font(.callout.weight(.medium))
                .foregroundStyle(route?.tint ?? .secondary)
                .frame(width: 126, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Route")
        .accessibilityValue(route?.title ?? String(localized: "Routing Mode"))
    }
}

struct EntryIcon: View {
    private var icons: EntryIcons { .shared }
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
