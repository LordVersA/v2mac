import Foundation
import Testing
@testable import V2MacCore

@Suite struct RuleV2Tests {
    /// Shaped like a real list (anonymised): services split into app and host rules, apps spelled
    /// several ways, local network repeated, a rule with apps and hosts, a disabled and a broken one.
    static let oldList: [CustomRule] = [
        CustomRule(name: "Local", action: .direct, hosts: "localhost\n10.0.0.0/8\n192.168.0.0/16"),
        CustomRule(name: "App - Chat", action: .proxy, apps: "\"Chat.app\"\nChat\ncom.example.chat\n*chat*"),
        CustomRule(name: "Host - Chat", action: .proxy, hosts: "chat.example\n*.chatcdn.example, keyword:chatapi"),
        CustomRule(name: "Editor in office", action: .direct, apps: "Editor.app; com.example.editor", hosts: "office.example\n172.16.0.0-172.16.1.255"),
        CustomRule(name: "Ads", action: .block, hosts: "geosite:category-ads-all\n||tracker.example^"),
        CustomRule(name: "Off", action: .proxy, hosts: "off.example", enabled: false),
        CustomRule(name: "Broken", action: .direct, apps: "Editor.app", hosts: "not a host"),
        CustomRule(name: "Missing app", action: .block, apps: "Nothing.app"),
        CustomRule(name: "Comment hosts", action: .direct, apps: "Editor.app", hosts: "# nothing here"),
    ]
    static let installed = [InstalledApp(path: "/Applications/Chat.app", bundleID: "com.example.chat"),
                            InstalledApp(path: "/Applications/Editor.app", bundleID: "com.example.editor")]

    /// The 1.1 compiler, kept here to prove migration routes exactly the same traffic.
    static func oldRules(_ rules: [CustomRule], apps installed: [InstalledApp]) -> [JSONValue] {
        var out: [JSONValue] = []
        for rule in rules where rule.enabled {
            let hosts = RuleMatchers(parsing: rule.hosts)
            let hasApps = !rule.apps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let apps = AppMatchers(parsing: rule.apps, apps: installed).processes
            if hasApps, apps.isEmpty { continue }
            var made: [JSONValue] = []
            if !hosts.domains.isEmpty { made.append(["type": "field", "domain": .array(hosts.domains.map { .string($0) }), "outboundTag": .string(rule.tag)]) }
            if !hosts.ips.isEmpty { made.append(["type": "field", "ip": .array(hosts.ips.map { .string($0) }), "outboundTag": .string(rule.tag)]) }
            if hasApps {
                let process: JSONValue = .array(apps.map { .string($0) })
                made = made.isEmpty && hosts.invalid.isEmpty
                    ? [["type": "field", "process": process, "outboundTag": .string(rule.tag)]]
                    : made.map { $0.setting("process", to: process) }
            }
            out += made
        }
        return out
    }

    static func newRules(_ rules: [Rule], custom: CustomRules = CustomRules(installedApps: installed)) -> [JSONValue] {
        rules.filter(\.enabled).flatMap { $0.xrayRules(apps: custom.installedApps, siteTags: custom.siteTags, target: custom.target(of: $0.action)) }
    }

    @Test func migrationRoutesExactlyTheSame() {
        let migrated = Self.oldList.map(Rule.init(migrating:))
        #expect(Self.newRules(migrated) == Self.oldRules(Self.oldList, apps: Self.installed))
        #expect(migrated.map(\.id) == Self.oldList.map(\.id))
        #expect(migrated[3].hostItems == ["domain:office.example", "172.16.0.0/23"])
        #expect(migrated[3].only.apps == ["Editor.app", "com.example.editor"])
        #expect(migrated[1].appItems == ["Chat.app", "Chat", "com.example.chat", "*chat*"])
        #expect(migrated[6].hostItems == ["not", "a", "host"])
        #expect(!migrated[5].enabled)
    }

    @Test func storedListRoundTrips() {
        var rules = Self.oldList.map(Rule.init(migrating:))
        rules.append(Rule(name: "Via", action: .via(.init(target: .group(UUID()), name: "Work", fallsBack: true)),
                          items: [.country("ir")], only: .init(ports: "443", network: .udp, protocols: [.quic])))
        let text = Rule.encode(rules)
        #expect(text.contains(#""version":2"#))
        #expect(Rule.decode(text) == rules)
        #expect(Rule.decode("[]") == nil)
        #expect(Rule.decode(CustomRule.encode(Self.oldList)) == nil)
    }

    @Test func itemsAreOrAndOnlyWhenIsAnd() {
        let rule = Rule(name: "Dev", action: .direct,
                        items: [.app("Editor.app"), .host("git.example"), .host("10.9.0.0/16")],
                        only: .init(ports: "22, 443", network: .tcp))
        let made = Self.newRules([rule])
        #expect(made.count == 3)
        #expect(made.map { $0["process"] != nil } == [true, false, false])
        #expect(made[1]["domain"] == ["domain:git.example"])
        #expect(made[2]["ip"] == ["10.9.0.0/16"])
        #expect(made.allSatisfy { $0["port"] == "22,443" && $0["network"] == "tcp" && $0["outboundTag"] == "direct" })
    }

    @Test func conditionsAlone() {
        let torrents = Rule(name: "Torrents", action: .direct, only: .init(protocols: [.bittorrent]))
        #expect(Self.newRules([torrents]) == [["type": "field", "protocol": ["bittorrent"], "outboundTag": "direct"]])
        // Nothing to match on: no rule at all, never a catch-all.
        #expect(Self.newRules([Rule(name: "Empty", action: .block)]).isEmpty)
        #expect(Self.newRules([Rule(name: "Bad port", action: .block, items: [.host("a.example")], only: .init(ports: "99999"))]).isEmpty)
        #expect(Self.newRules([Rule(name: "No app", action: .block, items: [.host("a.example")], only: .init(apps: ["Nothing.app"]))]).isEmpty)
    }

    @Test func portLists() {
        #expect(Rule.OnlyWhen.validPorts("443"))
        #expect(Rule.OnlyWhen.validPorts("53,443,8000-8100"))
        #expect(!Rule.OnlyWhen.validPorts("0"))
        #expect(!Rule.OnlyWhen.validPorts("10-5"))
        #expect(!Rule.OnlyWhen.validPorts("1-2-3"))
        #expect(!Rule.OnlyWhen.validPorts("http"))
    }

    @Test func countryItems() {
        let made = Self.newRules([Rule(name: "UK", action: .direct, items: [.country("GB")])],
                                 custom: CustomRules(siteTags: ["category-gb"]))
        #expect(made[0]["domain"] == ["domain:uk", "geosite:category-gb"])
        #expect(made[1]["ip"] == ["geoip:gb"])
    }

    @Test func viaTargets() {
        let group = UUID(), server = UUID(), gone = UUID()
        var custom = CustomRules()
        custom.via = [.group(group): ViaRoute(tag: "via-g0", isBalancer: true, fallbackBalancer: "via-g0-fb"),
                      .server(server): ViaRoute(tag: "via-s1-m0", isBalancer: false)]
        func target(_ t: Rule.Via.Target, fallsBack: Bool = false) -> String {
            let made = Self.newRules([Rule(name: "x", action: .via(.init(target: t, name: "x", fallsBack: fallsBack)), items: [.host("a.example")])], custom: custom)
            return made[0].objectValue!.filter { $0.key.hasSuffix("Tag") }.map { "\($0.key)=\($0.value.stringValue!)" }.joined()
        }
        #expect(target(.group(group)) == "balancerTag=via-g0")
        #expect(target(.group(group), fallsBack: true) == "balancerTag=via-g0-fb")
        #expect(target(.server(server)) == "outboundTag=via-s1-m0")
        // A target missing from the config fails closed, or uses the connected server when allowed.
        #expect(target(.server(gone)) == "outboundTag=block")
        #expect(target(.server(gone), fallsBack: true) == "outboundTag=proxy")
    }

    @Test func compiledRulesCarryUniqueTags() throws {
        let custom = CustomRules(rules: Self.oldList, installedApps: Self.installed, blockQUIC: true, proxyClientsRoute: .proxy, unmatchedRoute: .direct)
        let config = try ConfigBuilder.build(outbound: ["protocol": "freedom"], options: RunOptions(metricsPort: 1), routing: .rulesOnly, custom: custom)
        let tags = try #require(config["routing"]?["rules"]?.arrayValue).map { $0["ruleTag"]?.stringValue }
        #expect(!tags.contains(nil))
        #expect(Set(tags).count == tags.count)
        #expect(tags.prefix(4) == [RuleTag.quic, RuleTag.localNames, RuleTag.privateIPs, RuleTag.proxyPort])
        #expect(tags.last == RuleTag.unmatched)
        #expect(RuleTag.ruleID(tags[4]!) == Self.oldList[0].id)
    }
}

/// Small geo files built in the test, so the tester runs without the core's data.
enum GeoFixture {
    static func varint(_ v: Int) -> [UInt8] {
        var v = v, out: [UInt8] = []
        while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        return out + [UInt8(v)]
    }
    static func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { varint(n << 3 | 2) + varint(bytes.count) + bytes }

    /// `name: [(kind, value)]` with kinds 0 keyword, 1 regex, 2 domain, 3 full.
    static func sites(_ lists: [String: [(Int, String)]]) -> Data {
        Data(lists.flatMap { name, entries in
            field(1, field(1, Array(name.utf8)) + entries.flatMap { field(2, varint(1 << 3) + varint($0.0) + field(2, Array($0.1.utf8))) })
        })
    }

    static func ips(_ lists: [String: [String]]) -> Data {
        Data(lists.flatMap { name, cidrs in
            field(1, field(1, Array(name.utf8)) + cidrs.flatMap { cidr -> [UInt8] in
                let parts = cidr.split(separator: "/")
                var a4 = in_addr()
                inet_pton(AF_INET, String(parts[0]), &a4)
                let bytes = withUnsafeBytes(of: a4) { Array($0) }
                return field(2, field(1, bytes) + varint(2 << 3) + varint(Int(parts[1])!))
            })
        })
    }

    static let geo = GeoLists(
        siteFiles: ["geosite.dat": sites(["github": [(2, "github.com"), (0, "githubusercontent")], "category-ads-all": [(3, "ads.example")]])],
        ipFiles: ["geoip.dat": ips(["private": ["10.0.0.0/8", "192.168.0.0/16"], "us": ["8.8.8.0/24"]])])
}

@Suite struct RuleTesterTests {
    let geo = GeoFixture.geo
    let dev = Rule(name: "Developer", action: .direct, items: [.host("geosite:github"), .host("*chatgpt*")])
    let editor = Rule(name: "Editor", action: .block, items: [.app("Editor.app")])

    func routing(_ plan: RoutingPlan, _ rules: [Rule], unmatched: CustomRule.Action? = nil) throws -> JSONValue {
        let custom = CustomRules(rules: rules, installedApps: RuleV2Tests.installed, unmatchedRoute: unmatched)
        return try #require(try ConfigBuilder.build(outbound: ["protocol": "freedom"], options: RunOptions(metricsPort: 1), routing: plan, custom: custom)["routing"])
    }

    @Test func readsGeoFiles() {
        #expect(geo.site("geosite.dat:github", contains: "api.github.com") == "github.com")
        #expect(geo.site("geosite.dat:github", contains: "raw.githubusercontent.com") == "githubusercontent")
        #expect(geo.site("geosite.dat:github", contains: "notgithub.com") == nil)
        #expect(geo.ipList("geoip.dat:private", contains: "192.168.1.4"))
        #expect(!geo.ipList("geoip.dat:private", contains: "8.8.8.8"))
        #expect(geo.ipList("geoip.dat:us", contains: "8.8.8.8"))
    }

    @Test func answersWithTheUserRule() throws {
        let r = try routing(.global, [editor, dev])
        let a = try #require(RuleTester.route(RouteQuery(host: "API.github.com"), routing: r, geo: geo))
        #expect(a.outbound == "direct")
        #expect(a.matched == "geosite:github")
        #expect(a.ruleTag.flatMap(RuleTag.ruleID) == dev.id)
        let k = try #require(RuleTester.route(RouteQuery(host: "chatgpt.com"), routing: r, geo: geo))
        #expect(k.matched == "keyword:chatgpt")
        let app = try #require(RuleTester.route(RouteQuery(host: "api.github.com", process: "/Applications/Editor.app/Contents/MacOS/Helper"), routing: r, geo: geo))
        #expect(app.outbound == "block")
    }

    @Test func builtInsComeFirst() throws {
        let catchAll = Rule(name: "All", action: .proxy, items: [.host("0.0.0.0/0")])
        let r = try routing(.global, [catchAll])
        #expect(RuleTester.route(RouteQuery(host: "printer.local"), routing: r, geo: geo)?.ruleTag == RuleTag.localNames)
        #expect(RuleTester.route(RouteQuery(ips: ["192.168.1.9"]), routing: r, geo: geo)?.ruleTag == RuleTag.privateIPs)
        #expect(RuleTester.route(RouteQuery(ips: ["8.8.8.8"]), routing: r, geo: geo)?.outbound == "proxy")
    }

    @Test func modesDecideTheRest() throws {
        // Global: no rule matches, so the core's first outbound (the server) takes it.
        #expect(RuleTester.route(RouteQuery(host: "example.com"), routing: try routing(.global, [dev]), geo: geo) == nil)
        let only = try #require(RuleTester.route(RouteQuery(host: "example.com"), routing: try routing(.rulesOnly, [dev]), geo: geo))
        #expect(only.outbound == "direct")
        #expect(only.ruleTag?.hasPrefix(RuleTag.modePrefix) == true)
        // Direct mode keeps only block rules.
        let direct = try routing(.direct, [dev, editor])
        #expect(RuleTester.route(RouteQuery(host: "github.com"), routing: direct, geo: geo)?.ruleTag?.hasPrefix(RuleTag.modePrefix) == true)
        #expect(RuleTester.route(RouteQuery(host: "x.example", process: "/Applications/Editor.app/Contents/MacOS/Editor"), routing: direct, geo: geo)?.outbound == "block")
        #expect(RuleTester.route(RouteQuery(host: "example.com"), routing: try routing(.global, [dev], unmatched: .block), geo: geo)?.ruleTag == RuleTag.unmatched)
    }

    @Test func followsTheDomainStrategy() {
        let rules: JSONValue = [["type": "field", "ip": ["0.0.0.0/0"], "port": "80", "outboundTag": "r1"],
                                ["type": "field", "domain": ["domain:example.com"], "outboundTag": "r2"]]
        let q = RouteQuery(host: "example.com", ips: ["93.184.215.14"], port: 80)
        // The R0 spike's result with the real core.
        #expect(RuleTester.route(q, routing: ["domainStrategy": "IPOnDemand", "rules": rules], geo: geo)?.outbound == "r1")
        #expect(RuleTester.route(q, routing: ["domainStrategy": "IPIfNonMatch", "rules": rules], geo: geo)?.outbound == "r2")
        #expect(RuleTester.route(RouteQuery(host: "other.com", ips: ["1.1.1.1"]), routing: ["domainStrategy": "AsIs", "rules": rules], geo: geo) == nil)
    }
}

@Suite struct ViaConfigTests {
    static let group = UUID(), single = UUID(), chained = UUID()
    static let trojan = try! ShareLinkParser.parse(Fixtures.trojanPlain)
    static let hy2 = try! ShareLinkParser.parse(Fixtures.hy2)
    /// A full config whose proxy goes out through a second hop, with routing of its own.
    static let chainConfig: JSONValue = [
        "outbounds": [
            ["tag": "exit", "protocol": "socks", "settings": ["servers": [["address": "exit.example", "port": 1080]]],
             "streamSettings": ["sockopt": ["dialerProxy": "hop"]]],
            ["tag": "hop", "protocol": "socks", "settings": ["servers": [["address": "hop.example", "port": 1080]]]],
            ["tag": "direct", "protocol": "freedom"],
        ],
        "routing": ["rules": [["type": "field", "ip": ["1.1.1.1"], "outboundTag": "direct"]]],
    ]

    static func custom(fallsBack: Bool = false) -> CustomRules {
        CustomRules(rules: [
            Rule(name: "Work", action: .via(.init(target: .group(group), name: "Work")), items: [.host("work.example")]),
            Rule(name: "Work or current", action: .via(.init(target: .group(group), name: "Work", fallsBack: true)), items: [.host("mail.example")]),
            Rule(name: "One", action: .via(.init(target: .server(single), name: "One")), items: [.host("one.example")]),
            Rule(name: "Chain", action: .via(.init(target: .server(chained), name: "Chain")), items: [.host("chain.example")]),
        ], viaServers: [
            .group(group): [ViaServer(config: trojan.config, kind: .outbound), ViaServer(config: hy2.config, kind: .outbound)],
            .server(single): [ViaServer(config: trojan.config, kind: .outbound)],
            .server(chained): [ViaServer(config: chainConfig, kind: .custom)],
        ])
    }

    func build(_ plan: RoutingPlan, options: RunOptions = RunOptions(metricsPort: 1)) throws -> JSONValue {
        try ConfigBuilder.build(outbound: Self.trojan.config, options: options, routing: plan, custom: Self.custom())
    }

    func target(_ config: JSONValue, _ host: String) -> String? {
        let rule = config["routing"]?["rules"]?.arrayValue?.first { $0["domain"]?.arrayValue?.contains(.string("domain:" + host)) == true }
        return rule.map { ($0["balancerTag"] ?? $0["outboundTag"])!.stringValue! }
    }

    @Test func groupsBecomeBalancersThatFailClosed() throws {
        let c = try build(.global)
        let tags = c["outbounds"]!.arrayValue!.compactMap { $0["tag"]?.stringValue }
        #expect(tags.contains("via-g0-m0") && tags.contains("via-g0-m1"))
        let balancers = try #require(c["routing"]?["balancers"]?.arrayValue)
        #expect(balancers.map { $0["tag"]?.stringValue } == ["via-g0", "via-g0-fb"])
        #expect(balancers.map { $0["fallbackTag"]?.stringValue } == ["block", "proxy"])
        #expect(balancers[0]["selector"] == ["via-g0-m"])
        #expect(balancers[0]["strategy"]?["type"] == "leastPing")
        #expect(target(c, "work.example") == "via-g0")
        #expect(target(c, "mail.example") == "via-g0-fb")
        #expect(target(c, "one.example") == "via-s1-m0")
        #expect(c["observatory"]?["subjectSelector"] == ["via-g", "via-s"])
    }

    @Test func fullConfigsBringTheirChainOnly() throws {
        let c = try build(.global)
        let outbounds = c["outbounds"]!.arrayValue!
        let exit = try #require(outbounds.first { $0["tag"] == "via-s2-m0" })
        #expect(exit["settings"]?["servers"]?[0]?["address"] == "exit.example")
        #expect(exit["streamSettings"]?["sockopt"]?["dialerProxy"] == "via-hop-2-0-hop")
        #expect(outbounds.contains { $0["tag"] == "via-hop-2-0-hop" })
        // Its own freedom outbound and routing stay out.
        #expect(!outbounds.contains { $0["tag"]?.stringValue?.hasSuffix("direct") == true && $0["tag"] != "direct" })
        #expect(!(c["routing"]?["rules"]?.arrayValue ?? []).contains { $0["ip"] == ["1.1.1.1"] })
        #expect(target(c, "chain.example") == "via-s2-m0")
    }

    @Test func viaServersAreDialledLikeTheServer() throws {
        var options = RunOptions(metricsPort: 1, outboundInterface: "en9")
        options.dialer = DialerSettings(fragment: .init())
        let c = try build(.global, options: options)
        let members = c["outbounds"]!.arrayValue!.filter { $0["tag"]?.stringValue?.hasPrefix("via-") == true }
        #expect(members.allSatisfy { $0["streamSettings"]?["sockopt"]?["interface"] == "en9" })
        #expect(members.first { $0["tag"] == "via-g0-m0" }?["streamSettings"]?["sockopt"]?["dialerProxy"] == .string(ConfigBuilder.dialerTag))
    }

    @Test func killSwitchAllowsEveryViaServer() {
        #expect(Self.custom().viaHosts == ["1.2.3.4", "exit.example", "hop.example", "srv.example.com"])
        var off = Self.custom()
        off.rules = off.rules.map { var r = $0; r.enabled = false; return r }
        #expect(off.viaHosts.isEmpty)
    }

    @Test func directModeHasNoVia() throws {
        let c = try build(.direct)
        #expect(!c["outbounds"]!.arrayValue!.contains { $0["tag"]?.stringValue?.hasPrefix("via-") == true })
        #expect(c["observatory"] == nil && c["routing"]?["balancers"] == nil)
    }

    @Test func customConfigsGetBalancersWithTheirOwnTags() throws {
        let imported: JSONValue = ["outbounds": [["tag": "p", "protocol": "trojan", "settings": ["servers": [["address": "x.example", "port": 443, "password": "x"]]]]],
                                   "routing": ["balancers": [["tag": "own", "selector": ["p"]]]],
                                   "observatory": ["subjectSelector": ["p"], "probeInterval": "1m"]]
        let c = try ConfigBuilder.buildCustom(config: imported, options: RunOptions(metricsPort: 1), routing: .global, custom: Self.custom())
        let balancers = try #require(c["routing"]?["balancers"]?.arrayValue)
        #expect(balancers.map { $0["tag"]?.stringValue } == ["own", "via-g0", "via-g0-fb"])
        #expect(balancers[1]["fallbackTag"]?.stringValue?.hasPrefix("v2mac-block") == true)
        #expect(balancers[2]["fallbackTag"] == "p")
        #expect(c["observatory"]?["subjectSelector"] == ["p", "via-g", "via-s"])
        #expect(c["observatory"]?["probeInterval"] == "1m")
        #expect(c["outbounds"]!.arrayValue!.contains { $0["tag"] == "via-g0-m1" })
    }

    @Test(.tags(.integration), .enabled(if: TestSupport.coreAvailable), arguments: [false, true])
    func generatedViaConfigPassesXrayTest(custom: Bool) throws {
        let options = RunOptions(metricsPort: 1)
        let imported: JSONValue = ["outbounds": [Self.trojan.config.setting("tag", to: "p")]]
        let config = custom
            ? try ConfigBuilder.buildCustom(config: imported, options: options, routing: .rulesOnly, custom: Self.custom())
            : try ConfigBuilder.build(outbound: Self.trojan.config, options: options, routing: .bypass([]), custom: Self.custom())
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
        #expect(out.contains("Configuration OK"), Comment(rawValue: out))
    }
}

@Suite struct TidyUpTests {
    static let rules = RuleV2Tests.oldList.map(Rule.init(migrating:))

    func suggestions(_ rules: [Rule] = rules) -> [TidySuggestion.Kind] {
        TidyUp.suggestions(for: rules, apps: RuleV2Tests.installed).map(\.kind)
    }

    @Test func mergesAppAndHostHalves() {
        let s = suggestions()
        #expect(s.contains(.merge(into: Self.rules[1].id, from: Self.rules[2].id, name: "Chat")))
        let merged = TidyUp.apply(TidyUp.suggestions(for: Self.rules, apps: RuleV2Tests.installed).filter { if case .merge = $0.kind { true } else { false } }, to: Self.rules)
        #expect(merged.count == Self.rules.count - 1)
        #expect(merged[1].name == "Chat")
        #expect(merged[1].appItems.count == 4)
        #expect(merged[1].hostItems == ["domain:chat.example", "domain:chatcdn.example", "keyword:chatapi"])
    }

    @Test func mergingNeverJumpsARuleThatRoutesElsewhere() {
        let a = Rule(name: "App - Mail", action: .proxy, items: [.app("Mail.app")])
        let between = Rule(name: "Work", action: .direct, items: [.host("mail.example")])
        let b = Rule(name: "Host - Mail", action: .proxy, items: [.host("mail.example")])
        #expect(!suggestions([a, between, b]).contains { if case .merge = $0 { true } else { false } })
        let same = Rule(name: "Other", action: .proxy, items: [.host("x.example")])
        #expect(suggestions([a, same, b]).contains(.merge(into: a.id, from: b.id, name: "Mail")))
    }

    @Test func dropsWhatTheBuiltInsCover() {
        let s = suggestions()
        #expect(s.contains(.dropCovered(rule: Self.rules[0].id, items: [.host("10.0.0.0/8"), .host("192.168.0.0/16")])))
        #expect(TidyUp.isCoveredByBuiltIns(.host("domain:printer.local")))
        #expect(TidyUp.isCoveredByBuiltIns(.host("full:router.lan")))
        #expect(TidyUp.isCoveredByBuiltIns(.host("10.1.0.0/16")))
        #expect(TidyUp.isCoveredByBuiltIns(.host("geoip:private")))
        #expect(!TidyUp.isCoveredByBuiltIns(.host("0.0.0.0/0")))
        #expect(!TidyUp.isCoveredByBuiltIns(.host("11.0.0.0/8")))
        #expect(!TidyUp.isCoveredByBuiltIns(.host("domain:notlocal")))
    }

    @Test func collapsesOneAppsSpellings() {
        let s = suggestions()
        #expect(s.contains(.collapseApps(rule: Self.rules[1].id, items: ["Chat.app", "Chat", "com.example.chat", "*chat*"], into: "com.example.chat")))
        let applied = TidyUp.apply([.init(kind: .collapseApps(rule: Self.rules[1].id, items: ["Chat.app", "Chat", "com.example.chat", "*chat*"], into: "com.example.chat"))], to: Self.rules)
        #expect(applied[1].appItems == ["com.example.chat"])
        // Still the same app, so the rule still matches it.
        #expect(AppMatchers(parsing: "com.example.chat", apps: RuleV2Tests.installed).processes == ["/Applications/Chat.app/"])
    }

    @Test func dropsDuplicates() {
        let a = Rule(name: "A", action: .block, items: [.host("a.example"), .host("b.example"), .host("a.example")])
        let copy = Rule(name: "A again", action: .block, items: a.items)
        let s = suggestions([a, copy])
        #expect(s.contains(.dropRule(copy.id, sameAs: a.id)))
        #expect(s.contains(.dropDuplicates(rule: a.id, items: [.host("a.example")])))
        let applied = TidyUp.apply(TidyUp.suggestions(for: [a, copy], apps: []), to: [a, copy])
        #expect(applied.map(\.items) == [[.host("a.example"), .host("b.example")]])
    }

    @Test func tidiedListRoutesTheSame() throws {
        // Everything but collapsing keeps the compiled rules' matches; check with the tester.
        let chosen = TidyUp.suggestions(for: Self.rules, apps: RuleV2Tests.installed).filter { if case .collapseApps = $0.kind { false } else { true } }
        let tidied = TidyUp.apply(chosen, to: Self.rules)
        func route(_ rules: [Rule], _ q: RouteQuery) throws -> String? {
            let c = try ConfigBuilder.build(outbound: ["protocol": "freedom"], options: RunOptions(metricsPort: 1), routing: .global,
                                            custom: CustomRules(rules: rules, installedApps: RuleV2Tests.installed))
            return RuleTester.route(q, routing: c["routing"]!, geo: GeoFixture.geo)?.outbound
        }
        for q in [RouteQuery(host: "chat.example"), RouteQuery(host: "x.chatapi.example"), RouteQuery(ips: ["10.2.3.4"]),
                  RouteQuery(host: "office.example", process: "/Applications/Editor.app/Contents/MacOS/Editor"),
                  RouteQuery(host: "office.example"), RouteQuery(host: "other.example", process: "/Applications/Chat.app/Contents/MacOS/Chat"),
                  RouteQuery(host: "ads.example"), RouteQuery(host: "tracker.example")] {
            #expect(try route(tidied, q) == route(Self.rules, q), "\(q)")
        }
    }

    @Test func storedListsPreferV2AndMigrateV1() {
        let v1 = CustomRule.encode(RuleV2Tests.oldList)
        #expect(Rule.list(v2: nil, v1: v1) == Self.rules)
        #expect(Rule.list(v2: Rule.encode([]), v1: v1).isEmpty)
        let old = RuleProfile(name: "Work", rules: RuleV2Tests.oldList)
        let profiles = RuleProfileV2.list(v2: nil, v1: RuleProfile.encode([old]))
        #expect(profiles.map(\.id) == [old.id] && profiles[0].rules == Self.rules)
        #expect(RuleProfileV2.list(v2: RuleProfileV2.encode(profiles), v1: nil) == profiles)
    }
}
