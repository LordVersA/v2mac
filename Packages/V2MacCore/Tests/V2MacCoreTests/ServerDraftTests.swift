import Foundation
import Testing
@testable import V2MacCore

@Suite struct ServerDraftTests {
    func draft(_ link: String) throws -> ServerDraft {
        let parsed = try ShareLinkParser.parse(link)
        return try #require(ServerDraft(outbound: parsed.config, name: parsed.name))
    }

    /// Opening a server in the editor and saving it untouched must not change it.
    @Test(arguments: Fixtures.valid.map(\.name))
    func untouchedDraftKeepsTheOutbound(name: String) throws {
        let link = try #require(Fixtures.valid.first { $0.name == name }?.link)
        let parsed = try ShareLinkParser.parse(link)
        let draft = try #require(ServerDraft(outbound: parsed.config, name: parsed.name))
        #expect(draft.problems() == [])
        let saved = try draft.profile()
        #expect(saved.config == parsed.config)
        #expect(saved.fingerprint == parsed.fingerprint)
        #expect(saved.name == parsed.name)
        #expect(saved.protocolName == parsed.protocolName)
        #expect(saved.address == parsed.address && saved.port == parsed.port)
        #expect(saved.transport == parsed.transport && saved.security == parsed.security)
        #expect(saved.warnings == parsed.warnings)
    }

    /// The link written for a server reads back as the same server.
    @Test(arguments: Fixtures.valid.map(\.name))
    func writtenLinkReadsBack(name: String) throws {
        let link = try #require(Fixtures.valid.first { $0.name == name }?.link)
        let parsed = try ShareLinkParser.parse(link)
        let saved = try draft(link).profile()
        let written = try #require(saved.originalLink)
        let again = try ShareLinkParser.parse(written)
        #expect(again.config == parsed.config)
        #expect(again.name == parsed.name)
    }

    @Test func readsFields() throws {
        let reality = try draft(Fixtures.vlessRealityVision)
        #expect(reality.proto == .vless && reality.address == "srv.example.com" && reality.port == "443")
        #expect(reality.id == Fixtures.uuid && reality.flow == "xtls-rprx-vision" && reality.encryption == "none")
        #expect(reality.transport == "raw" && reality.security == "reality")
        #expect(reality.sni == "www.microsoft.com" && reality.fingerprint == "chrome")
        #expect(reality.realityPublicKey == Fixtures.realityKey && reality.realityShortID == "ab12" && reality.realitySpiderX == "/")

        let ws = try draft(Fixtures.vlessWS)
        #expect(ws.transport == "ws" && ws.path == "/ws?ed=2048" && ws.host == "cdn.example.com")
        #expect(ws.security == "tls" && ws.alpn == "h2,http/1.1")

        let hop = try draft(Fixtures.hy2Hop)
        #expect(hop.proto == .hysteria && hop.password == "pw" && hop.hopPorts == "5000-6000")
        #expect(hop.obfs && hop.obfsPassword == "ob")

        let wg = try draft(Fixtures.wireguard)
        #expect(wg.address == "1.2.3.4" && wg.port == "51820")
        #expect(wg.wgAddresses == "10.0.0.2/32,fd00::2/128" && wg.wgMTU == "1280" && wg.wgReserved == "1,2,3")

        let socks = try draft(Fixtures.socksPlain)
        #expect(socks.username == "user" && socks.password == "pass")
    }

    @Test func readsTheOlderNestedLayout() throws {
        let outbound: JSONValue = [
            "protocol": "vless",
            "settings": ["vnext": [[
                "address": "old.example.com", "port": 8443,
                "users": [["id": .string(Fixtures.uuid), "encryption": "none", "flow": "xtls-rprx-vision"]],
            ]]],
            "streamSettings": ["network": "tcp", "security": "tls", "tlsSettings": ["serverName": "old.example.com"]],
        ]
        let draft = try #require(ServerDraft(outbound: outbound, name: "Old"))
        #expect(draft.address == "old.example.com" && draft.port == "8443")
        #expect(draft.id == Fixtures.uuid && draft.flow == "xtls-rprx-vision")
        #expect(draft.transport == "raw" && draft.sni == "old.example.com")

        let settings = draft.outbound()["settings"]
        #expect(settings?["vnext"] == nil)
        #expect(settings?["address"]?.stringValue == "old.example.com" && settings?["port"]?.intValue == 8443)

        let trojan: JSONValue = [
            "protocol": "trojan",
            "settings": ["servers": [["address": "t.example.com", "port": 443, "password": "secret"]]],
        ]
        let read = try #require(ServerDraft(outbound: trojan, name: "T"))
        #expect(read.address == "t.example.com" && read.password == "secret")
    }

    @Test func unknownProtocolIsNotEditable() {
        #expect(ServerDraft(outbound: ["protocol": "freedom"], name: "x") == nil)
    }

    @Test func keepsWhatTheFormDoesNotShow() throws {
        var config = try ShareLinkParser.parse(Fixtures.vlessWS).config
        let stream = try #require(config["streamSettings"])
        let ws = try #require(stream["wsSettings"])
        config = config.setting("streamSettings", to: stream
            .setting("sockopt", to: ["tcpFastOpen": true])
            .setting("wsSettings", to: ws.setting("heartbeatPeriod", to: 30)))

        var draft = try #require(ServerDraft(outbound: config, name: "WS"))
        draft.path = "/new"
        let saved = draft.outbound()["streamSettings"]
        #expect(saved?["sockopt"]?["tcpFastOpen"]?.boolValue == true)
        #expect(saved?["wsSettings"]?["heartbeatPeriod"]?.intValue == 30)
        #expect(saved?["wsSettings"]?["path"]?.stringValue == "/new")
    }

    @Test func changingTransportAndSecurityDropsTheOldOnes() throws {
        var draft = try draft(Fixtures.vlessWS)
        draft.transport = "grpc"
        draft.serviceName = "svc"
        draft.security = "reality"
        draft.realityPublicKey = Fixtures.realityKey
        let stream = try draft.profile().config["streamSettings"]
        #expect(stream?["network"]?.stringValue == "grpc")
        #expect(stream?["wsSettings"] == nil && stream?["tlsSettings"] == nil)
        #expect(stream?["grpcSettings"]?["serviceName"]?.stringValue == "svc")
        #expect(stream?["realitySettings"]?["publicKey"]?.stringValue == Fixtures.realityKey)
    }

    @Test func changingProtocolStartsClean() throws {
        var draft = try draft(Fixtures.vlessWS)
        draft.proto = .trojan
        draft.password = "pw"
        let config = try draft.profile().config
        #expect(config["protocol"]?.stringValue == "trojan")
        #expect(config["settings"]?["id"] == nil)
        #expect(config["settings"]?["password"]?.stringValue == "pw")
        #expect(config["streamSettings"]?["wsSettings"]?["path"]?.stringValue == "/ws?ed=2048")
    }

    @Test func mux() throws {
        var draft = try draft(Fixtures.trojanWS)
        #expect(!draft.muxEnabled)
        draft.muxEnabled = true
        draft.muxConcurrency = "4"
        let saved = try draft.profile()
        #expect(saved.config["mux"]?["enabled"]?.boolValue == true)
        #expect(saved.config["mux"]?["concurrency"]?.intValue == 4)
        // The link stays: no link carries Mux.
        #expect(saved.originalLink != nil)

        var again = try #require(ServerDraft(outbound: saved.config, name: saved.name))
        #expect(again.muxEnabled && again.muxConcurrency == "4")
        again.muxEnabled = false
        #expect(again.outbound()["mux"] == nil)
    }

    @Test func newServer() throws {
        var draft = ServerDraft(proto: .vless)
        #expect(draft.problems().count == 2)
        draft.address = "new.example.com"
        draft.id = Fixtures.uuid
        draft.security = "tls"
        draft.sni = "new.example.com"
        let saved = try draft.profile()
        #expect(saved.name == "new.example.com:443")
        #expect(saved.protocolName == "vless" && saved.transport == "raw" && saved.security == "tls")
        #expect(try ShareLinkParser.parse(try #require(saved.originalLink)).config == saved.config)

        var socks = ServerDraft(proto: .socks)
        #expect(socks.port == "1080")
        socks.proto = .http
        socks.protocolChanged(from: .socks)
        #expect(socks.port == "8080")
    }

    @Test func problems() {
        var draft = ServerDraft(proto: .vless)
        draft.address = "a.example.com"
        draft.id = Fixtures.uuid
        draft.port = "70000"
        #expect(draft.problems() == ["The port must be a number from 1 to 65535."])
        draft.port = "443"
        draft.security = "reality"
        #expect(draft.problems() == ["Enter the REALITY public key."])
        draft.security = "none"
        draft.transport = "xhttp"
        draft.xhttpExtra = "not json"
        #expect(draft.problems() == ["The XHTTP extra options must be a JSON object."])
        #expect(throws: DraftError.self) { try draft.profile() }

        var wg = ServerDraft(proto: .wireguard)
        wg.address = "1.2.3.4"
        wg.wgSecretKey = "k"
        wg.wgPublicKey = "p"
        wg.wgAddresses = "10.0.0.2"
        wg.wgReserved = "1,2"
        #expect(wg.problems() == ["Reserved must be three numbers from 0 to 255, separated by commas."])
    }

    @Test func warnsAboutPlainVLESSAndInsecure() throws {
        var draft = ServerDraft(proto: .vless)
        draft.address = "a.example.com"
        draft.id = Fixtures.uuid
        #expect(try draft.profile().warnings.count == 1)
        draft.security = "tls"
        draft.allowInsecure = true
        let saved = try draft.profile()
        #expect(saved.warnings == [StreamBuilder.insecureWarning])
        #expect(InsecureTLS.isRequested(by: saved.config))
        #expect(try #require(saved.originalLink).contains("allowInsecure=1"))
    }
}
