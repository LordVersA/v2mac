import Foundation
import Testing
@testable import V2MacCore

@Suite struct RoutingTests {
    let outbound: JSONValue = ["protocol": "freedom"]
    let iran = RegionRoute(geositeFile: "region-ir-geosite.dat", geositeTags: ["ir"], geoipFile: "region-ir-geoip.dat", geoipTags: ["ir"])

    func build(_ plan: RoutingPlan) throws -> JSONValue {
        try ConfigBuilder.build(outbound: outbound, options: RunOptions(metricsPort: 20000), routing: plan)
    }

    @Test func bypassRules() throws {
        let c = try build(.bypass([iran]))
        #expect(c["routing"]?["domainStrategy"]?.stringValue == "IPIfNonMatch")
        let rules = try #require(c["routing"]?["rules"]?.arrayValue)
        #expect(rules.count == 4)
        #expect(rules[0]["domain"]?[0]?.stringValue == "full:localhost")
        #expect(rules[1]["ip"]?[0]?.stringValue == "geoip:private")
        #expect(rules[2]["domain"]?[0]?.stringValue == "ext:region-ir-geosite.dat:ir")
        #expect(rules[3]["ip"]?[0]?.stringValue == "ext:region-ir-geoip.dat:ir")
        for rule in rules { #expect(rule["outboundTag"]?.stringValue == "direct") }
        #expect(c["dns"]?["servers"]?[0]?.stringValue == "https://1.1.1.1/dns-query")
        #expect(c["dns"]?["servers"]?[1]?.stringValue == "https://8.8.8.8/dns-query")
        #expect(c["dns"]?["queryStrategy"]?.stringValue == "UseIP")
        #expect(c["dns"]?["enableParallelQuery"]?.boolValue == true)
    }

    @Test func bypassWithoutPacksIsGlobal() throws {
        let c = try build(.bypass([]))
        #expect(c["routing"] == (try build(.global))["routing"])
        #expect(c["dns"] == nil)
    }

    @Test func globalHasNoDNS() throws {
        #expect(try build(.global)["dns"] == nil)
    }

    @Test func directIsOneCatchAll() throws {
        let rules = try #require(try build(.direct)["routing"]?["rules"]?.arrayValue)
        #expect(rules.count == 1)
        #expect(rules[0]["network"]?.stringValue == "tcp,udp")
        #expect(rules[0]["outboundTag"]?.stringValue == "direct")
    }

    @Test func buildGlobalStillMatchesGlobalPlan() throws {
        let options = RunOptions(metricsPort: 1)
        #expect(try ConfigBuilder.buildGlobal(outbound: outbound, options: options) == ConfigBuilder.build(outbound: outbound, options: options, routing: .global))
    }
}

@Suite struct CustomConfigTests {
    let options = RunOptions(inbound: InboundSettings(port: 12345), logLevel: .info, metricsPort: 23456)

    let config: JSONValue = [
        "log": ["loglevel": "debug", "access": "/tmp/x.log"],
        "inbounds": [
            ["tag": "socks-in", "protocol": "socks", "port": 1080],
            ["tag": "http-in", "protocol": "http", "port": 1081],
            ["tag": "tun-in", "protocol": "tun"],
        ],
        "outbounds": [
            ["tag": "p", "protocol": "vless", "settings": ["address": "a.com"]],
            ["tag": "direct", "protocol": "freedom"],
        ],
        "routing": [
            "rules": [
                ["type": "field", "inboundTag": ["socks-in", "http-in"], "outboundTag": "p"],
                ["type": "field", "inboundTag": ["tun-in"], "outboundTag": "direct"],
                ["type": "field", "inboundTag": ["tun-in", "socks-in"], "outboundTag": "direct"],
                ["type": "field", "domain": ["geosite:ir"], "outboundTag": "direct"],
            ],
        ],
        "policy": ["system": ["statsOutboundUplink": true], "levels": ["0": ["handshake": 4]]],
        "dns": ["servers": ["8.8.8.8"]],
    ]

    @Test func replacesInboundsLogMetricsStats() throws {
        let out = try ConfigBuilder.buildCustom(config: config, options: options)
        #expect(out["inbounds"]?.arrayValue?.count == 1)
        #expect(out["inbounds"]?[0]?["tag"]?.stringValue == "mixed-in")
        #expect(out["inbounds"]?[0]?["port"]?.intValue == 12345)
        #expect(out["log"]?["loglevel"]?.stringValue == "info")
        #expect(out["log"]?["access"]?.stringValue == "none")
        #expect(out["metrics"]?["listen"]?.stringValue == "127.0.0.1:23456")
        #expect(out["stats"] != nil)
    }

    @Test func mergesPolicyAndKeepsTheRest() throws {
        let out = try ConfigBuilder.buildCustom(config: config, options: options)
        let system = out["policy"]?["system"]
        #expect(system?["statsOutboundUplink"]?.boolValue == true)
        #expect(system?["statsInboundUplink"]?.boolValue == true)
        #expect(system?["statsInboundDownlink"]?.boolValue == true)
        #expect(out["policy"]?["levels"]?["0"]?["handshake"]?.intValue == 4)
        #expect(out["outbounds"] == config["outbounds"])
        #expect(out["dns"] == config["dns"])
    }

    @Test func rewritesInboundTagsInRules() throws {
        let rules = try #require(try ConfigBuilder.buildCustom(config: config, options: options)["routing"]?["rules"]?.arrayValue)
        // rule 1: both proxy inbounds collapse to the single mixed inbound
        #expect(rules[0]["inboundTag"]?.arrayValue == ["mixed-in"])
        // rule 2 referenced only the removed tun inbound -> dropped
        // rule 3 keeps the rewritten socks tag
        #expect(rules[1]["inboundTag"]?.arrayValue == ["mixed-in"])
        // rules without inboundTag survive untouched
        #expect(rules[2]["domain"]?[0]?.stringValue == "geosite:ir")
        #expect(rules.count == 3)
    }

    @Test func configWithoutOptionalSectionsStillWorks() throws {
        let bare: JSONValue = ["outbounds": [["protocol": "freedom"]]]
        let out = try ConfigBuilder.buildCustom(config: bare, options: options)
        #expect(out["routing"] == nil)
        #expect(out["inbounds"]?.arrayValue?.count == 1)
    }

    @Test(arguments: [RoutingPlan.global, .bypass([]), .direct])
    func appRulesPrecedeImportedRules(plan: RoutingPlan) throws {
        let custom = CustomRules(rules: [CustomRule(name: "Mine", action: .block, hosts: "priority.example")])
        let out = try ConfigBuilder.buildCustom(config: config, options: options, routing: plan, custom: custom)
        let rules = try #require(out["routing"]?["rules"]?.arrayValue)
        #expect(rules[0]["domain"]?[0] == "full:localhost")
        #expect(rules[1]["ip"] == ["geoip:private"])
        #expect(rules[2]["domain"] == ["domain:priority.example"])
        #expect(rules[2]["outboundTag"] == "v2mac-block")
        #expect(out["outbounds"]?[0] == config["outbounds"]?[0])
        #expect(rules.suffix(3) == (try ConfigBuilder.buildCustom(config: config, options: options))["routing"]?["rules"]?.arrayValue?[...])
        if plan == .direct {
            #expect(rules[3]["network"] == "tcp,udp")
            #expect(rules[3]["outboundTag"] == "v2mac-direct")
        }
    }

    @Test func proxyExceptionUsesTheImportedServerTag() throws {
        let custom = CustomRules(rules: [CustomRule(name: "Blocked", action: .block, hosts: "priority.example")], proxyClientsRoute: .proxy)
        let out = try ConfigBuilder.buildCustom(config: config, options: options, routing: .global, custom: custom)
        #expect(out["routing"]?["rules"]?[2] == ["type": "field", "inboundTag": ["mixed-in"], "outboundTag": "p"])
    }

    @Test func priorityIPRulesResolveBeforeTheImportedCatchAll() throws {
        let custom = CustomRules(rules: [CustomRule(name: "Blocked", action: .block, hosts: "203.0.113.0/24")])
        let full: JSONValue = ["outbounds": [["protocol": "freedom"]],
                               "routing": ["rules": [["type": "field", "network": "tcp,udp", "outboundTag": "fallback"]]]]
        let out = try ConfigBuilder.buildCustom(config: full, options: options, routing: .global, custom: custom)
        #expect(out["routing"]?["domainStrategy"] == "IPOnDemand")
        #expect(out["dns"] != nil)
        let direct = try ConfigBuilder.build(outbound: ["protocol": "freedom"], options: options, routing: .direct, custom: custom)
        #expect(direct["routing"]?["domainStrategy"] == "IPOnDemand")
    }

    @Test func appOutboundsDoNotReplaceImportedTagsOrTheirSettings() throws {
        let original: JSONValue = ["outbounds": [
            ["tag": "v2mac-direct", "protocol": "freedom", "proxySettings": ["tag": "upstream"]],
            ["tag": "v2mac-block", "protocol": "blackhole"],
            ["tag": "upstream", "protocol": "socks", "settings": ["servers": [["address": "127.0.0.1", "port": 9999]]]],
        ]]
        let out = try ConfigBuilder.buildCustom(config: original, options: options, routing: .global)
        #expect(out["outbounds"]?.arrayValue?.prefix(3) == original["outbounds"]?.arrayValue?[...])
        #expect(out["routing"]?["rules"]?[0]?["outboundTag"] == "v2mac-direct-1")
        #expect(out["outbounds"]?[3]?["proxySettings"] == nil)
        let untagged = try ConfigBuilder.buildCustom(config: ["outbounds": [["protocol": "freedom"]]], options: options, routing: .global)
        #expect(untagged["outbounds"]?[0]?["tag"] == "v2mac-proxy")
    }

    @Test func missingOutboundCannotSilentlySkipAppRules() {
        #expect(throws: CoreError.startFailed("This config has no outbound for routing.")) {
            try ConfigBuilder.buildCustom(config: ["outbounds": []], options: options, routing: .global)
        }
    }
}

@Suite struct LatencySupportTests {
    @Test func freePortsAreDistinct() throws {
        let ports = try PortUtil.freePorts(40)
        #expect(Set(ports).count == 40)
        #expect(ports.allSatisfy { PortUtil.isFree(port: $0) })
    }

    @Test func batchConfigPairsEachInboundWithItsOutbound() {
        let c = LatencyConfig.batch(outbounds: [["protocol": "freedom"], ["protocol": "blackhole"]], ports: [1001, 1002])
        #expect(c["inbounds"]?.arrayValue?.count == 2)
        #expect(c["inbounds"]?[1]?["port"]?.intValue == 1002)
        #expect(c["outbounds"]?[1]?["tag"]?.stringValue == "out-1")
        #expect(c["routing"]?["rules"]?[1]?["inboundTag"]?[0]?.stringValue == "in-1")
        #expect(c["routing"]?["rules"]?[1]?["outboundTag"]?.stringValue == "out-1")
        #expect(c["log"]?["loglevel"]?.stringValue == "none")
        #expect(c["metrics"] == nil)
    }

    @Test func tcpPingReachesListeningPortAndFailsOnClosedOne() async throws {
        let holder = try TestSupport.PortHolder()
        let closed = try PortUtil.freePort()
        let ok = await TCPPing.ping(TCPPingTarget(id: UUID(), host: "127.0.0.1", port: holder.port), timeout: 2)
        holder.release()
        let bad = await TCPPing.ping(TCPPingTarget(id: UUID(), host: "127.0.0.1", port: closed), timeout: 2)
        guard case .ok(let ms) = ok else { Issue.record("expected ok, got \(ok)"); return }
        #expect(ms >= 1)
        #expect(bad == .timeout)
    }

    @Test func tcpPingRunDeliversEveryResult() async throws {
        let holders = try (0..<5).map { _ in try TestSupport.PortHolder() }
        defer { holders.forEach { $0.release() } }
        let ids = holders.map { _ in UUID() }
        let targets = zip(ids, holders).map { TCPPingTarget(id: $0, host: "127.0.0.1", port: $1.port) }
        let collected = OSLockedBox<[LatencyResult]>([])
        await TCPPing.run(targets, concurrency: 2) { r in collected.append(r) }
        let results = collected.value
        #expect(Set(results.map(\.id)) == Set(ids))
        #expect(results.allSatisfy { if case .ok = $0.outcome { true } else { false } })
    }
}
