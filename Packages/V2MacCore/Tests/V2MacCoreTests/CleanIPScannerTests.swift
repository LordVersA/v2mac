import Foundation
import Testing
@testable import V2MacCore

@Suite struct CleanIPScannerTests {
    func outbound(_ link: String) throws -> JSONValue { try ShareLinkParser.parse(link).config }

    @Test func onlyCDNTransportsWithAName() throws {
        #expect(CleanIPScanner.hostName(of: try outbound(Fixtures.vlessWS)) == "cdn.example.com")
        #expect(CleanIPScanner.hostName(of: try outbound(Fixtures.vlessGRPC)) == "a.example.com")
        #expect(CleanIPScanner.hostName(of: try outbound(Fixtures.vlessRealityVision)) == nil)
        #expect(CleanIPScanner.hostName(of: try outbound(Fixtures.trojanPlain)) == nil)
        // An address-only WS server has no name for SNI and Host.
        #expect(CleanIPScanner.hostName(of: try outbound("vless://\(Fixtures.uuid)@1.2.3.4:443?type=ws&security=tls#x")) == nil)
    }

    @Test func pointingKeepsTheNameAsSNIAndHost() throws {
        let bare = try outbound("vless://\(Fixtures.uuid)@cdn.example.com:443?type=ws&security=tls&path=%2F#x")
        let name = try #require(CleanIPScanner.hostName(of: bare))
        let pointed = CleanIPScanner.pointing(bare, to: "104.16.1.2", name: name)
        #expect(pointed["settings"]?["address"]?.stringValue == "104.16.1.2")
        #expect(pointed["streamSettings"]?["tlsSettings"]?["serverName"]?.stringValue == "cdn.example.com")
        #expect(pointed["streamSettings"]?["wsSettings"]?["host"]?.stringValue == "cdn.example.com")
        let vnext: JSONValue = ["protocol": "vmess", "settings": ["vnext": [["address": "a.example.com", "port": 443]]],
                                "streamSettings": ["network": "ws", "security": "tls", "tlsSettings": ["serverName": "b.example.com"]]]
        let moved = CleanIPScanner.pointing(vnext, to: "104.16.1.2", name: "b.example.com")
        #expect(moved["settings"]?["vnext"]?[0]?["address"]?.stringValue == "104.16.1.2")
        #expect(moved["settings"]?["vnext"]?[0]?["port"]?.intValue == 443)
    }

    @Test func sampleIsDistinctPerBlockAndInsideTheRanges() {
        let ips = CleanIPScanner.sample(300)
        #expect(ips.count == 300)
        #expect(Set(ips.map { $0.split(separator: ".").prefix(3).joined(separator: ".") }).count == 300)
        for ip in ips {
            let last = Int(ip.split(separator: ".")[3])!
            #expect((1...254).contains(last))
        }
        #expect(CleanIPScanner.sample(10, from: ["104.16.5.0/24"]).count == 1)
        #expect(CleanIPScanner.sample(10, from: ["10.0.0.0/8"]).allSatisfy { $0.hasPrefix("10.") })
    }
}
