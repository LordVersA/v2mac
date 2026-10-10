import Foundation
import Testing
@testable import V2MacCore

@Suite struct ShareLinkTests {
    func parse(_ link: String) throws -> ParsedProfile { try ShareLinkParser.parse(link) }

    @Test func vlessReality() throws {
        let p = try parse(Fixtures.vlessRealityVision)
        #expect(p.name == "Reality Vision")
        #expect(p.protocolName == "vless")
        #expect(p.address == "srv.example.com" && p.port == 443)
        #expect(p.transport == "raw" && p.security == "reality")
        let s = p.config["settings"]
        #expect(s?["id"]?.stringValue == Fixtures.uuid)
        #expect(s?["encryption"]?.stringValue == "none")
        #expect(s?["flow"]?.stringValue == "xtls-rprx-vision")
        let r = p.config["streamSettings"]?["realitySettings"]
        #expect(r?["publicKey"]?.stringValue == Fixtures.realityKey)
        #expect(r?["shortId"]?.stringValue == "ab12")
        #expect(r?["spiderX"]?.stringValue == "/")
        #expect(r?["serverName"]?.stringValue == "www.microsoft.com")
        #expect(p.config["tag"] == nil)
        #expect(p.originalLink == Fixtures.vlessRealityVision)
    }

    @Test func vlessWebSocketTLS() throws {
        let p = try parse(Fixtures.vlessWS)
        #expect(p.transport == "ws" && p.security == "tls")
        let st = p.config["streamSettings"]
        #expect(st?["network"]?.stringValue == "ws")
        #expect(st?["wsSettings"]?["path"]?.stringValue == "/ws?ed=2048")
        #expect(st?["wsSettings"]?["host"]?.stringValue == "cdn.example.com")
        #expect(st?["tlsSettings"]?["alpn"]?.arrayValue == ["h2", "http/1.1"])
        #expect(st?["tlsSettings"]?["fingerprint"]?.stringValue == "chrome")
    }

    @Test func vlessGRPCMulti() throws {
        let g = try parse(Fixtures.vlessGRPC).config["streamSettings"]?["grpcSettings"]
        #expect(g?["serviceName"]?.stringValue == "svc")
        #expect(g?["multiMode"]?.boolValue == true)
    }

    @Test func xhttpExtraAndSplitHTTPAlias() throws {
        let x = try parse(Fixtures.vlessXHTTP)
        #expect(x.transport == "xhttp")
        let xs = x.config["streamSettings"]?["xhttpSettings"]
        #expect(xs?["mode"]?.stringValue == "auto")
        #expect(xs?["extra"]?["xPaddingBytes"]?.stringValue == "100-1000")
        #expect(x.config["streamSettings"]?["realitySettings"]?["fingerprint"]?.stringValue == "firefox")
        #expect(try parse(Fixtures.vlessSplitHTTP).transport == "xhttp")
    }

    @Test func rawHTTPHeader() throws {
        let h = try parse(Fixtures.vlessRawHTTP).config["streamSettings"]?["rawSettings"]?["header"]
        #expect(h?["type"]?.stringValue == "http")
        #expect(h?["request"]?["path"]?[0]?.stringValue == "/")
        #expect(h?["request"]?["headers"]?["Host"]?[0]?.stringValue == "a.example.com")
    }

    @Test func tcpIsWrittenAsRaw() throws {
        let p = try parse(Fixtures.vlessRealityVision)
        #expect(p.config["streamSettings"]?["network"]?.stringValue == "raw")
    }

    @Test func ipv6AddressIsUnbracketed() throws {
        let p = try parse(Fixtures.vlessIPv6)
        #expect(p.address == "2001:db8::1")
        #expect(p.config["settings"]?["address"]?.stringValue == "2001:db8::1")
    }

    @Test func names() throws {
        #expect(try parse(Fixtures.vlessEmojiName).name == "🇩🇪 Frankfurt | 01")
        #expect(try parse(Fixtures.vlessNoName).name == "srv.example.com:443")
        #expect(try parse(Fixtures.vlessIPv6).name == "IPv6")
    }

    @Test func pinnedCertAndECH() throws {
        let t = try parse(Fixtures.vlessPinned).config["streamSettings"]?["tlsSettings"]
        #expect(t?["pinnedPeerCertSha256"]?.stringValue == Fixtures.sha)
        #expect(t?["verifyPeerCertByName"]?.stringValue == "a.example.com")
        let e = try parse(Fixtures.vlessECH).config["streamSettings"]?["tlsSettings"]
        #expect(e?["echConfigList"]?.stringValue == "AEX+DQBB")
    }

    @Test func allowInsecureIsDroppedWithWarning() throws {
        let p = try parse(Fixtures.vlessInsecure)
        #expect(p.warnings == [StreamBuilder.insecureWarning])
        #expect(p.config["streamSettings"]?["tlsSettings"]?["allowInsecure"] == nil)
        #expect(try parse(Fixtures.hy2Insecure).warnings == [StreamBuilder.insecureWarning])
    }

    @Test func hysteriaPinBecomesXrayPin() throws {
        let p = try parse(Fixtures.hy2Pinned)
        #expect(p.config["streamSettings"]?["tlsSettings"]?["pinnedPeerCertSha256"]?.stringValue == Fixtures.sha)
        #expect(p.warnings.isEmpty)
    }

    @Test func shadowsocksPluginsBecomeTransports() throws {
        let ws = try parse(Fixtures.ssV2rayPlugin)
        #expect(ws.transport == "ws" && ws.security == "tls")
        let stream = ws.config["streamSettings"]
        #expect(stream?["wsSettings"]?["path"]?.stringValue == "/ss")
        #expect(stream?["wsSettings"]?["host"]?.stringValue == "cdn.example.com")
        #expect(stream?["tlsSettings"]?["serverName"]?.stringValue == "cdn.example.com")
        #expect(ws.config["settings"]?["method"]?.stringValue == "aes-256-gcm")

        let obfs = try parse(Fixtures.ssObfsHTTP)
        #expect(obfs.transport == "raw" && obfs.security == "none")
        let header = obfs.config["streamSettings"]?["rawSettings"]?["header"]
        #expect(header?["type"]?.stringValue == "http")
        #expect(header?["request"]?["headers"]?["Host"]?[0]?.stringValue == "a.example.com")
    }

    // MARK: VMess

    @Test func vmessBase64WebSocket() throws {
        let p = try parse(Fixtures.vmessWS)
        #expect(p.name == "VMess WS")
        #expect(p.protocolName == "vmess")
        #expect(p.port == 443)
        #expect(p.config["settings"]?["id"]?.stringValue == Fixtures.uuid)
        #expect(p.config["settings"]?["security"]?.stringValue == "auto")
        #expect(p.config["settings"]?["alterId"] == nil)
        #expect(p.transport == "ws" && p.security == "tls")
        #expect(p.config["streamSettings"]?["wsSettings"]?["path"]?.stringValue == "/vm")
        #expect(p.config["streamSettings"]?["tlsSettings"]?["serverName"]?.stringValue == "cdn.example.com")
    }

    @Test func vmessNumericFieldsAndGRPC() throws {
        let p = try parse(Fixtures.vmessGRPC)
        #expect(p.port == 443)
        let g = p.config["streamSettings"]?["grpcSettings"]
        #expect(g?["serviceName"]?.stringValue == "svc")
        #expect(g?["multiMode"]?.boolValue == true)
    }

    @Test func vmessTCPHTTPHeaderAndKCPSeed() throws {
        let h = try parse(Fixtures.vmessTCPHTTP)
        #expect(h.security == "none")
        #expect(h.config["streamSettings"]?["rawSettings"]?["header"]?["type"]?.stringValue == "http")
        let k = try parse(Fixtures.vmessKCP).config["streamSettings"]?["kcpSettings"]
        #expect(k?["seed"]?.stringValue == "seedval")
        #expect(k?["header"]?["type"]?.stringValue == "srtp")
    }

    @Test func vmessURLForm() throws {
        let p = try parse(Fixtures.vmessURL)
        #expect(p.name == "VMess URL")
        #expect(p.config["settings"]?["security"]?.stringValue == "zero")
        #expect(p.transport == "ws")
    }

    // MARK: Trojan / SS / Hysteria2 / SOCKS / HTTP / WireGuard

    @Test func trojanDefaultsToTLSAndDecodesPassword() throws {
        let p = try parse(Fixtures.trojanWS)
        #expect(p.config["settings"]?["password"]?.stringValue == "p@ss")
        #expect(p.security == "tls")
        #expect(try parse(Fixtures.trojanPlain).security == "tls")
    }

    @Test func shadowsocksForms() throws {
        for link in [Fixtures.ssSIP002, Fixtures.ssLegacy] {
            let p = try parse(link)
            let s = p.config["settings"]
            #expect(s?["method"]?.stringValue == "aes-256-gcm")
            #expect(s?["password"]?.stringValue == "pa55word")
            #expect(s?["address"]?.stringValue == "1.2.3.4")
            #expect(s?["port"]?.intValue == 8388)
            #expect(p.protocolName == "shadowsocks")
        }
        #expect(try parse(Fixtures.ssSIP002).name == "SS SIP002")
        #expect(try parse(Fixtures.ssLegacy).name == "SS Legacy")
        let p22 = try parse(Fixtures.ss2022)
        #expect(p22.config["settings"]?["method"]?.stringValue == "2022-blake3-aes-128-gcm")
        #expect(p22.config["settings"]?["password"]?.stringValue == "MTIzNDU2Nzg5MDEyMzQ1Ng==")
    }

    @Test func hysteria2() throws {
        let p = try parse(Fixtures.hy2)
        #expect(p.protocolName == "hysteria" && p.transport == "hysteria" && p.security == "tls")
        #expect(p.config["settings"]?["version"]?.intValue == 2)
        #expect(p.config["streamSettings"]?["hysteriaSettings"]?["auth"]?.stringValue == "pw")
        #expect(p.config["streamSettings"]?["tlsSettings"]?["alpn"]?[0]?.stringValue == "h3")
        #expect(p.config["streamSettings"]?["finalmask"] == nil)

        let hop = try parse(Fixtures.hy2Hop)
        #expect(hop.port == 443)
        #expect(hop.config["streamSettings"]?["hysteriaSettings"]?["udphop"]?["port"]?.stringValue == "5000-6000")
        let mask = hop.config["streamSettings"]?["finalmask"]?["udp"]?[0]
        #expect(mask?["type"]?.stringValue == "salamander")
        #expect(mask?["settings"]?["password"]?.stringValue == "ob")
    }

    @Test func socksAndHTTP() throws {
        for link in [Fixtures.socksB64, Fixtures.socksPlain] {
            let s = try parse(link).config["settings"]
            #expect(s?["user"]?.stringValue == "user")
            #expect(s?["pass"]?.stringValue == "pass")
        }
        #expect(try parse(Fixtures.socksNoAuth).config["settings"]?["user"] == nil)
        let h = try parse(Fixtures.httpProxy)
        #expect(h.protocolName == "http" && h.security == "none")
        let hs = try parse(Fixtures.httpsProxy)
        #expect(hs.security == "tls")
        #expect(hs.config["streamSettings"]?["tlsSettings"]?["serverName"]?.stringValue == "proxy.example.com")
    }

    @Test func wireguard() throws {
        let p = try parse(Fixtures.wireguard)
        let s = p.config["settings"]
        #expect(s?["secretKey"]?.stringValue == "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=")
        #expect(s?["address"]?.arrayValue == ["10.0.0.2/32", "fd00::2/128"])
        #expect(s?["mtu"]?.intValue == 1280)
        #expect(s?["reserved"]?.arrayValue == [1, 2, 3])
        let peer = s?["peers"]?[0]
        #expect(peer?["publicKey"]?.stringValue == "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=")
        #expect(peer?["endpoint"]?.stringValue == "1.2.3.4:51820")
        #expect(peer?["allowedIPs"]?.arrayValue == ["0.0.0.0/0", "::/0"])
    }

    // MARK: Skips, fingerprints, whole corpus

    @Test(arguments: Fixtures.skipped.map { $0.name })
    func skippedLinks(name: String) throws {
        let entry = try #require(Fixtures.skipped.first { $0.name == name })
        do {
            _ = try parse(entry.link)
            Issue.record("\(name) should have been skipped")
        } catch let skip as LinkSkip {
            #expect(skip.reason.localizedCaseInsensitiveContains(entry.reason), "\(skip.reason)")
        }
    }

    @Test(arguments: Fixtures.valid.map { $0.name })
    func validLinksParse(name: String) throws {
        let entry = try #require(Fixtures.valid.first { $0.name == name })
        let p = try parse(entry.link)
        #expect(!p.name.isEmpty)
        #expect(!p.address.isEmpty)
        #expect((1...65535).contains(p.port))
        #expect(p.config["protocol"]?.stringValue != nil)
        #expect(p.config["tag"] == nil)
        #expect(p.fingerprint.count == 64)
    }

    @Test func fingerprintIgnoresNameOnly() throws {
        let a = try parse(Fixtures.vlessWS)
        let b = try parse(Fixtures.vlessWS.replacingOccurrences(of: "#WS%20TLS", with: "#Renamed"))
        let c = try parse(Fixtures.vlessWS.replacingOccurrences(of: "443", with: "8443"))
        #expect(a.name != b.name)
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.fingerprint != c.fingerprint)
    }

    @Test func customFingerprintIgnoresRemarksAndFirstOutboundTag() {
        let base: JSONValue = ["outbounds": [["tag": "a", "protocol": "vless", "settings": ["address": "x"]]], "remarks": "one"]
        let other: JSONValue = ["outbounds": [["tag": "zzz", "protocol": "vless", "settings": ["address": "x"]]], "remarks": "two"]
        #expect(ParsedProfile.fingerprint(kind: .custom, config: base) == ParsedProfile.fingerprint(kind: .custom, config: other))
    }
}
