import Foundation
import Testing
@testable import V2MacCore

@Suite struct BrewUpdaterTests {
    /// A stand-in `brew` that logs each call (arguments and proxy) to `calls`, offers
    /// `version` in `info`, and fails every call made through a proxy when `failProxy` is set.
    private func fakeBrew(in dir: URL, version: String, failProxy: Bool = false) throws -> (BrewUpdater, URL) {
        let calls = dir.appendingPathComponent("calls")
        let brew = dir.appendingPathComponent("brew")
        let script = """
        #!/bin/sh
        echo "$* | proxy=$all_proxy | auto=$HOMEBREW_NO_AUTO_UPDATE" >> '\(calls.path)'
        \(failProxy ? #"[ -n "$all_proxy" ] && { echo "curl: (7) Failed to connect"; exit 1; }"# : "")
        if [ "$1" = info ]; then
          echo "==> a notice"
          echo '{"formulae":[],"casks":[{"token":"v2mac","version":"\(version)"}]}'
        fi
        exit 0
        """
        try script.write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        return (BrewUpdater(executable: brew), calls)
    }

    @Test func readsTheCaskVersion() {
        let output = "Warning: a notice\n{\"formulae\":[],\"casks\":[{\"version\":\"0.6.0\"}]}"
        #expect(BrewUpdater.caskVersion(Data(output.utf8)) == "0.6.0")
        #expect(BrewUpdater.caskVersion(Data("Error: No available cask".utf8)) == nil)
    }

    @Test func pointsBrewAtTheLocalProxy() {
        let direct = BrewUpdater.proxyEnvironment(for: .direct)
        #expect(direct["ALL_PROXY"] == "" && direct["https_proxy"] == "")
        let env = BrewUpdater.proxyEnvironment(for: .proxy(host: "127.0.0.1", port: 10808, username: "u", password: "p@ss"))
        #expect(env["all_proxy"] == "socks5h://u:p%40ss@127.0.0.1:10808")
        #expect(env["HTTPS_PROXY"] == env["all_proxy"])
        let persian = BrewUpdater.proxyEnvironment(for: .proxy(host: "127.0.0.1", port: 1, username: "علی", password: nil))
        #expect(persian["all_proxy"] == "socks5h://%D8%B9%D9%84%DB%8C@127.0.0.1:1")
    }

    @Test func findsOnlyAnInstalledCask() throws {
        let prefix = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let bin = prefix.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: bin.appendingPathComponent("brew").path)
        #expect(BrewUpdater.locate(prefixes: [prefix]) == nil)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Caskroom/v2mac/0.5.1"), withIntermediateDirectories: true)
        #expect(BrewUpdater.locate(prefixes: [prefix])?.executable.path == bin.appendingPathComponent("brew").path)
    }

    @Test func preparesThroughTheProxyThenDirect() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proxy = FetchRoute.localProxy(port: 10808)

        let (brew, calls) = try fakeBrew(in: dir, version: "0.6.0")
        try await brew.prepare(version: "v0.6.0", routes: [proxy, .direct])
        let lines = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [
            "update --quiet | proxy=socks5h://127.0.0.1:10808 | auto=1",
            "info --cask --json=v2 lordversa/tap/v2mac | proxy=socks5h://127.0.0.1:10808 | auto=1",
            "fetch --cask lordversa/tap/v2mac | proxy=socks5h://127.0.0.1:10808 | auto=1",
        ])

        let failing = dir.appendingPathComponent("failing")
        try FileManager.default.createDirectory(at: failing, withIntermediateDirectories: true)
        let (fallback, fallbackCalls) = try fakeBrew(in: failing, version: "0.6.0", failProxy: true)
        try await fallback.prepare(version: "0.6.0", routes: [proxy, .direct])
        let last = try String(contentsOf: fallbackCalls, encoding: .utf8).split(separator: "\n").last.map(String.init)
        #expect(last == "fetch --cask lordversa/tap/v2mac | proxy= | auto=1")
        await #expect(throws: BrewUpdateError.failed(command: "info", output: "curl: (7) Failed to connect")) {
            try await fallback.prepare(version: "0.6.0", routes: [proxy])
        }
    }

    @Test func acceptsANewerReleaseInTheTap() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (brew, calls) = try fakeBrew(in: dir, version: "0.6.1")
        try await brew.prepare(version: "v0.6.0", routes: [.direct])
        #expect(try String(contentsOf: calls, encoding: .utf8).contains("fetch"))
    }

    @Test func refusesWhenTheTapIsBehind() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (brew, calls) = try fakeBrew(in: dir, version: "0.5.1")
        await #expect(throws: BrewUpdateError.notInTap("0.6.0")) {
            try await brew.prepare(version: "v0.6.0", routes: [.direct])
        }
        #expect(try !String(contentsOf: calls, encoding: .utf8).contains("fetch"))
    }

    @Test func upgradesOnlyAfterTheAppQuits() async throws {
        let fm = FileManager.default
        let dir = try TestSupport.makeTempDirectory()
        defer { try? fm.removeItem(at: dir) }
        let (brew, calls) = try fakeBrew(in: dir, version: "0.6.0")
        let app = dir.appendingPathComponent("V2Mac.app")
        let status = dir.appendingPathComponent("brew-upgrade.status")
        let opened = dir.appendingPathComponent("opened")
        let open = dir.appendingPathComponent("open.sh")
        try "#!/bin/sh\necho \"$1\" > '\(opened.path)'\n".write(to: open, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["60"]
        try running.run()

        try brew.scheduleUpgrade(app: app, processID: running.processIdentifier, statusFile: status, openCommand: open.path)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!fm.fileExists(atPath: calls.path), "brew ran while the app was still open")

        running.terminate()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !fm.fileExists(atPath: opened.path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try String(contentsOf: opened, encoding: .utf8).trimmingCharacters(in: .newlines) == app.path)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "upgrade --cask lordversa/tap/v2mac | proxy= | auto=1\n")
        #expect(BrewUpdater.takeResult(status)?.succeeded == true)
        #expect(BrewUpdater.takeResult(status) == nil)
        #expect(!fm.fileExists(atPath: status.path + ".log"))
    }
}
