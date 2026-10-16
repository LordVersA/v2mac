import Foundation
import Observation
import V2MacCore

/// Connections through the core (spec 8.6, 12.10): who opened them, where to, how they were routed
/// and how many bytes went each way, plus the hosts and apps the simple rule editor lists.
/// It records only while a window watches it, since it asks `nettop` once a second.
@MainActor @Observable
final class ConnectionWatcher {
    struct Seen: Identifiable {
        let id: String
        var count = 0
        var last = Date.distantPast
        var outbound = ""
    }

    struct Connection: Identifiable {
        let id: Int
        /// The app's source port, which links the access log line to its `nettop` row.
        let sourcePort: Int?
        let host: String
        let port: Int?
        let inbound: String
        let outbound: String
        let start: Date
        /// The `.app` folder, or the executable for command-line tools.
        var app: String?
        var process: String?
        var end: Date?
        var sent: Int64 = 0
        var received: Int64 = 0
        /// No `nettop` row ever matched (TUN traffic, or closed before the first look).
        var untracked = false

        var target: String { port.map { "\(host):\($0)" } ?? host }
        var isOpen: Bool { end == nil && !untracked }
    }

    struct Event: Identifiable {
        enum Kind { case opened, closed }
        let id: Int
        let date: Date
        let kind: Kind
        var connection: Connection
    }

    private(set) var hosts: [String: Seen] = [:]
    /// By `.app` folder, or executable path for command-line tools.
    private(set) var apps: [String: Seen] = [:]
    private(set) var connections: [Connection] = []
    private(set) var events: [Event] = []

    @ObservationIgnored var proxyPort: () -> Int = { Prefs.inbound.port }
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored fileprivate var nextID = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var paths: [Int32: String] = [:]
    private let limit = 1000

    var isWatching: Bool { watchers > 0 }

    func watch() {
        watchers += 1
        guard watchers == 1 else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func unwatch() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func record(_ seen: SeenConnection) {
        // The core's own lookups (its DNS inbound) are not an app's traffic.
        guard isWatching, ConfigBuilder.trafficInboundTags.contains(seen.inbound) else { return }
        nextID += 1
        let connection = Connection(id: nextID, sourcePort: seen.sourcePort, host: seen.host, port: seen.port,
                                    inbound: seen.inbound, outbound: seen.outbound, start: .now)
        connections.append(connection)
        if connections.count > limit { connections.removeFirst(connections.count - limit) }
        log(.opened, connection)
        hosts[seen.host, default: Seen(id: seen.host)].note(seen.outbound)
        if hosts.count > limit { hosts = Self.trimmed(hosts, to: limit) }
    }

    func clear() {
        hosts = [:]
        apps = [:]
        connections.removeAll { !$0.isOpen }
        events = []
    }

    fileprivate func log(_ kind: Event.Kind, _ connection: Connection) {
        nextID += 1
        events.append(Event(id: nextID, date: .now, kind: kind, connection: connection))
        if events.count > limit * 2 { events.removeFirst(events.count - limit * 2) }
    }

    private func poll() async {
        guard connections.contains(where: \.isOpen) else { return }
        let flows = await ProxyFlow.read(proxyPort: proxyPort())
        let byPort = Dictionary(flows.map { ($0.localPort, $0) }, uniquingKeysWith: { first, _ in first })
        var list = connections
        for index in list.indices where list[index].isOpen && list[index].sourcePort != nil {
            if let port = list[index].sourcePort, let flow = byPort[port] {
                list[index].sent = flow.sent
                list[index].received = flow.received
                if list[index].app == nil {
                    list[index].process = flow.process
                    list[index].app = app(of: flow.pid)
                    if let app = list[index].app { apps[app, default: Seen(id: app)].note(list[index].outbound) }
                    // The open line was logged before the app was known.
                    if let event = events.lastIndex(where: { $0.connection.id == list[index].id }) { events[event].connection = list[index] }
                }
            } else if list[index].app != nil {
                list[index].end = .now
                log(.closed, list[index])
            } else if Date.now.timeIntervalSince(list[index].start) > 3 {
                // shortcut: a connection that closed before the first look has no app or bytes; fine for a monitor.
                list[index].untracked = true
            }
        }
        connections = list
        if apps.count > limit { apps = Self.trimmed(apps, to: limit) }
    }

    private func app(of pid: Int32) -> String? {
        if let known = paths[pid] { return known }
        guard let path = SocketOwners.path(of: pid) else { return nil }
        let app = SocketOwners.appBundle(of: path) ?? path
        paths[pid] = app
        return app
    }

    private static func trimmed(_ seen: [String: Seen], to limit: Int) -> [String: Seen] {
        Dictionary(uniqueKeysWithValues: seen.values.sorted { $0.last > $1.last }.prefix(limit).map { ($0.id, $0) })
    }
}

#if DEBUG
extension ConnectionWatcher {
    /// `-debugDemoData YES`: made-up connections, so a snapshot of the Connections window has rows.
    func addDemoConnections() {
        guard connections.isEmpty else { return }
        let rows: [(String?, String, String, Int, TimeInterval, Int64, Int64, Bool)] = [
            ("/System/Applications/Music.app", "api.music.example.com", "proxy", 443, 1, 1_240, 88_200, true),
            ("/Applications/Safari.app", "www.example.com", "direct", 443, 4, 7_440, 19_500, true),
            ("/System/Applications/Mail.app", "imap.example.org", "proxy", 993, 42, 22_000, 5_650, true),
            ("/Applications/Safari.app", "ads.example.net", "block", 443, 63, 0, 0, false),
            (nil, "updates.example.com", "direct", 80, 95, 3_260, 1_090, false),
        ]
        for (app, host, outbound, port, age, sent, received, open) in rows {
            nextID += 1
            var c = Connection(id: nextID, sourcePort: nil, host: host, port: port, inbound: ConfigBuilder.inboundTag,
                               outbound: outbound, start: .now.addingTimeInterval(-age))
            c.app = app
            c.process = app == nil ? "curl" : nil
            c.sent = sent
            c.received = received
            if !open { c.end = c.start.addingTimeInterval(min(age, 3)) }
            connections.append(c)
            log(.opened, c)
            if !open { log(.closed, c) }
        }
    }
}
#endif

private extension ConnectionWatcher.Seen {
    mutating func note(_ outbound: String) {
        count += 1
        last = .now
        self.outbound = outbound
    }
}
