import Foundation
import Testing
@testable import V2MacCore

@Suite struct CustomRulesTests {
    @Test func parsesCommonFormats() {
        let m = RuleMatchers(parsing: """
        # comment
        example.com, *.wild.org +.plus.net
        full:exact.io
        geosite:category-ads-all
        geoip:IR
        10.0.0.0/8
        2001:db8::/32
        ext:region-ir-geosite.dat:ir
        ext:region-ir-geoip.dat:ir
        DOMAIN-SUFFIX,clash.com,DIRECT
        - DOMAIN,host.clash.com
        - '+.provider.com'
        IP-CIDR,1.2.3.0/24,PROXY,no-resolve
        GEOIP,CN
        0.0.0.0 ads.one.com ads.two.com
        ||tracker.net^
        bad!entry, 1.2.3.4/40
        not a rule, .ir
        """)
        #expect(m.domains == [
            "domain:example.com", "domain:wild.org", "domain:plus.net", "full:exact.io", "geosite:category-ads-all",
            "ext:region-ir-geosite.dat:ir", "domain:clash.com", "full:host.clash.com", "domain:provider.com",
            "full:ads.one.com", "full:ads.two.com", "domain:tracker.net", "domain:ir",
        ])
        #expect(m.ips == ["geoip:ir", "10.0.0.0/8", "2001:db8::/32", "ext:region-ir-geoip.dat:ir", "1.2.3.0/24", "geoip:cn"])
        #expect(m.invalid == ["bad!entry", "1.2.3.4/40", "not", "a", "rule"])
    }

    func build(_ plan: RoutingPlan, _ custom: CustomRules) throws -> JSONValue {
        try ConfigBuilder.build(outbound: ["protocol": "freedom"], options: RunOptions(metricsPort: 1), routing: plan, custom: custom)
    }

    func lists(proxy: String = "", direct: String = "", block: String = "") -> CustomRules {
        CustomRules(rules: CustomRule.migrating(proxy: proxy, direct: direct, block: block))
    }

    @Test func rulesComeFirstInOrder() throws {
        let c = try build(.global, lists(proxy: "a.com", direct: "b.com\n1.1.1.1", block: "c.com"))
        let rules = try #require(c["routing"]?["rules"]?.arrayValue)
        #expect(rules.map { $0["outboundTag"]?.stringValue } == ["direct", "block", "proxy", "direct", "direct", "direct"])
        #expect(rules[0]["domain"]?[0]?.stringValue == "full:localhost")
        #expect(rules[5]["ip"]?[0]?.stringValue == "geoip:private")
        #expect(c["routing"]?["domainStrategy"]?.stringValue == "IPIfNonMatch")
        #expect(c["dns"] != nil)
    }

    @Test func domainOnlyGlobalStaysAsIs() throws {
        let c = try build(.global, lists(proxy: "a.com"))
        #expect(c["routing"]?["domainStrategy"]?.stringValue == "AsIs")
        #expect(c["dns"] == nil)
    }

    @Test func directModeKeepsOnlyBlock() throws {
        let rules = try #require(try build(.direct, lists(proxy: "a.com", block: "c.com"))["routing"]?["rules"]?.arrayValue)
        #expect(rules.map { $0["outboundTag"]?.stringValue } == ["direct", "block", "direct"])
    }

    @Test func emptyRulesChangeNothing() throws {
        for plan in [RoutingPlan.global, .direct, .bypass([])] {
            #expect(try build(plan, CustomRules()) == ConfigBuilder.build(outbound: ["protocol": "freedom"], options: RunOptions(metricsPort: 1), routing: plan))
        }
    }

    @Test func proxifierHostForms() {
        let m = RuleMatchers(parsing: "*google*; *.example.com\n10.0.0.0-10.255.255.255\n10.0.0.1-10.0.0.6\n2001:db8::-2001:db8::ffff\n0.0.0.0-255.255.255.255\n*a*b*")
        #expect(m.domains == ["keyword:google", "domain:example.com"])
        #expect(m.ips == ["10.0.0.0/8", "10.0.0.1/32", "10.0.0.2/31", "10.0.0.4/31", "10.0.0.6/32", "2001:db8::/112", "0.0.0.0/0"])
        #expect(m.invalid == ["*a*b*"])
        #expect(RuleMatchers.range("::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff") == ["::/0"])
        #expect(RuleMatchers.range("10.0.0.9-10.0.0.1") == nil)
        #expect(RuleMatchers.range("10.0.0.1-::1") == nil)
    }

    @Test func appForms() {
        let apps = [InstalledApp(path: "/Applications/Spotify.app", bundleID: "com.spotify.client"),
                    InstalledApp(path: "/Applications/Discord.app", bundleID: "com.hnc.Discord")]
        let m = AppMatchers(parsing: "\"Spotify.app\"; com.hnc.discord\n*disc*\ncurl\n/usr/bin/git\n~/Apps/Tool.app\nMissing.app\norg.unknown.chat", apps: apps)
        #expect(m.processes == ["/Applications/Spotify.app/", "/Applications/Discord.app/", "curl",
                                "/usr/bin/git", NSHomeDirectory() + "/Apps/Tool.app/", "org.unknown.chat"])
        #expect(m.unmatched == ["Missing.app"])
        #expect(AppMatchers(parsing: "Spotify", apps: apps).processes == ["Spotify", "/Applications/Spotify.app/"])
    }

    @Test func orderedRulesWithAppsAndQUIC() throws {
        let apps = [InstalledApp(path: "/Applications/Spotify.app", bundleID: "com.spotify.client")]
        let custom = CustomRules(rules: [
            CustomRule(name: "LAN", action: .direct, hosts: "10.0.0.0/8"),
            CustomRule(name: "Off", action: .block, hosts: "a.com", enabled: false),
            CustomRule(name: "Music", action: .proxy, apps: "Spotify.app"),
            CustomRule(name: "Gone", action: .proxy, apps: "Missing.app"),
            CustomRule(name: "Both", action: .block, apps: "curl", hosts: "b.com"),
        ], installedApps: apps, blockQUIC: true)
        let rules = try #require(try build(.global, custom)["routing"]?["rules"]?.arrayValue)
        #expect(rules[0] == ["type": "field", "network": "udp", "port": "443", "outboundTag": "block"])
        #expect(rules.dropFirst(2).map { $0["outboundTag"]?.stringValue } == ["direct", "proxy", "block", "direct"])
        #expect(rules[3]["process"] == ["/Applications/Spotify.app/"])
        #expect(rules[4]["process"] == ["curl"] && rules[4]["domain"] == ["domain:b.com"])
    }

    @Test func storedRulesRoundTrip() {
        let rules = [CustomRule(name: "A", action: .proxy, apps: "x", hosts: "y.com", enabled: false)]
        #expect(CustomRule.decode(CustomRule.encode(rules)) == rules)
        #expect(CustomRule.decode("not json").isEmpty)
        #expect(CustomRule.migrating(proxy: "a.com", direct: " ", block: "b.com").map(\.action) == [.block, .proxy])
    }

    @Test func importsProxifierProfile() throws {
        let p = try ProxifierProfile(data: Data(Fixtures.proxifierProfile.utf8))
        #expect(p.blockQUIC)
        #expect(p.skipped == ["Elsewhere", "Chain"])
        #expect(p.rules.map(\.name) == ["Proxifier exclusions", "Direct - LAN", "Apps", "Hosts", "Ads"])
        #expect(p.rules.map(\.action) == [.direct, .direct, .proxy, .proxy, .block])
        #expect(p.rules[0].hosts == "localhost\n*.local")
        #expect(p.rules[2].apps == "\"Example.app\"\ncom.example.chat\n*tool*")
        #expect(!p.rules[3].enabled)
        #expect(throws: (any Error).self) { try ProxifierProfile(data: Data("<x/>".utf8)) }
    }
}

@Suite struct GeoTagsTests {
    /// A protobuf list entry: field 1 holding a message whose field 1 is the name, plus one more field.
    func entry(_ name: String) -> [UInt8] {
        let inner: [UInt8] = [0x0a, UInt8(name.utf8.count)] + Array(name.utf8) + [0x12, 0x01, 0x00]
        return [0x0a, UInt8(inner.count)] + inner
    }

    @Test func readsNamesLowercased() {
        #expect(GeoTags.read(Data(entry("IR") + entry("CATEGORY-ADS-ALL"))) == ["ir", "category-ads-all"])
        #expect(GeoTags.read(Data(entry("CN") + [0x0a, 0x7f])) == ["cn"])
    }

    @Test(.tags(.integration), .enabled(if: TestSupport.coreAvailable)) func bundledFiles() {
        let dir = TestSupport.vendorCore
        let ip = GeoTags.read(contentsOf: dir.appendingPathComponent("geoip.dat"))
        #expect(ip.contains("ir") && ip.contains("private"))
        #expect(GeoTags.read(contentsOf: dir.appendingPathComponent("geosite.dat")).contains("category-ads-all"))
    }

    @Test func countryRules() {
        let all = CountryRuleOptions()
        #expect(all.rules(for: "IR", siteTags: ["category-ir"]) == ["geoip:ir", "domain:ir", "geosite:category-ir"])
        #expect(all.rules(for: "GB", siteTags: []) == ["geoip:gb", "domain:uk"])
        #expect(CountryRuleOptions(ipRanges: false, topLevelDomain: false).rules(for: "cn", siteTags: ["cn", "category-cn"]) == ["geosite:category-cn", "geosite:cn"])
    }
}

@Suite struct SimpleRulesTests {
    @Test func readsAccessLog() throws {
        let a = try #require(SeenConnection(line: "2026/10/17 00:34:27.238170 from tcp:127.0.0.1:51973 accepted tcp:Example.com:443 [mixed-in >> direct]"))
        #expect(a.sourcePort == 51973 && a.host == "example.com" && a.inbound == "mixed-in" && a.outbound == "direct")
        let b = try #require(SeenConnection(line: "2026/10/17 00:34:30.875797 from 127.0.0.1:51978 accepted http://blockme.example.org/x [mixed-in -> block]"))
        #expect(b.host == "blockme.example.org" && b.sourcePort == 51978 && b.outbound == "block")
        #expect(SeenConnection(line: "x from 1.2.3.4:5 accepted udp:[2001:db8::1]:53 [tun-in -> proxy]")?.host == "2001:db8::1")
        #expect(SeenConnection(line: "2026/10/17 [Warning] core: Xray started") == nil)
        #expect(SocketOwners.appBundle(of: "/Applications/A.app/Contents/Frameworks/H.app/Contents/MacOS/H") == "/Applications/A.app")
        #expect(SocketOwners.appBundle(of: "/usr/bin/curl") == nil)
    }

    @Test func groupsByName() {
        #expect(EntryGroups.brand(ofHost: "www.google.co.uk") == "google")
        #expect(EntryGroups.brand(ofHost: "mail.google.com") == "google")
        #expect(EntryGroups.brand(ofHost: "1.2.3.4") == nil)
        #expect(EntryGroups.brand(ofBundleID: "com.google.Chrome") == "google")
        #expect(EntryGroups.keys(for: ["google", "googleapis", "gstatic", "x"]) == ["google": "google", "googleapis": "google", "gstatic": "gstatic", "x": "x"])
    }

    @Test func movesEntriesBetweenColumns() {
        var rules = [CustomRule(name: "Mine", action: .direct, hosts: "a.com\nb.com"),
                     CustomRule(name: "Both", action: .proxy, apps: "x", hosts: "c.com"),
                     CustomRule(name: "Ads", action: .block, hosts: "a.com")]
        #expect(SimpleRules.entries(rules, action: .direct) == [RuleEntry(.host, "a.com"), RuleEntry(.host, "b.com")])
        #expect(SimpleRules.entries(rules, action: .proxy).isEmpty)
        #expect(SimpleRules.sourceRules(rules, action: .direct).mapValues(\.name) == ["host:a.com": "Mine", "host:b.com": "Mine"])
        rules = SimpleRules.move([RuleEntry(.host, "A.com"), RuleEntry(.app, "/Applications/S.app")], to: .proxy, in: rules)
        #expect(rules.map(\.name) == ["Sites through the proxy", "Apps through the proxy", "Mine", "Both"])
        // A blocked entry moved to Proxy leaves the block rule; an emptied rule goes.
        #expect(rules[2].hosts == "b.com" && !rules.contains { $0.name == "Ads" })
        #expect(SimpleRules.entries(rules, action: .proxy).map(\.text) == ["A.com", "/Applications/S.app"])
        rules = SimpleRules.move([RuleEntry(.host, "b.com")], to: .proxy, in: rules)
        #expect(rules[0].hosts == "A.com\nb.com" && !rules.contains { $0.name == "Mine" })
        rules = SimpleRules.move([RuleEntry(.host, "a.com"), RuleEntry(.host, "b.com")], to: nil, in: rules)
        #expect(rules.map(\.name) == ["Apps through the proxy", "Both"])
        rules = SimpleRules.move([RuleEntry(.host, "ads.com")], to: .block, in: rules)
        #expect(rules.first?.name == "Sites blocked" && SimpleRules.entries(rules, action: .block) == [RuleEntry(.host, "ads.com")])
        #expect(RuleEntry(id: RuleEntry(.app, "x:y").id) == RuleEntry(.app, "x:y"))
        let r = [CustomRule(name: "K", action: .direct, hosts: "*google*\nexample.org"), CustomRule(name: "A", action: .proxy, apps: "*chat*\ncurl")]
        #expect(SimpleRules.action(forHost: "www.google.de", in: r) == .direct)
        #expect(SimpleRules.action(forHost: "a.example.org", in: r) == .direct)
        #expect(SimpleRules.action(forHost: "example.com", in: r) == nil)
        #expect(SimpleRules.action(forApp: "/Applications/Chat.app", bundleID: "x.y.chat", in: r) == .proxy)
        #expect(SimpleRules.action(forApp: "/usr/bin/curl", bundleID: "", in: r) == .proxy)
        #expect(SimpleRules.action(forApp: "/Applications/Mail.app", bundleID: "com.apple.mail", in: r) == nil)
        let p = [RuleProfile(name: "Work", rules: rules)]
        #expect(RuleProfile.decode(RuleProfile.encode(p)) == p)
    }
}
