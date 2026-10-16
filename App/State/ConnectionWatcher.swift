import Foundation
import Observation
import V2MacCore

/// Hosts and apps that made connections through the core, for the simple rule editor (spec 8.6).
/// It records only while `isWatching`, since finding a connection's app scans every process.
@MainActor @Observable
final class ConnectionWatcher {
    struct Seen: Identifiable {
        let id: String
        var count = 0
        var last = Date.distantPast
        var outbound = ""
    }

    private(set) var hosts: [String: Seen] = [:]
    /// By `.app` folder, or executable path for command-line tools.
    private(set) var apps: [String: Seen] = [:]
    var isWatching = false

    @ObservationIgnored var proxyPort: () -> Int = { Prefs.inbound.port }
    @ObservationIgnored private var pending: [SeenConnection] = []
    @ObservationIgnored private var owners: [Int: String] = [:]
    private let limit = 400

    func record(_ connection: SeenConnection) {
        guard isWatching else { return }
        pending.append(connection)
        guard pending.count == 1 else { return }
        Task { [weak self] in
            // Batches lines, and lets the socket show up in the process table.
            try? await Task.sleep(for: .milliseconds(400))
            await self?.resolve()
        }
    }

    func clear() {
        hosts = [:]
        apps = [:]
    }

    private func resolve() async {
        let batch = pending
        pending = []
        // TUN traffic arrives from the root forwarder, whose sockets say nothing about the app.
        if batch.contains(where: { $0.inbound == ConfigBuilder.inboundTag && $0.sourcePort.map { owners[$0] == nil } ?? false }) {
            let port = proxyPort()
            // shortcut: a connection closed before this scan has no app; fine for a list of what is in use.
            owners = await Task.detached { SocketOwners.scan(proxyPort: port) }.value
        }
        var hosts = self.hosts, apps = self.apps
        for connection in batch {
            hosts[connection.host, default: Seen(id: connection.host)].note(connection)
            if connection.inbound == ConfigBuilder.inboundTag, let path = connection.sourcePort.flatMap({ owners[$0] }) {
                let app = SocketOwners.appBundle(of: path) ?? path
                apps[app, default: Seen(id: app)].note(connection)
            }
        }
        self.hosts = Self.trimmed(hosts, to: limit)
        self.apps = Self.trimmed(apps, to: limit)
    }

    private static func trimmed(_ seen: [String: Seen], to limit: Int) -> [String: Seen] {
        guard seen.count > limit else { return seen }
        return Dictionary(uniqueKeysWithValues: seen.values.sorted { $0.last > $1.last }.prefix(limit).map { ($0.id, $0) })
    }
}

private extension ConnectionWatcher.Seen {
    mutating func note(_ connection: SeenConnection) {
        count += 1
        last = .now
        outbound = connection.outbound
    }
}
