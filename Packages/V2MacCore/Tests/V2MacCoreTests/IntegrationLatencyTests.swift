import Foundation
import Network
import Testing
@testable import V2MacCore

@Suite(.tags(.integration), .serialized, .enabled(if: TestSupport.coreAvailable))
struct LatencyIntegrationTests {
    /// A copy of the core for this suite alone: `xrayCount` counts processes by path, and other
    /// suites run the original at the same time.
    static let xray: URL = {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("xray-latency-\(getpid())")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: TestSupport.xray, to: copy)
        return copy
    }()

    func tester(_ options: LatencyOptions = LatencyOptions()) -> RealDelayTester {
        RealDelayTester(executable: Self.xray, assetDirectory: TestSupport.vendorCore, options: options)
    }

    func xrayCount() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", Self.xray.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").count
    }

    @Test func fragmentTunerTriesEveryCandidate() async {
        let options = LatencyOptions(timeout: 5)
        let make: @Sendable (FragmentSettings?) -> RealDelayTester = { fragment in
            RealDelayTester(executable: Self.xray, assetDirectory: TestSupport.vendorCore, options: options, dialer: DialerSettings(fragment: fragment))
        }
        let reached = OSLockedBox<[FragmentTuner.Trial]>([])
        let open = await FragmentTuner.run(LatencyTarget(id: UUID(), config: ["protocol": "freedom"], kind: .outbound), tester: make) { trial in reached.mutate { $0.append(trial) } }
        #expect(open.allSatisfy { $0.ms != nil } && reached.value.count == FragmentTuner.candidates.count)
        #expect(FragmentTuner.pick(open) != nil)
        let closed = await FragmentTuner.run(LatencyTarget(id: UUID(), config: ["protocol": "blackhole"], kind: .outbound), rounds: 1, tester: make) { _ in }
        #expect(closed.allSatisfy { $0.ms == nil } && FragmentTuner.pick(closed) == nil)
        #expect(xrayCount() == 0)
    }

    /// A local VMess-over-WebSocket server that only accepts Host `localhost`, scanned at 127.0.0.1.
    @Test func cleanIPScanReachesTheServerAtAnotherAddress() async throws {
        let port = try PortUtil.freePort()
        let server: JSONValue = [
            "log": ["loglevel": "none"],
            "inbounds": [["listen": "127.0.0.1", "port": .number(Double(port)), "protocol": "vmess",
                          "settings": ["clients": [["id": .string(Fixtures.uuid)]]],
                          "streamSettings": ["network": "ws", "wsSettings": ["path": "/ws", "host": "localhost"]]]],
            "outbounds": [["protocol": "freedom"]],
        ]
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CoreRunner(executable: Self.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await runner.start(config: server, readyPort: port)
        defer { Task { await runner.stop() } }

        let outbound = try ShareLinkParser.parse("vmess://\(Fixtures.uuid)@localhost:\(port)?type=ws&path=%2Fws#local").config
        #expect(CleanIPScanner.hostName(of: outbound) == "localhost")
        let found = await CleanIPScanner.scan(outbound, port: port, addresses: ["127.0.0.1", "127.0.0.2"], tester: tester(LatencyOptions(timeout: 5))) { _ in }
        #expect(found.first?.ip == "127.0.0.1")
        #expect(found.first?.realMs != nil)
        // Without the name as Host the server turns the request away.
        let wrongHost = outbound.setting("streamSettings", to: (outbound["streamSettings"] ?? [:]).setting("wsSettings", to: ["path": "/ws", "host": "other.example.com"]))
        let refused = await CleanIPScanner.scan(wrongHost, port: port, addresses: ["127.0.0.1"], tester: tester(LatencyOptions(timeout: 3))) { _ in }
        #expect(refused.first?.realMs == nil)
    }

    @Test func hundredServersWithBadOnesAmongThemWhileLiveConnectionRuns() async throws {
        // Live connection that must not be disturbed.
        let options = RunOptions(inbound: InboundSettings(port: try PortUtil.freePort()), metricsPort: try PortUtil.freePort())
        let liveConfig = try ConfigBuilder.buildGlobal(outbound: ["protocol": "freedom"], options: options)
        let liveDir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: liveDir) }
        let live = CoreRunner(executable: Self.xray, assetDirectory: TestSupport.vendorCore, runDirectory: liveDir)
        try await live.start(config: liveConfig, readyPort: options.inbound.port)
        let livePid = try #require(pid_t(String(contentsOf: liveDir.appendingPathComponent("xray.pid"), encoding: .utf8)))

        // 96 freedom servers + 2 that Xray refuses to load + 2 that load but never connect.
        var targets: [LatencyTarget] = []
        var good: Set<UUID> = [], invalid: Set<UUID> = [], dead: Set<UUID> = []
        for i in 0..<96 {
            let t = LatencyTarget(id: UUID(), config: ["protocol": "freedom", "settings": ["userLevel": .number(Double(i))]], kind: .outbound)
            targets.append(t); good.insert(t.id)
        }
        for _ in 0..<2 {
            let bad = LatencyTarget(id: UUID(), config: ["protocol": "nonexistent-protocol"], kind: .outbound)
            targets.insert(bad, at: Int.random(in: 0..<targets.count)); invalid.insert(bad.id)
            let blackhole = LatencyTarget(id: UUID(), config: ["protocol": "blackhole"], kind: .outbound)
            targets.insert(blackhole, at: Int.random(in: 0..<targets.count)); dead.insert(blackhole.id)
        }
        #expect(targets.count == 100)

        let collected = OSLockedBox<[LatencyResult]>([])
        let started = ContinuousClock.now
        await tester().run(targets) { collected.append($0) }
        let elapsed = ContinuousClock.now - started
        let results = collected.value

        #expect(results.count == 100, "every target gets exactly one result")
        #expect(Set(results.map(\.id)).count == 100)
        for r in results {
            if good.contains(r.id) {
                guard case .ok(let ms) = r.outcome else { Issue.record("good server \(r.id) -> \(r.outcome)"); continue }
                #expect(ms > 0 && ms < 8000)
            } else if invalid.contains(r.id) {
                guard case .invalid(let detail) = r.outcome else { Issue.record("bad config -> \(r.outcome)"); continue }
                #expect(!detail.isEmpty)
            } else if dead.contains(r.id) {
                #expect(r.outcome == .timeout)
            }
        }
        print("PROBE 100 servers tested in \(elapsed)")

        // Live core untouched: same process, still proxying, no throwaway cores left behind.
        #expect(kill(livePid, 0) == 0)
        #expect(await live.state == .running)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(options.inbound.port))!)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        let (_, response) = try await URLSession(configuration: cfg).data(from: URL(string: "https://www.gstatic.com/generate_204")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 204)
        #expect(xrayCount() == 1, "only the live core should remain")
        await live.stop()
    }

    @Test func cancellationStopsRequestsAndKillsTheThrowawayCore() async throws {
        let targets = (0..<64).map { i in
            LatencyTarget(id: UUID(), config: ["protocol": "freedom", "settings": ["userLevel": .number(Double(i))]], kind: .outbound)
        }
        let before = xrayCount()
        let task = Task { await tester().run(targets) { _ in } }
        try await Task.sleep(for: .milliseconds(700))
        task.cancel()
        await task.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(xrayCount() == before, "throwaway cores must be gone after cancel")
    }

    @Test func customProfileIsTestedThroughItsOwnCore() async throws {
        let custom = LatencyTarget(
            id: UUID(),
            config: ["outbounds": [["tag": "p", "protocol": "freedom"]], "routing": ["rules": [["type": "field", "inboundTag": ["old-in"], "outboundTag": "p"]]],
                     "inbounds": [["tag": "old-in", "protocol": "socks", "port": 1080]]],
            kind: .custom
        )
        let collected = OSLockedBox<[LatencyResult]>([])
        await tester().run([custom]) { collected.append($0) }
        guard case .ok? = collected.value.first.map({ r -> LatencyOutcome in
            if case .ok = r.outcome { return .ok(ms: 0) } else { return r.outcome }
        }) else { Issue.record("custom -> \(String(describing: collected.value.first))"); return }
    }
}
