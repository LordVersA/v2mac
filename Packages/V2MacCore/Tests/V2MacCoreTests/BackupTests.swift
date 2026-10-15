import Foundation
import Testing
@testable import V2MacCore

@Suite struct BackupTests {
    func sample() throws -> Backup {
        let parsed = try ShareLinkParser.parse(Fixtures.vlessRealityVision)
        let custom = ParsedProfile(name: "Pasted", kind: .custom, protocolName: "custom", address: "", port: 0,
                                   transport: "", security: "", config: ["outbounds": [["protocol": "freedom"]]])
        return Backup(
            app: "1.2.3", created: Date(timeIntervalSince1970: 1_700_000_000),
            groups: [
                .init(name: "Provider", subscriptionURL: "https://sub.example.com/token", autoUpdate: true, intervalHours: 6,
                      color: "teal", userAgent: nil, servers: [.init(profile: parsed, favorite: true)]),
                .init(name: "Custom Configs", subscriptionURL: "", autoUpdate: false, intervalHours: nil, color: nil,
                      userAgent: nil, servers: [.init(profile: custom, favorite: false)]),
            ],
            settings: ["proxyPort": 10808, "killSwitch": true, "routingMode": "global", "enabledRegionPacks": ["ir"]]
        )
    }

    @Test func roundTripsThroughTheFile() throws {
        let backup = try sample()
        let data = try backup.fileData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("{"), "the file holds base64, not JSON")
        #expect(text.split(separator: "\n").allSatisfy { $0.count <= 76 })
        let read = try Backup.read(data)
        #expect(read == backup)
        // The servers keep their identity: the fingerprint is worked out again from the config.
        #expect(read.groups[0].servers[0].profile.fingerprint == backup.groups[0].servers[0].profile.fingerprint)
    }

    @Test func refusesOtherFilesAndNewerVersions() throws {
        #expect(throws: Backup.ReadError.notABackup) { try Backup.read(Data("vless://not-a-backup".utf8)) }
        let json = Data(#"{"format":"something-else","version":1}"#.utf8).base64EncodedData()
        #expect(throws: Backup.ReadError.notABackup) { try Backup.read(json) }
        let newer = Data(#"{"format":"v2mac-backup","version":2}"#.utf8).base64EncodedData()
        #expect(throws: Backup.ReadError.newerVersion) { try Backup.read(newer) }
    }

    @Test func preferencesKeepTheirTypes() {
        let values: [String: Any] = ["on": true, "port": 10808, "timeout": 8.5, "url": "https://x", "packs": ["ir", "cn"],
                                     "intervals": ["ir": "daily"]]
        let json = values.compactMapValues(Backup.json(fromPreference:))
        #expect(json["on"] == .bool(true))
        #expect(json["port"] == .number(10808))
        let back = json.compactMapValues(Backup.preference(from:))
        #expect(back["on"] as? Bool == true)
        #expect(back["port"] as? Int == 10808)
        #expect(back["timeout"] as? Double == 8.5)
        #expect(back["packs"] as? [String] == ["ir", "cn"])
        #expect(back["intervals"] as? [String: String] == ["ir": "daily"])
    }
}
