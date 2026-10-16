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
        var routingMode: RoutingMode?
        var rules: [CustomRule] = []
        var usesProxySetting = false
        var action: CustomRule.Action?
        var configFallback = false
        var isDefaultRoute = false
        var skipsRules: Bool { usesProxySetting && routingMode != .direct && action == .proxy }
        /// The `.app` folder, or the executable for command-line tools.
        var app: String?
        var process: String?
        var end: Date?
        var sent: Int64 = 0
        var received: Int64 = 0
        /// The `nettop` connection this row follows, once found.
        var flowKey: String?
        /// Where the traffic really goes, when known: the app's own connection in TUN mode, or a
        /// target that is an address. Proxy mode only knows the name.
        var remoteAddress: String?
        /// No `nettop` connection ever matched (closed before the first look, or not found in TUN mode).
        var untracked = false

        var target: String { port.map { "\(host):\($0)" } ?? host }
        /// Sort keys for the Connections table.
        var appName: String {
            app.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") } ?? process ?? ""
        }
        var lifetime: TimeInterval { (end ?? .now).timeIntervalSince(start) }
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
    @ObservationIgnored var routingMode: RoutingMode?
    @ObservationIgnored var customRules = CustomRules()
    @ObservationIgnored var hasConfigFallback = false
    @ObservationIgnored var outboundActions: [String: CustomRule.Action] = [:]
    @ObservationIgnored var modeOutbounds: Set<String> = []
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored fileprivate var nextID = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Access log lines since the last flush: a burst of lines updates the window once, not per line.
    @ObservationIgnored private var pending: [Connection] = []
    @ObservationIgnored private var paths: [Int32: String] = [:]
    /// TUN mode: what each site resolves to, to find the app's own connection (`NetFlow.tunClient`).
    @ObservationIgnored private var resolved: [String: Set<String>] = [:]
    @ObservationIgnored private var resolving: Set<String> = []
    /// The core's own connections are never an app's.
    private static let coreProcesses: Set<String> = ["xray"]
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
        // The core's own lookups (its DNS inbound) are not an app's traffic, nor are the lookups
        // TUN mode hands to the core's resolver.
        guard isWatching, ConfigBuilder.trafficInboundTags.contains(seen.inbound), seen.outbound != ConfigBuilder.tunDNSTag else { return }
        nextID += 1
        var connection = Connection(id: nextID, sourcePort: seen.sourcePort, host: seen.host, port: seen.port,
                                    inbound: seen.inbound, outbound: seen.outbound, start: .now)
        // Keep the running configuration with the row, even after settings change.
        connection.routingMode = routingMode
        connection.action = outboundActions[seen.outbound] ?? CustomRule.Action(rawValue: seen.outbound)
        connection.isDefaultRoute = seen.isDefaultRoute
        connection.configFallback = hasConfigFallback && (seen.isDefaultRoute || !modeOutbounds.contains(seen.outbound))
        connection.rules = routingMode == nil ? [] : customRules.rules.filter { routingMode != .direct || $0.action == .block }
        connection.usesProxySetting = routingMode != nil && customRules.proxyClientsSkipRules && seen.inbound == ConfigBuilder.inboundTag
        pending.append(connection)
        guard pending.count == 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.flush()
        }
    }

    private func flush() {
        let batch = pending
        pending = []
        var list = connections
        var seenHosts = hosts
        for var connection in batch {
            if RuleMatchers.isIP(connection.host) { connection.remoteAddress = connection.host }
            list.append(connection)
            log(.opened, connection)
            if !connection.usesProxySetting {
                seenHosts[connection.host, default: Seen(id: connection.host)].note(connection.outbound)
            }
        }
        if list.count > limit { list.removeFirst(list.count - limit) }
        if seenHosts.count > limit { seenHosts = Self.trimmed(seenHosts, to: limit) }
        connections = list
        hosts = seenHosts
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
        let flows = await NetFlow.read()
        let byKey = Dictionary(flows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let proxyPort = proxyPort()
        var list = connections
        var claimed = Set(list.filter(\.isOpen).compactMap(\.flowKey))
        for index in list.indices where list[index].isOpen {
            let row = list[index]
            let isTun = row.inbound == ConfigBuilder.tunInboundTag
            let flow: NetFlow?
            if let key = row.flowKey {
                flow = byKey[key]
            } else if isTun {
                if let addresses = resolved[row.host] {
                    flow = NetFlow.tunClient(flows, port: row.port, addresses: addresses, claimed: claimed, skipping: Self.coreProcesses)
                } else {
                    resolve(row.host)
                    flow = nil
                }
            } else if let port = row.sourcePort {
                flow = NetFlow.proxyClient(flows, proxyPort: proxyPort, sourcePort: port)
            } else {
                continue
            }
            if let flow {
                list[index].sent = flow.sent
                list[index].received = flow.received
                guard row.flowKey == nil else { continue }
                list[index].flowKey = flow.key
                if !NetFlow.isLoopback(flow.remoteAddress) { list[index].remoteAddress = flow.remoteAddress }
                claimed.insert(flow.key)
                list[index].process = flow.process
                list[index].app = app(of: flow.pid)
                if !row.usesProxySetting, let app = list[index].app { apps[app, default: Seen(id: app)].note(row.outbound) }
                // The open line was logged before the app was known.
                if let event = events.lastIndex(where: { $0.connection.id == row.id }) { events[event].connection = list[index] }
            } else if row.flowKey != nil {
                list[index].end = .now
                log(.closed, list[index])
            } else if Date.now.timeIntervalSince(row.start) > (isTun ? 6 : 3) {
                // shortcut: a connection that closed before it was found has no app or bytes; fine for a monitor.
                list[index].untracked = true
            }
        }
        connections = list
        if apps.count > limit { apps = Self.trimmed(apps, to: limit) }
    }

    /// Looks a site up as the app did: in TUN mode this asks the core's resolver, through the tunnel.
    private func resolve(_ host: String) {
        guard resolving.insert(host).inserted else { return }
        Task { [weak self] in
            let addresses = await Task.detached { HostAddresses.lookup(host) }.value
            guard let self else { return }
            resolving.remove(host)
            if resolved.count > limit { resolved = [:] }
            resolved[host] = addresses
        }
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
            ("/System/Applications/Mail.app", "mail.example.org", "imported-server", 993, 12, 2_000, 9_000, true),
        ]
        for (app, host, outbound, port, age, sent, received, open) in rows {
            nextID += 1
            var c = Connection(id: nextID, sourcePort: nil, host: host, port: port, inbound: ConfigBuilder.inboundTag,
                               outbound: outbound, start: .now.addingTimeInterval(-age))
            c.routingMode = .global
            c.action = CustomRule.Action(rawValue: outbound) ?? .proxy
            c.configFallback = outbound == "imported-server"
            c.usesProxySetting = outbound == ConfigBuilder.proxyTag
            c.rules = [CustomRule(name: "Browsers direct", action: .direct, apps: "Safari.app"),
                       CustomRule(name: "Block ads", action: .block, hosts: "ads.example.net")]
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
