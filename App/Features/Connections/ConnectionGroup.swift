import Foundation
import V2MacCore

/// The rule editor's host/vendor grouping, with the original connections kept as children.
struct ConnectionGroup: Identifiable {
    enum Row: Identifiable {
        case connection(ConnectionWatcher.Connection)
        case group(ConnectionGroup)

        var connection: ConnectionWatcher.Connection? { if case .connection(let row) = self { row } else { nil } }
        var group: ConnectionGroup? { if case .group(let group) = self { group } else { nil } }
        var id: String {
            switch self {
            case .connection(let row): "connection:\(row.id)"
            case .group(let group): "group:\(group.id)"
            }
        }
        var appName: String { connection?.appName ?? group?.title ?? "" }
        var target: String { connection?.target ?? group?.title ?? "" }
        var start: Date { connection?.start ?? group?.connections.map(\.start).max() ?? .distantPast }
        var outbound: String { connection?.outbound ?? group?.connections.first?.outbound ?? "" }
        var sent: Int64 { connection?.sent ?? group?.sent ?? 0 }
        var received: Int64 { connection?.received ?? group?.received ?? 0 }
        var hasTrackedTraffic: Bool { connection.map { !$0.untracked } ?? group?.hasTrackedTraffic ?? false }
        var children: [Self] { group?.connections.map(Self.connection) ?? [] }
    }

    let id: String
    let title: String
    let entry: RuleEntry
    let connections: [ConnectionWatcher.Connection]

    var openCount: Int { connections.filter(\.isOpen).count }
    var sent: Int64 { connections.reduce(0) { $0 + $1.sent } }
    var received: Int64 { connections.reduce(0) { $0 + $1.received } }
    var hasTrackedTraffic: Bool { connections.contains { !$0.untracked } }

    @MainActor private static var bundleIDs: [String: String] = [:]

    @MainActor static func bundleID(of app: String) -> String {
        if let known = bundleIDs[app] { return known }
        let id = Bundle(path: app)?.bundleIdentifier ?? ""
        bundleIDs[app] = id
        return id
    }

    @MainActor static func make(_ connections: [ConnectionWatcher.Connection], by kind: RuleEntry.Kind) -> [Self] {
        let entries = connections.map { connection in
            let identity: String
            let brand: String?
            switch kind {
            case .host:
                identity = connection.host
                brand = EntryGroups.brand(ofHost: connection.host)
            case .app:
                identity = connection.app.map { "app:\($0)" } ?? connection.process.map { "process:\($0)" } ?? "unknown"
                brand = connection.app.flatMap { EntryGroups.brand(ofBundleID: bundleID(of: $0)) }
            }
            return (connection: connection, identity: identity, brand: brand)
        }
        let keys = EntryGroups.keys(for: Set(entries.compactMap(\.brand)))
        let grouped = Dictionary(grouping: entries) { entry in
            entry.brand.flatMap { keys[$0] }.map { "brand:\($0)" } ?? "entry:\(entry.identity)"
        }
        return grouped.map { key, entries in
            let first = entries[0].connection
            let isSingle = Set(entries.map(\.identity)).count == 1
            let title: String
            let text: String
            if isSingle {
                title = kind == .host ? first.host : first.appName.isEmpty ? String(localized: "Unknown app") : first.appName
                text = kind == .host ? first.host : first.app ?? first.process ?? title
            } else {
                title = String(key.dropFirst("brand:".count))
                text = kind == .host ? title : "*\(title)*"
            }
            return Self(id: "\(kind):\(key)", title: title, entry: RuleEntry(kind, text), connections: entries.map(\.connection))
        }
        .sorted { $0.connections.count == $1.connections.count ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.connections.count > $1.connections.count }
    }
}
