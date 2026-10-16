import SwiftUI
import V2MacCore

/// Spec 12.10: every connection through the core, live, with its app, target, rule and traffic,
/// above a log of opens and closes. Recorded only while this window or the rule editor is open.
struct ConnectionsView: View {
    static let windowID = "connections"

    enum Filter: String, CaseIterable, Identifiable {
        case all, open
        var id: Self { self }
        var title: LocalizedStringKey { self == .all ? "All" : "Open" }
    }

    @Environment(AppModel.self) private var model
    @AppStorage("customRuleList") private var stored = "[]"
    @State private var selection: Set<ConnectionWatcher.Connection.ID> = []
    @State private var filter = Filter.all
    @State private var search = ""
    /// The column and direction, kept across launches: `<column>:<asc|desc>`.
    @AppStorage("connectionsSort") private var storedSort = "time:desc"

    typealias Row = ConnectionWatcher.Connection
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
        let rules = CustomRule.decode(stored)
        let rows = watcher.connections.filter(matches).sorted(using: sortOrder.wrappedValue)
        VSplitView {
            Table(rows, selection: $selection, sortOrder: sortOrder) {
                TableColumn("Application", value: \.appName) { row in AppCell(connection: row) }
                    .width(min: 160, ideal: 220)
                TableColumn("Target", value: \.target) { row in
                    Text(row.target).lineLimit(1).truncationMode(.middle).help(row.target)
                }
                .width(min: 160, ideal: 260)
                TableColumn("Time", value: \.start) { row in StatusCell(connection: row) }
                    .width(min: 80, ideal: 96)
                TableColumn("Rule", value: \.outbound) { row in RuleCell(connection: row, rules: rules) }
                    .width(min: 120, ideal: 200)
                TableColumn("Sent", value: \.sent) { row in BytesCell(bytes: row.sent, isKnown: !row.untracked) }
                    .width(min: 64, ideal: 80)
                TableColumn("Received", value: \.received) { row in BytesCell(bytes: row.received, isKnown: !row.untracked) }
                    .width(min: 64, ideal: 80)
            }
            .alternatingRowBackgrounds()
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label(model.connection.isRunning ? "No connections yet" : "Not connected", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Connections appear here while this window is open.")
                    }
                }
            }
            .frame(minHeight: 260, idealHeight: 520)
            EventLog(events: watcher.events, search: search)
                .frame(minHeight: 90, idealHeight: 150, maxHeight: 400)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Apps and targets")
        .navigationSubtitle(summary)
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button("Clear", systemImage: "trash") { watcher.clear() }
                    .help("Clear closed connections and the log")
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

    private var summary: String {
        let open = watcher.connections.filter(\.isOpen)
        let sent = open.reduce(0) { $0 + $1.sent }, received = open.reduce(0) { $0 + $1.received }
        return String(localized: "\(open.count) open · ↑ \(sent.formatted(Self.bytes)) · ↓ \(received.formatted(Self.bytes))")
    }

    private func matches(_ row: ConnectionWatcher.Connection) -> Bool {
        (filter == .all || row.isOpen)
            && (search.isEmpty || row.target.localizedCaseInsensitiveContains(search)
                || (row.app.map(AppCell.name(of:)) ?? row.process ?? "").localizedCaseInsensitiveContains(search))
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
                Text(connection.process ?? (connection.inbound == ConfigBuilder.inboundTag ? String(localized: "Unknown") : String(localized: "TUN")))
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
    let rules: [CustomRule]

    var body: some View {
        let action = CustomRule.Action(rawValue: connection.outbound)
        let tint = action.map { RuleList($0).tint } ?? .secondary
        let rule = matchingRule(action)
        HStack(spacing: 6) {
            Text(action.map { RuleList($0).title } ?? connection.outbound)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(tint.opacity(0.14), in: .capsule)
                .fixedSize()
            Text(rule?.name ?? String(localized: "Routing mode"))
                .foregroundStyle(rule == nil ? .tertiary : .secondary)
                .lineLimit(1)
        }
    }

    /// The first rule naming the app or the host whose action matches where the traffic went.
    private func matchingRule(_ action: CustomRule.Action?) -> CustomRule? {
        let byApp = connection.app.flatMap { app in
            SimpleRules.rule(forApp: app, bundleID: Bundle(path: app)?.bundleIdentifier ?? "", in: rules)
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
        let action = CustomRule.Action(rawValue: c.outbound)
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
