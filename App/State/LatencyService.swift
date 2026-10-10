import Foundation
import Observation
import SwiftData
import V2MacCore

@MainActor @Observable
final class LatencyService {
    private(set) var testingIDs: Set<UUID> = []
    /// Rows still waiting for or running their download test.
    private(set) var speedTestingIDs: Set<UUID> = []
    private(set) var completed = 0
    private(set) var total = 0
    var isRunning: Bool { task != nil }

    private let container: ModelContainer
    private let store: LatencyStore
    private var task: Task<Void, Never>?
    /// Set while TUN mode is up: tests must leave through this interface, not the tunnel.
    var physicalInterface: @MainActor () -> String? = { nil }

    init(container: ModelContainer) {
        self.container = container
        self.store = LatencyStore(modelContainer: container)
    }

    private struct Snapshot: Sendable {
        let id: UUID
        let kind: ProfileKind
        let config: JSONValue
        let protocolName: String
        let transport: String
        let address: String
        let port: Int
    }

    private func snapshots(for ids: [UUID]) -> [Snapshot] {
        let wanted = Set(ids)
        let all = (try? container.mainContext.fetch(FetchDescriptor<Profile>())) ?? []
        return all.compactMap { p in
            guard wanted.contains(p.id), let config = p.config else { return nil }
            return Snapshot(id: p.id, kind: p.kind, config: config, protocolName: p.protocolName,
                            transport: p.transport, address: p.address, port: p.port)
        }
    }

    // MARK: Real delay

    func testReal(_ ids: [UUID]) {
        let targets = snapshots(for: ids)
        guard !targets.isEmpty else { return }
        begin(targets.map(\.id))
        let tester = RealDelayTester(
            executable: AppPaths.coreExecutable,
            assetDirectory: AppPaths.assetsDirectory,
            options: Prefs.latencyOptions,
            outboundInterface: physicalInterface(),
            dialer: Prefs.dialer,
            allowInsecure: Prefs.allowInsecure
        )
        let latencyTargets = targets.map { LatencyTarget(id: $0.id, config: $0.config, kind: $0.kind) }
        task = Task { [weak self] in
            await tester.run(latencyTargets) { [weak self] result in
                await self?.record(result, kind: "real")
            }
            self?.finish()
        }
    }

    // MARK: Speed

    /// Real delay first; servers that answer are then timed downloading the speed-test file.
    func testSpeed(_ ids: [UUID]) {
        let targets = snapshots(for: ids)
        guard !targets.isEmpty else { return }
        begin(targets.map(\.id))
        speedTestingIDs = Set(targets.map(\.id))
        var options = Prefs.latencyOptions
        options.speedURL = Prefs.speedURL
        let tester = RealDelayTester(
            executable: AppPaths.coreExecutable,
            assetDirectory: AppPaths.assetsDirectory,
            options: options,
            outboundInterface: physicalInterface(),
            dialer: Prefs.dialer,
            allowInsecure: Prefs.allowInsecure
        )
        let latencyTargets = targets.map { LatencyTarget(id: $0.id, config: $0.config, kind: $0.kind) }
        task = Task { [weak self] in
            await tester.run(latencyTargets, onResult: { [weak self] result in
                await self?.record(result, kind: "real", expectsSpeed: true)
            }, onSpeed: { [weak self] result in
                await self?.recordSpeed(result)
            })
            self?.finish()
        }
    }

    // MARK: TCP ping

    func testTCP(_ ids: [UUID]) {
        let all = snapshots(for: ids)
        guard !all.isEmpty else { return }
        // UDP-based servers have no TCP handshake to time. A custom config is pinged at the
        // address of its proxy outbound, and is skipped only when it has none.
        let udp: Set<String> = ["hysteria", "wireguard"]
        let applicable = all.filter { !udp.contains($0.protocolName) && $0.transport != "kcp" && !$0.address.isEmpty && $0.port > 0 }
        let notApplicable = all.filter { s in !applicable.contains(where: { $0.id == s.id }) }

        begin(all.map(\.id))
        let targets = applicable.map { TCPPingTarget(id: $0.id, host: $0.address, port: $0.port) }
        let naIDs = notApplicable.map(\.id)
        let interface = physicalInterface()
        task = Task { [weak self] in
            for id in naIDs { await self?.recordNotApplicable(id) }
            await TCPPing.run(targets, interface: interface) { [weak self] result in
                await self?.record(result, kind: "tcp")
            }
            self?.finish()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        testingIDs = []
        speedTestingIDs = []
    }

    // MARK: Bookkeeping

    private func begin(_ ids: [UUID]) {
        task?.cancel()
        testingIDs = Set(ids)
        speedTestingIDs = []
        completed = 0
        total = ids.count
    }

    private func record(_ result: LatencyResult, kind: String, expectsSpeed: Bool = false) async {
        try? await store.apply(id: result.id, outcome: result.outcome, kind: kind)
        testingIDs.remove(result.id)
        if expectsSpeed {
            // Only servers that answered get a download test; the rest are done now.
            if case .ok = result.outcome { return }
            try? await store.applySpeed(id: result.id, outcome: nil)
            speedTestingIDs.remove(result.id)
        }
        completed += 1
    }

    private func recordSpeed(_ result: SpeedResult) async {
        try? await store.applySpeed(id: result.id, outcome: result.outcome)
        speedTestingIDs.remove(result.id)
        completed += 1
    }

    private func recordNotApplicable(_ id: UUID) async {
        try? await store.apply(id: id, outcome: nil, kind: "tcp")
        testingIDs.remove(id)
        completed += 1
    }

    private func finish() {
        testingIDs = []
        speedTestingIDs = []
        task = nil
        #if DEBUG
        print("[v2mac-debug] latency run finished: \(completed)/\(total)")
        #endif
    }
}
