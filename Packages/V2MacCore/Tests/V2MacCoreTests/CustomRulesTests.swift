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

    @Test func rulesComeFirstInOrder() throws {
        let c = try build(.global, CustomRules(proxy: "a.com", direct: "b.com\n1.1.1.1", block: "c.com"))
        let rules = try #require(c["routing"]?["rules"]?.arrayValue)
        #expect(rules.map { $0["outboundTag"]?.stringValue } == ["block", "proxy", "direct", "direct", "direct"])
        #expect(rules[4]["ip"]?[0]?.stringValue == "geoip:private")
        #expect(c["routing"]?["domainStrategy"]?.stringValue == "IPIfNonMatch")
        #expect(c["dns"] != nil)
    }

    @Test func domainOnlyGlobalStaysAsIs() throws {
        let c = try build(.global, CustomRules(proxy: "a.com"))
        #expect(c["routing"]?["domainStrategy"]?.stringValue == "AsIs")
        #expect(c["dns"] == nil)
    }

    @Test func directModeKeepsOnlyBlock() throws {
        let rules = try #require(try build(.direct, CustomRules(proxy: "a.com", block: "c.com"))["routing"]?["rules"]?.arrayValue)
        #expect(rules.map { $0["outboundTag"]?.stringValue } == ["block", "direct"])
    }

    @Test func emptyRulesChangeNothing() throws {
        for plan in [RoutingPlan.global, .direct, .bypass([])] {
            #expect(try build(plan, CustomRules()) == ConfigBuilder.build(outbound: ["protocol": "freedom"], options: RunOptions(metricsPort: 1), routing: plan))
        }
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
