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
    private(set) var isEnabled = Prefs.tunEnabled
    /// The session's `utunN`; the lifecycle monitor ignores it as a network change.
    private(set) var interfaceName: String?

    private let logs: LogStore
    private var port: Int?
    private var watcher: Task<Void, Never>?
    private let stateDirectory = AppPaths.runDirectory
    private let rootDirectory = TunHelper.rootDirectory()

    private var sessionFlag: URL { stateDirectory.appendingPathComponent(TunHelper.sessionFlag) }
    private var onFlag: URL { stateDirectory.appendingPathComponent(TunHelper.onFlag) }

    var isOn: Bool { state == .on }

    /// Short progress note for the connection status line; nil when there is nothing to say.
    var statusNote: String? {
        switch state {
        case .on: "TUN"
        case .starting: "TUN starting…"
        case .authorizing: "TUN waiting for administrator access"
        case .off, .failed: nil
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

    init(logs: LogStore) {
        self.logs = logs
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
    /// Nil means "connect without TUN": the prompt was cancelled, or something failed.
    func prepare() async -> TunLink? {
        guard let primary = NetworkInterfaces.primary(excluding: interfaceName) else {
            fail("TUN mode is waiting for a network connection.")
            return nil
        }
        if let port, TunHelper.isAlive(rootDirectory: rootDirectory) {
            return TunLink(port: port, outboundInterface: primary)
        }

        watcher?.cancel()
        port = nil
        interfaceName = nil
        do {
            let newPort = Self.pickPort()
            let name = NetworkInterfaces.freeUtunName()
            let command = try writeSessionFiles(port: newPort, interface: name)
            state = .authorizing
            logs.append("[v2mac] TUN mode: asking for administrator access")
            switch await Self.runAsRoot(command) {
            case .cancelled:
                logs.append("[v2mac] TUN mode: administrator access was not given, TUN mode is off")
                removeFlags()
                setEnabled(false)
                return nil
            case .failed(let message):
                throw TunError(message: message)
            case .started:
                break
            }
            guard await helperAppeared() else {
                throw TunError(message: "The TUN helper did not start.")
            }
            port = newPort
            interfaceName = name
            state = .off
            return TunLink(port: newPort, outboundInterface: primary)
        } catch {
            removeFlags()
            fail("TUN mode could not start: \(error.localizedDescription)")
            return nil
        }
    }

    /// Brings the TUN up. The core must already be listening on the session's port.
    func up() {
        guard port != nil, let name = interfaceName else { return }
        FileManager.default.createFile(atPath: onFlag.path, contents: nil)
        if state != .on { state = .starting }
        watcher?.cancel()
        watcher = Task { [weak self] in await self?.watch(name) }
    }

    /// Takes the TUN down; the helper stays for the next connect.
    func down(clearingError: Bool = false) {
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

    private enum LaunchResult {
        case started, cancelled
        case failed(String)
    }

    /// Follows the interface: reports it up, reports a start that never happens, and notices
    /// a helper that went away.
    private func watch(_ name: String) async {
        var deadline = ContinuousClock.now + .seconds(8)
        while !Task.isCancelled {
            if NetworkInterfaces.exists(name) {
                if state != .on {
                    state = .on
                    logs.append("[v2mac] TUN mode is on (\(name))")
                }
            } else if !TunHelper.isAlive(rootDirectory: rootDirectory) {
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

    private func writeSessionFiles(port: Int, interface: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = stateDirectory.appendingPathComponent("tun-helper.sh")
        let config = stateDirectory.appendingPathComponent("tun-config.json")
        try TunHelper.script.write(to: script, atomically: true, encoding: .utf8)
        try ConfigBuilder.tunForwarder(interfaceName: interface, corePort: port, logLevel: .warning)
            .data(pretty: true).write(to: config, options: .atomic)
        removeFlags()
        fm.createFile(atPath: sessionFlag.path, contents: nil)
        return TunHelper.launchCommand(
            script: script, appPID: ProcessInfo.processInfo.processIdentifier, stateDirectory: stateDirectory,
            core: AppPaths.coreExecutable, config: config, rootDirectory: rootDirectory
        )
    }

    private func helperAppeared() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if TunHelper.isAlive(rootDirectory: rootDirectory) { return true }
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
