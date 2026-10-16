import Foundation
import Testing
@testable import V2MacCore

@Suite(.tags(.integration), .serialized, .enabled(if: TestSupport.coreAvailable))
struct ProxyResponseIntegrationTests {
    // A public destination is redirected inside the test core to a loopback fixture.
    // URLSession must traverse SOCKS, and no Internet service is contacted.
    let url = URL(string: "http://example.com/probe")!

    @Test(arguments: [false, true], [false, true])
    func fullConfigAppliesUserIPRulesBeforeFallback(useAppRules: Bool, skip: Bool) async throws {
        let http = try await TestHTTPServer.start { _ in .init(status: 204) }
        defer { http.stop() }
        let directory = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = RunOptions(inbound: .init(port: try PortUtil.freePort()), metricsPort: try PortUtil.freePort())
        let original: JSONValue = [
            "outbounds": [["tag": "fallback", "protocol": "freedom", "settings": ["redirect": .string("127.0.0.1:\(http.port)")]]],
            "dns": ["hosts": ["example.com": "93.184.216.34"], "servers": []],
            "routing": ["rules": [["type": "field", "network": "tcp,udp", "outboundTag": "fallback"]]],
        ]
        let custom = CustomRules(rules: [CustomRule(name: "User block", action: .block, hosts: "93.184.216.0/24")], proxyClientsSkipRules: skip)
        let config = try ConfigBuilder.buildCustom(config: original, options: options, routing: useAppRules ? .global : nil, custom: custom)
        // Keep this fixture out of the latency suite's counts of the bundled executable.
        let executable = directory.appendingPathComponent("xray-routing")
        try FileManager.default.copyItem(at: TestSupport.xray, to: executable)
        let core = CoreRunner(executable: executable, assetDirectory: TestSupport.vendorCore, runDirectory: directory)
        try await core.start(config: config, readyPort: options.inbound.port)
        let outcome = await ProxyHealthProbe.measure(route: .localProxy(port: options.inbound.port), url: url, timeout: 1)
        await core.stop()
        if useAppRules && !skip {
            #expect(outcome == .timeout)
        } else {
            guard case .ok = outcome else { Issue.record("The config fallback must answer through the loopback fixture"); return }
        }
    }

    @Test func tcpSuccessWithoutAnHTTPResponseCannotBeSelected() async throws {
        let unresponsive = try await TestHTTPServer.start { _ in .init(withholdResponse: true) }
        let working = try await TestHTTPServer.start { _ in .init(status: 204) }
        defer { unresponsive.stop(); working.stop() }
        let ping = await TCPPing.ping(.init(id: UUID(), host: "127.0.0.1", port: unresponsive.port), timeout: 1)
        guard case .ok = ping else { Issue.record("fixture must accept TCP"); return }
        let dead = LatencyTarget(id: UUID(), config: ["protocol": "freedom", "settings": ["redirect": .string("127.0.0.1:\(unresponsive.port)")]], kind: .outbound)
        let good = LatencyTarget(id: UUID(), config: ["protocol": "freedom", "settings": ["redirect": .string("127.0.0.1:\(working.port)")]], kind: .outbound)
        let collected = OSLockedBox<[LatencyResult]>([])
        let tester = RealDelayTester(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore,
                                     options: .init(url: url, timeout: 1))
        await tester.run([dead, good]) { collected.append($0) }
        #expect(collected.value.first(where: { $0.id == dead.id })?.outcome == .timeout)
        var policy = AutoSelectionPolicy()
        #expect(policy.choose(results: collected.value, currentID: dead.id, reason: .initial, now: .now) == good.id)
    }

    @Test func liveProbeRejectsHTTPErrorAndNeverFallsBackDirect() async throws {
        let response = OSLockedBox(TestHTTPServer.Response(status: 204))
        let http = try await TestHTTPServer.start { _ in response.value }
        defer { http.stop() }
        let directory = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = RunOptions(inbound: .init(port: try PortUtil.freePort()), metricsPort: try PortUtil.freePort())
        let config = try ConfigBuilder.buildGlobal(
            outbound: ["protocol": "freedom", "settings": ["redirect": .string("127.0.0.1:\(http.port)")]], options: options)
        let core = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: directory)
        try await core.start(config: config, readyPort: options.inbound.port)
        let route = FetchRoute.localProxy(port: options.inbound.port)
        let success = await ProxyHealthProbe.measure(route: route, url: url, timeout: 1)
        guard case .ok = success else { await core.stop(); Issue.record("live proxy must respond"); return }
        response.mutate { $0.status = 503 }
        #expect(await ProxyHealthProbe.measure(route: route, url: url, timeout: 1) == .timeout)
        response.mutate { $0.status = 204; $0.withholdResponse = true }
        #expect(await ProxyHealthProbe.measure(route: route, url: url, timeout: 1) == .timeout)
        await core.stop()
        #expect(await ProxyHealthProbe.measure(route: route, url: url, timeout: 1) == .timeout)
    }
}
