import Foundation

/// Runs one Xray process: config file, readiness, log stream, clean stop.
/// Crash-restart policy lives above this type.
public actor CoreRunner {
    public nonisolated let logs: AsyncStream<String>
    public nonisolated let states: AsyncStream<CoreState>

    private let logContinuation: AsyncStream<String>.Continuation
    private let stateContinuation: AsyncStream<CoreState>.Continuation

    private var executable: URL
    private let assetDirectory: URL
    private let runDirectory: URL
    private let allowedExecutables: [URL]

    public private(set) var state: CoreState = .stopped {
        didSet { if oldValue != state { stateContinuation.yield(state) } }
    }

    private var process: Process?
    private var output: ProcessOutput?
    private var generation = 0

    private var configURL: URL { runDirectory.appendingPathComponent("config.json") }
    private var pidURL: URL { runDirectory.appendingPathComponent("xray.pid") }

    public init(
        executable: URL,
        assetDirectory: URL,
        runDirectory: URL,
        allowedExecutables: [URL]? = nil
    ) {
        self.executable = executable
        self.assetDirectory = assetDirectory
        self.runDirectory = runDirectory
        self.allowedExecutables = allowedExecutables ?? [executable]
        (logs, logContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(5000))
        (states, stateContinuation) = AsyncStream.makeStream(of: CoreState.self, bufferingPolicy: .bufferingNewest(16))
    }

    deinit {
        logContinuation.finish()
        stateContinuation.finish()
    }

    /// Picks up an updated or reverted core without recreating the runner.
    public func setExecutable(_ url: URL) { executable = url }

    // MARK: Start

    /// Starts the core with `config`. `readyPort` is the mixed inbound port,
    /// used for the pre-check and as a readiness fallback.
    public func start(config: JSONValue, readyPort: Int, listenHost: String = "127.0.0.1") async throws {
        switch state {
        case .stopped, .failed: break
        default: throw CoreError.alreadyRunning
        }

        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            let error = CoreError.coreNotFound(executable.path)
            state = .failed(error.localizedDescription)
            throw error
        }

        state = .starting
        do {
            try await launch(config: config, readyPort: readyPort, listenHost: listenHost)
            state = .running
        } catch {
            await terminateCurrentProcess()
            removeRunFiles()
            let coreError = (error as? CoreError) ?? (error is CancellationError ? .cancelled : .startFailed(error.localizedDescription))
            if state == .starting {
                state = .failed(coreError.localizedDescription)
            }
            throw coreError
        }
    }

    private func launch(config: JSONValue, readyPort: Int, listenHost: String) async throws {
        OrphanKiller.terminateOrphan(pidFile: pidURL, allowedExecutables: allowedExecutables)

        guard PortUtil.isFree(port: readyPort, host: listenHost) else {
            throw CoreError.portInUse(readyPort)
        }

        try prepareRunDirectory()
        try writeConfig(config)

        let output = ProcessOutput { [logContinuation] line in logContinuation.yield(line) }
        self.output = output

        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", "-c", configURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["XRAY_LOCATION_ASSET": assetDirectory.path]
        ) { _, new in new }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        for (index, pipe) in [outPipe, errPipe].enumerated() {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    output.flush(stream: index)
                } else {
                    output.ingest(data, stream: index)
                }
            }
        }

        generation += 1
        let gen = generation
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { await self?.handleExit(generation: gen, status: status) }
        }

        logContinuation.yield("[v2mac] Starting \(executable.lastPathComponent)")
        try process.run()
        self.process = process
        try? "\(process.processIdentifier)".write(to: pidURL, atomically: true, encoding: .utf8)

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard state == .starting else { throw CoreError.cancelled }
            if !process.isRunning {
                try? await Task.sleep(for: .milliseconds(150))
                let lines = output.recentLines
                if CoreOutputParser.indicatesPortBusy(lines) { throw CoreError.portInUse(readyPort) }
                throw CoreError.exitedBeforeReady(
                    code: process.terminationStatus,
                    detail: CoreOutputParser.failureDetail(from: lines)
                )
            }
            if output.readySeen || PortUtil.canConnect(port: readyPort) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CoreError.readyTimeout
    }

    // MARK: Stop

    public func stop() async {
        guard process != nil else {
            if state != .stopped { state = .stopped }
            removeRunFiles()
            return
        }
        state = .stopping
        await terminateCurrentProcess()
        removeRunFiles()
        state = .stopped
    }

    private func terminateCurrentProcess() async {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            await waitForExit(process, timeout: .seconds(2))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                await waitForExit(process, timeout: .seconds(2))
            }
        }
        self.process = nil
    }

    private func waitForExit(_ process: Process, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Unexpected exit

    private func handleExit(generation gen: Int, status: Int32) {
        guard gen == generation, state == .running else { return }
        logContinuation.yield("[v2mac] Xray exited unexpectedly (exit \(status))")
        process = nil
        removeRunFiles()
        state = .failed("Xray stopped unexpectedly (exit \(status)).")
    }

    // MARK: Files

    private func prepareRunDirectory() throws {
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func writeConfig(_ config: JSONValue) throws {
        let data = try config.data(pretty: true)
        let tmp = runDirectory.appendingPathComponent("config.json.tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CoreError.startFailed("Could not write the Xray config.")
        }
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
    }

    private func removeRunFiles() {
        try? FileManager.default.removeItem(at: configURL)
        try? FileManager.default.removeItem(at: pidURL)
    }
}
