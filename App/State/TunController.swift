import Foundation
import Observation
import V2MacCore

/// TUN mode: a root helper, started once per app session after the administrator prompt,
/// runs a second Xray that captures all system traffic and feeds it to the core.
@MainActor @Observable
final class TunController {
    enum State: Equatable {
        case off
        /// The administrator prompt is on screen.
        case authorizing
        case starting
        case on
        case failed(String)
    }

    private(set) var state: State = .off
    /// TUN mode could not start or went down by itself (spec 12.6).
    @ObservationIgnored var onFailure: @MainActor (String) -> Void = { _ in }
    private(set) var isEnabled = Prefs.tunEnabled
    /// The session's `utunN`; the lifecycle monitor ignores it as a network change.
    private(set) var interfaceName: String?

    private let logs: LogStore
    private var port: Int?
    private var watcher: Task<Void, Never>?
    private let stateDirectory: URL
    private let rootDirectory: URL
    private let primaryInterface: @MainActor (String?) -> String?
    private let authorize: @MainActor (String) async -> LaunchResult
    private let helperIsAlive: @MainActor (URL) -> Bool
    private let interfaceExists: @MainActor (String) -> Bool
    private var preparationGeneration = 0

    private var sessionFlag: URL { stateDirectory.appendingPathComponent(TunHelper.sessionFlag) }
    private var onFlag: URL { stateDirectory.appendingPathComponent(TunHelper.onFlag) }

    var isOn: Bool { state == .on }

    /// Short progress note for the connection status line; nil when there is nothing to say.
    var statusNote: String? {
        switch state {
        case .on: "System tunnel active"
        case .starting: "TUN starting…"
        case .authorizing: "TUN waiting for administrator access"
        case .off: isEnabled ? "System tunnel inactive" : nil
        case .failed: "System tunnel unavailable"
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// The interface latency tests must use while the TUN is up, so they measure the servers
    /// and not the tunnel.
    var physicalInterface: String? {
        switch state {
        case .on, .starting: NetworkInterfaces.primary(excluding: interfaceName)
        default: nil
        }
    }

    init(logs: LogStore, stateDirectory: URL = AppPaths.runDirectory, rootDirectory: URL = TunHelper.rootDirectory(),
         primaryInterface: @escaping @MainActor (String?) -> String? = { NetworkInterfaces.primary(excluding: $0) },
         authorize: @escaping @MainActor (String) async -> LaunchResult = { await runAsRoot($0) },
         helperIsAlive: @escaping @MainActor (URL) -> Bool = { TunHelper.isAlive(rootDirectory: $0) },
         interfaceExists: @escaping @MainActor (String) -> Bool = { NetworkInterfaces.exists($0) }) {
        self.logs = logs
        self.stateDirectory = stateDirectory
        self.rootDirectory = rootDirectory
        self.primaryInterface = primaryInterface
        self.authorize = authorize
        self.helperIsAlive = helperIsAlive
        self.interfaceExists = interfaceExists
        // Flags left by a crash would start a new helper with the TUN already wanted.
        removeFlags()
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        Prefs.tunEnabled = on
        if !on { down(clearingError: true) }
    }

    // MARK: Session

    /// Makes sure the helper is running and returns what the core config needs.
    /// The connection controller applies the user's failure policy when this returns nil.
    func prepare() async -> TunLink? {
        let generation = preparationGeneration
        guard let primary = primaryInterface(interfaceName) else {
            fail("TUN mode is waiting for a network connection.")
            return nil
        }
        if let port, helperIsAlive(rootDirectory) {
            return TunLink(port: port, outboundInterface: primary)
        }

        watcher?.cancel()
        port = nil
        interfaceName = nil
        do {
            let newPort = Self.pickPort()
            let name = NetworkInterfaces.freeUtunName()
            let command = try await sessionCommand(port: newPort, interface: name)
            state = .authorizing
            logs.append("[v2mac] TUN mode: asking for administrator access")
            let authorization = await authorize(command)
            guard preparationGeneration == generation, isEnabled else { removeFlags(); return nil }
            switch authorization {
            case .cancelled:
                removeFlags()
                fail("Administrator access was cancelled; the system tunnel is inactive.")
                return nil
            case .failed(let message):
                throw TunError(message: message)
            case .started:
                break
            }
            guard await helperAppeared() else {
                throw TunError(message: "The TUN helper did not start.")
            }
            guard isEnabled, !Task.isCancelled else { removeFlags(); return nil }
            port = newPort
            interfaceName = name
            state = .off
            return TunLink(port: newPort, outboundInterface: primary)
        } catch {
            removeFlags()
            guard preparationGeneration == generation, isEnabled else { return nil }
            fail("TUN mode could not start: \(error.localizedDescription)")
            return nil
        }
    }

    /// Brings the TUN up. The core must already be listening on the session's port.
    func up() {
        guard port != nil, let name = interfaceName else { return }
        guard FileManager.default.createFile(atPath: onFlag.path, contents: nil) else {
            fail("TUN mode could not start: its request file could not be written.")
            return
        }
        if state != .on { state = .starting }
        watcher?.cancel()
        watcher = Task { [weak self] in await self?.watch(name) }
    }

    /// Takes the TUN down; the helper stays for the next connect.
    func down(clearingError: Bool = false) {
        preparationGeneration += 1
        watcher?.cancel()
        watcher = nil
        try? FileManager.default.removeItem(at: onFlag)
        if case .failed = state, !clearingError { return }
        if state == .on { logs.append("[v2mac] TUN mode is off") }
        state = .off
    }

    /// Ends the helper too; used on quit.
    func endSession() {
        down()
        removeFlags()
        port = nil
        interfaceName = nil
    }

    // MARK: Internals

    private struct TunError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum LaunchResult {
        case started, cancelled
        case failed(String)
    }

    /// Follows the interface: reports it up, reports a start that never happens, and notices
    /// a helper that went away.
    private func watch(_ name: String) async {
        var deadline = ContinuousClock.now + .seconds(8)
        while !Task.isCancelled {
            if interfaceExists(name) {
                if state != .on {
                    state = .on
                    logs.append("[v2mac] TUN mode is on (\(name))")
                }
            } else if !helperIsAlive(rootDirectory) {
                port = nil
                interfaceName = nil
                try? FileManager.default.removeItem(at: onFlag)
                fail("The TUN helper stopped. Reconnect to start it again.")
                return
            } else if state == .on {
                // The helper restarts a forwarder that died; give it time.
                state = .starting
                deadline = ContinuousClock.now + .seconds(8)
            } else if ContinuousClock.now > deadline {
                let detail = TunHelper.failureDetail(rootDirectory: rootDirectory)
                try? FileManager.default.removeItem(at: onFlag)
                fail("TUN mode could not start" + (detail.map { ": \($0)" } ?? "."))
                return
            }
            try? await Task.sleep(for: state == .on ? .seconds(2) : .milliseconds(200))
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        logs.append("[v2mac] \(message)")
        onFailure(message)
    }

    private func removeFlags() {
        try? FileManager.default.removeItem(at: onFlag)
        try? FileManager.default.removeItem(at: sessionFlag)
    }

    /// A stable port outside the range the system hands to outgoing connections, so it is
    /// still free each time the core restarts during the session.
    private static func pickPort() -> Int {
        let preferred = (10890...10990).first { $0 != Prefs.port && PortUtil.isFree(port: $0) }
        return preferred ?? (try? PortUtil.freePort()) ?? 10890
    }

    private func sessionCommand(port: Int, interface: String) async throws -> String {
        let core = AppPaths.coreExecutable
        let coreSHA256 = try await TunHelper.sha256(of: core)
        let config = try ConfigBuilder.tunForwarder(interfaceName: interface, corePort: port, logLevel: .warning).data()
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        removeFlags()
        FileManager.default.createFile(atPath: sessionFlag.path, contents: nil)
        return TunHelper.launchCommand(
            appPID: ProcessInfo.processInfo.processIdentifier, stateDirectory: stateDirectory,
            core: core, coreSHA256: coreSHA256, config: String(decoding: config, as: UTF8.self), rootDirectory: rootDirectory
        )
    }

    private func helperAppeared() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if helperIsAlive(rootDirectory) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Runs `command` as root through the system's administrator prompt.
    private static func runAsRoot(_ command: String) async -> LaunchResult {
        let source = TunHelper.appleScript(
            command: command,
            prompt: "V2Mac needs administrator access to turn on TUN mode, which routes all traffic on this Mac through the proxy."
        )
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: .started)
                } else if text.contains("-128") {
                    continuation.resume(returning: .cancelled)
                } else {
                    let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: .failed(detail.isEmpty ? "The administrator prompt failed." : detail))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }
}
