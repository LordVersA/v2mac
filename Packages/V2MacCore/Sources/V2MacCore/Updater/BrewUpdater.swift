import Foundation

public enum BrewUpdateError: Error, Sendable, Equatable, LocalizedError {
    /// A `brew` command exited with an error; `output` is its last line.
    case failed(command: String, output: String)
    /// Homebrew's cask does not offer the release yet.
    case notInTap(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let command, let output):
            output.isEmpty ? "brew \(command) failed." : "brew \(command) failed: \(output)"
        case .notInTap(let version):
            "Homebrew does not offer V2Mac \(version) yet. Try again later."
        }
    }
}

/// Updates a copy of the app that Homebrew installed, through `brew` so that Homebrew keeps
/// track of the version (spec 11.3).
public struct BrewUpdater: Sendable, Equatable {
    /// The cask in the project's own tap (LordVersA/homebrew-tap).
    public static let cask = "lordversa/tap/v2mac"
    static let token = "v2mac"
    public static let defaultPrefixes = ["/opt/homebrew", "/usr/local"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    public var executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// The Homebrew installation that has the cask installed, if any.
    public static func locate(prefixes: [URL] = defaultPrefixes) -> BrewUpdater? {
        let fm = FileManager.default
        for prefix in prefixes {
            let brew = prefix.appendingPathComponent("bin/brew")
            var isDirectory: ObjCBool = false
            if fm.isExecutableFile(atPath: brew.path),
               fm.fileExists(atPath: prefix.appendingPathComponent("Caskroom/\(token)").path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return BrewUpdater(executable: brew)
            }
        }
        return nil
    }

    /// Variables that make curl and git, and so `brew`, connect through `route`. The direct
    /// route clears any proxy the app inherited, so it really is direct.
    public static func proxyEnvironment(for route: FetchRoute) -> [String: String] {
        let names = ["all_proxy", "http_proxy", "https_proxy", "ALL_PROXY", "HTTP_PROXY", "HTTPS_PROXY"]
        guard case .proxy(let host, let port, let username, let password) = route else {
            return Dictionary(uniqueKeysWithValues: names.map { ($0, "") })
        }
        // ASCII only: `.alphanumerics` would let other scripts' letters through unencoded.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encoded(_ part: String) -> String {
            part.addingPercentEncoding(withAllowedCharacters: unreserved) ?? part
        }
        var credentials = ""
        if let username {
            credentials = encoded(username) + (password.map { ":" + encoded($0) } ?? "") + "@"
        }
        let url = "socks5h://\(credentials)\(host):\(port)"
        return Dictionary(uniqueKeysWithValues: names.map { ($0, url) })
    }

    /// Settings for every `brew` call: no hints, and no update of its own after `prepare` did one.
    static let quiet = ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_AUTO_UPDATE": "1"]

    /// The longest a single `brew` call may take, so a stalled route cannot lock Update Now.
    static let callTimeout: Duration = .seconds(600)

    /// Refreshes Homebrew and downloads `version` into its cache, trying each route in turn.
    /// Run it while the app is still open, so the local proxy can carry the downloads.
    /// Nothing is installed.
    public func prepare(version: String, routes: [FetchRoute]) async throws {
        var lastError: Error = BrewUpdateError.failed(command: "update", output: "")
        var updated = false
        for route in routes.isEmpty ? [.direct] : routes {
            do {
                try await prepare(version: version, environment: Self.proxyEnvironment(for: route), updated: &updated)
                return
            } catch BrewUpdateError.notInTap(let version) {
                throw BrewUpdateError.notInTap(version)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// `updated` is set once `brew update` succeeds, so a later route does not repeat it.
    private func prepare(version: String, environment: [String: String], updated: inout Bool) async throws {
        let environment = environment.merging(Self.quiet) { _, quiet in quiet }
        // A broken unrelated tap makes `update` fail; what matters is whether the cask has the version.
        let update = updated ? nil : try await brew(["update", "--quiet"], environment)
        if update?.status == 0 { updated = true }
        let info = try await brew(["info", "--cask", "--json=v2", Self.cask], environment)
        guard info.status == 0 else { throw Self.failure("info", info.output) }
        // A newer release in the tap is fine: `brew upgrade` installs that one.
        guard let offered = Self.caskVersion(Data(info.output.utf8)), !VersionCompare.isNewer(version, than: offered) else {
            if let update, update.status != 0 { throw Self.failure("update", update.output) }
            throw BrewUpdateError.notInTap(VersionCompare.normalized(version))
        }
        let fetch = try await brew(["fetch", "--cask", Self.cask], environment)
        guard fetch.status == 0 else { throw Self.failure("fetch", fetch.output) }
    }

    private func brew(_ arguments: [String], _ environment: [String: String]) async throws -> (status: Int32, output: String) {
        try await CoreUpdater.run(executable.path, arguments, environment: environment, timeout: Self.callTimeout)
    }

    private static func failure(_ command: String, _ output: String) -> BrewUpdateError {
        let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return .failed(command: command, output: last.trimmingCharacters(in: .whitespaces))
    }

    /// The version in `brew info --cask --json=v2` output.
    static func caskVersion(_ data: Data) -> String? {
        struct Info: Decodable {
            struct Cask: Decodable { var version: String }
            var casks: [Cask]
        }
        // `brew` can print notices before the JSON.
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let info = try? JSONDecoder().decode(Info.self, from: data[start...]) else { return nil }
        return info.casks.first.map { VersionCompare.normalized($0.version) }
    }

    // MARK: Upgrade

    /// Waits for the running app (`$1`) to exit, so that `brew` neither has to quit it nor skips
    /// quitting it (it does when it runs inside the app), upgrades the cask (`$3`) from the cache
    /// with `brew` (`$2`), writes its exit status to `$5` and its output to `$5.log`, and opens
    /// the app (`$4`) with the command in `$6`, updated or not.
    public static let upgradeScript = """
    #!/bin/sh
    APP_PID="$1"; BREW="$2"; CASK="$3"; APP="$4"; STATUS="$5"; OPEN="$6"

    n=0
    while kill -0 "$APP_PID" 2>/dev/null; do
      n=$((n + 1))
      [ "$n" -gt 300 ] && exit 1
      sleep 0.2
    done

    "$BREW" upgrade --cask "$CASK" >"$STATUS.log" 2>&1
    echo "$?" >"$STATUS"
    rm -f "$0"
    "$OPEN" "$APP"

    """

    /// Starts the upgrade script detached. The caller then quits the app, which lets it proceed.
    public func scheduleUpgrade(
        app: URL,
        processID: Int32,
        statusFile: URL,
        openCommand: String = "/usr/bin/open"
    ) throws {
        try? FileManager.default.removeItem(at: statusFile)
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-brew-\(UUID().uuidString).sh")
        try Self.upgradeScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "\(processID)", executable.path, Self.cask, app.path, statusFile.path, openCommand]
        process.environment = ProcessInfo.processInfo.environment.merging(Self.quiet) { _, quiet in quiet }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// The result the upgrade script left behind, with the last line of `brew`'s output; both
    /// files are removed once read. Nil when there is none.
    public static func takeResult(_ statusFile: URL) -> (succeeded: Bool, lastLine: String)? {
        let log = URL(fileURLWithPath: statusFile.path + ".log")
        defer { try? FileManager.default.removeItem(at: log) }
        guard let text = try? String(contentsOf: statusFile, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: statusFile)
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let last = output.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return (text.trimmingCharacters(in: .whitespacesAndNewlines) == "0", last)
    }
}
