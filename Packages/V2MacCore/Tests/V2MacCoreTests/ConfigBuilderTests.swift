import Testing
@testable import V2MacCore

@Suite struct ConfigBuilderTests {
    let outbound: JSONValue = ["protocol": "freedom"]

    func build(_ inbound: InboundSettings = InboundSettings(), connections: Bool = false) throws -> JSONValue {
        try ConfigBuilder.buildGlobal(
            outbound: outbound,
            options: RunOptions(inbound: inbound, logConnections: connections, metricsPort: 20000)
        )
    }

    @Test func defaultShape() throws {
        let c = try build()
        #expect(c["inbounds"]?[0]?["port"]?.intValue == 10808)
        #expect(c["inbounds"]?[0]?["listen"]?.stringValue == "127.0.0.1")
        #expect(c["inbounds"]?[0]?["protocol"]?.stringValue == "mixed")
        #expect(c["inbounds"]?[0]?["settings"]?["auth"]?.stringValue == "noauth")
        #expect(c["outbounds"]?[0]?["tag"]?.stringValue == "proxy")
        #expect(c["outbounds"]?[0]?["protocol"]?.stringValue == "freedom")
        #expect(c["outbounds"]?[1]?["tag"]?.stringValue == "direct")
        #expect(c["outbounds"]?[2]?["tag"]?.stringValue == "block")
        #expect(c["metrics"]?["listen"]?.stringValue == "127.0.0.1:20000")
        #expect(c["stats"] != nil)
        #expect(c["policy"]?["system"]?["statsInboundDownlink"]?.boolValue == true)
        #expect(c["log"]?["access"]?.stringValue == "none")
        #expect(c["log"]?["loglevel"]?.stringValue == "warning")
        #expect(c["dns"] == nil)
    }

    @Test func globalRoutingSendsPrivateDirect() throws {
        let rule = try build()["routing"]?["rules"]?[0]
        #expect(rule?["ip"]?[0]?.stringValue == "geoip:private")
        #expect(rule?["outboundTag"]?.stringValue == "direct")
        #expect(try build()["routing"]?["rules"]?[1] == nil)
    }

    @Test func logConnectionsOmitsAccessNone() throws {
        #expect(try build(connections: true)["log"]?["access"] == nil)
    }

    @Test func lanAndCredentials() throws {
        let c = try build(InboundSettings(port: 9000, allowLAN: true, username: "u", password: "p"))
        let inbound = c["inbounds"]?[0]
        #expect(inbound?["listen"]?.stringValue == "0.0.0.0")
        #expect(inbound?["port"]?.intValue == 9000)
        #expect(inbound?["settings"]?["auth"]?.stringValue == "password")
        #expect(inbound?["settings"]?["accounts"]?[0]?["user"]?.stringValue == "u")
        #expect(inbound?["settings"]?["accounts"]?[0]?["pass"]?.stringValue == "p")
    }

    @Test func partialCredentialsAreIgnored() throws {
        let c = try build(InboundSettings(username: "u", password: ""))
        #expect(c["inbounds"]?[0]?["settings"]?["auth"]?.stringValue == "noauth")
    }

    @Test func outboundMustBeObject() {
        #expect(throws: ConfigBuilderError.outboundNotAnObject) {
            try ConfigBuilder.buildGlobal(outbound: "x", options: RunOptions(metricsPort: 1))
        }
    }
}
