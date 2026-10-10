import Foundation
import Testing
@testable import V2MacCore

@Suite(.tags(.integration), .enabled(if: TestSupport.coreAvailable))
struct ParsingIntegrationTests {
    func xrayTest(config: JSONValue) throws -> (ok: Bool, output: String) {
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
        return (p.terminationStatus == 0 && out.contains("Configuration OK"), out)
    }

    /// Guard against upstream format drift: every produced outbound must load in the real core.
    @Test func everyFixtureOutboundPassesXrayTest() throws {
        var failures: [String] = []
        for (name, link) in Fixtures.valid {
            let profile = try ShareLinkParser.parse(link)
            let config = try ConfigBuilder.buildGlobal(
                outbound: profile.config,
                options: RunOptions(inbound: InboundSettings(port: 19999), metricsPort: 19998)
            )
            let result = try xrayTest(config: config)
            if !result.ok {
                let reason = result.output.split(separator: "\n").last(where: { $0.contains("Failed") }) ?? "?"
                failures.append("\(name): \(reason.suffix(220))")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// What the server editor writes and no link does: Mux, the keep-alive, options typed by hand.
    @Test func editedOutboundsPassXrayTest() throws {
        func draft(_ link: String) throws -> ServerDraft {
            let parsed = try ShareLinkParser.parse(link)
            return try #require(ServerDraft(outbound: parsed.config, name: parsed.name))
        }
        var mux = try draft(Fixtures.trojanWS)
        mux.muxEnabled = true
        var kcp = try draft(Fixtures.vmessWS)
        kcp.transport = "kcp"
        kcp.security = "none"
        kcp.headerType = "wechat-video"
        kcp.kcpSeed = "seed"
        var xhttp = try draft(Fixtures.vlessWS)
        xhttp.transport = "xhttp"
        xhttp.xhttpMode = "packet-up"
        xhttp.xhttpExtra = #"{"xPaddingBytes":"100-1000"}"#
        var wireguard = try draft(Fixtures.wireguard)
        wireguard.wgKeepAlive = "25"
        wireguard.wgAllowedIPs = "0.0.0.0/0"
        var hysteria = ServerDraft(proto: .hysteria)
        hysteria.address = "srv.example.com"
        hysteria.password = "pw"
        hysteria.hopPorts = "5000-6000"
        hysteria.hopInterval = "20"
        hysteria.obfs = true
        hysteria.obfsPassword = "ob"
        var shadowsocks = ServerDraft(proto: .shadowsocks)
        shadowsocks.address = "1.2.3.4"
        shadowsocks.password = "pa55word"
        shadowsocks.transport = "grpc"
        shadowsocks.serviceName = "svc"
        shadowsocks.security = "tls"
        var https = ServerDraft(proto: .http)
        https.address = "proxy.example.com"
        https.security = "tls"
        https.sni = "other.example.com"

        var failures: [String] = []
        for (name, draft) in [("mux", mux), ("kcp", kcp), ("xhttp", xhttp), ("wireguard", wireguard),
                              ("hysteria", hysteria), ("shadowsocks", shadowsocks), ("https", https)] {
            let config = try ConfigBuilder.buildGlobal(
                outbound: try draft.profile().config,
                options: RunOptions(inbound: InboundSettings(port: 19999), metricsPort: 19998)
            )
            let result = try xrayTest(config: config)
            if !result.ok {
                let reason = result.output.split(separator: "\n").last(where: { $0.contains("Failed") }) ?? "?"
                failures.append("\(name): \(reason.suffix(220))")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}
