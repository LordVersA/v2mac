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
}
