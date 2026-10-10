import Foundation
import Testing
@testable import V2MacCore

/// A local Xray with a self-signed certificate, served over TLS (Trojan) and QUIC (Hysteria 2).
@Suite(.tags(.integration), .serialized, .enabled(if: TestSupport.coreAvailable))
struct InsecureTLSTests {
    func xray(_ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = TestSupport.xray
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out
    }

    func outbound(_ link: String) throws -> JSONValue { try ShareLinkParser.parse(link).config }

    @Test func pinsTheCertificateTheServerPresents() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try xray(["tls", "cert", "-domain=selfsigned.test", "-file=\(dir.path)/c"])
        let expected = try xray(["tls", "hash", "--cert", "\(dir.path)/c.crt"])
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init) ?? ""
        #expect(expected.count == 64)

        let ports = try PortUtil.freePorts(2)
        let certificates: JSONValue = [["certificateFile": .string("\(dir.path)/c.crt"), "keyFile": .string("\(dir.path)/c.key")]]
        let server: JSONValue = [
            "log": ["loglevel": "none"],
            "inbounds": [
                [
                    "listen": "127.0.0.1", "port": .number(Double(ports[0])), "protocol": "trojan",
                    "settings": ["clients": [["password": "pw"]]],
                    "streamSettings": ["network": "tcp", "security": "tls", "tlsSettings": ["certificates": certificates]],
                ],
                [
                    "listen": "127.0.0.1", "port": .number(Double(ports[1])), "protocol": "hysteria",
                    "settings": ["version": 2, "clients": [["auth": "pw"]]],
                    "streamSettings": [
                        "network": "hysteria", "security": "tls",
                        "tlsSettings": ["alpn": ["h3"], "certificates": certificates],
                        "hysteriaSettings": ["version": 2, "auth": "pw"],
                    ],
                ],
            ],
            "outbounds": [["protocol": "blackhole"]],
        ]
        let runner = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await runner.start(config: server, readyPort: ports[0])

        let trojan = try outbound("trojan://pw@127.0.0.1:\(ports[0])?sni=selfsigned.test&allowInsecure=1#t")
        let pinnedTrojan = await InsecureTLS.pinning(trojan)
        #expect(pinnedTrojan["streamSettings"]?["tlsSettings"]?["pinnedPeerCertSha256"]?.stringValue == expected)
        #expect(!InsecureTLS.isRequested(by: pinnedTrojan))

        let hysteria = try outbound("hysteria2://pw@127.0.0.1:\(ports[1])/?sni=selfsigned.test&insecure=1#h")
        let pinnedHysteria = await InsecureTLS.pinning(hysteria)
        #expect(pinnedHysteria["streamSettings"]?["tlsSettings"]?["pinnedPeerCertSha256"]?.stringValue == expected)

        await runner.stop()

        // Nobody answers now: the flag is dropped and the outbound is left unpinned.
        let unreachable = await InsecureTLS.pinning(trojan, timeout: 1)
        #expect(unreachable == InsecureTLS.stripping(trojan))
    }

    @Test func leavesOtherOutboundsAlone() async throws {
        let plain = try outbound(Fixtures.vlessWS)
        #expect(await InsecureTLS.pinning(plain) == plain)
        #expect(await InsecureTLS.pinning([plain, plain]) == [plain, plain])
    }
}
