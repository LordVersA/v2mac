import Foundation
import Testing
@testable import V2MacCore

@Suite struct SandboxTests {
    @Test func linkMessagesRoundTripAcrossSplitFrames() throws {
        let sent: [SandboxLink.ToHelper] = [
            .hello(version: 2, ramCapMB: 4096, core: "/x/xray"),
            .probe,
            .servers([.init(id: "a", name: "Frankfurt")], active: "a"),
            .outbound(id: "a", json: nil),
            .quitRequest,
        ]
        let bytes = try sent.map(SandboxLink.frame).reduce(Data(), +)
        var reader = SandboxLink.Reader<SandboxLink.ToHelper>()
        var got: [SandboxLink.ToHelper] = []
        for start in stride(from: 0, to: bytes.count, by: 7) {
            got += try reader.feed(bytes.subdata(in: start..<min(start + 7, bytes.count)))
        }
        #expect(got == sent)
    }

    @Test func linkRefusesOversizedAndMalformedFrames() {
        var reader = SandboxLink.Reader<SandboxLink.ToApp>()
        #expect(throws: SandboxLink.FrameTooLarge.self) { try reader.feed(Data([0x7f, 0, 0, 0])) }
        var other = SandboxLink.Reader<SandboxLink.ToApp>()
        #expect(throws: (any Error).self) { try other.feed(Data([0, 0, 0, 2]) + Data("{}".utf8)) }
    }

    @Test func linkSurvivesRandomBytes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var reader = SandboxLink.Reader<SandboxLink.ToApp>()
            let junk = Data((0..<Int.random(in: 0..<64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = try? reader.feed(junk) // must throw or return, never trap
        }
    }

    @Test func defaultRAMCapIsAQuarterWithinTwoToEightGB() {
        #expect(SandboxFiles.defaultRAMCapMB(physicalMemory: 8 << 30) == 2048)
        #expect(SandboxFiles.defaultRAMCapMB(physicalMemory: 24 << 30) == 6144)
        #expect(SandboxFiles.defaultRAMCapMB(physicalMemory: 128 << 30) == 8192)
    }

    @Test func downloadRestartsWhenTheServerIgnoresRangeThenInstallChecksHashes() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("v2mac-sandbox-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let appDir = work.appendingPathComponent("src/\(SandboxFiles.appName)/Contents/MacOS")
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        let executable = appDir.appendingPathComponent("V2Mac Sandbox")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let zip = work.appendingPathComponent("sandbox.zip")
        _ = try await CoreUpdater.run("/usr/bin/ditto", ["-c", "-k", "--keepParent",
                                                         work.appendingPathComponent("src/\(SandboxFiles.appName)").path, zip.path])
        let body = try Data(contentsOf: zip)
        let server = try await TestHTTPServer.start { _ in .init(body: body) }
        defer { server.stop() }

        let files = SandboxFiles(root: work.appendingPathComponent("sandbox"))
        try fm.createDirectory(at: files.root, withIntermediateDirectories: true)
        try Data("stale partial bytes".utf8).write(to: files.partial)
        let url = URL(string: "http://127.0.0.1:\(server.port)/sandbox.zip")!
        try await ResumableDownload(routes: [.direct]).fetch(url, to: files.partial, expectedSize: Int64(body.count))
        #expect(try Data(contentsOf: files.partial) == body)

        let pin = SandboxPin(url: url, sha256: try SandboxFiles.sha256(of: zip),
                             executableSHA256: try SandboxFiles.sha256(of: executable), size: Int64(body.count))
        var wrong = pin
        wrong.executableSHA256 = String(repeating: "0", count: 64)
        await #expect(throws: SandboxInstallError.helperChanged) { try await files.install(wrong) }
        #expect(!files.isInstalled)

        try await ResumableDownload(routes: [.direct]).fetch(url, to: files.partial, expectedSize: Int64(body.count))
        try await files.install(pin)
        #expect(files.isInstalled)
        try files.verify(pin)
        try Data("changed".utf8).write(to: files.executable)
        #expect(throws: SandboxInstallError.helperChanged) { try files.verify(pin) }
    }

    @Test func handedOutOutboundIsTaggedAndBound() {
        let server: JSONValue = ["protocol": "vless", "settings": ["vnext": [["address": "1.2.3.4", "port": 443]]]]
        let out = SandboxLink.outbound(server, tag: "vm-a", interface: "en0")
        #expect(out["tag"]?.stringValue == "vm-a")
        #expect(out["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en0")
        #expect(SandboxLink.outbound(server, tag: "vm-a", interface: nil)["streamSettings"] == nil)
    }

    @Test func jsonConfigsExitThroughTheirStandaloneProxy() {
        let proxy: JSONValue = ["protocol": "vless", "tag": "proxy"]
        let config: JSONValue = ["outbounds": [["protocol": "freedom", "tag": "direct"], proxy, ["protocol": "blackhole"]]]
        #expect(SandboxLink.exitOutbound(config, kind: .custom) == proxy)
        #expect(SandboxLink.exitOutbound(proxy, kind: .outbound) == proxy)
        let chained: JSONValue = ["outbounds": [["protocol": "vless", "streamSettings": ["sockopt": ["dialerProxy": "frag"]]], ["protocol": "freedom", "tag": "frag"]]]
        #expect(SandboxLink.exitOutbound(chained, kind: .custom) == nil)
        #expect(SandboxLink.exitOutbound(["outbounds": [["protocol": "freedom"]]], kind: .custom) == nil)
    }
}
