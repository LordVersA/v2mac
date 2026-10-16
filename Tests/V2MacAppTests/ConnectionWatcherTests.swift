import Foundation
import Testing
import V2MacCore

@Suite @MainActor
struct ConnectionWatcherTests {
    @Test func proxySettingKeepsItsOriginAndDoesNotDiscoverRules() async throws {
        let watcher = ConnectionWatcher()
        watcher.routingMode = .global
        watcher.customRules = CustomRules(proxyClientsSkipRules: true)
        watcher.watch()
        defer { watcher.unwatch() }
        watcher.record(try #require(SeenConnection(line: "x from 127.0.0.1:50000 accepted tcp:example.com:443 [mixed-in -> proxy]")))
        // Change before the batch flushes: the earlier connection keeps its configuration.
        watcher.routingMode = .direct
        watcher.customRules = CustomRules()
        try await Task.sleep(for: .milliseconds(400))
        let row = try #require(watcher.connections.first)
        #expect(row.skipsRules && row.routingMode == .global)
        #expect(watcher.hosts.isEmpty)
        #expect(watcher.events.first?.connection.skipsRules == true)
    }

    @Test(arguments: [RoutingMode.global, .bypassRegions, .direct], [false, true])
    func systemProxyAndTunTrafficRemainDiscoverable(mode: RoutingMode, skip: Bool) async throws {
        let watcher = ConnectionWatcher()
        watcher.routingMode = mode
        watcher.customRules = CustomRules(rules: [CustomRule(name: "Direct", action: .direct, hosts: "example.com"),
                                                  CustomRule(name: "Block", action: .block, hosts: "ads.example.com")],
                                          proxyClientsSkipRules: skip)
        watcher.watch()
        defer { watcher.unwatch() }
        for inbound in ConfigBuilder.trafficInboundTags {
            watcher.record(try #require(SeenConnection(line: "x from 127.0.0.1:50000 accepted tcp:example.com:443 [\(inbound) -> direct]")))
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(watcher.connections.count == 2)
        #expect(watcher.connections.filter(\.usesProxySetting).count == (skip ? 1 : 0))
        #expect(watcher.connections.allSatisfy { !$0.skipsRules })
        #expect(watcher.hosts["example.com"]?.count == (skip ? 1 : 2))
        #expect(watcher.connections.first?.rules.count == (mode == .direct ? 1 : 2))
    }
}
