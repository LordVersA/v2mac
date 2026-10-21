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
        #expect(rules.map { $0["outboundTag"]?.stringValue } == ["direct", "direct", "block", "proxy", "direct", "direct"])
        #expect(rules[0]["domain"]?[0]?.stringValue == "full:localhost")
        #expect(rules[1]["ip"]?[0]?.stringValue == "geoip:private")
        #expect(c["routing"]?["domainStrategy"]?.stringValue == "IPOnDemand")
        #expect(c["dns"] != nil)
    }

    @Test func domainOnlyGlobalStaysAsIs() throws {
        let c = try build(.global, lists(proxy: "a.com"))
        #expect(c["routing"]?["domainStrategy"]?.stringValue == "AsIs")
        #expect(c["dns"] == nil)
    }

    @Test func directModeKeepsOnlyBlock() throws {
        let rules = try #require(try build(.direct, lists(proxy: "a.com", block: "c.com"))["routing"]?["rules"]?.arrayValue)
        #expect(rules.map { $0["outboundTag"]?.stringValue } == ["direct", "direct", "block", "direct"])
    }

    @Test func rulesOnlyProxiesMatchesAndDefaultsDirect() throws {
        let rules = try #require(try build(.rulesOnly, lists(proxy: "a.com", block: "c.com"))["routing"]?["rules"]?.arrayValue)
        #expect(rules.map { $0["outboundTag"]?.stringValue } == ["direct", "direct", "block", "proxy", "proxy", "direct"])
        #expect(rules[4]["domain"]?.arrayValue?.contains("full:ipwho.is") == true)
        #expect(rules.last?["network"]?.stringValue == "tcp,udp")
    }

    @Test func rulesOnlySendsTheCoreResolverThroughTheProxy() throws {
        let c = try build(.rulesOnly, lists(proxy: "geoip:us"))
        let servers = ConfigBuilder.dohServers.compactMap { URL(string: $0)?.host }
        #expect(c["dns"] != nil)
        let rules = try #require(c["routing"]?["rules"]?.arrayValue)
        let resolver = try #require(rules.firstIndex { $0["ip"]?.arrayValue == servers.map { .string($0) } })
        #expect(rules[resolver]["outboundTag"] == "proxy")
        #expect(resolver < rules.firstIndex { $0["network"] == "tcp,udp" }!)
    }

    @Test func unmatchedRouteEndsTheRules() throws {
        var custom = lists(proxy: "a.com")
        custom.unmatchedRoute = .block
        for plan in [RoutingPlan.global, .rulesOnly] {
            let rules = try #require(try build(plan, custom)["routing"]?["rules"]?.arrayValue)
            #expect(rules.last == ["type": "field", "network": "tcp,udp", "outboundTag": "block"])
            #expect(rules.filter { $0["network"] == "tcp,udp" }.count == 1)
        }
        let direct = try #require(try build(.direct, custom)["routing"]?["rules"]?.arrayValue)
        #expect(direct.last?["outboundTag"] == "direct")
    }

    @Test func proxyClientsCanGoDirect() throws {
        var custom = lists(proxy: "a.com")
        custom.proxyClientsRoute = .direct
        let rules = try #require(try build(.global, custom)["routing"]?["rules"]?.arrayValue)
        #expect(rules[2] == ["type": "field", "inboundTag": ["mixed-in"], "outboundTag": "direct"])
    }

    @Test(arguments: [RoutingPlan.global, .bypass([]), .bypass([
        RegionRoute(geositeFile: "sites.dat", geositeTags: ["ir"], geoipFile: "ips.dat", geoipTags: ["ir"]),
    ])], [false, true])
    func proxyClientsSkipRulesAfterLocalTraffic(plan: RoutingPlan, skip: Bool) throws {
        var custom = lists(direct: "a.com", block: "b.com")
        custom.proxyClientsRoute = skip ? .proxy : nil
        let rules = try #require(try build(plan, custom)["routing"]?["rules"]?.arrayValue)
        #expect(rules[0]["domain"]?[0]?.stringValue == "full:localhost")
        #expect(rules[1]["ip"]?[0]?.stringValue == "geoip:private")
        if skip {
            #expect(rules[2] == ["type": "field", "inboundTag": ["mixed-in"], "outboundTag": "proxy"])
        } else {
            #expect(!rules.contains { $0["inboundTag"] != nil })
        }
        #expect(rules[skip ? 3 : 2]["domain"] == ["domain:b.com"])
        #expect(rules[skip ? 4 : 3]["domain"] == ["domain:a.com"])
        // QUIC remains blocked before the proxy-port exception.
        custom.blockQUIC = true
        let quic = try #require(try build(plan, custom)["routing"]?["rules"]?.arrayValue)
        #expect(quic.first == ["type": "field", "network": "udp", "port": "443", "outboundTag": "block"])
        let direct = try #require(try build(.direct, custom)["routing"]?["rules"]?.arrayValue)
        #expect(!direct.contains { $0["inboundTag"] != nil })
        #expect(!direct.contains { $0["outboundTag"] == "proxy" })
        #expect(direct.contains { $0["domain"] == ["domain:b.com"] && $0["outboundTag"] == "block" })
        #expect(direct.last?["outboundTag"] == "direct")
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
        #expect(rules.dropFirst(3).map { $0["outboundTag"]?.stringValue } == ["direct", "proxy", "block"])
        #expect(rules[4]["process"] == ["/Applications/Spotify.app/"])
        #expect(rules[5]["process"] == ["curl"] && rules[5]["domain"] == ["domain:b.com"])
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
        #expect(try RuleImport(data: Data(Fixtures.proxifierProfile.utf8)).format == .proxifier)
    }

    @Test func importsClashRules() throws {
        let r = try RuleImport(data: Data(Fixtures.clashConfig.utf8))
        #expect(r.format == .clash)
        #expect(r.rules.map(\.action) == [.proxy, .proxy, .direct, .block])
        #expect(r.rules[0].hosts == "DOMAIN-SUFFIX,blocked.example\nDOMAIN-KEYWORD,tracker")
        #expect(r.rules[1].apps == "Telegram" && r.rules[1].hosts.isEmpty)
        #expect(RuleMatchers(parsing: r.rules[2].hosts).ips == ["10.0.0.0/8", "geoip:ir"])
        #expect(r.skipped == ["RULE-SET,streaming,PROXY"])
    }

    @Test func importsSingBoxRules() throws {
        let r = try RuleImport(data: Data(Fixtures.singBoxConfig.utf8))
        #expect(r.format == .singBox)
        #expect(r.rules.map(\.action) == [.direct, .proxy, .block])
        #expect(r.rules[0].hosts == "domain:ir\ngeoip:ir")
        #expect(r.rules[1].apps == "Safari" && r.rules[1].hosts == "full:x.example.com")
        #expect(r.skipped.count == 1)
    }

    @Test func importsV2rayNRules() throws {
        let r = try RuleImport(data: Data(Fixtures.v2rayNRules.utf8))
        #expect(r.format == .xray)
        #expect(r.rules.map(\.name) == ["Iran direct", "Block ads", "Telegram"])
        #expect(r.rules.map(\.action) == [.direct, .block, .proxy])
        #expect(!r.rules[2].enabled && r.rules[2].apps == "Telegram")
        #expect(r.skipped == ["Ports"])
    }

    @Test func importsSurgeRules() throws {
        let r = try RuleImport(data: Data(Fixtures.surgeConfig.utf8))
        #expect(r.format == .surge)
        #expect(r.rules.count == 2 && r.rules[0].hosts.split(separator: "\n").count == 2)
        #expect(r.skipped == ["RULE-SET,https://lists.example.com/ads.list,REJECT"])
        #expect(throws: (any Error).self) { try RuleImport(data: Data("hello".utf8)) }
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
        #expect(a.sourcePort == 51973 && a.host == "example.com" && a.port == 443 && a.inbound == "mixed-in" && a.outbound == "direct")
        #expect(a.isDefaultRoute)
        let b = try #require(SeenConnection(line: "2026/10/17 00:34:30.875797 from 127.0.0.1:51978 accepted http://blockme.example.org/x [mixed-in -> block]"))
        #expect(b.host == "blockme.example.org" && b.port == 80 && b.sourcePort == 51978 && b.outbound == "block")
        #expect(!b.isDefaultRoute)
        let v6 = SeenConnection(line: "x from 1.2.3.4:5 accepted udp:[2001:db8::1]:53 [tun-in -> proxy]")
        #expect(v6?.host == "2001:db8::1" && v6?.port == 53)
        let flows = NetFlow.parse("""
        ,bytes_in,bytes_out,
        launchd.1,,,
        tcp4 127.0.0.1:10808<->*:*,,,
        curl.17295,30758,1814,
        tcp4 127.0.0.1:56187<->127.0.0.1:10808,30758,1814,
        tcp4 198.18.0.1:5000<->93.184.216.34:443,70,7,
        xray.900,1,1,
        tcp4 192.168.1.5:6000<->93.184.216.34:443,1,1,
        Google Chrome H.4410,9,9,
        tcp6 ::1:61000<->::1:10808,100,200,
        """)
        #expect(flows.map(\.process) == ["curl", "curl", "xray", "Google Chrome H"])
        #expect(NetFlow.proxyClient(flows, proxyPort: 10808, sourcePort: 56187)?.received == 30758)
        #expect(NetFlow.proxyClient(flows, proxyPort: 10808, sourcePort: 61000)?.pid == 4410)
        #expect(NetFlow.proxyClient(flows, proxyPort: 10808, sourcePort: 5000) == nil)
        let tun = NetFlow.tunClient(flows, port: 443, addresses: ["93.184.216.34"], claimed: [], skipping: ["xray"])
        #expect(tun?.localPort == 5000 && tun?.sent == 7)
        #expect(NetFlow.tunClient(flows, port: 443, addresses: ["93.184.216.34"], claimed: [tun!.key], skipping: ["xray"]) == nil)
        #expect(HostAddresses.lookup("10.1.2.3") == ["10.1.2.3"] && HostAddresses.lookup("localhost").contains("127.0.0.1"))
        #expect(NetFlow.tunClient(flows, port: 80, addresses: ["93.184.216.34"], claimed: [], skipping: ["xray"]) == nil)
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

@Suite struct CountryPlacesTests {
    @Test func readsZoneTab() {
        let places = CountryPlaces.read("# comment\nDE\t+5230+01322\tEurope/Berlin\nDE\t+4742+00841\tEurope/Busingen\nGB\t+513030-0000731\tEurope/London\nXX\tbad\tNowhere\n")
        #expect(places.count == 2)
        #expect(abs(places["DE"]!.latitude - 52.5) < 0.001 && abs(places["DE"]!.longitude - 13.3667) < 0.001)
        #expect(abs(places["GB"]!.latitude - 51.5083) < 0.001 && abs(places["GB"]!.longitude + 0.1253) < 0.001)
    }

    @Test func systemFileCoversCountries() throws {
        let text = try String(contentsOf: CountryPlaces.systemFile, encoding: .utf8)
        let places = CountryPlaces.read(text)
        #expect(places.count > 200 && places["JP"] != nil && places["IR"] != nil)
    }
}

@Suite struct GeoIPIndexTests {
    func field(_ number: UInt8, _ payload: [UInt8]) -> [UInt8] { [number << 3 | 2, UInt8(payload.count)] + payload }
    func cidr(_ ip: [UInt8], _ prefix: UInt8) -> [UInt8] { field(2, field(1, ip) + [0x10, prefix]) }

    @Test func findsCountries() {
        let de = field(1, field(1, Array("DE".utf8)) + cidr([93, 184, 0, 0], 16) + cidr([0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 12), 32))
        let jp = field(1, field(1, Array("jp".utf8)) + cidr([1, 2, 3, 0], 24))
        let named = field(1, field(1, Array("private".utf8)) + cidr([10, 0, 0, 0], 8))
        let index = GeoIPIndex(data: Data(de + jp + named))
        #expect(index.country(of: "93.184.216.34") == "DE")
        #expect(index.country(of: "1.2.3.200") == "JP")
        #expect(index.country(of: "1.2.4.1") == nil)
        #expect(index.country(of: "10.1.1.1") == nil)
        #expect(index.country(of: "2001:db8::5") == "DE")
        #expect(index.country(of: "example.com") == nil)
    }

    @Test(.tags(.integration), .enabled(if: TestSupport.coreAvailable)) func bundledFile() {
        let index = GeoIPIndex(contentsOf: TestSupport.vendorCore.appendingPathComponent("geoip.dat"))
        // Since Xray 26.10.21 the bundled file has only the CN, IR and RU country lists.
        #expect(index.country(of: "223.5.5.5") == "CN")
    }
}

@Suite struct RuleImportSafetyTests {
    @Test func malformedLinesAreSkippedNotFatal() throws {
        let r = try RuleImport(data: Data(",\n,,\nDOMAIN,,PROXY\nDOMAIN,a.example.com,PROXY".utf8))
        #expect(r.rules.count == 1 && r.skipped.count == 3)
    }

    @Test func rulesWithConditionsV2MacLacksAreSkipped() throws {
        let sing = #"{"outbounds":[{"type":"direct","tag":"d"}],"route":{"rules":[{"domain":["a.example.com"],"port":[443],"outbound":"d"},{"domain":["b.example.com"],"invert":true,"outbound":"d"},{"domain":["c.example.com"],"outbound":"d"}]}}"#
        let s = try RuleImport(data: Data(sing.utf8))
        #expect(s.rules.map(\.hosts) == ["full:c.example.com"] && s.skipped.count == 2)
        let xray = #"[{"outboundTag":"direct","domain":["a.example.com"],"ip":["1.2.3.4"]},{"outboundTag":"direct","domain":["b.example.com"],"network":"udp"},{"outboundTag":"direct","domain":["c.example.com"],"port":"","inboundTag":null}]"#
        let x = try RuleImport(data: Data(xray.utf8))
        #expect(x.rules.map(\.hosts) == ["c.example.com"] && x.skipped.count == 2)
    }

    @Test func deepNestingIsCutOff() {
        let flow = "proxies: " + String(repeating: "[", count: 10_000)
        _ = MiniYAML.parse(flow)
        let block = (0..<5_000).map { String(repeating: " ", count: $0) + "k\($0):" }.joined(separator: "\n")
        _ = MiniYAML.parse(block)
    }
}
