import CryptoKit
import Foundation
import Synchronization
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

    @Test func downloadRestartsWhenTheServerIgnoresRange() async throws {
        let body = Data((0..<5000).map { UInt8($0 % 256) })
        let server = try await TestHTTPServer.start { _ in .init(body: body) }
        defer { server.stop() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-range-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("stale partial bytes".utf8).write(to: file)
        try await ResumableDownload(routes: [.direct]).fetch(URL(string: "http://127.0.0.1:\(server.port)/x")!, to: file, expectedSize: Int64(body.count))
        #expect(try Data(contentsOf: file) == body)
    }

    private static func manifestJSON(_ files: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": "1", "files": files])
    }

    private static let hashA = String(repeating: "a", count: 64), hashB = String(repeating: "b", count: 64)

    @Test func planCopiesUnchangedPatchesKnownAndDownloadsTheRest() throws {
        let zip: [String: Any] = ["url": "f.zip", "sha256": Self.hashA, "size": 100]
        let patch: [String: Any] = ["url": "f.bsdiff", "sha256": Self.hashA, "size": 7, "from": Self.hashB]
        let manifest = try BundleManifest(data: Self.manifestJSON([
            ["path": "Contents/A", "sha256": Self.hashA, "size": 1, "executable": false, "zip": zip, "patches": []],
            ["path": "Contents/B", "sha256": Self.hashA, "size": 1, "executable": false, "zip": zip, "patches": [patch]],
            ["path": "Contents/C", "sha256": Self.hashA, "size": 1, "executable": false, "zip": zip, "patches": [patch]],
            ["path": "Contents/D", "sha256": Self.hashA, "size": 1, "executable": false, "zip": zip, "patches": []],
        ]))
        let damaged = String(repeating: "c", count: 64)
        let plan = manifest.plan(installed: ["Contents/A": Self.hashA, "Contents/B": Self.hashB, "Contents/C": damaged])
        #expect(plan.map(\.step) == [.copy, .patch(manifest.files[1].patches[0]), .full, .full])
        #expect(BundleManifest.downloadSize(plan) == 7 + 100 + 100)
    }

    @Test func manifestRefusesPathsAndNamesOutsideTheRelease() throws {
        func entry(path: String = "Contents/A", url: String = "a.zip", sha: String = Self.hashA) -> [String: Any] {
            ["path": path, "sha256": Self.hashA, "size": 1, "executable": false,
             "zip": ["url": url, "sha256": sha, "size": 1], "patches": []]
        }
        _ = try BundleManifest(data: Self.manifestJSON([entry()]))
        for bad in [entry(path: "Contents/../../x"), entry(path: "/etc/x"), entry(path: "Contents//x"), entry(path: "Other/x"),
                    entry(url: "../x.zip"), entry(url: "https://example.com/x.zip"), entry(url: ".hidden"),
                    entry(sha: Self.hashA.uppercased())] {
            #expect(throws: SandboxInstallError.checksumMismatch) { try BundleManifest(data: Self.manifestJSON([bad])) }
        }
        #expect(throws: SandboxInstallError.checksumMismatch) { try BundleManifest(data: Self.manifestJSON([entry(), entry()])) }
    }

    /// Made with Debian's bsdiff (sandbox release CI's) from `old` to `new` below: macOS's bspatch must take it.
    private static let debianPatch = Data(base64Encoded: "QlNESUZGNDAzAAAAAAAAAEAAAAAAAAAABBAAAAAAAABCWmg5MUFZJlNZj1OChgAABmBCXABAAEAAAACgACGahkIYDrNaVHAvi7kinChIR6nBQwBCWmg5MUFZJlNZYM+0wgAAAE0gwAAAA/8AQAAAAgAIIAAhtUZBkyEAACrAZgSH1vnYn1XIkvi7kinChIMGfaYQQlpoOTFBWSZTWWQbDTYAAAGBgCAkBAAgACGaaDNNEzxdyRThQkGQbDTY")!

    @Test func updateDownloadsOnlyThePatchAndChangedFilesAndKeepsTheOldSandboxOnFailure() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("v2mac-sandbox-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let old = Data((0..<4096).map { UInt8($0 % 251) })
        var new = old
        new.replaceSubrange(100..<110, with: Data(repeating: 0xaa, count: 10))
        new += Data("tail".utf8)

        // A release: every file zipped on its own, its manifest, served by name. `broken` serves other bytes.
        let served = Mutex<[String: Data]>([:]), requested = Mutex<[String]>([])
        let server = try await TestHTTPServer.start { path in
            let name = String(path.dropFirst())
            requested.withLock { $0.append(name) }
            return served.withLock { $0[name] }.map { .init(body: $0) } ?? .init(status: 404)
        }
        defer { server.stop() }
        func release(_ files: [String: Data], patch: Data? = nil, broken: Set<String> = []) async throws -> SandboxPin {
            var entries: [[String: Any]] = [], bodies: [String: Data] = [:]
            for (path, body) in files.sorted(by: { $0.key < $1.key }) {
                let name = path.split(separator: "/").last!.replacingOccurrences(of: " ", with: "_")
                let src = work.appendingPathComponent("src-\(UUID().uuidString)/\(path.split(separator: "/").last!)")
                try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: src)
                let zip = work.appendingPathComponent("\(name).zip")
                try? fm.removeItem(at: zip)
                _ = try await CoreUpdater.run("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])
                let zipBody = try Data(contentsOf: zip)
                bodies["\(name).zip"] = broken.contains(path) ? Data(repeating: 0, count: zipBody.count) : zipBody
                var patches: [[String: Any]] = []
                if let patch, path.hasSuffix("rootfs") {
                    bodies["rootfs.bsdiff"] = broken.contains("patch") ? Data(repeating: 0, count: patch.count) : patch
                    patches = [["url": "rootfs.bsdiff", "sha256": Self.hash(patch), "size": patch.count, "from": Self.hash(old)]]
                }
                entries.append(["path": path, "sha256": Self.hash(body), "size": body.count, "executable": path.contains("MacOS"),
                                "zip": ["url": "\(name).zip", "sha256": Self.hash(zipBody), "size": zipBody.count], "patches": patches])
            }
            let manifest = try Self.manifestJSON(entries)
            bodies["files.json"] = manifest
            served.withLock { $0 = bodies }
            requested.withLock { $0 = [] }
            return SandboxPin(url: URL(string: "http://127.0.0.1:\(server.port)/files.json")!, sha256: Self.hash(manifest),
                              executableSHA256: Self.hash(files["Contents/MacOS/V2Mac Sandbox"]!), size: 0)
        }
        let files = SandboxFiles(root: work.appendingPathComponent("sandbox"))
        let download = ResumableDownload(routes: [.direct])
        let helper1 = Data("#!/bin/sh\n".utf8), helper2 = Data("#!/bin/sh\necho 2\n".utf8), strings = Data("\"a\" = \"b\";".utf8)

        let v1 = try await release(["Contents/MacOS/V2Mac Sandbox": helper1, "Contents/Resources/rootfs": old, "Contents/Resources/fa.lproj/L.strings": strings])
        try await files.install(v1, download: download)
        #expect(files.isInstalled)
        try files.verify(v1)

        // v2: the helper changed, the rootfs has a patch from v1's, the strings did not change.
        let v2files = ["Contents/MacOS/V2Mac Sandbox": helper2, "Contents/Resources/rootfs": new, "Contents/Resources/fa.lproj/L.strings": strings]
        let v2 = try await release(v2files, patch: Self.debianPatch)
        #expect(BundleManifest.downloadSize(try await files.plan(v2, download: download)) < Int64(new.count))
        try await files.install(v2, download: download)
        #expect(Set(requested.withLock { $0 }) == ["files.json", "files.json", "V2Mac_Sandbox.zip", "rootfs.bsdiff"])
        #expect(try Data(contentsOf: files.app.appendingPathComponent("Contents/Resources/rootfs")) == new)
        #expect(try Data(contentsOf: files.app.appendingPathComponent("Contents/Resources/fa.lproj/L.strings")) == strings)
        #expect(fm.isExecutableFile(atPath: files.executable.path))
        try files.verify(v2)

        // A patch that fails its hash: the rootfs comes in full.
        try await files.install(try await release(["Contents/MacOS/V2Mac Sandbox": helper1, "Contents/Resources/rootfs": old,
                                                   "Contents/Resources/fa.lproj/L.strings": strings]), download: download)
        let v2broken = try await release(v2files, patch: Self.debianPatch, broken: ["patch"])
        try await files.install(v2broken, download: download)
        #expect(requested.withLock { $0 }.contains("rootfs.zip"))
        #expect(try Data(contentsOf: files.app.appendingPathComponent("Contents/Resources/rootfs")) == new)

        // A broken zip: the install fails and the installed sandbox stays.
        let v3 = try await release(["Contents/MacOS/V2Mac Sandbox": helper1, "Contents/Resources/rootfs": old,
                                    "Contents/Resources/fa.lproj/L.strings": strings], broken: ["Contents/MacOS/V2Mac Sandbox"])
        await #expect(throws: SandboxInstallError.checksumMismatch) { try await files.install(v3, download: download) }
        try files.verify(v2broken)
        #expect(try Data(contentsOf: files.app.appendingPathComponent("Contents/Resources/rootfs")) == new)
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

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
