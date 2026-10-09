import Foundation
import Network

public struct LatencyOptions: Sendable, Equatable {
    public var url: URL
    public var timeout: TimeInterval
    public var concurrency: Int
    public var batchSize: Int

    public init(
        url: URL = URL(string: "https://www.gstatic.com/generate_204")!,
        timeout: TimeInterval = 8,
        concurrency: Int = 8,
        batchSize: Int = 32
    ) {
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

public struct LatencyResult: Sendable, Equatable {
    public var id: UUID
    public var outcome: LatencyOutcome
}

enum LatencyConfig {
    /// One loopback SOCKS inbound per outbound, each routed only to its own outbound.
    static func batch(outbounds: [JSONValue], ports: [Int]) -> JSONValue {
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
            tagged.append(outbound.setting("tag", to: .string("out-\(i)")))
            rules.append(["type": "field", "inboundTag": [.string("in-\(i)")], "outboundTag": .string("out-\(i)")])
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

    public init(executable: URL, assetDirectory: URL, options: LatencyOptions = LatencyOptions()) {
        self.executable = executable
        self.assetDirectory = assetDirectory
        self.options = options
    }

    /// Results are delivered as they arrive. Cancelling the calling task stops outstanding
    /// requests and kills the throwaway core.
    public func run(_ targets: [LatencyTarget], onResult: @escaping @Sendable (LatencyResult) async -> Void) async {
        let outbounds = targets.filter { $0.kind == .outbound }
        let customs = targets.filter { $0.kind == .custom }

        var index = 0
        while index < outbounds.count {
            if Task.isCancelled { return }
            let end = min(index + options.batchSize, outbounds.count)
            await testBatch(Array(outbounds[index..<end]), onResult: onResult)
            index = end
        }
        for target in customs {
            if Task.isCancelled { return }
            await testCustom(target, onResult: onResult)
        }
    }

    // MARK: Batches

    private func testBatch(_ batch: [LatencyTarget], onResult: @escaping @Sendable (LatencyResult) async -> Void, attempt: Int = 0) async {
        guard !batch.isEmpty else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-latency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let ports = try PortUtil.freePorts(batch.count)
            let config = LatencyConfig.batch(outbounds: batch.map(\.config), ports: ports)
            let runner = CoreRunner(executable: executable, assetDirectory: assetDirectory, runDirectory: dir)
            do {
                try await runner.start(config: config, readyPort: ports[0])
            } catch {
                await runner.stop()
                throw error
            }
            await waitUntilListening(ports)
            await withTaskCancellationHandler {
                await measure(batch, ports: ports, onResult: onResult)
            } onCancel: {
                Task { await runner.stop() }
            }
            await runner.stop()
        } catch {
            if Task.isCancelled { return }
            if case CoreError.portInUse = error, attempt < 2 {
                await testBatch(batch, onResult: onResult, attempt: attempt + 1)
                return
            }
            if batch.count == 1 {
                let detail = (error as? CoreError)?.localizedDescription ?? error.localizedDescription
                await onResult(LatencyResult(id: batch[0].id, outcome: .invalid(detail)))
            } else {
                // One bad outbound stops the whole core: bisect to find it.
                let mid = batch.count / 2
                await testBatch(Array(batch[..<mid]), onResult: onResult)
                await testBatch(Array(batch[mid...]), onResult: onResult)
            }
        }
    }

    private func testCustom(_ target: LatencyTarget, onResult: @escaping @Sendable (LatencyResult) async -> Void) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-latency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let ports = try PortUtil.freePorts(2)
            let config = try ConfigBuilder.buildCustom(
                config: target.config,
                options: RunOptions(inbound: InboundSettings(port: ports[0]), logLevel: .none, metricsPort: ports[1])
            )
            let runner = CoreRunner(executable: executable, assetDirectory: assetDirectory, runDirectory: dir)
            do {
                try await runner.start(config: config, readyPort: ports[0])
            } catch {
                await runner.stop()
                throw error
            }
            await withTaskCancellationHandler {
                await measure([target], ports: [ports[0]], onResult: onResult)
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

    private func measure(_ batch: [LatencyTarget], ports: [Int], onResult: @escaping @Sendable (LatencyResult) async -> Void) async {
        let url = options.url
        let timeout = options.timeout
        let limit = options.concurrency
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
                if Task.isCancelled { group.cancelAll(); continue }
                launch()
            }
        }
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
