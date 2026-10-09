import Foundation
import Testing
@testable import V2MacCore

@Suite struct SubscriptionParserTests {
    func links(_ items: [String]) -> String { items.joined(separator: "\n") }

    var sample: [String] { [Fixtures.vlessWS, Fixtures.trojanPlain, Fixtures.hy2] }

    @Test func plainLinkList() throws {
        let body = "# comment\n// another\n\n" + links(sample) + "\n"
        let r = try SubscriptionParser.parse(text: body)
        #expect(r.profiles.map(\.protocolName) == ["vless", "trojan", "hysteria"])
        #expect(r.skipped.isEmpty)
    }

    @Test func base64Variants() throws {
        let raw = links(sample)
        let std = Data(raw.utf8).base64EncodedString()
        let url = std.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let noPad = std.replacingOccurrences(of: "=", with: "")
        let wrapped = stride(from: 0, to: std.count, by: 20).map { i -> String in
            let s = std.index(std.startIndex, offsetBy: i)
            return String(std[s..<std.index(s, offsetBy: min(20, std.count - i))])
        }.joined(separator: "\r\n")
        for variant in [std, url, noPad, wrapped] {
            let r = try SubscriptionParser.parse(text: variant)
            #expect(r.profiles.count == 3)
        }
    }

    @Test func bomAndCRLF() throws {
        let body = "\u{FEFF}" + links(sample).replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try SubscriptionParser.parse(text: body).profiles.count == 3)
    }

    @Test func skippedEntriesAreCountedNotFatal() throws {
        let body = links([Fixtures.vlessWS, "vless://\(Fixtures.uuid)@a.com:443?type=h2&security=tls#x", "tuic://x@y.com:1#z", Fixtures.trojanPlain])
        let r = try SubscriptionParser.parse(text: body)
        #expect(r.profiles.count == 2)
        #expect(r.skipped.count == 2)
        #expect(r.skipped[0].index == 2)
        #expect(r.skipped[0].reason.contains("removed from Xray"))
    }

    @Test func allSkippedIsFailure() {
        let body = "tuic://x@y.com:1#z\nvless://\(Fixtures.uuid)@a.com:443?type=h2&security=tls#x"
        #expect(throws: SubscriptionError.noServers(skipped: 2)) { try SubscriptionParser.parse(text: body) }
    }

    @Test func garbageIsUnrecognised() {
        #expect(throws: SubscriptionError.unrecognisedFormat) { try SubscriptionParser.parse(text: "<html>nope</html>") }
        #expect(throws: SubscriptionError.unrecognisedFormat) { try SubscriptionParser.parse(text: "") }
    }

    @Test func clashAndSingBoxHaveSpecificErrors() {
        let clash = "port: 7890\nproxies:\n  - name: a\n    type: vless\n"
        #expect(throws: SubscriptionError.unsupportedFormat("Clash")) { try SubscriptionParser.parse(text: clash) }
        let singbox = #"{"outbounds":[{"type":"vless","tag":"a","server":"x","server_port":443}]}"#
        let r = try? SubscriptionParser.parse(text: singbox)
        #expect(r == nil)
    }

    // MARK: JSON

    let customConfig = #"""
    {"remarks":"Custom A","outbounds":[{"tag":"p","protocol":"vless","settings":{"vnext":[{"address":"srv.example.com","port":443,"users":[{"id":"x"}]}]}},{"tag":"direct","protocol":"freedom"}]}
    """#

    @Test func jsonArrayOfCustomConfigs() throws {
        let body = "[\(customConfig), {\"outbounds\":[{\"protocol\":\"trojan\",\"settings\":{\"address\":\"b.com\",\"port\":8443}}]}]"
        let r = try SubscriptionParser.parse(text: body)
        #expect(r.profiles.count == 2)
        #expect(r.profiles[0].kind == .custom)
        #expect(r.profiles[0].name == "Custom A")
        #expect(r.profiles[0].address == "srv.example.com" && r.profiles[0].port == 443)
        #expect(r.profiles[1].name == "Config 2")
        #expect(r.profiles[1].address == "b.com")
    }

    @Test func customConfigIsDescribedByItsProxyOutbound() throws {
        let body = #"""
        [{"remarks":"A","outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"srv.example.com","port":443,"users":[{"id":"x"}]}]},"streamSettings":{"network":"splithttp","security":"reality"}},{"tag":"block","protocol":"blackhole"}]},
         {"remarks":"B","outbounds":[{"protocol":"trojan","settings":{"address":"b.com","port":8443},"streamSettings":{"network":"tcp","security":"tls"}}]},
         {"remarks":"C","outbounds":[{"protocol":"vmess","settings":{"address":"c.com","port":80}}]}]
        """#
        let p = try SubscriptionParser.parse(text: body).profiles
        #expect(p.map(\.kind) == [.custom, .custom, .custom])
        #expect(p.map(\.protocolName) == ["vless", "trojan", "vmess"])
        #expect(p.map(\.transport) == ["xhttp", "raw", "raw"])
        #expect(p.map(\.security) == ["reality", "tls", "none"])
        #expect(p[0].address == "srv.example.com" && p[0].port == 443)
    }

    @Test func customConfigWithoutAProxyOutbound() throws {
        let direct = try #require(try SubscriptionParser.parse(text: #"{"outbounds":[{"tag":"direct","protocol":"freedom"}]}"#).profiles.first)
        #expect(direct.kind == .custom && direct.protocolName == "freedom")
        let empty = try #require(try SubscriptionParser.parse(text: #"{"outbounds":[]}"#).profiles.first)
        #expect(empty.protocolName == "custom" && empty.transport.isEmpty && empty.security.isEmpty)
    }

    @Test func singleCustomConfigAndSingleOutbound() throws {
        #expect(try SubscriptionParser.parse(text: customConfig).profiles.first?.kind == .custom)
        let ob = #"{"tag":"my","protocol":"vless","settings":{"address":"a.com","port":443,"id":"x","encryption":"none"},"streamSettings":{"network":"tcp","security":"tls"}}"#
        let p = try #require(try SubscriptionParser.parse(text: ob).profiles.first)
        #expect(p.kind == .outbound)
        #expect(p.name == "my")
        #expect(p.transport == "raw" && p.security == "tls")
        #expect(p.config["tag"] == nil)
    }

    @Test func configsPastedOneAfterAnother() throws {
        let second = #"{"remarks":"Has } and \" inside","outbounds":[{"protocol":"trojan","settings":{"address":"b.com","port":8443}}]}"#
        let r = try SubscriptionParser.parse(text: "\(customConfig)\n\n\(second)\n{\"broken\": }")
        #expect(r.profiles.map(\.name) == ["Custom A", "Has } and \" inside"])
        #expect(r.skipped.map(\.index) == [3])
    }

    @Test func singBoxJSONIsRejectedPerEntry() {
        let body = #"[{"outbounds":[{"type":"vless","tag":"a"}]}]"#
        #expect(throws: SubscriptionError.noServers(skipped: 1)) { try SubscriptionParser.parse(text: body) }
    }

    @Test func base64WrappedJSON() throws {
        let b64 = Data(customConfig.utf8).base64EncodedString()
        #expect(try SubscriptionParser.parse(text: b64).profiles.count == 1)
    }

    // MARK: Metadata

    @Test func headerMetadata() throws {
        let headers = [
            "Profile-Title": "base64:" + Data("My Provider".utf8).base64EncodedString(),
            "Profile-Update-Interval": "6",
            "Subscription-Userinfo": "upload=100; download=900; total=5000; expire=1793000000",
        ]
        let m = try SubscriptionParser.parse(text: Fixtures.trojanPlain, headers: headers).metadata
        #expect(m.title == "My Provider")
        #expect(m.updateIntervalHours == 6)
        #expect(m.usedBytes == 1000)
        #expect(m.totalBytes == 5000)
        #expect(m.expiresAt == Date(timeIntervalSince1970: 1793000000))
    }

    @Test func titleFallbacks() throws {
        let cd = ["content-disposition": #"attachment; filename="Provider X.txt""#]
        #expect(try SubscriptionParser.parse(text: Fixtures.trojanPlain, headers: cd).metadata.title == "Provider X.txt")
        let star = ["Content-Disposition": "attachment; filename*=UTF-8''Caf%C3%A9"]
        #expect(try SubscriptionParser.parse(text: Fixtures.trojanPlain, headers: star).metadata.title == "Café")
        let plain = ["profile-title": "Plain Title"]
        #expect(try SubscriptionParser.parse(text: Fixtures.trojanPlain, headers: plain).metadata.title == "Plain Title")
    }

    @Test func bodyDirectivesWhenNoHeaders() throws {
        let body = "#profile-title: From Body\n#profile-update-interval: 3\n" + Fixtures.trojanPlain
        let m = try SubscriptionParser.parse(text: body).metadata
        #expect(m.title == "From Body")
        #expect(m.updateIntervalHours == 3)
        let override = try SubscriptionParser.parse(text: body, headers: ["profile-title": "Header"]).metadata
        #expect(override.title == "Header")
    }

    @Test func zeroExpireAndTotalMeanUnlimited() throws {
        let m = try SubscriptionParser.parse(
            text: Fixtures.trojanPlain,
            headers: ["subscription-userinfo": "upload=1; download=2; total=0; expire=0"]
        ).metadata
        #expect(m.totalBytes == nil && m.expiresAt == nil && m.usedBytes == 3)
    }

    @Test func readsUsageSplitAndLinksFromProviderHeaders() throws {
        let m = try SubscriptionParser.parse(
            text: Fixtures.trojanPlain,
            headers: [
                "Subscription-Userinfo": "upload=37300980403; total=536870912000; download=455983178372; expire=1854001441",
                "Profile-Title": "base64:Rm94eW5ldA==",
                "Profile-Update-Interval": "12",
                "Support-Url": "https://t.me/foxynet_fa",
                "Profile-Web-Page-Url": "javascript:alert(1)",
            ]
        ).metadata
        #expect(m.title == "Foxynet")
        #expect(m.uploadBytes == 37_300_980_403 && m.downloadBytes == 455_983_178_372)
        #expect(m.usedBytes == Int64(493_284_158_775))
        #expect(m.totalBytes == 536_870_912_000)
        #expect(m.expiresAt == Date(timeIntervalSince1970: 1_854_001_441))
        #expect(m.updateIntervalHours == 12)
        #expect(m.supportURL?.absoluteString == "https://t.me/foxynet_fa")
        #expect(m.webPageURL == nil) // non-http(s) links are dropped
    }
}

@Suite(.serialized) struct SubscriptionFetcherTests {
    let body = Fixtures.trojanPlain + "\n" + Fixtures.hy2

    @Test func directFetchSendsUserAgentAndReadsHeaders() async throws {
        let payload = Data(body.utf8)
        let server = try await TestHTTPServer.start { _ in
            .init(headers: ["profile-title": "Local", "profile-update-interval": "4"], body: payload)
        }
        defer { server.stop() }
        let fetcher = SubscriptionFetcher(userAgent: "v2mac/0.1.0-test")
        let r = try await fetcher.fetch(url: URL(string: "http://127.0.0.1:\(server.port)/sub")!, route: .direct)
        #expect(r.profiles.count == 2)
        #expect(r.metadata.title == "Local")
        #expect(r.metadata.updateIntervalHours == 4)
        #expect(server.userAgent == "v2mac/0.1.0-test")
    }

    @Test func httpErrorIsReported() async throws {
        let server = try await TestHTTPServer.start { _ in .init(status: 404) }
        defer { server.stop() }
        await #expect(throws: SubscriptionError.http(404)) {
            try await SubscriptionFetcher(userAgent: "t").fetch(url: URL(string: "http://127.0.0.1:\(server.port)/")!, route: .direct)
        }
    }

    @Test func oversizeBodyIsRejected() async throws {
        let server = try await TestHTTPServer.start { _ in .init(body: Data(repeating: 0x41, count: 5000)) }
        defer { server.stop() }
        await #expect(throws: SubscriptionError.tooLarge) {
            try await SubscriptionFetcher(userAgent: "t", maxBytes: 1000)
                .fetch(url: URL(string: "http://127.0.0.1:\(server.port)/")!, route: .direct)
        }
    }

    @Test func invalidURLIsRejected() async {
        await #expect(throws: SubscriptionError.invalidURL) {
            try await SubscriptionFetcher(userAgent: "t").fetch(url: URL(string: "ftp://x.com/a")!, route: .direct)
        }
    }

    @Test func parseFailureSurfacesAsError() async throws {
        let server = try await TestHTTPServer.start { _ in .init(body: Data("<html>hi</html>".utf8)) }
        defer { server.stop() }
        await #expect(throws: SubscriptionError.unrecognisedFormat) {
            try await SubscriptionFetcher(userAgent: "t").fetch(url: URL(string: "http://127.0.0.1:\(server.port)/")!, route: .direct)
        }
    }
}

@Suite(.tags(.integration), .serialized, .enabled(if: TestSupport.coreAvailable))
struct SubscriptionProxyRouteTests {
    /// URLSession never proxies loopback/private destinations, so this uses a public URL
    /// (needs internet, like the M1 engine test) and checks the core's inbound counters.
    @Test func downloadViaLocalProxyGoesThroughTheCore() async throws {
        let options = RunOptions(inbound: InboundSettings(port: try PortUtil.freePort()), metricsPort: try PortUtil.freePort())
        let config = try ConfigBuilder.buildGlobal(outbound: ["protocol": "freedom"], options: options)
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await runner.start(config: config, readyPort: options.inbound.port)

        let fetcher = SubscriptionFetcher(userAgent: "v2mac/test")
        let (body, _) = try await fetcher.download(
            url: URL(string: "https://www.gstatic.com/generate_204")!,
            route: .localProxy(port: options.inbound.port)
        )
        #expect(body.isEmpty)

        let stats = try await StatsClient(port: options.metricsPort).snapshot()
        #expect(stats.uplink > 0, "request did not pass through the core")
        #expect(stats.downlink > 0)
        await runner.stop()
    }
}
