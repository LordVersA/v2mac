import SwiftUI
import V2MacCore

/// Spec 12.10: every connection through the core, live, with its app, target, rule and traffic,
/// above a log of opens and closes. Recorded only while this window or the rule editor is open.
struct ConnectionsView: View {
    static let windowID = "connections"

    enum Tab: String { case list, map }

    enum Grouping: String, CaseIterable, Identifiable {
        case none, host, application
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .none: "No grouping"
            case .host: "By Host"
            case .application: "By Application"
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, open
        var id: Self { self }
        var title: LocalizedStringKey { self == .all ? "All" : "Open" }
    }

    @Environment(AppModel.self) private var model
    @State private var selection: Set<ConnectionGroup.Row.ID> = []
    @State private var expanded: Set<ConnectionGroup.Row.ID> = []
    @State private var filter = Filter.all
    @State private var actionFilter: CustomRule.Action?
    @AppStorage("connectionsTab") private var tab = Tab.list
    @AppStorage("connectionsGrouping") private var grouping = Grouping.none
    @State private var search = ""
    /// The column and direction, kept across launches: `<column>:<asc|desc>`.
    @AppStorage("connectionsSort") private var storedSort = "time:desc"

    typealias Row = ConnectionGroup.Row
    private static let columns: [String: KeyPathComparator<Row>] = [
        "app": KeyPathComparator(\Row.appName), "target": KeyPathComparator(\Row.target),
        "time": KeyPathComparator(\Row.start), "rule": KeyPathComparator(\Row.outbound),
        "sent": KeyPathComparator(\Row.sent), "received": KeyPathComparator(\Row.received),
    ]

    private var sortOrder: Binding<[KeyPathComparator<Row>]> {
        Binding {
            let parts = storedSort.split(separator: ":").map(String.init)
            guard var comparator = Self.columns[parts.first ?? ""] else { return [KeyPathComparator(\Row.start, order: .reverse)] }
            comparator.order = parts.last == "asc" ? .forward : .reverse
            return [comparator]
        } set: { order in
            guard let first = order.first, let key = Self.columns.first(where: { $0.value.keyPath == first.keyPath })?.key else { return }
            storedSort = key + (first.order == .forward ? ":asc" : ":desc")
        }
    }

    private var watcher: ConnectionWatcher { model.connection.watcher }

    var body: some View {
        Group {
            switch tab {
            case .list: list
            case .map: ConnectionMapView()
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Apps and targets")
        .navigationSubtitle(summary)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    Label("Connections", systemImage: "list.bullet").tag(Tab.list)
                    Label("Map", systemImage: "globe.europe.africa.fill").tag(Tab.map)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
            }
            if tab == .list {
                ToolbarItem {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    Menu {
                        Picker("Filter by route", selection: $actionFilter) {
                            Text("All").tag(Optional<CustomRule.Action>.none)
                            ForEach(CustomRule.Action.allCases, id: \.self) { action in
                                Text(RuleList(action).title).tag(Optional(action))
                            }
                        }
                    } label: {
                        Label(actionFilter.map { RuleList($0).title } ?? String(localized: "All"), systemImage: "line.3.horizontal.decrease")
                    }
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .help("Filter by route")
                }
                ToolbarItem {
                    Menu {
                        Picker("Group by", selection: $grouping) {
                            ForEach(Grouping.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Text(grouping.title)
                    }
                    .fixedSize()
                    .help("Group by")
                }
                ToolbarItem {
                    Button("Clear", systemImage: "trash") { watcher.clear() }
                        .help("Clear closed connections and the log")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .task { await EntryIcons.shared.load() }
        .onAppear { watcher.watch() }
        .onDisappear { watcher.unwatch() }
        #if DEBUG
        .task { if UserDefaults.standard.bool(forKey: "debugDemoData") { watcher.addDemoConnections() } }
        #endif
    }

    @ViewBuilder private var list: some View {
        let rows = watcher.connections.filter(matches).map(Row.connection).sorted(using: sortOrder.wrappedValue)
        let groups = grouping == .none ? [] : ConnectionGroup.make(rows.compactMap(\.connection), by: grouping == .host ? .host : .app)
            .map(Row.group).sorted(using: sortOrder.wrappedValue)
        VSplitView {
            table(rows, groups: groups)
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label(model.connection.isRunning ? "No connections yet" : "Not connected", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Connections appear here while this window is open.")
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(minHeight: 260, idealHeight: 520)
            EventLog(events: watcher.events, search: search)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.35))
                .clipShape(.rect(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 100, idealHeight: 170, maxHeight: 420)
        }
    }

    private func table(_ rows: [Row], groups: [Row]) -> some View {
        Table(of: Row.self, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Application", value: \.appName) { row in
                if let connection = row.connection {
                    AppCell(connection: connection)
                } else if let group = row.group {
                    HStack(spacing: 8) {
                        EntryIcon(entry: group.entry).scaleEffect(0.8).frame(width: 20, height: 20)
                        Text(group.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .width(min: 140, ideal: 180)
            TableColumn("Target", value: \.target) { row in
                if let connection = row.connection {
                    Text(connection.target).lineLimit(1).truncationMode(.middle).help(connection.target)
                } else if let group = row.group {
                    HStack(spacing: 4) {
                        Text("Connections")
                        Text(group.connections.count, format: .number)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Time", value: \.start) { row in
                if let connection = row.connection {
                    StatusCell(connection: connection)
                } else if let group = row.group {
                    Text("\(group.openCount) open").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 64, ideal: 76)
            TableColumn("Rule", value: \.outbound) { row in
                if let connection = row.connection { RuleCell(connection: connection) }
            }
            .width(min: 120, ideal: 190)
            TableColumn("Sent", value: \.sent) { row in BytesCell(bytes: row.sent, isKnown: row.hasTrackedTraffic) }
                .width(min: 60, ideal: 72)
            TableColumn("Received", value: \.received) { row in BytesCell(bytes: row.received, isKnown: row.hasTrackedTraffic) }
                .width(min: 60, ideal: 72)
        } rows: {
            if grouping == .none {
                ForEach(rows) { TableRow($0) }
            } else {
                ForEach(groups) { group in
                    DisclosureTableRow(group, isExpanded: Binding {
                        expanded.contains(group.id)
                    } set: { open in
                        if open { expanded.insert(group.id) } else { expanded.remove(group.id) }
                    }) {
                        ForEach(group.children) { TableRow($0) }
                    }
                }
            }
        }
        .alternatingRowBackgrounds()
    }

    private var summary: String {
        let open = watcher.connections.filter(\.isOpen)
        let sent = open.reduce(0) { $0 + $1.sent }, received = open.reduce(0) { $0 + $1.received }
        return String(localized: "\(open.count) open · ↑ \(sent.formatted(Self.bytes)) · ↓ \(received.formatted(Self.bytes))")
    }

    private func matches(_ row: ConnectionWatcher.Connection) -> Bool {
        row.matches(search: search, onlyOpen: filter == .open, action: actionFilter)
    }
}

private struct AppCell: View {
    let connection: ConnectionWatcher.Connection

    static func name(of app: String) -> String {
        let last = (app as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    var body: some View {
        HStack(spacing: 8) {
            if let app = connection.app {
                EntryIcon(entry: RuleEntry(.app, app)).scaleEffect(0.8).frame(width: 20, height: 20)
                Text(Self.name(of: app)).lineLimit(1)
            } else {
                Image(systemName: connection.inbound == ConfigBuilder.inboundTag ? "questionmark.app.dashed" : "network")
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
                Text(connection.process ?? (connection.inbound == ConfigBuilder.inboundTag ? String(localized: "Unknown") : String(localized: "Unknown app")))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(connection.app ?? "")
    }
}

private struct StatusCell: View {
    let connection: ConnectionWatcher.Connection

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connection.isOpen ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            if connection.isOpen {
                TimelineView(.periodic(from: connection.start, by: 1)) { context in
                    Text(Self.duration(context.date.timeIntervalSince(connection.start)))
                }
            } else if let end = connection.end {
                Text(Self.duration(end.timeIntervalSince(connection.start))).foregroundStyle(.secondary)
            } else {
                Text(verbatim: "—").foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .accessibilityLabel(connection.isOpen ? Text("Open") : Text("Closed"))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(seconds, 0)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// The outbound the core chose, tinted, with the custom rule that most likely sent it there.
private struct RuleCell: View {
    let connection: ConnectionWatcher.Connection

    var body: some View {
        let action = connection.action
        let viaProxySetting = connection.skipsRules
        let rule = viaProxySetting ? nil : matchingRule(action)
        let fromConfig = rule == nil && connection.configFallback
        let tint: Color = viaProxySetting ? .orange : fromConfig ? .purple : action.map { RuleList($0).tint } ?? .secondary
        HStack(spacing: 6) {
            Text(action.map { RuleList($0).title } ?? connection.outbound)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(tint.opacity(0.14), in: .capsule)
                .fixedSize()
            if viaProxySetting {
                Label("App's proxy setting", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("This app was set to use V2Mac's proxy port, so it goes to the server without any rule.")
            } else if fromConfig {
                Label("Config fallback", systemImage: "arrow.turn.down.right")
                    .foregroundStyle(.purple)
                    .lineLimit(1)
            } else {
                Text(rule?.name ?? connection.routingMode.map { String(localized: "No rule · \($0.title)") } ?? String(localized: "Custom routing"))
                    .foregroundStyle(rule == nil ? .tertiary : .secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The first rule naming the app or the host whose action matches where the traffic went.
    private func matchingRule(_ action: CustomRule.Action?) -> CustomRule? {
        guard !connection.isDefaultRoute else { return nil }
        let rules = connection.rules
        let byApp = connection.app.flatMap { app in
            SimpleRules.rule(forApp: app, bundleID: ConnectionGroup.bundleID(of: app), in: rules)
        }
        return [byApp, SimpleRules.rule(forHost: connection.host, in: rules)].compactMap { $0 }.first { $0.action == action }
    }
}

extension View {
    /// "0 B" rather than "Zero kB".
    static var bytes: ByteCountFormatStyle { .byteCount(style: .file, spellsOutZero: false) }
}

private struct BytesCell: View {
    let bytes: Int64
    let isKnown: Bool

    var body: some View {
        Text(isKnown ? bytes.formatted(Self.bytes) : "—")
            .monospacedDigit()
            .foregroundStyle(isKnown ? .primary : .tertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Opens and closes, newest at the bottom, following the end while it is in view.
private struct EventLog: View {
    let events: [ConnectionWatcher.Event]
    let search: String

    var body: some View {
        let shown = search.isEmpty ? events : events.filter {
            $0.connection.target.localizedCaseInsensitiveContains(search)
                || ($0.connection.app ?? $0.connection.process ?? "").localizedCaseInsensitiveContains(search)
        }
        ScrollViewReader { proxy in
            List(shown) { event in
                EventRow(event: event).id(event.id)
            }
            .listStyle(.plain)
            .onChange(of: shown.last?.id) {
                if let id = shown.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

private struct EventRow: View {
    let event: ConnectionWatcher.Event

    var body: some View {
        let c = event.connection
        let action = c.action
        HStack(spacing: 8) {
            Text(event.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Image(systemName: event.kind == .opened ? "arrow.up.right.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(event.kind == .opened ? (action.map { RuleList($0).tint } ?? .secondary) : .secondary)
            Text(c.app.map(AppCell.name(of:)) ?? c.process ?? "—").fontWeight(.medium)
            Text(c.target).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            switch event.kind {
            case .opened:
                Text("via \(action.map { RuleList($0).title } ?? c.outbound)").foregroundStyle(.secondary)
            case .closed:
                Text("↑ \(c.sent.formatted(Self.bytes))  ↓ \(c.received.formatted(Self.bytes))  \(StatusCell.duration((c.end ?? event.date).timeIntervalSince(c.start)))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
    }
}
