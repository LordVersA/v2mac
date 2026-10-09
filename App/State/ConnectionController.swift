import Foundation
import Observation
import V2MacCore

@MainActor @Observable
final class ConnectionController {
    enum Phase: Equatable {
        case off, connecting, switching, connected
        case failed(String)
    }

    private(set) var coreState: CoreState = .stopped
    private(set) var isSwitching = false
    private(set) var localError: String?
    private(set) var activeServer: ActiveServer?
    private(set) var port = Prefs.port
    private(set) var routingMode = Prefs.routingMode
    /// Supplied by the region pack service: rules for enabled, downloaded packs.
    var regionRoutes: @MainActor () -> [RegionRoute] = { [] }
    /// Set when the configured port is taken: the busy port and a free one to offer.
    private(set) var portConflict: PortConflict?
    private(set) var isRecovering = false
    private(set) var downRate: Double = 0
    private(set) var upRate: Double = 0
    /// The last minute of rates, one sample per second, oldest first.
    private(set) var rateHistory: [RateSample] = []

    struct RateSample: Identifiable, Equatable {
        let id: Int
        let down: Double
        let up: Double
    }
    private var sampleCounter = 0

    struct PortConflict: Equatable {
        let busy: Int
        let suggested: Int
    }

    /// Crash-restart delays (spec 9.3); the counter resets after 60 s of stable running.
    private static let restartDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10)]

    let logs: LogStore
    let tun: TunController
    private let runner: CoreRunner
    private var metricsPort: Int?
    private var statsTask: Task<Void, Never>?
    private var queue: Task<Void, Never>?
    private var userWantsRunning = false
    private var crashCount = 0
    private var recoveryTask: Task<Void, Never>?
    private var stableTask: Task<Void, Never>?
    private var lifecycle: LifecycleMonitor?

    var phase: Phase {
        if isSwitching || isRecovering { return .switching }
        if let localError { return .failed(localError) }
        switch coreState {
        case .stopped, .stopping: return .off
        case .starting: return .connecting
        case .running: return .connected
        case .failed(let message): return .failed(message)
        }
    }

    var isRunning: Bool { coreState == .running }
    var localAddress: String { "127.0.0.1:\(port)" }

    init(logs: LogStore) {
        self.logs = logs
        tun = TunController(logs: logs)
        runner = CoreRunner(
            executable: AppPaths.coreExecutable,
            assetDirectory: AppPaths.assetsDirectory,
            runDirectory: AppPaths.runDirectory,
            allowedExecutables: [AppPaths.coreExecutable, AppPaths.bundledCore]
        )
        let states = runner.states
        let lines = runner.logs
        lifecycle = LifecycleMonitor(
            ignoredInterface: { [weak self] in self?.tun.interfaceName },
            onTrigger: { [weak self] reason in self?.systemEvent(reason) }
        )
        Task { [weak self] in
            for await state in states { self?.coreStateChanged(state) }
        }
        Task { [weak self] in
            for await line in lines {
                self?.logs.append(line)
                #if DEBUG
                if line.contains(">>") || line.contains("->") || line.hasPrefix("[v2mac]") { print("[v2mac-debug] \(line)") }
                #endif
            }
        }
    }

    // MARK: Commands

    /// Changing the routing mode while connected restarts the core.
    func setRoutingMode(_ mode: RoutingMode) {
        guard mode != routingMode else { return }
        routingMode = mode
        Prefs.routingMode = mode
        reconnectIfRunning()
    }

    /// TUN mode routes all system traffic through the core. Changing it while connected
    /// restarts the core, which needs a different config for it.
    func setTunEnabled(_ on: Bool) {
        guard on != tun.isEnabled else { return }
        tun.setEnabled(on)
        reconnectIfRunning()
    }

    /// Restarts the core when it is up (mode, pack or port changed).
    func reconnectIfRunning() {
        switch phase {
        case .connected, .connecting, .switching:
            cancelRecovery()
            connectActive()
        case .off, .failed: break
        }
    }

    var activeIsCustom: Bool { activeServer?.kind == .custom }

    func setActive(_ server: ActiveServer?) {
        activeServer = server
        Prefs.activeProfileID = server?.id
    }

    /// Activating a server connects to it immediately (decision 19).
    func activate(_ server: ActiveServer) {
        cancelRecovery()
        setActive(server)
        connectActive()
    }

    func connectActive() {
        guard let server = activeServer else { return }
        enqueue { await self.performConnect(server) }
    }

    func disconnect() {
        userWantsRunning = false
        cancelRecovery()
        portConflict = nil
        // First, so nothing is left pointing at a core that is about to stop.
        tun.down(clearingError: true)
        enqueue {
            self.localError = nil
            Prefs.wasRunning = false
            // Again: a connect that was waiting for the administrator prompt may have raised it.
            self.tun.down(clearingError: true)
            await self.runner.stop()
        }
    }

    func toggle() {
        switch phase {
        case .off, .failed:
            cancelRecovery()
            connectActive()
        case .connecting, .switching, .connected: disconnect()
        }
    }

    /// Moves to the offered free port and reconnects (the "Use <port>" fix).
    func useSuggestedPort() {
        guard let conflict = portConflict else { return }
        Prefs.port = conflict.suggested
        portConflict = nil
        cancelRecovery()
        connectActive()
    }

    /// Wake from sleep or a network change: restart a live connection if the setting is on.
    private func systemEvent(_ reason: String) {
        // In TUN mode the core is bound to one interface, so a network change always needs a restart.
        guard Prefs.restartOnWakeOrNetwork || tun.isEnabled, userWantsRunning, activeServer != nil else { return }
        switch coreState {
        case .running, .failed:
            logs.append("[v2mac] Restarting core after \(reason)")
            crashCount = 0
            connectActive()
        default: break
        }
    }

    private func scheduleRestart() {
        guard crashCount < Self.restartDelays.count else {
            isRecovering = false
            return
        }
        let delay = Self.restartDelays[crashCount]
        crashCount += 1
        isRecovering = true
        logs.append("[v2mac] Core stopped; restarting (attempt \(crashCount) of \(Self.restartDelays.count))")
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, userWantsRunning else { return }
            connectActive()
        }
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
        crashCount = 0
    }

    /// Stops the core and waits; used on quit.
    func shutdown() async {
        userWantsRunning = false
        cancelRecovery()
        tun.endSession()
        await queue?.value
        await runner.stop()
    }

    // MARK: Internals

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func performConnect(_ server: ActiveServer) async {
        userWantsRunning = true
        localError = nil
        portConflict = nil
        // Before the running core stops: the administrator prompt can stay open for a while.
        let tunLink = tun.isEnabled ? await tun.prepare() : nil
        if tunLink == nil { tun.down() }
        if coreState != .stopped {
            isSwitching = true
            await runner.stop()
        }
        defer { isSwitching = false }

        await runner.setExecutable(AppPaths.coreExecutable)
        let inbound = Prefs.inbound
        port = inbound.port
        do {
            let metrics = try PortUtil.freePort()
            metricsPort = metrics
            let options = RunOptions(inbound: inbound, logLevel: Prefs.logLevel, logConnections: Prefs.logConnections, metricsPort: metrics, tun: tunLink)
            let config: JSONValue
            switch server.kind {
            case .outbound:
                let plan: RoutingPlan
                switch routingMode {
                case .global: plan = .global
                case .bypassRegions: plan = .bypass(regionRoutes())
                case .direct: plan = .direct
                }
                config = try ConfigBuilder.build(outbound: server.config, options: options, routing: plan)
            case .custom:
                config = try ConfigBuilder.buildCustom(config: server.config, options: options)
            }
            logs.append("[v2mac] Connecting to \(server.name)")
            try await runner.start(config: config, readyPort: port)
            Prefs.wasRunning = true
            if tunLink != nil { tun.up() }
        } catch {
            tun.down()
            if case CoreError.portInUse(let busy) = error {
                portConflict = suggestPort(avoiding: busy)
            }
            // The runner's own state already reflects the failure; only surface errors it can't.
            if case .failed = coreState { return }
            localError = error.localizedDescription
        }
    }

    private func suggestPort(avoiding busy: Int) -> PortConflict? {
        let host = Prefs.inbound.listenAddress
        let candidate = (busy + 1...min(busy + 100, 65535)).first { PortUtil.isFree(port: $0, host: host) }
            ?? (try? PortUtil.freePort())
        return candidate.map { PortConflict(busy: busy, suggested: $0) }
    }

    private func coreStateChanged(_ state: CoreState) {
        let previous = coreState
        coreState = state
        #if DEBUG
        print("[v2mac-debug] core state \(previous) -> \(state); phase=\(phase); conflict=\(String(describing: portConflict))")
        #endif
        if state == .running {
            isRecovering = false
            stableTask?.cancel()
            stableTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { self?.crashCount = 0 }
            }
            startPolling()
        } else {
            stableTask?.cancel()
            if case .failed = state, userWantsRunning, portConflict == nil, previous == .running || isRecovering {
                scheduleRestart()
            }
            // A core that is not coming back must not keep the whole system's traffic.
            if case .failed = state, !isRecovering { tun.down() }
            statsTask?.cancel()
            statsTask = nil
            downRate = 0
            upRate = 0
            rateHistory = []
        }
    }

    private func startPolling() {
        guard let metricsPort else { return }
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            let client = StatsClient(port: metricsPort)
            var previous: TrafficSnapshot?
            while !Task.isCancelled {
                if let snapshot = try? await client.snapshot() {
                    if let previous {
                        let rate = snapshot.rate(since: previous)
                        self?.downRate = rate.downBytesPerSecond
                        self?.upRate = rate.upBytesPerSecond
                        self?.record(down: rate.downBytesPerSecond, up: rate.upBytesPerSecond)
                    }
                    previous = snapshot
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func record(down: Double, up: Double) {
        sampleCounter += 1
        rateHistory.append(RateSample(id: sampleCounter, down: down, up: up))
        if rateHistory.count > 60 { rateHistory.removeFirst(rateHistory.count - 60) }
    }
}
