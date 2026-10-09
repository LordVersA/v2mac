import Foundation
import Testing
@testable import V2MacCore

@Suite(.serialized) struct CoreUpdaterTests {
    @Test func comparesVersions() {
        #expect(VersionCompare.isNewer("v26.10.1", than: "Xray 26.9.30 (Xray, Penetrates Everything.)"))
        #expect(!VersionCompare.isNewer("v26.9.30", than: "26.9.30"))
        #expect(!VersionCompare.isNewer("v1.9", than: "1.10.0"))
        #expect(VersionCompare.isNewer("1.2.1", than: "1.2"))
        #expect(!VersionCompare.isNewer("nightly", than: "1.0"))
        #expect(VersionCompare.normalized("Xray 26.9.30 (go1.24)") == "26.9.30")
    }

    @Test func picksNewestReleaseIncludingPrereleases() throws {
        let json = """
        [{"tag_name":"v1.0.0","published_at":"2026-01-01T00:00:00Z","draft":false,"assets":[{"name":"Xray-macos-arm64-v8a.zip","browser_download_url":"https://x/1.zip"}]},
         {"tag_name":"v1.1.0-rc","published_at":"2026-03-01T00:00:00Z","prerelease":true,"draft":false,"assets":[{"name":"Xray-macos-arm64-v8a.zip","browser_download_url":"https://x/2.zip"},{"name":"Xray-macos-arm64-v8a.zip.dgst","browser_download_url":"https://x/2.dgst"}]},
         {"tag_name":"v9","published_at":"2026-05-01T00:00:00Z","draft":true,"assets":[{"name":"Xray-macos-arm64-v8a.zip","browser_download_url":"https://x/9.zip"}]}]
        """
        let release = try CoreUpdater.parseAPI(Data(json.utf8))
        #expect(release.tag == "v1.1.0-rc")
        #expect(release.assetURL.absoluteString == "https://x/2.zip")
        #expect(release.checksumURL.absoluteString == "https://x/2.dgst")
    }

    @Test func skipsReleasesWithoutTheMacAsset() throws {
        let json = """
        [{"tag_name":"v2","published_at":"2026-05-01T00:00:00Z","assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://x/l.zip"}]},
         {"tag_name":"v1","published_at":"2026-01-01T00:00:00Z","assets":[{"name":"Xray-macos-arm64-v8a.zip","browser_download_url":"https://x/1.zip"}]}]
        """
        #expect(try CoreUpdater.parseAPI(Data(json.utf8)).tag == "v1")
        #expect(throws: CoreUpdateError.malformedResponse) { try CoreUpdater.parseAPI(Data("{}".utf8)) }
    }

    @Test func parsesAtomFallback() throws {
        let atom = """
        <feed><entry><id>1</id><link rel="alternate" href="https://github.com/XTLS/Xray-core/releases/tag/v1.0.0"/><updated>2026-01-01T00:00:00Z</updated></entry>
        <entry><id>2</id><link rel="alternate" href="https://github.com/XTLS/Xray-core/releases/tag/v1.2.0"/><updated>2026-04-01T00:00:00Z</updated></entry></feed>
        """
        let release = try CoreUpdater.parseAtom(Data(atom.utf8))
        #expect(release.tag == "v1.2.0")
        #expect(release.assetURL.absoluteString.hasSuffix("/download/v1.2.0/Xray-macos-arm64-v8a.zip"))
    }

    @Test func parsesDigestFile() throws {
        let hex = String(repeating: "0f", count: 32)
        let dgst = "MD5= abc\nSHA1= def\nSHA2-256= \(hex)\nSHA2-512= 123\n"
        #expect(try CoreUpdater.parseDigest(Data(dgst.utf8)) == hex)
        #expect(throws: CoreUpdateError.checksumMissing) { try CoreUpdater.parseDigest(Data("MD5= abc".utf8)) }
    }

    @Test func parsesAppRelease() throws {
        let json = #"{"tag_name":"v0.2.0","html_url":"https://github.com/o/r/releases/tag/v0.2.0"}"#
        let release = try AppUpdateChecker.parse(Data(json.utf8))
        #expect(release.version == "0.2.0")
        #expect(VersionCompare.isNewer(release.tag, than: "0.1.0"))
    }

    @Test func parsesAppReleaseAtomFallback() throws {
        let atom = """
        <feed><updated>2026-09-01T00:00:00Z</updated>
        <entry><id>2</id><updated>2026-09-01T00:00:00Z</updated><link rel="alternate" type="text/html" href="https://github.com/o/r/releases/tag/v0.2.1"/></entry>
        <entry><id>3</id><updated>2026-09-02T00:00:00Z</updated><link rel="alternate" type="text/html" href="https://github.com/o/r/releases/tag/v0.10.0"/></entry>
        <entry><id>1</id><updated>2026-08-01T00:00:00Z</updated><link rel="alternate" type="text/html" href="https://github.com/o/r/releases/tag/v0.2.0"/></entry></feed>
        """
        let release = try AppUpdateChecker.parseAtom(Data(atom.utf8))
        #expect(release.tag == "v0.10.0")
        #expect(release.pageURL.absoluteString == "https://github.com/o/r/releases/tag/v0.10.0")
        #expect(throws: CoreUpdateError.noRelease) { try AppUpdateChecker.parseAtom(Data("<feed></feed>".utf8)) }
    }

    // MARK: Install with a stand-in binary

    private func makeZip(script: String) throws -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zipsrc-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data(script.utf8).write(to: dir.appendingPathComponent("xray"))
        try Data("geoip".utf8).write(to: dir.appendingPathComponent("geoip.dat"))
        try Data("geosite".utf8).write(to: dir.appendingPathComponent("geosite.dat"))
        let zip = dir.appendingPathComponent("out.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "out.zip", "xray", "geoip.dat", "geosite.dat"]
        try p.run(); p.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    private func serve(zip: Data, digest: String? = nil) async throws -> (TestHTTPServer, CoreRelease) {
        let sum = digest ?? RegionPackInstaller.sha256(zip)
        let server = try await TestHTTPServer.start { path in
            switch path {
            case "/core.zip": .init(body: zip)
            case "/core.dgst": .init(body: Data("SHA2-256= \(sum)\n".utf8))
            default: .init(status: 404)
            }
        }
        let base = "http://127.0.0.1:\(server.port)"
        return (server, CoreRelease(tag: "v9.9.9", publishedAt: nil, assetURL: URL(string: base + "/core.zip")!, checksumURL: URL(string: base + "/core.dgst")!))
    }

    private func dirs() throws -> (core: URL, assets: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(UUID().uuidString)")
        return (root.appendingPathComponent("core"), root.appendingPathComponent("assets"))
    }

    @Test func installsAVerifiedCore() async throws {
        let zip = try makeZip(script: "#!/bin/sh\n[ \"$1\" = version ] && echo 'Xray 9.9.9 (stand-in)'\nexit 0\n")
        let (server, release) = try await serve(zip: zip)
        defer { server.stop() }
        let d = try dirs()
        let result = try await CoreUpdater.install(release, downloader: FileDownloader(routes: [.direct]), coreDirectory: d.core, assetDirectory: d.assets)
        #expect(result.version == "9.9.9")
        #expect(FileManager.default.isExecutableFile(atPath: d.core.appendingPathComponent("xray").path))
        #expect(FileManager.default.fileExists(atPath: d.assets.appendingPathComponent("geoip.dat").path))
    }

    @Test func rejectsChecksumMismatchAndTouchesNothing() async throws {
        let zip = try makeZip(script: "#!/bin/sh\necho 'Xray 9.9.9'\n")
        let (server, release) = try await serve(zip: zip, digest: String(repeating: "0", count: 64))
        defer { server.stop() }
        let d = try dirs()
        await #expect(throws: DownloadError.self) {
            _ = try await CoreUpdater.install(release, downloader: FileDownloader(routes: [.direct]), coreDirectory: d.core, assetDirectory: d.assets)
        }
        #expect(!FileManager.default.fileExists(atPath: d.core.path))
    }

    @Test func rejectsACoreThatFailsItsSelfTest() async throws {
        let zip = try makeZip(script: "#!/bin/sh\n[ \"$1\" = version ] && echo 'Xray 9.9.9' && exit 0\necho 'bad config' >&2\nexit 1\n")
        let (server, release) = try await serve(zip: zip)
        defer { server.stop() }
        let d = try dirs()
        await #expect(throws: CoreUpdateError.self) {
            _ = try await CoreUpdater.install(release, downloader: FileDownloader(routes: [.direct]), coreDirectory: d.core, assetDirectory: d.assets)
        }
        #expect(!FileManager.default.fileExists(atPath: d.core.appendingPathComponent("xray").path))
    }

    @Test func revertRemovesCopiesButKeepsSymlinks() throws {
        let d = try dirs()
        let fm = FileManager.default
        try fm.createDirectory(at: d.core, withIntermediateDirectories: true)
        try fm.createDirectory(at: d.assets, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: d.core.appendingPathComponent("xray"))
        try Data("x".utf8).write(to: d.assets.appendingPathComponent("geoip.dat"))
        try fm.createSymbolicLink(at: d.assets.appendingPathComponent("geosite.dat"), withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        CoreUpdater.revert(coreDirectory: d.core, assetDirectory: d.assets)
        #expect(!fm.fileExists(atPath: d.core.appendingPathComponent("xray").path))
        #expect(!fm.fileExists(atPath: d.assets.appendingPathComponent("geoip.dat").path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: d.assets.appendingPathComponent("geosite.dat").path)) != nil)
    }
}
