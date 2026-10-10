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
    /// Events worth a notification (spec 12.8); `AppModel` turns them into one.
    enum Notice: Equatable {
        case failed(server: String, message: String)
        /// The core stopped and every restart attempt failed.
        case lost(server: String)
        case reconnected(server: String)
        case portInUse(busy: Int, suggested: Int?)
    }
    @ObservationIgnored var onNotice: @MainActor (Notice) -> Void = { _ in }
    /// Set when a restart was the app's own doing (sleep, network change), not the user's.
    @ObservationIgnored private var announceReconnect = false
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
    /// What the running core was started with, kept only for servers that can be switched live.
    private var running: (options: RunOptions, plan: RoutingPlan)?
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
        enqueue { await self.performConnect(server, mayLiveSwitch: true) }
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
            announceReconnect = true
            connectActive()
        default: break
        }
    }

    private func scheduleRestart() {
        guard crashCount < Self.restartDelays.count else {
            isRecovering = false
            onNotice(.lost(server: activeServer?.name ?? ""))
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

    private var routingPlan: RoutingPlan {
        switch routingMode {
        case .global: .global
        case .bypassRegions: .bypass(regionRoutes())
        case .direct: .direct
        }
    }

    /// `mayLiveSwitch` is set only when the user picks a server: every other caller is asking
    /// for a real restart (new settings, a network change, a crash).
    private func performConnect(_ server: ActiveServer, mayLiveSwitch: Bool = false) async {
        userWantsRunning = true
        localError = nil
        portConflict = nil
        // Before the running core stops: the administrator prompt can stay open for a while.
        let tunLink = tun.isEnabled ? await tun.prepare() : nil
        if tunLink == nil { tun.down() }
        let inbound = Prefs.inbound
        let plan = routingPlan
        func options(metrics: Int, api: Int?) -> RunOptions {
            RunOptions(inbound: inbound, logLevel: Prefs.logLevel, logConnections: Prefs.logConnections, metricsPort: metrics,
                       tun: tunLink, dialer: Prefs.dialer, dns: Prefs.dns, apiPort: api)
        }

        // Before the core stops as well: asking a server for its certificate takes a moment.
        var outboundConfig = server.config
        if server.kind == .outbound, Prefs.allowInsecure, InsecureTLS.isRequested(by: outboundConfig) {
            outboundConfig = await InsecureTLS.pinning(outboundConfig)
            if outboundConfig["streamSettings"]?["tlsSettings"]?["pinnedPeerCertSha256"] != nil {
                logs.append("[v2mac] \(server.name): accepting the certificate the server presents (allowInsecure)")
            } else {
                logs.append("[v2mac] \(server.name): could not read the server's certificate, so it will be checked normally")
            }
        }

        // Same settings, only the server differs: swap the outbound and keep the core.
        if mayLiveSwitch, Prefs.liveSwitch, coreState == .running, server.kind == .outbound,
           let running, let api = running.options.apiPort,
           options(metrics: running.options.metricsPort, api: api) == running.options, plan == running.plan {
            isSwitching = true
            do {
                let outbound = ConfigBuilder.proxyOutbound(outboundConfig, options: running.options)
                try await runner.replaceOutbound(tag: ConfigBuilder.proxyTag, with: outbound, apiPort: api)
                logs.append("[v2mac] Switched to \(server.name) without restarting the core")
                #if DEBUG
                print("[v2mac-debug] live switch ok")
                #endif
                isSwitching = false
                return
            } catch {
                logs.append("[v2mac] Could not switch without a restart (\(error.localizedDescription)); restarting the core")
            }
        }

        running = nil
        if coreState != .stopped {
            isSwitching = true
            await runner.stop()
        }
        defer { isSwitching = false }

        await runner.setExecutable(AppPaths.coreExecutable)
        port = inbound.port
        do {
            let metrics = try PortUtil.freePort()
            metricsPort = metrics
            let config: JSONValue
            var started: RunOptions?
            switch server.kind {
            case .outbound:
                let options = options(metrics: metrics, api: Prefs.liveSwitch ? try PortUtil.freePort() : nil)
                config = try ConfigBuilder.build(outbound: outboundConfig, options: options, routing: plan)
                started = options
            case .custom:
                config = try ConfigBuilder.buildCustom(config: server.config, options: options(metrics: metrics, api: nil))
            }
            logs.append("[v2mac] Connecting to \(server.name)")
            try await runner.start(config: config, readyPort: port)
            running = started.map { ($0, plan) }
            Prefs.wasRunning = true
            if tunLink != nil { tun.up() }
        } catch {
            tun.down()
            if case CoreError.portInUse(let busy) = error {
                portConflict = suggestPort(avoiding: busy)
                onNotice(.portInUse(busy: busy, suggested: portConflict?.suggested))
            } else if crashCount == 0 {
                // A restart attempt that fails is reported once, when the attempts run out.
                onNotice(.failed(server: server.name, message: error.localizedDescription))
            }
            announceReconnect = false
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
            if isRecovering || announceReconnect { onNotice(.reconnected(server: activeServer?.name ?? "")) }
            announceReconnect = false
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
