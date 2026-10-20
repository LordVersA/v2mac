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
    /// Where traffic comes out, looked up through the proxy after every connect (spec 9.6).
    enum ExitState: Equatable {
        case unknown
        case checking
        case known(ExitInfo)
        /// Nothing answered through the proxy: the core runs but traffic is not passing.
        case failed
    }
    private(set) var exit: ExitState = .unknown
    @ObservationIgnored private var exitTask: Task<Void, Never>?

    /// Events worth a notification (spec 12.6); `AppModel` turns them into one.
    enum Notice: Equatable {
        case failed(server: String, message: String)
        /// The core stopped and every restart attempt failed.
        case lost(server: String)
        case reconnected(server: String)
        case portInUse(busy: Int, suggested: Int?)
        /// The chosen outgoing network disconnected, so the setting went back to Automatic.
        case networkGone(name: String)
    }
    @ObservationIgnored var onNotice: @MainActor (Notice) -> Void = { _ in }
    @ObservationIgnored var onTunFailure: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var automaticCandidates: @MainActor (UUID) -> [ActiveServer] = { _ in [] }
    @ObservationIgnored var onAutomaticResults: @MainActor ([LatencyResult]) async -> Void = { _ in }
    private(set) var isSelectingAutomatically = false
    private(set) var healthFailed = false
    @ObservationIgnored private var selectionTask: Task<[LatencyResult], Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    private var selectionPolicy = AutoSelectionPolicy()
    /// Spec 9.7, conditions: the live download rate, while that condition is on.
    @ObservationIgnored private var speedWatch: SlowSpeedWatch?
    /// Invalidates queued work and results after a manual command, disconnect or settings change.
    private var commandGeneration = 0
    private var pendingConnectionGeneration: Int?
    private static let noWorkingServer = String(localized: "No working server answered in this group.")
    /// Set when a restart was the app's own doing (sleep, network change), not the user's.
    @ObservationIgnored private var announceReconnect = false
    /// Supplied by the region pack service: rules for enabled, downloaded packs.
    var regionRoutes: @MainActor () -> [RegionRoute] = { [] }
    /// Set when the configured port is taken: the busy port and a free one to offer.
    private(set) var portConflict: PortConflict?
    private(set) var isRecovering = false
    /// Servers a connection came up on, newest first; the active one is among them.
    private(set) var recentServerIDs: [UUID] = Prefs.recentServerIDs
    private(set) var downRate: Double = 0
    private(set) var upRate: Double = 0
    /// Session and total traffic (spec 12.8); counted only while `Prefs.countTraffic` is on.
    private(set) var usage = Prefs.trafficUsage
    /// The running core's last counters, so each poll adds only what is new.
    private var lastCounters: TrafficSnapshot?
    /// Usage is written every half minute, and when the core stops, not on every poll.
    @ObservationIgnored private var usageSaved = ContinuousClock.now
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
    /// Fed from the access log, which is always on; its lines reach `logs` only with "Log connections".
    let watcher = ConnectionWatcher()
    let tun: TunController
    let killSwitch: KillSwitchController
    let systemProxy: SystemProxyController
    private let runner: CoreRunner
    private let executable: @MainActor () -> URL
    private let assetDirectory: URL
    private let healthInterval: Duration
    private var metricsPort: Int?
    /// What the running core was started with, kept only for servers that can be switched live.
    private var running: (options: RunOptions, plan: RoutingPlan, custom: CustomRules)?
    private var statsTask: Task<Void, Never>?
    private var queue: Task<Void, Never>?
    private var userWantsRunning = false
    private var crashCount = 0
    private var recoveryTask: Task<Void, Never>?
    private var stableTask: Task<Void, Never>?
    private var lifecycle: LifecycleMonitor?

    var phase: Phase {
        if isSwitching || isRecovering || isSelectingAutomatically { return .switching }
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
    var connectedTitle: String { tun.isOn ? String(localized: "System tunnel active") : String(localized: "Local proxy connected") }

    init(logs: LogStore, executable: @escaping @MainActor () -> URL = { AppPaths.coreExecutable },
         assetDirectory: URL = AppPaths.assetsDirectory, runDirectory: URL = AppPaths.runDirectory,
         tun: TunController? = nil, monitorsLifecycle: Bool = true, healthInterval: Duration = .seconds(30)) {
        self.logs = logs
        self.executable = executable
        self.assetDirectory = assetDirectory
        self.healthInterval = healthInterval
        let tun = tun ?? TunController(logs: logs)
        self.tun = tun
        killSwitch = KillSwitchController(session: tun)
        systemProxy = SystemProxyController(session: tun)
        runner = CoreRunner(
            executable: executable(),
            assetDirectory: assetDirectory,
            runDirectory: runDirectory,
            allowedExecutables: [executable(), AppPaths.bundledCore]
        )
        self.tun.onFailure = { [weak self] message in
            self?.onTunFailure(message)
            self?.tunFailurePolicyChanged()
        }
        let states = runner.states
        let lines = runner.logs
        if monitorsLifecycle { lifecycle = LifecycleMonitor(
            ignoredInterface: { [weak self] in self?.tun.interfaceName },
            onTrigger: { [weak self] reason in self?.systemEvent(reason) }
        ) }
        Task { [weak self] in
            for await state in states { self?.coreStateChanged(state) }
        }
        Task { [weak self] in
            for await line in lines {
                if let seen = SeenConnection(line: line) { self?.watcher.record(seen) }
                // Every access line, read or not, stays out of the log unless the user asked for them.
                if !Prefs.logConnections, line.contains(" from "), line.contains(" accepted ") || line.contains(" rejected ") { continue }
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

    /// Spec 9.9. Takes effect at once while a connection is wanted.
    func setSystemProxyEnabled(_ on: Bool) {
        guard on != systemProxy.isEnabled else { return }
        systemProxy.setEnabled(on)
        if on, coreState == .running {
            let port = port
            Task { await systemProxy.apply(port: port) }
        } else if !on {
            systemProxy.clear()
        }
        // Whether the proxy port skips the rules depends on it.
        reconnectIfRunning()
    }

    /// Spec 9.8. Turned on while a connection is wanted, the block goes up at once.
    func setKillSwitchEnabled(_ on: Bool) {
        Prefs.killSwitch = on
        if !on {
            Task { await killSwitch.lift() }
        } else if userWantsRunning, let server = activeServer {
            Task { _ = await killSwitch.arm(allowing: KillSwitch.hosts(in: server.config, kind: server.kind)) }
        }
    }

    /// Spec 8.4, Outgoing network. Restarts a running core on the new network.
    func setOutboundInterface(_ name: String?) {
        guard name != Prefs.outboundInterface else { return }
        Prefs.outboundInterface = name
        reconnectIfRunning()
    }

    /// The network the user picked, while it is connected. One that has gone is dropped: the
    /// setting goes back to Automatic and the user is told.
    private func chosenInterface() -> String? {
        guard let name = Prefs.outboundInterface else { return nil }
        if NetworkInterfaces.isConnected(name) { return name }
        Prefs.outboundInterface = nil
        logs.append("[v2mac] \(name) is no longer connected; using the automatic network")
        onNotice(.networkGone(name: name))
        return nil
    }

    /// The interface latency tests are bound to: the chosen network, or the physical one in TUN mode.
    var testInterface: String? {
        Prefs.outboundInterface.flatMap { NetworkInterfaces.isConnected($0) ? $0 : nil } ?? tun.physicalInterface
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
        if activeServer?.id != server?.id { cancelAutomation() }
        activeServer = server
        Prefs.activeProfileID = server?.id
    }

    /// Activating a server connects to it immediately (decision 19).
    func activate(_ server: ActiveServer) {
        cancelRecovery()
        selectionPolicy.selectManually()
        setActive(server)
        requestConnect(server, mayLiveSwitch: true)
    }

    func connectActive() {
        guard let server = activeServer else { return }
        requestConnect(server, selection: .initial)
    }

    func disconnect() {
        userWantsRunning = false
        commandGeneration += 1
        cancelAutomation()
        selectionPolicy = AutoSelectionPolicy()
        cancelRecovery()
        portConflict = nil
        // First, so nothing is left pointing at a core that is about to stop.
        tun.down(clearingError: true)
        systemProxy.clear()
        Task { await killSwitch.lift() }
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
        let lostNetwork = Prefs.outboundInterface != nil && chosenInterface() == nil
        // In TUN mode, or on a chosen network that went away, the core is bound to an interface,
        // so a network change always needs a restart.
        guard Prefs.restartOnWakeOrNetwork || tun.isEnabled || lostNetwork, userWantsRunning, activeServer != nil else { return }
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
            if Prefs.autoSelectServer, automationAllowed, let activeServer {
                requestConnect(activeServer, selection: .fallback)
            }
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
            if let activeServer { requestConnect(activeServer) }
        }
    }

    /// Puts a server at the head of the recent list, which keeps the last six.
    func noteRecent(_ id: UUID) {
        guard recentServerIDs.first != id else { return }
        recentServerIDs = Array(([id] + recentServerIDs.filter { $0 != id }).prefix(6))
        Prefs.recentServerIDs = recentServerIDs
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
        commandGeneration += 1
        cancelAutomation()
        cancelRecovery()
        await tun.endSession()
        await queue?.value
        await runner.stop()
        saveUsage()
    }

    /// Asks through the local proxy, a few times: the first request to a server can be slow.
    /// Skipped in Direct mode, where the answer would be the user's own address.
    func checkExit() {
        exitTask?.cancel()
        guard Prefs.checkExit, coreState == .running, routingMode != .direct else {
            exit = .unknown
            return
        }
        exit = .checking
        let inbound = Prefs.inbound
        let route = FetchRoute.localProxy(port: port, username: inbound.username, password: inbound.password)
        exitTask = Task { [weak self] in
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                let info = await ExitLookup.lookup(route: route)
                if Task.isCancelled { return }
                if let info {
                    self?.exit = .known(info)
                    #if DEBUG
                    print("[v2mac-debug] exit: \(info.countryCode ?? "??") \(info.city ?? "-")")
                    #endif
                    return
                }
            }
            self?.exit = .failed
            self?.logs.append("[v2mac] Nothing answered through the server: traffic is not passing")
            #if DEBUG
            print("[v2mac-debug] exit: failed")
            #endif
        }
    }

    // MARK: Internals

    private var automationAllowed: Bool { routingMode != .direct }

    func autoSelectionChanged() {
        let wasConnecting = pendingConnectionGeneration != nil
        commandGeneration += 1
        cancelAutomation()
        selectionPolicy = AutoSelectionPolicy()
        if localError == Self.noWorkingServer { localError = nil }
        if userWantsRunning {
            if Prefs.autoSelectServer || wasConnecting || coreState != .running { connectActive() }
            else if coreState == .running { startHealthChecks() }
        }
    }

    func tunFailurePolicyChanged() {
        guard tun.isEnabled, tun.failureMessage != nil, Prefs.tunFailurePolicy.stopsProxy else { return }
        stopForTunFailure()
    }

    private func stopForTunFailure() {
        let message = tun.failureMessage ?? String(localized: "The system tunnel could not start.")
        userWantsRunning = false
        Prefs.wasRunning = false
        commandGeneration += 1
        cancelAutomation()
        cancelRecovery()
        localError = message + " " + String(localized: "Connection stopped by the TUN failure policy.")
        tun.down()
        enqueue { await self.runner.stop() }
    }

    /// The kill switch is on but could not go up: nothing connects without it.
    private func stopForKillSwitchFailure() {
        var message = String(localized: "The kill switch could not be turned on.")
        if case .failed(let detail) = killSwitch.state { message += " " + detail }
        userWantsRunning = false
        Prefs.wasRunning = false
        commandGeneration += 1
        cancelAutomation()
        cancelRecovery()
        localError = message + " " + String(localized: "V2Mac did not connect, so no traffic went around it.")
        tun.down()
        systemProxy.clear()
        enqueue { await self.runner.stop() }
    }

    private func cancelAutomation() {
        selectionTask?.cancel()
        selectionTask = nil
        healthTask?.cancel()
        healthTask = nil
        isSelectingAutomatically = false
        healthFailed = false
    }

    private func requestConnect(_ server: ActiveServer, mayLiveSwitch: Bool = false, selection: AutoSelectionPolicy.Reason? = nil) {
        commandGeneration += 1
        let generation = commandGeneration
        cancelAutomation()
        speedWatch = nil
        // A connect from off starts a new session; reconnects and switches continue it.
        if !userWantsRunning { usage.startSession() }
        userWantsRunning = true
        pendingConnectionGeneration = generation
        enqueue {
            defer {
                if self.pendingConnectionGeneration == generation { self.pendingConnectionGeneration = nil }
            }
            guard self.commandGeneration == generation, self.userWantsRunning else { return }
            var target = server
            if let selection, Prefs.autoSelectServer, self.automationAllowed,
               selection == .fallback || selection == .degraded || !self.selectionPolicy.manualOverride {
                self.isSelectingAutomatically = true
                let candidates = self.automaticCandidates(server.id)
                let results = await self.measureCandidates(candidates, activeID: server.id)
                guard self.commandGeneration == generation, self.userWantsRunning else { return }
                self.isSelectingAutomatically = false
                if let id = self.selectionPolicy.choose(results: results, currentID: server.id, reason: selection, now: .now),
                   let chosen = self.automaticCandidates(server.id).first(where: { $0.id == id }) {
                    target = chosen
                    self.selectionPolicy.didSwitch(at: .now)
                    self.logs.append("[v2mac] Automatically selected \(chosen.name) using real response delay")
                    self.setActive(chosen)
                } else if selection == .degraded {
                    // Nothing better answered: the connection stays as it is.
                    self.logs.append("[v2mac] No faster server answered; staying on \(server.name)")
                    self.startHealthChecks()
                    return
                } else if !results.contains(where: { result in
                    guard result.id == server.id, case .ok = result.outcome else { return false }
                    return true
                }) {
                    self.healthFailed = true
                    self.logs.append("[v2mac] \(Self.noWorkingServer)")
                    if self.coreState != .running {
                        self.localError = Self.noWorkingServer
                        self.tun.down()
                    }
                    self.startHealthChecks()
                    return
                }
            }
            await self.performConnect(target, mayLiveSwitch: mayLiveSwitch, generation: generation)
        }
    }

    private func measureCandidates(_ candidates: [ActiveServer], activeID: UUID) async -> [LatencyResult] {
        let tester = RealDelayTester(executable: executable(), assetDirectory: assetDirectory,
                                     options: Prefs.latencyOptions, outboundInterface: testInterface,
                                     dialer: Prefs.dialer, allowInsecure: Prefs.allowInsecure)
        let targets = candidates.map { LatencyTarget(id: $0.id, config: $0.config, kind: $0.kind) }
        await killSwitch.allow(candidates.flatMap { KillSwitch.hosts(in: $0.config, kind: $0.kind) })
        let task = Task {
            let collector = AutomaticLatencyResults()
            await tester.run(targets) { await collector.append($0) }
            return await collector.results
        }
        selectionTask = task
        let results = await task.value
        guard !task.isCancelled else { return [] }
        // Subscriptions or editing can replace/remove a config while its request is in flight.
        let current = automaticCandidates(activeID)
        let validIDs = Set(current.filter { candidate in
            candidates.contains { $0.id == candidate.id && $0.kind == candidate.kind && $0.config == candidate.config }
        }.map(\.id))
        let validResults = results.filter { validIDs.contains($0.id) }
        await onAutomaticResults(validResults)
        let byID = Dictionary(uniqueKeysWithValues: validResults.map { ($0.id, $0) })
        return current.compactMap { byID[$0.id] }
    }

    private func startHealthChecks() {
        healthTask?.cancel()
        guard Prefs.autoSelectServer, userWantsRunning, automationAllowed else { return }
        let generation = commandGeneration
        healthTask = Task { [weak self] in
            var nextOptimization = Date.now.addingTimeInterval(180)
            while !Task.isCancelled {
                guard let interval = self?.healthInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, commandGeneration == generation,
                      Prefs.autoSelectServer, userWantsRunning, let server = activeServer else { return }
                if coreState != .running {
                    guard portConflict == nil, !isRecovering else { return }
                    requestConnect(server, selection: .fallback)
                    return
                }
                let inbound = Prefs.inbound
                let outcome = await ProxyHealthProbe.measure(
                    route: .localProxy(port: port, username: inbound.username, password: inbound.password),
                    url: Prefs.latencyOptions.url, timeout: Prefs.latencyOptions.timeout
                )
                guard !Task.isCancelled, commandGeneration == generation else { return }
                let needsFallback = selectionPolicy.recordHealth(outcome)
                healthFailed = needsFallback
                if case .ok = outcome, localError == Self.noWorkingServer { localError = nil }
                if needsFallback {
                    logs.append("[v2mac] Two real response checks failed; testing fallback servers")
                    requestConnect(server, mayLiveSwitch: true, selection: .fallback)
                    return
                }
                if let limit = Prefs.switchDelayLimit, selectionPolicy.recordDelay(outcome, limit: limit) {
                    logs.append("[v2mac] Two checks in a row answered slower than \(limit) ms; looking for a faster server")
                    requestConnect(server, mayLiveSwitch: true, selection: .degraded)
                    return
                }
                // Testing the whole group costs battery and data: in Low Power Mode only failures switch.
                guard !selectionPolicy.manualOverride, Date.now >= nextOptimization, !ProcessInfo.processInfo.isLowPowerModeEnabled else { continue }
                nextOptimization = Date.now.addingTimeInterval(180)
                let candidates = automaticCandidates(server.id)
                var results = await measureCandidates(candidates, activeID: server.id)
                guard !Task.isCancelled, commandGeneration == generation else { return }
                // Use the response from the actual live connection for the hysteresis comparison.
                results.removeAll { $0.id == server.id }
                results.append(LatencyResult(id: server.id, outcome: outcome))
                if let id = selectionPolicy.choose(results: results, currentID: server.id, reason: .faster, now: .now),
                   let chosen = automaticCandidates(server.id).first(where: { $0.id == id }) {
                    selectionPolicy.didSwitch(at: .now)
                    setActive(chosen)
                    requestConnect(chosen, mayLiveSwitch: true)
                    return
                }
            }
        }
    }

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
        case .rulesOnly: .rulesOnly
        }
    }

    /// Server activation and automatic fallback may switch live; settings and lifecycle
    /// changes require a restart.
    private func performConnect(_ server: ActiveServer, mayLiveSwitch: Bool = false, generation: Int) async {
        guard commandGeneration == generation, userWantsRunning else { return }
        localError = nil
        portConflict = nil
        do { try SecretStore.shared.values() }
        catch {
            localError = String(localized: "Saved secrets could not be read. Check Secret storage in General settings.")
            return
        }
        // Before anything connects, so nothing leaves around the connection meanwhile (spec 9.8).
        if Prefs.killSwitch {
            let armed = await killSwitch.arm(allowing: KillSwitch.hosts(in: server.config, kind: server.kind))
            guard commandGeneration == generation, userWantsRunning else { return }
            guard armed else {
                stopForKillSwitchFailure()
                return
            }
        }
        // Before the running core stops: the administrator prompt can stay open for a while.
        let requestedTun = tun.isEnabled
        let outboundInterface = chosenInterface()
        let tunLink = requestedTun ? await tun.prepare(outboundInterface: outboundInterface) : nil
        guard commandGeneration == generation, userWantsRunning else { return }
        if requestedTun, tunLink == nil, Prefs.tunFailurePolicy.stopsProxy {
            stopForTunFailure()
            return
        }
        if tunLink == nil { tun.down() }
        let inbound = Prefs.inbound
        let plan = routingPlan
        var custom = Prefs.customRules
        if custom.needsApps { custom.installedApps = await InstalledApps.all() }
        func options(metrics: Int, api: Int?) -> RunOptions {
            RunOptions(inbound: inbound, logLevel: Prefs.logLevel, logConnections: true, metricsPort: metrics,
                       tun: tunLink, dialer: Prefs.dialer, dns: Prefs.dns, apiPort: api, warpExit: Prefs.warpExit,
                       outboundInterface: outboundInterface)
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
        guard commandGeneration == generation, userWantsRunning else { return }

        // Same settings, only the server differs: swap the outbound and keep the core. Not in TUN
        // mode, whose config lists the server's name for its own lookups (`ConfigBuilder.tunDNS`).
        if mayLiveSwitch, Prefs.liveSwitch, coreState == .running, server.kind == .outbound,
           let running, running.options.tun == nil, let api = running.options.apiPort,
           options(metrics: running.options.metricsPort, api: api) == running.options, plan == running.plan, custom == running.custom {
            isSwitching = true
            do {
                let outbound = ConfigBuilder.proxyOutbound(outboundConfig, options: running.options)
                try await runner.replaceOutbound(tag: ConfigBuilder.serverTag(running.options), with: outbound, apiPort: api)
                logs.append("[v2mac] Switched to \(server.name) without restarting the core")
                noteRecent(server.id)
                checkExit()
                #if DEBUG
                print("[v2mac-debug] live switch ok")
                #endif
                isSwitching = false
                startHealthChecks()
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

        await runner.setExecutable(executable())
        guard commandGeneration == generation, userWantsRunning else { return }
        port = inbound.port
        do {
            let metrics = try PortUtil.freePort()
            metricsPort = metrics
            let config: JSONValue
            var started: RunOptions?
            switch server.kind {
            case .outbound:
                let options = options(metrics: metrics, api: Prefs.liveSwitch ? try PortUtil.freePort() : nil)
                config = try ConfigBuilder.build(outbound: outboundConfig, options: options, routing: plan, custom: custom)
                started = options
            case .custom:
                config = try ConfigBuilder.buildCustom(config: server.config, options: options(metrics: metrics, api: nil), routing: plan, custom: custom)
            }
            logs.append("[v2mac] Connecting to \(server.name)")
            watcher.routingMode = routingMode
            watcher.customRules = custom
            watcher.hasConfigFallback = server.kind == .custom
            let outbounds = config["outbounds"]?.arrayValue ?? []
            watcher.outboundActions = Dictionary(outbounds.compactMap { outbound -> (String, CustomRule.Action)? in
                guard let tag = outbound["tag"]?.stringValue else { return nil }
                let action: CustomRule.Action = switch outbound["protocol"]?.stringValue {
                case "freedom": .direct
                case "blackhole": .block
                default: .proxy
                }
                return (tag, action)
            }, uniquingKeysWith: { first, _ in first })
            let importedTags = Set((server.config["outbounds"]?.arrayValue ?? []).compactMap { $0["tag"]?.stringValue })
            watcher.modeOutbounds = Set(outbounds.compactMap { $0["tag"]?.stringValue }).subtracting(importedTags)
            try await runner.start(config: config, readyPort: port)
            guard commandGeneration == generation, userWantsRunning else { await runner.stop(); return }
            running = started.map { ($0, plan, custom) }
            Prefs.wasRunning = true
            if tunLink != nil { tun.up() }
            if systemProxy.isEnabled {
                let port = port
                Task { await systemProxy.apply(port: port) }
            }
            startHealthChecks()
        } catch {
            tun.down()
            if Prefs.autoSelectServer, !isRecovering { startHealthChecks() }
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
            if let activeServer { noteRecent(activeServer.id) }
            if isRecovering || announceReconnect { onNotice(.reconnected(server: activeServer?.name ?? "")) }
            announceReconnect = false
            isRecovering = false
            checkExit()
            stableTask?.cancel()
            stableTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { self?.crashCount = 0 }
            }
            startPolling()
        } else {
            stableTask?.cancel()
            exitTask?.cancel()
            exit = .unknown
            if case .failed = state, userWantsRunning, portConflict == nil, previous == .running || isRecovering {
                scheduleRestart()
            }
            // A core that is not coming back must not keep the whole system's traffic.
            if case .failed = state, !isRecovering { tun.down() }
            statsTask?.cancel()
            statsTask = nil
            saveUsage()
            lastCounters = nil
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
                    self?.count(snapshot)
                    if let previous {
                        let rate = snapshot.rate(since: previous)
                        self?.downRate = rate.downBytesPerSecond
                        self?.upRate = rate.upBytesPerSecond
                        self?.record(down: rate.downBytesPerSecond, up: rate.upBytesPerSecond)
                        self?.watchSpeed(rate.downBytesPerSecond)
                    }
                    previous = snapshot
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    #if DEBUG
    /// `-debugFakeRates YES`: a made-up minute of traffic, so a snapshot shows the graph.
    func fakeRates() {
        rateHistory = (1...60).map { i in
            let t = Double(i)
            let down = (2.2 + sin(t / 6) * 1.2 + sin(t / 2.3) * 0.5 + (i > 40 && i < 50 ? 2.5 : 0)) * 1_048_576
            return RateSample(id: i, down: down, up: (0.4 + sin(t / 4) * 0.25) * 1_048_576)
        }
        sampleCounter = 60
        downRate = rateHistory[59].down
        upRate = rateHistory[59].up
        usage.startSession(at: Date().addingTimeInterval(-4000))
        usage.add(up: 88_000_000, down: 1_340_000_000)
    }
    #endif

    private func count(_ snapshot: TrafficSnapshot) {
        let new = snapshot.bytes(since: lastCounters)
        lastCounters = snapshot
        guard Prefs.countTraffic, new.up > 0 || new.down > 0 else { return }
        usage.add(up: new.up, down: new.down)
        guard ContinuousClock.now - usageSaved >= .seconds(30) else { return }
        saveUsage()
    }

    private func saveUsage() {
        usageSaved = .now
        Prefs.trafficUsage = usage
    }

    func resetTotalUsage() {
        usage.resetTotal()
        Prefs.trafficUsage = usage
    }

    /// Spec 9.7, conditions: a download rate that stayed under the floor looks for a faster server.
    private func watchSpeed(_ rate: Double) {
        guard Prefs.autoSelectServer, automationAllowed, userWantsRunning, !isSelectingAutomatically, !isSwitching,
              let server = activeServer, let floor = Prefs.switchSpeedFloor else {
            speedWatch = nil
            return
        }
        if speedWatch?.floor != floor.bytesPerSecond || speedWatch?.seconds != floor.minutes * 60 {
            speedWatch = SlowSpeedWatch(floor: floor.bytesPerSecond, minutes: floor.minutes)
        }
        guard speedWatch?.record(rate) == true else { return }
        speedWatch = nil
        logs.append("[v2mac] Download speed stayed under \(Format.steadyRate(floor.bytesPerSecond)) for \(floor.minutes) min; looking for a faster server")
        requestConnect(server, mayLiveSwitch: true, selection: .degraded)
    }

    private func record(down: Double, up: Double) {
        sampleCounter += 1
        rateHistory.append(RateSample(id: sampleCounter, down: down, up: up))
        if rateHistory.count > 60 { rateHistory.removeFirst(rateHistory.count - 60) }
    }
}
