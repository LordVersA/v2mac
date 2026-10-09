import Foundation
import Network
import Testing
@testable import V2MacCore

@Suite struct DialerTests {
    let both = DialerSettings(fragment: FragmentSettings(), noise: NoiseSettings())

    func vless() throws -> JSONValue { try ShareLinkParser.parse(Fixtures.vlessWS).config }

    func options(dialer: DialerSettings = DialerSettings(), dns: DNSSettings? = nil, api: Int? = nil, tun: TunLink? = nil) -> RunOptions {
        RunOptions(metricsPort: 20000, tun: tun, dialer: dialer, dns: dns, apiPort: api)
    }

    @Test func rangesAreValidated() {
        #expect(RangeText.normalised(" 50 - 100 ", default: "x") == "50-100")
        #expect(RangeText.normalised("40", default: "x") == "40")
        #expect(RangeText.normalised("100-50", default: "x") == "x")
        #expect(RangeText.normalised("abc", default: "x") == "x")
        #expect(RangeText.normalised("1-2-3", default: "x") == "x")
        #expect(RangeText.normalised("", default: "x") == "x")
        #expect(FragmentSettings(length: "junk", interval: "5").length == FragmentSettings.defaultLength)
        #expect(FragmentSettings(length: "junk", interval: "5").interval == "5")
        #expect(NoiseSettings(packet: "-", delay: "1-2").packet == NoiseSettings.defaultPacket)
    }

    @Test func offByDefault() throws {
        let c = try ConfigBuilder.buildGlobal(outbound: vless(), options: options())
        #expect(c["outbounds"]?.arrayValue?.count == 3)
        #expect(c["outbounds"]?[0]?["streamSettings"]?["sockopt"]?["dialerProxy"] == nil)
        #expect(c["api"] == nil)
        #expect(c["dns"] == nil)
        #expect(c["outbounds"]?[1]?["settings"] == nil)
    }

    @Test func fragmentAndNoiseDialThroughHelper() throws {
        let c = try ConfigBuilder.buildGlobal(outbound: vless(), options: options(dialer: both))
        #expect(c["outbounds"]?[0]?["tag"]?.stringValue == "proxy")
        #expect(c["outbounds"]?[0]?["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue == "v2mac-dialer")
        #expect(c["outbounds"]?[0]?["streamSettings"]?["network"]?.stringValue == "ws")
        let helper = c["outbounds"]?[3]
        #expect(helper?["tag"]?.stringValue == "v2mac-dialer")
        #expect(helper?["protocol"]?.stringValue == "freedom")
        #expect(helper?["settings"]?["fragment"]?["packets"]?.stringValue == "tlshello")
        #expect(helper?["settings"]?["fragment"]?["length"]?.stringValue == "100-200")
        #expect(helper?["settings"]?["noises"]?[0]?["type"]?.stringValue == "rand")
        // Direct traffic is not fragmented.
        #expect(c["outbounds"]?[1]?["streamSettings"] == nil)
    }

    @Test func fragmentAloneCarriesNoNoise() throws {
        let settings = DialerSettings(fragment: FragmentSettings(packets: .firstPackets, length: "10-20", interval: "1"))
        let helper = try ConfigBuilder.buildGlobal(outbound: vless(), options: options(dialer: settings))["outbounds"]?[3]
        #expect(helper?["settings"]?["fragment"]?["packets"]?.stringValue == "1-3")
        #expect(helper?["settings"]?["noises"] == nil)
    }

    @Test func outboundsThatMustNotBeDialledAreLeftAlone() throws {
        let chained = try vless().setting("streamSettings", to: ["sockopt": ["dialerProxy": "other"]])
        #expect(ConfigBuilder.dialing(chained, through: both) == chained)
        let viaProxySettings = try vless().setting("proxySettings", to: ["tag": "other"])
        #expect(ConfigBuilder.dialing(viaProxySettings, through: both) == viaProxySettings)
        let local: JSONValue = ["protocol": "socks", "settings": ["address": "127.0.0.1", "port": 1080]]
        #expect(ConfigBuilder.dialing(local, through: both) == local)
        for proto in ["freedom", "blackhole", "dns", "wireguard"] {
            let outbound: JSONValue = ["protocol": .string(proto)]
            #expect(ConfigBuilder.dialing(outbound, through: both) == outbound)
        }
        #expect(try ConfigBuilder.dialing(vless(), through: DialerSettings()) == vless())
    }

    @Test func tunBindsTheHelperNotJustTheProxy() throws {
        let tun = TunLink(port: 30000, outboundInterface: "en0")
        let c = try ConfigBuilder.buildGlobal(outbound: vless(), options: options(dialer: both, tun: tun))
        #expect(c["outbounds"]?[3]?["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en0")
        #expect(c["outbounds"]?[0]?["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue == "v2mac-dialer")
    }

    @Test func customConfigGetsTheHelperOnlyWhereItHasNoDialer() throws {
        let own = try vless().setting("tag", to: "a").setting("streamSettings", to: ["sockopt": ["dialerProxy": "frag"]])
        let plain = try vless().setting("tag", to: "b")
        let config: JSONValue = ["outbounds": [own, plain, ["tag": "frag", "protocol": "freedom"], ["tag": "direct", "protocol": "freedom"]]]
        let c = try ConfigBuilder.buildCustom(config: config, options: options(dialer: both))
        #expect(c["outbounds"]?[0]?["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue == "frag")
        #expect(c["outbounds"]?[1]?["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue == "v2mac-dialer")
        #expect(c["outbounds"]?[3]?["streamSettings"] == nil)
        #expect(c["outbounds"]?[4]?["tag"]?.stringValue == "v2mac-dialer")

        let untouched: JSONValue = ["outbounds": [own, ["tag": "frag", "protocol": "freedom"]]]
        #expect(try ConfigBuilder.buildCustom(config: untouched, options: options(dialer: both))["outbounds"]?.arrayValue?.count == 2)
        #expect(try ConfigBuilder.buildCustom(config: config, options: options())["outbounds"] == config["outbounds"])
    }

    @Test func dnsSettings() throws {
        let dns = DNSSettings(servers: DNSSettings.servers(from: " https://9.9.9.9/dns-query ,\n1.1.1.1, bad server ,"), queryStrategy: .useIPv4)
        #expect(dns.servers == ["https://9.9.9.9/dns-query", "1.1.1.1"])
        #expect(DNSSettings(servers: ["  "]).servers == DNSSettings.defaultServers)

        let c = try ConfigBuilder.buildGlobal(outbound: vless(), options: options(dns: dns))
        #expect(c["dns"]?["servers"]?[1]?.stringValue == "1.1.1.1")
        #expect(c["dns"]?["queryStrategy"]?.stringValue == "UseIPv4")
        #expect(c["outbounds"]?[1]?["settings"]?["domainStrategy"]?.stringValue == "UseIPv4")

        // The chosen servers replace the built-in pair of the bypass mode.
        let route = RegionRoute(geositeFile: "geosite.dat", geositeTags: ["ir"], geoipFile: "geoip.dat", geoipTags: ["ir"])
        let bypass = try ConfigBuilder.build(outbound: vless(), options: options(dns: dns), routing: .bypass([route]))
        #expect(bypass["dns"]?["servers"]?[0]?.stringValue == "https://9.9.9.9/dns-query")
        #expect(try ConfigBuilder.build(outbound: vless(), options: options(), routing: .bypass([route]))["dns"]?["servers"]?[0]?.stringValue == "https://1.1.1.1/dns-query")
    }

    @Test func customConfigKeepsItsOwnDNS() throws {
        let dns = DNSSettings(servers: ["1.1.1.1"])
        let with: JSONValue = ["outbounds": [["protocol": "freedom"]], "dns": ["servers": ["8.8.4.4"]]]
        #expect(try ConfigBuilder.buildCustom(config: with, options: options(dns: dns))["dns"]?["servers"]?[0]?.stringValue == "8.8.4.4")
        let without: JSONValue = ["outbounds": [["protocol": "freedom"]]]
        #expect(try ConfigBuilder.buildCustom(config: without, options: options(dns: dns))["dns"]?["servers"]?[0]?.stringValue == "1.1.1.1")
    }

    @Test func apiSectionOnlyWhenAsked() throws {
        let c = try ConfigBuilder.buildGlobal(outbound: vless(), options: options(api: 20001))
        #expect(c["api"]?["listen"]?.stringValue == "127.0.0.1:20001")
        #expect(c["api"]?["services"]?[0]?.stringValue == "HandlerService")
        #expect(try ConfigBuilder.buildCustom(config: ["outbounds": [["protocol": "freedom"]]], options: options(api: 20001))["api"] == nil)
    }

    @Test func latencyBatchUsesTheDialer() throws {
        let c = LatencyConfig.batch(outbounds: [try vless(), ["protocol": "freedom"]], ports: [1, 2], interface: "en0", dialer: both)
        #expect(c["outbounds"]?[0]?["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue == "v2mac-dialer")
        #expect(c["outbounds"]?[1]?["streamSettings"]?["sockopt"]?["dialerProxy"] == nil)
        #expect(c["outbounds"]?[2]?["tag"]?.stringValue == "v2mac-dialer")
        #expect(c["outbounds"]?[2]?["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en0")
        #expect(LatencyConfig.batch(outbounds: [try vless()], ports: [1])["outbounds"]?.arrayValue?.count == 1)
    }
}

@Suite(.tags(.integration), .serialized, .enabled(if: TestSupport.coreAvailable))
struct LiveSwitchIntegrationTests {
    func status(port: Int) async -> Int {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!))]
        cfg.timeoutIntervalForRequest = 10
        let response = try? await URLSession(configuration: cfg).data(from: URL(string: "https://www.gstatic.com/generate_204")!).1
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    @Test func everySettingPassesXrayTest() throws {
        let options = RunOptions(
            metricsPort: try PortUtil.freePort(),
            tun: TunLink(port: try PortUtil.freePort(), outboundInterface: "lo0"),
            dialer: DialerSettings(fragment: FragmentSettings(), noise: NoiseSettings()),
            dns: DNSSettings(queryStrategy: .useIPv4),
            apiPort: try PortUtil.freePort()
        )
        let config = try ConfigBuilder.buildGlobal(outbound: ShareLinkParser.parse(Fixtures.vlessWS).config, options: options)
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
    }

    @Test func outboundIsReplacedWhileTheCoreKeepsRunning() async throws {
        let options = RunOptions(inbound: InboundSettings(port: try PortUtil.freePort()), metricsPort: try PortUtil.freePort(), apiPort: try PortUtil.freePort())
        let port = options.inbound.port
        let api = try #require(options.apiPort)
        // A SOCKS server nobody runs: every request fails until the outbound is replaced.
        let dead: JSONValue = ["protocol": "socks", "settings": ["address": "127.0.0.1", "port": .number(Double(try PortUtil.freePort()))]]
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await runner.start(config: ConfigBuilder.buildGlobal(outbound: dead, options: options), readyPort: port)
        let pid = try String(contentsOf: dir.appendingPathComponent("xray.pid"), encoding: .utf8)
        #expect(await status(port: port) == -1)

        try await runner.replaceOutbound(tag: ConfigBuilder.proxyTag, with: ConfigBuilder.proxyOutbound(["protocol": "freedom"], options: options), apiPort: api)
        #expect(await status(port: port) == 204)
        #expect(await runner.state == .running)
        #expect(try String(contentsOf: dir.appendingPathComponent("xray.pid"), encoding: .utf8) == pid)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("outbound-") }.isEmpty)

        // A port nothing listens on: the failure is reported, not swallowed.
        await #expect(throws: CoreError.self) {
            try await runner.replaceOutbound(tag: ConfigBuilder.proxyTag, with: ["protocol": "freedom"], apiPort: try PortUtil.freePort())
        }
        await runner.stop()
        await #expect(throws: CoreError.self) {
            try await runner.replaceOutbound(tag: ConfigBuilder.proxyTag, with: ["protocol": "freedom"], apiPort: api)
        }
    }
}
