import Foundation
import Network
import Testing
@testable import V2MacCore

@Suite(.tags(.integration), .serialized, .enabled(if: TestSupport.coreAvailable))
struct EngineIntegrationTests {
    let testURL = URL(string: "https://www.gstatic.com/generate_204")!

    func makeConfig() throws -> (config: JSONValue, options: RunOptions) {
        let options = RunOptions(
            inbound: InboundSettings(port: try PortUtil.freePort()),
            metricsPort: try PortUtil.freePort()
        )
        let config = try ConfigBuilder.buildGlobal(outbound: ["protocol": "freedom"], options: options)
        return (config, options)
    }

    func statusCode(via proxy: ProxyConfiguration) async throws -> Int {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.proxyConfigurations = [proxy]
        cfg.timeoutIntervalForRequest = 15
        let (_, response) = try await URLSession(configuration: cfg).data(from: testURL)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    @Test func generatedConfigPassesXrayTest() throws {
        let (config, _) = try makeConfig()
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try config.data().write(to: file)

        let p = Process()
        p.executableURL = TestSupport.xray
        p.arguments = ["run", "-test", "-c", file.path]
        p.environment = ["XRAY_LOCATION_ASSET": TestSupport.vendorCore.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, Comment(rawValue: out))
        #expect(out.contains("Configuration OK"))
    }

    @Test func startFetchOverSocksAndHttpReadStatsStop() async throws {
        let (config, options) = try makeConfig()
        let port = options.inbound.port
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await runner.start(config: config, readyPort: port)
        #expect(await runner.state == .running)

        let configFile = dir.appendingPathComponent("config.json")
        let pidFile = dir.appendingPathComponent("xray.pid")
        let attrs = try FileManager.default.attributesOfItem(atPath: configFile.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)))

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let socks = try await statusCode(via: ProxyConfiguration(socksv5Proxy: endpoint))
        let http = try await statusCode(via: ProxyConfiguration(httpCONNECTProxy: endpoint))
        #expect(socks == 204)
        #expect(http == 204)

        let stats = try await StatsClient(port: options.metricsPort).snapshot()
        #expect(stats.downlink > 0)
        #expect(stats.uplink > 0)

        await runner.stop()
        #expect(await runner.state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: configFile.path))
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        #expect(kill(pid, 0) != 0)
        #expect(PortUtil.isFree(port: port))
    }

    @Test func badConfigFailsBeforeReady() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = try PortUtil.freePort()
        let runner = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        let bad: JSONValue = ["outbounds": [["protocol": "nonexistent-protocol"]]]
        do {
            try await runner.start(config: bad, readyPort: port)
            Issue.record("expected failure")
        } catch let CoreError.exitedBeforeReady(_, detail) {
            #expect(detail != nil)
        }
        guard case .failed = await runner.state else {
            Issue.record("expected failed state")
            return
        }
    }

    @Test func externalKillIsReportedAsFailure() async throws {
        let (config, options) = try makeConfig()
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await runner.start(config: config, readyPort: options.inbound.port)
        let pid = try #require(pid_t(String(contentsOf: dir.appendingPathComponent("xray.pid"), encoding: .utf8)))
        kill(pid, SIGKILL)
        for _ in 0..<100 {
            if case .failed = await runner.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .failed = await runner.state else {
            Issue.record("expected failed state after external kill")
            return
        }
        await runner.stop()
    }

    @Test func orphanFromPreviousRunIsTerminated() async throws {
        let (config, options) = try makeConfig()
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulate an orphan: a core started by one runner, never stopped.
        let first = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await first.start(config: config, readyPort: options.inbound.port)
        let orphanPid = try #require(pid_t(String(contentsOf: dir.appendingPathComponent("xray.pid"), encoding: .utf8)))

        let second = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await second.start(config: config, readyPort: options.inbound.port)
        #expect(kill(orphanPid, 0) != 0)
        await second.stop()
    }

    @Test func logStreamCarriesCoreOutput() async throws {
        let (config, options) = try makeConfig()
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await runner.start(config: config, readyPort: options.inbound.port)
        await runner.stop()

        var sawStarted = false
        let logs = runner.logs
        let task = Task { () -> Bool in
            for await line in logs where CoreOutputParser.indicatesReady(line) { return true }
            return false
        }
        // Stream is buffered; the readiness line must already be present.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        sawStarted = await task.value
        #expect(sawStarted)
    }
}
