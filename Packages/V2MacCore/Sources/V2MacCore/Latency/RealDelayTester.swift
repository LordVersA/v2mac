import Foundation
import Network

public struct LatencyOptions: Sendable, Equatable {
    public var url: URL
    public var timeout: TimeInterval
    public var concurrency: Int
    public var batchSize: Int
    /// When set, every server that answers is also timed downloading this file.
    public var speedURL: URL?

    public init(
        url: URL = URL(string: "https://www.gstatic.com/generate_204")!,
        timeout: TimeInterval = 8,
        concurrency: Int = 8,
        batchSize: Int = 32,
        speedURL: URL? = nil
    ) {
        self.speedURL = speedURL
        self.url = url
        self.timeout = timeout
        self.concurrency = max(1, concurrency)
        self.batchSize = max(1, batchSize)
    }
}

public struct LatencyTarget: Sendable {
    public var id: UUID
    public var config: JSONValue
    public var kind: ProfileKind

    public init(id: UUID, config: JSONValue, kind: ProfileKind) {
        self.id = id
        self.config = config
        self.kind = kind
    }
}

public enum LatencyOutcome: Sendable, Equatable {
    case ok(ms: Int)
    case timeout
    case invalid(String)
}

public enum SpeedOutcome: Sendable, Equatable {
    case ok(bytesPerSecond: Double)
    case failed
}

public struct SpeedResult: Sendable, Equatable {
    public var id: UUID
    public var outcome: SpeedOutcome
}

public struct LatencyResult: Sendable, Equatable {
    public var id: UUID
    public var outcome: LatencyOutcome
}

enum LatencyConfig {
    /// One loopback SOCKS inbound per outbound, each routed only to its own outbound.
    static func batch(outbounds: [JSONValue], ports: [Int], interface: String? = nil, dialer: DialerSettings = DialerSettings()) -> JSONValue {
        var inbounds: [JSONValue] = []
        var tagged: [JSONValue] = []
        var rules: [JSONValue] = []
        for (i, outbound) in outbounds.enumerated() {
            inbounds.append([
                "tag": .string("in-\(i)"),
                "listen": "127.0.0.1",
                "port": .number(Double(ports[i])),
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": false],
            ])
            let bound = ConfigBuilder.dialing(InsecureTLS.stripping(outbound).setting("tag", to: .string("out-\(i)")), through: dialer)
            tagged.append(interface.map { ConfigBuilder.binding(bound, to: $0) } ?? bound)
            rules.append(["type": "field", "inboundTag": [.string("in-\(i)")], "outboundTag": .string("out-\(i)")])
        }
        if let extra = ConfigBuilder.dialerOutbound(dialer) {
            tagged.append(interface.map { ConfigBuilder.binding(extra, to: $0) } ?? extra)
        }
        return [
            "log": ["loglevel": "none"],
            "inbounds": .array(inbounds),
            "outbounds": .array(tagged),
            "routing": ["domainStrategy": "AsIs", "rules": .array(rules)],
        ]
    }
}

/// Measures real end-to-end delay through throwaway cores; the live connection is never touched.
public struct RealDelayTester: Sendable {
    private let executable: URL
    private let assetDirectory: URL
    private let options: LatencyOptions
    /// Set in TUN mode, so the test cores reach each server directly instead of through the tunnel.
    private let outboundInterface: String?
    /// Fragment and noise settings, so a test dials the server the way a connection would.
    private let dialer: DialerSettings
    /// Pin the certificate of servers whose link says `allowInsecure`, as a connection would.
    private let allowInsecure: Bool

    public init(executable: URL, assetDirectory: URL, options: LatencyOptions = LatencyOptions(), outboundInterface: String? = nil, dialer: DialerSettings = DialerSettings(), allowInsecure: Bool = false) {
        self.dialer = dialer
        self.allowInsecure = allowInsecure
        self.executable = executable
        self.assetDirectory = assetDirectory
        self.options = options
        self.outboundInterface = outboundInterface
    }

    /// Results are delivered as they arrive. Cancelling the calling task stops outstanding
    /// requests and kills the throwaway core.
    public func run(
        _ targets: [LatencyTarget],
        onResult: @escaping @Sendable (LatencyResult) async -> Void,
        onSpeed: @escaping @Sendable (SpeedResult) async -> Void = { _ in }
    ) async {
        let outbounds = targets.filter { $0.kind == .outbound }
        let customs = targets.filter { $0.kind == .custom }

        var index = 0
        while index < outbounds.count {
            if Task.isCancelled { return }
            let end = min(index + options.batchSize, outbounds.count)
            var batch = Array(outbounds[index..<end])
            if allowInsecure {
                let pinned = await InsecureTLS.pinning(batch.map(\.config), timeout: min(options.timeout, 4))
                for i in batch.indices { batch[i].config = pinned[i] }
            }
            await testBatch(batch, onResult: onResult, onSpeed: onSpeed)
            index = end
        }
        for target in customs {
            if Task.isCancelled { return }
            await testCustom(target, onResult: onResult, onSpeed: onSpeed)
        }
    }

    // MARK: Batches

    private func testBatch(_ batch: [LatencyTarget], onResult: @escaping @Sendable (LatencyResult) async -> Void, onSpeed: @escaping @Sendable (SpeedResult) async -> Void, attempt: Int = 0) async {
        guard !batch.isEmpty else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-latency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let ports = try PortUtil.freePorts(batch.count)
            let config = LatencyConfig.batch(outbounds: batch.map(\.config), ports: ports, interface: outboundInterface, dialer: dialer)
            let runner = CoreRunner(executable: executable, assetDirectory: assetDirectory, runDirectory: dir)
            do {
                try await runner.start(config: config, readyPort: ports[0])
            } catch {
                await runner.stop()
                throw error
            }
            await waitUntilListening(ports)
            await withTaskCancellationHandler {
                await measure(batch, ports: ports, onResult: onResult, onSpeed: onSpeed)
            } onCancel: {
                Task { await runner.stop() }
            }
            await runner.stop()
        } catch {
            if Task.isCancelled { return }
            if case CoreError.portInUse = error, attempt < 2 {
                await testBatch(batch, onResult: onResult, onSpeed: onSpeed, attempt: attempt + 1)
                return
            }
            if batch.count == 1 {
                let detail = (error as? CoreError)?.localizedDescription ?? error.localizedDescription
                await onResult(LatencyResult(id: batch[0].id, outcome: .invalid(detail)))
            } else {
                // One bad outbound stops the whole core: bisect to find it.
                let mid = batch.count / 2
                await testBatch(Array(batch[..<mid]), onResult: onResult, onSpeed: onSpeed)
                await testBatch(Array(batch[mid...]), onResult: onResult, onSpeed: onSpeed)
            }
        }
    }

    private func testCustom(_ target: LatencyTarget, onResult: @escaping @Sendable (LatencyResult) async -> Void, onSpeed: @escaping @Sendable (SpeedResult) async -> Void) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-latency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let ports = try PortUtil.freePorts(2)
            var config = try ConfigBuilder.buildCustom(
                config: target.config,
                options: RunOptions(inbound: InboundSettings(port: ports[0]), logLevel: .none, metricsPort: ports[1], dialer: dialer)
            )
            if let outboundInterface { config = ConfigBuilder.bindingOutbounds(of: config, to: outboundInterface) }
            let runner = CoreRunner(executable: executable, assetDirectory: assetDirectory, runDirectory: dir)
            do {
                try await runner.start(config: config, readyPort: ports[0])
            } catch {
                await runner.stop()
                throw error
            }
            await withTaskCancellationHandler {
                await measure([target], ports: [ports[0]], onResult: onResult, onSpeed: onSpeed)
            } onCancel: {
                Task { await runner.stop() }
            }
            await runner.stop()
        } catch {
            if Task.isCancelled { return }
            let detail = (error as? CoreError)?.localizedDescription ?? error.localizedDescription
            await onResult(LatencyResult(id: target.id, outcome: .invalid(detail)))
        }
    }

    /// The core accepts on the first port before the rest are bound; wait for all of them.
    private func waitUntilListening(_ ports: [Int]) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if ports.allSatisfy({ PortUtil.canConnect(port: $0) }) { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: Requests

    private func measure(_ batch: [LatencyTarget], ports: [Int], onResult: @escaping @Sendable (LatencyResult) async -> Void, onSpeed: @escaping @Sendable (SpeedResult) async -> Void) async {
        let url = options.url
        let timeout = options.timeout
        let limit = options.concurrency
        var reachable: [(id: UUID, port: Int)] = []
        let portByID = Dictionary(uniqueKeysWithValues: zip(batch.map(\.id), ports))
        await withTaskGroup(of: LatencyResult.self) { group in
            var next = 0
            func launch() {
                guard next < batch.count else { return }
                let target = batch[next], port = ports[next]
                next += 1
                group.addTask { LatencyResult(id: target.id, outcome: await Self.measureOne(port: port, url: url, timeout: timeout)) }
            }
            for _ in 0..<min(limit, batch.count) { launch() }
            while let result = await group.next() {
                await onResult(result)
                if case .ok = result.outcome, let port = portByID[result.id] { reachable.append((result.id, port)) }
                if Task.isCancelled { group.cancelAll(); continue }
                launch()
            }
        }
        // One at a time: parallel downloads would share the link and understate every server.
        guard let speedURL = options.speedURL else { return }
        for item in reachable {
            if Task.isCancelled { return }
            let outcome = await Self.measureSpeed(port: item.port, url: speedURL, timeout: timeout)
            await onSpeed(SpeedResult(id: item.id, outcome: outcome))
        }
    }

    static func measureSpeed(port: Int, url: URL, timeout: TimeInterval) async -> SpeedOutcome {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failed }
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: nwPort))]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + SpeedMeter().maximumDuration
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let counter = ByteCounter()
        let session = URLSession(configuration: config, delegate: counter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: url))
        task.resume()

        let clock = ContinuousClock()
        var meter = SpeedMeter()
        var start: ContinuousClock.Instant?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let state = counter.snapshot()
            if state.failed || (state.status != nil && !(200..<300).contains(state.status!)) { break }
            if start == nil, state.bytes > 0 { start = clock.now }
            if let begin = start {
                let elapsed = (clock.now - begin) / .seconds(1)
                if state.finished {
                    // The file ended before the speed settled: use the whole transfer.
                    return .ok(bytesPerSecond: max(meter.peak, SpeedMeter.average(bytes: state.bytes, elapsed: elapsed)))
                }
                if meter.add(elapsed: elapsed, bytes: state.bytes) { return .ok(bytesPerSecond: meter.peak) }
            } else if state.finished {
                break
            }
        }
        task.cancel()
        return meter.peak > 0 ? .ok(bytesPerSecond: meter.peak) : .failed
    }

    static func measureOne(port: Int, url: URL, timeout: TimeInterval) async -> LatencyOutcome {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .timeout }
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: nwPort))]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            // Headers are enough; the body is never read.
            let (_, response) = try await session.bytes(for: URLRequest(url: url))
            let elapsed = clock.now - start
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return .timeout }
            return .ok(ms: max(1, Int((elapsed / .milliseconds(1)).rounded())))
        } catch {
            return .timeout
        }
    }
}

/// Counts downloaded bytes from a URLSession delegate; read from a polling loop.
private final class ByteCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct State {
        var bytes: Int64 = 0
        var status: Int?
        var finished = false
        var failed = false
    }
    private let lock = NSLock()
    private var state = State()

    func snapshot() -> State { lock.withLock { state } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { state.status = (response as? HTTPURLResponse)?.statusCode }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { state.bytes += Int64(data.count) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            if error != nil { state.failed = state.bytes == 0 }
            state.finished = true
        }
    }
}
