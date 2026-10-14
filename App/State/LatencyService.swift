import Foundation
import Observation
import SwiftData
import V2MacCore

/// Runs delay, speed and TCP tests one request after another. A test asked for while another
/// runs (say from the menu bar, then from the window) waits its turn instead of replacing it.
@MainActor @Observable
final class LatencyService {
    private(set) var testingIDs: Set<UUID> = []
    /// Rows still waiting for or running their download test.
    private(set) var speedTestingIDs: Set<UUID> = []
    /// The download running right now: `bps` is nil while it is still connecting.
    private(set) var liveSpeed: LiveSpeed?
    private(set) var completed = 0
    private(set) var total = 0
    var isRunning: Bool { task != nil }

    struct LiveSpeed: Equatable {
        let id: UUID
        let bps: Double?
    }

    private let container: ModelContainer
    private let store: LatencyStore
    private var task: Task<Void, Never>?
    @ObservationIgnored private var queue: [@MainActor (Int) async -> Void] = []
    /// Bumped by `cancel`, so results arriving late from a stopped run change nothing.
    @ObservationIgnored private var generation = 0
    /// How many queued requests still owe each row a result; a row can be in more than one.
    @ObservationIgnored private var delayPending: [UUID: Int] = [:]
    @ObservationIgnored private var speedPending: [UUID: Int] = [:]
    /// Set while TUN mode is up: tests must leave through this interface, not the tunnel.
    var physicalInterface: @MainActor () -> String? = { nil }
    /// A run ended by itself: how many servers, and the fastest one that answered (spec 12.8).
    @ObservationIgnored var onFinished: @MainActor (_ tested: Int, _ best: (id: UUID, ms: Int)?) -> Void = { _, _ in }
    @ObservationIgnored private var best: (id: UUID, ms: Int)?

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
        // A row already waiting for a delay result is not queued twice.
        let targets = snapshots(for: ids).filter { delayPending[$0.id] == nil }
        guard !targets.isEmpty else { return }
        let latencyTargets = targets.map { LatencyTarget(id: $0.id, config: $0.config, kind: $0.kind) }
        enqueue(delay: targets.map(\.id)) { [weak self] generation in
            // Read when the request's turn comes, so it uses the settings and interface of that moment.
            guard let self else { return }
            let tester = self.tester(options: Prefs.latencyOptions)
            await tester.run(latencyTargets) { [weak self] result in
                await self?.record(result, kind: "real", generation: generation)
            }
        }
    }

    // MARK: Speed

    /// Real delay first; servers that answer are then timed downloading the speed-test file.
    func testSpeed(_ ids: [UUID]) {
        let targets = snapshots(for: ids).filter { speedPending[$0.id] == nil }
        guard !targets.isEmpty else { return }
        let latencyTargets = targets.map { LatencyTarget(id: $0.id, config: $0.config, kind: $0.kind) }
        enqueue(delay: targets.map(\.id), speed: true) { [weak self] generation in
            guard let self else { return }
            var options = Prefs.latencyOptions
            options.speedURL = Prefs.speedURL
            let tester = self.tester(options: options)
            await tester.run(latencyTargets, onResult: { [weak self] result in
                await self?.record(result, kind: "real", expectsSpeed: true, generation: generation)
            }, onSpeed: { [weak self] result in
                await self?.recordSpeed(result, generation: generation)
            }, onSpeedProgress: { [weak self] id, bps in
                await self?.showSpeed(id: id, bps: bps, generation: generation)
            })
        }
    }

    private func tester(options: LatencyOptions) -> RealDelayTester {
        RealDelayTester(
            executable: AppPaths.coreExecutable,
            assetDirectory: AppPaths.assetsDirectory,
            options: options,
            outboundInterface: physicalInterface(),
            dialer: Prefs.dialer,
            allowInsecure: Prefs.allowInsecure
        )
    }

    // MARK: TCP ping

    func testTCP(_ ids: [UUID]) {
        let all = snapshots(for: ids).filter { delayPending[$0.id] == nil }
        guard !all.isEmpty else { return }
        // UDP-based servers have no TCP handshake to time. A custom config is pinged at the
        // address of its proxy outbound, and is skipped only when it has none.
        let udp: Set<String> = ["hysteria", "wireguard"]
        let applicable = all.filter { !udp.contains($0.protocolName) && $0.transport != "kcp" && !$0.address.isEmpty && $0.port > 0 }
        let notApplicable = all.filter { s in !applicable.contains(where: { $0.id == s.id }) }

        let targets = applicable.map { TCPPingTarget(id: $0.id, host: $0.address, port: $0.port) }
        let naIDs = notApplicable.map(\.id)
        enqueue(delay: all.map(\.id)) { [weak self] generation in
            guard let self else { return }
            for id in naIDs { await self.recordNotApplicable(id, generation: generation) }
            await TCPPing.run(targets, interface: self.physicalInterface()) { [weak self] result in
                await self?.record(result, kind: "tcp", generation: generation)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        queue = []
        generation += 1
        delayPending = [:]
        speedPending = [:]
        testingIDs = []
        speedTestingIDs = []
        liveSpeed = nil
    }

    // MARK: Queue

    private func enqueue(delay ids: [UUID], speed: Bool = false, _ job: @escaping @MainActor (Int) async -> Void) {
        if task == nil {
            completed = 0
            total = 0
            best = nil
        }
        for id in ids { delayPending[id, default: 0] += 1 }
        if speed { for id in ids { speedPending[id, default: 0] += 1 } }
        testingIDs = Set(delayPending.keys)
        speedTestingIDs = Set(speedPending.keys)
        total += ids.count
        queue.append(job)
        guard task == nil else { return }
        let generation = generation
        task = Task { [weak self] in
            while let self, self.generation == generation, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                await next(generation)
            }
            self?.finish(generation: generation)
        }
    }

    // MARK: Bookkeeping

    private func settle(_ id: UUID, in pending: inout [UUID: Int]) {
        guard let count = pending[id] else { return }
        pending[id] = count > 1 ? count - 1 : nil
    }

    private func record(_ result: LatencyResult, kind: String, expectsSpeed: Bool = false, generation: Int) async {
        try? await store.apply(id: result.id, outcome: result.outcome, kind: kind)
        guard generation == self.generation else { return }
        settle(result.id, in: &delayPending)
        testingIDs = Set(delayPending.keys)
        if case .ok(let ms) = result.outcome, ms < (best?.ms ?? .max) { best = (result.id, ms) }
        if expectsSpeed {
            // Only servers that answered get a download test; the rest are done now.
            if case .ok = result.outcome { return }
            try? await store.applySpeed(id: result.id, outcome: nil)
            guard generation == self.generation else { return }
            settle(result.id, in: &speedPending)
            speedTestingIDs = Set(speedPending.keys)
        }
        completed += 1
    }

    private func recordSpeed(_ result: SpeedResult, generation: Int) async {
        try? await store.applySpeed(id: result.id, outcome: result.outcome)
        guard generation == self.generation else { return }
        settle(result.id, in: &speedPending)
        speedTestingIDs = Set(speedPending.keys)
        if liveSpeed?.id == result.id { liveSpeed = nil }
        completed += 1
    }

    private func showSpeed(id: UUID, bps: Double?, generation: Int) {
        guard generation == self.generation else { return }
        liveSpeed = LiveSpeed(id: id, bps: bps)
    }

    private func recordNotApplicable(_ id: UUID, generation: Int) async {
        try? await store.apply(id: id, outcome: nil, kind: "tcp")
        guard generation == self.generation else { return }
        settle(id, in: &delayPending)
        testingIDs = Set(delayPending.keys)
        completed += 1
    }

    private func finish(generation: Int) {
        // A stopped run has already been cleared, and a newer one may be running.
        guard generation == self.generation else { return }
        delayPending = [:]
        speedPending = [:]
        testingIDs = []
        speedTestingIDs = []
        liveSpeed = nil
        task = nil
        onFinished(total, best)
        #if DEBUG
        print("[v2mac-debug] latency run finished: \(completed)/\(total)")
        #endif
    }
}
