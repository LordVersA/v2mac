import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import V2MacCore

/// docs/app-auto-update.md: the app's own release file by file, staging, and the core range.
@Suite(.serialized) struct AppDeltaUpdateTests {
    private static let key = Curve25519.Signing.PrivateKey()

    /// A signed stand-in app; `data` is a resource that changes between versions, `same` one that does not.
    private func makeApp(at app: URL, version: String, data: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": "test.v2mac", "CFBundleShortVersionString": version,
            "CFBundleExecutable": "V2Mac", "CFBundlePackageType": "APPL",
        ]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/V2Mac").path)
        try Data(data.utf8).write(to: app.appendingPathComponent("Contents/Resources/data"))
        try Data("same".utf8).write(to: app.appendingPathComponent("Contents/Resources/same"))
        #expect(try await CoreUpdater.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]).status == 0)
    }

    /// What release CI publishes for `app`: one zip per file and the signed `files.json`, by name.
    private func release(of app: URL, version: String, work: URL, signer: Curve25519.Signing.PrivateKey = key) async throws -> [String: Data] {
        let fm = FileManager.default
        var bodies: [String: Data] = [:], entries: [[String: Any]] = []
        let paths = fm.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey])!
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path.dropFirst(app.standardizedFileURL.path.count + 1)) }.sorted()
        for path in paths {
            let name = path.dropFirst("Contents/".count).replacingOccurrences(of: "/", with: "_") + ".zip"
            let zip = work.appendingPathComponent(name)
            try? fm.removeItem(at: zip)
            _ = try await CoreUpdater.run("/usr/bin/ditto", ["-c", "-k", app.appendingPathComponent(path).path, zip.path])
            bodies[name] = try Data(contentsOf: zip)
            let file = app.appendingPathComponent(path)
            entries.append(["path": path, "sha256": try BundleManifest.sha256(of: file),
                            "size": try Data(contentsOf: file).count, "executable": fm.isExecutableFile(atPath: file.path),
                            "zip": ["url": name, "sha256": RegionPackInstaller.sha256(bodies[name]!), "size": bodies[name]!.count],
                            "patches": [Any]()])
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["version": version, "files": entries])
        bodies["files.json"] = manifest
        bodies["files.json.sig"] = Data(try signer.signature(for: manifest).base64EncodedString().utf8)
        return bodies
    }

    @Test func buildsTheNextReleaseFromChangedFilesOnlyAndRefusesAnUnsignedManifest() async throws {
        let fm = FileManager.default
        let home = try TestSupport.makeTempDirectory()
        defer { try? fm.removeItem(at: home) }
        let installed = home.appendingPathComponent("installed/V2Mac.app")
        try await makeApp(at: installed, version: "1.0.0", data: "one")
        let next = home.appendingPathComponent("next/V2Mac.app")
        try await makeApp(at: next, version: "1.1.0", data: "two")

        let served = Mutex<[String: Data]>([:]), requested = Mutex<[String]>([])
        let server = try await TestHTTPServer.start { path in
            let name = String(path.dropFirst())
            requested.withLock { $0.append(name) }
            return served.withLock { $0[name] }.map { .init(body: $0) } ?? .init(status: 404)
        }
        defer { server.stop() }
        let bodies = try await release(of: next, version: "1.1.0", work: home)
        served.withLock { $0 = bodies }
        let url = URL(string: "http://127.0.0.1:\(server.port)/files.json")!
        func prepare(key: Curve25519.Signing.PublicKey = Self.key.publicKey, version: String = "1.1.0") async throws -> AppInstaller.Staged {
            try await AppInstaller.prepareDelta(
                manifest: url, expectedVersion: version, bundleIdentifier: "test.v2mac", installed: installed,
                work: home.appendingPathComponent("updates/building"), downloader: FileDownloader(routes: [.direct]),
                download: ResumableDownload(routes: [.direct]), signedBy: key
            )
        }

        let prepared = try await prepare()
        #expect(prepared.version == "1.1.0")
        // Only what changed: the resource, Info.plist and the signature (in the executable too); `same` is copied.
        let fetched = Set(requested.withLock { $0 }).subtracting(["files.json", "files.json.sig"])
        #expect(fetched == ["Info.plist.zip", "Resources_data.zip", "_CodeSignature_CodeResources.zip", "MacOS_V2Mac.zip"])
        #expect(try String(contentsOf: prepared.app.appendingPathComponent("Contents/Resources/data"), encoding: .utf8) == "two")

        let updates = home.appendingPathComponent("updates")
        let staged = try AppInstaller.stage(prepared, in: updates)
        #expect(staged.app.path == updates.appendingPathComponent("V2Mac.app").path)
        #expect(!fm.fileExists(atPath: prepared.workDirectory.path))
        #expect(AppInstaller.staged(in: updates, newerThan: "1.0.0", bundleIdentifier: "test.v2mac")?.version == "1.1.0")
        #expect(AppInstaller.staged(in: updates, newerThan: "1.0.0", bundleIdentifier: "other") == nil)
        #expect(!fm.fileExists(atPath: updates.path), "a stale staged app is removed")

        // A manifest signed with another key, or for another version: nothing is built.
        await #expect(throws: AppInstallError.notSignedByProject) { _ = try await prepare(key: Curve25519.Signing.PrivateKey().publicKey) }
        await #expect(throws: AppInstallError.wrongApp) { _ = try await prepare(version: "1.2.0") }
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("updates/building/V2Mac.app").path))

        // A zip that does not match the manifest: the build fails and leaves no app behind.
        served.withLock { $0["Resources_data.zip"] = Data(repeating: 0, count: bodies["Resources_data.zip"]!.count) }
        try? fm.removeItem(at: home.appendingPathComponent("updates"))
        await #expect(throws: SandboxInstallError.checksumMismatch) { _ = try await prepare() }
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("updates/building/V2Mac.app").path))
    }

    @Test func alternateCopyCountsAsInstalledWhenItIsTheNewFile() throws {
        let fm = FileManager.default
        let home = try TestSupport.makeTempDirectory()
        defer { try? fm.removeItem(at: home) }
        let app = home.appendingPathComponent("V2Mac.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: app.appendingPathComponent("Contents/Helpers/xray"))
        let core = home.appendingPathComponent("xray")
        try Data("new".utf8).write(to: core)
        let new = RegionPackInstaller.sha256(Data("new".utf8))
        let json = try JSONSerialization.data(withJSONObject: ["version": "2", "files": [[
            "path": "Contents/Helpers/xray", "sha256": new, "size": 3, "executable": true,
            "zip": ["url": "x.zip", "sha256": new, "size": 9], "patches": [Any](),
        ]]])
        let manifest = try BundleManifest(data: json)
        #expect(manifest.plan(installed: manifest.current(in: app).mapValues(\.sha256)).first?.step == .full)
        let current = manifest.current(in: app, alternates: ["Contents/Helpers/xray": core])
        #expect(current["Contents/Helpers/xray"]?.url == core)
        #expect(manifest.plan(installed: current.mapValues(\.sha256)).first?.step == .copy)
    }

    @Test func swapAtQuitDoesNotReopen() async throws {
        let fm = FileManager.default
        let home = try TestSupport.makeTempDirectory()
        defer { try? fm.removeItem(at: home) }
        let target = home.appendingPathComponent("V2Mac.app"), updates = home.appendingPathComponent("updates")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: updates.appendingPathComponent("V2Mac.app"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: updates.appendingPathComponent("V2Mac.app/marker"))
        let staged = AppInstaller.Staged(app: updates.appendingPathComponent("V2Mac.app"), workDirectory: updates, version: "2")
        // A process id that has already exited.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try AppInstaller.scheduleSwap(staged, replacing: target, processID: gone.processIdentifier, openCommand: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, fm.fileExists(atPath: updates.path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(fm.fileExists(atPath: target.appendingPathComponent("marker").path))
        #expect(try fm.contentsOfDirectory(atPath: home.path) == ["V2Mac.app"])
    }

    @Test func corePinAcceptsItsRangeOnly() throws {
        let pin = try #require(CorePin(info: [
            "V2MacCoreVersion": "v26.10.21", "V2MacCoreSHA256": String(repeating: "A", count: 64),
            "V2MacCoreMin": "26.10.21", "V2MacCoreMaxExclusive": "27.0.0",
        ]))
        #expect(pin.accepts("26.10.21") && pin.accepts("Xray 26.12.1 (go)"))
        #expect(!pin.accepts("26.10.17") && !pin.accepts("27.0.0") && !pin.accepts(""))
        #expect(pin.sha256 == String(repeating: "a", count: 64))
        #expect(pin.release.assetURL.absoluteString == "https://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-macos-arm64-v8a.zip")
        #expect(CorePin(info: [:]) == nil)
        #expect(AppInstaller.manifestURL(repository: "o/r", tag: "v1.2.0")?.absoluteString == "https://github.com/o/r/releases/download/v1.2.0/files.json")
    }
}
