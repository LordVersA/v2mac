import Foundation
import Observation
import V2MacCore

/// TUN mode: a root session, started through the managed daemon or the macOS prompt,
/// runs a second Xray that captures all system traffic and feeds it to the core. The same
/// session sets the system proxy and holds the kill switch (`startSession`).
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
    /// The app's run directory, where the helper's flag files go.
    let stateDirectory: URL
    let rootDirectory: URL
    @ObservationIgnored private var starting: Task<LaunchResult, Never>?
    private let primaryInterface: @MainActor (String?) -> String?
    private let authorize: (@MainActor (String) async -> LaunchResult)?
    private let helperIsAlive: @MainActor (URL) -> Bool
    private let interfaceExists: @MainActor (String) -> Bool
    /// The core the helper copies and runs as the forwarder.
    private let core: @MainActor () -> URL
    private var preparationGeneration = 0
    @ObservationIgnored private(set) var privilegedState = PrivilegedSessionState(
        tunEnabled: false, proxyPort: nil, killSwitchEnabled: false, allowedAddresses: []
    )

    func requestSystemProxy(port: Int?) { privilegedState.proxyPort = port }
    func requestKillSwitch(_ enabled: Bool) { privilegedState.killSwitchEnabled = enabled }
    func requestAllowedAddresses(_ addresses: [String]) { privilegedState.allowedAddresses = addresses }

    private var sessionFlag: URL { stateDirectory.appendingPathComponent(TunHelper.sessionFlag) }
    private var onFlag: URL { stateDirectory.appendingPathComponent(TunHelper.onFlag) }

    var isOn: Bool { state == .on }

    /// Short progress note for the connection status line; nil when there is nothing to say.
    var statusNote: String? {
        switch state {
        case .on: String(localized: "System tunnel active")
        case .starting: String(localized: "TUN starting…")
        case .authorizing: String(localized: "TUN waiting for administrator access")
        case .off: isEnabled ? String(localized: "System tunnel inactive") : nil
        case .failed: String(localized: "System tunnel unavailable")
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

    init(logs: LogStore, stateDirectory: URL = AppPaths.runDirectory, rootDirectory: URL = TunHelper.rootDirectory(name: AppPaths.dataFolderName),
         primaryInterface: @escaping @MainActor (String?) -> String? = { NetworkInterfaces.primary(excluding: $0) },
         authorize: (@MainActor (String) async -> LaunchResult)? = nil,
         helperIsAlive: @escaping @MainActor (URL) -> Bool = { TunHelper.isAlive(rootDirectory: $0) },
         interfaceExists: @escaping @MainActor (String) -> Bool = { NetworkInterfaces.exists($0) },
         core: @escaping @MainActor () -> URL = { AppPaths.coreExecutable }) {
        self.logs = logs
        self.stateDirectory = stateDirectory
        self.rootDirectory = rootDirectory
        self.primaryInterface = primaryInterface
        self.authorize = authorize
        self.helperIsAlive = helperIsAlive
        self.interfaceExists = interfaceExists
        self.core = core
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
            fail(String(localized: "TUN mode is waiting for a network connection."))
            return nil
        }
        if !isSessionAlive {
            watcher?.cancel()
            state = .authorizing
        }
        let result = await startSession()
        guard preparationGeneration == generation, isEnabled, !Task.isCancelled else { return nil }
        switch result {
        case .cancelled:
            fail(String(localized: "Administrator access was cancelled; the system tunnel is inactive."))
            return nil
        case .failed(let message):
            fail(String(localized: "TUN mode could not start: \(message)"))
            return nil
        case .started:
            guard let port else { return nil }
            if state == .authorizing { state = .off }
            return TunLink(port: port, outboundInterface: primary, resolvers: NetworkInterfaces.dnsServers())
        }
    }

    var isSessionAlive: Bool { port != nil && helperIsAlive(rootDirectory) }

    /// One root session serves TUN, proxy and firewall. Signed builds use SMAppService;
    /// ad-hoc builds use the system dialog. Concurrent callers share one start.
    func startSession() async -> LaunchResult {
        if isSessionAlive { return .started }
        if let starting { return await starting.value }
        let task = Task { await launchSession() }
        starting = task
        let result = await task.value
        starting = nil
        return result
    }

    private func launchSession() async -> LaunchResult {
        port = nil
        interfaceName = nil
        do {
            let newPort = Self.pickPort()
            let name = NetworkInterfaces.freeUtunName()
            let authorization: LaunchResult
            if authorize == nil, PrivilegedHelperService.shared.isSupported {
                try prepareSessionFlags()
                logs.append("[v2mac] Starting the managed privileged helper")
                authorization = await PrivilegedHelperService.shared.startSession(port: newPort, interfaceName: name, snapshot: { [weak self] in
                    self?.privilegedState ?? PrivilegedSessionState(tunEnabled: false, proxyPort: nil, killSwitchEnabled: false, allowedAddresses: [])
                }) { [weak self] message in
                    self?.port = nil
                    self?.interfaceName = nil
                    if let self { try? FileManager.default.removeItem(at: stateDirectory.appendingPathComponent(KillSwitch.flag)) }
                    self?.fail(message)
                }
            } else {
                let command = try await sessionCommand(port: newPort, interface: name)
                logs.append("[v2mac] Asking macOS for administrator access")
                if let authorize { authorization = await authorize(command) }
                else { authorization = await Self.runAsRoot(command) }
            }
            guard case .started = authorization else {
                try? FileManager.default.removeItem(at: sessionFlag)
                return authorization
            }
            guard await helperAppeared() else {
                try? FileManager.default.removeItem(at: sessionFlag)
                return .failed(String(localized: "The helper did not start."))
            }
            port = newPort
            interfaceName = name
            return .started
        } catch {
            try? FileManager.default.removeItem(at: sessionFlag)
            return .failed(error.localizedDescription)
        }
    }

    /// Brings the TUN up. The core must already be listening on the session's port.
    func up() {
        guard port != nil, let name = interfaceName else { return }
        guard FileManager.default.createFile(atPath: onFlag.path, contents: nil) else {
            fail(String(localized: "TUN mode could not start: its request file could not be written."))
            return
        }
        privilegedState.tunEnabled = true
        if state != .on { state = .starting }
        watcher?.cancel()
        watcher = Task { [weak self] in await self?.watch(name) }
    }

    /// Takes the TUN down; the helper stays for the next connect.
    func down(clearingError: Bool = false) {
        privilegedState.tunEnabled = false
        preparationGeneration += 1
        watcher?.cancel()
        watcher = nil
        try? FileManager.default.removeItem(at: onFlag)
        if case .failed = state, !clearingError { return }
        if state == .on { logs.append("[v2mac] TUN mode is off") }
        state = .off
    }

    /// Ends the helper too; used on quit.
    func endSession() async {
        down()
        removeFlags()
        if authorize == nil { await PrivilegedHelperService.shared.endSession() }
        port = nil
        interfaceName = nil
    }

    // MARK: Internals

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
                fail(String(localized: "The TUN helper stopped. Reconnect to start it again."))
                return
            } else if state == .on {
                // The helper restarts a forwarder that died; give it time.
                state = .starting
                deadline = ContinuousClock.now + .seconds(8)
            } else if ContinuousClock.now > deadline {
                let detail = TunHelper.failureDetail(rootDirectory: rootDirectory)
                try? FileManager.default.removeItem(at: onFlag)
                fail(detail.map { String(localized: "TUN mode could not start: \($0)") } ?? String(localized: "TUN mode could not start."))
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
        privilegedState = PrivilegedSessionState(tunEnabled: false, proxyPort: nil, killSwitchEnabled: false, allowedAddresses: [])
        for name in [TunHelper.onFlag, TunHelper.sessionFlag, SystemProxy.flag, KillSwitch.flag, KillSwitch.allowFile] {
            try? FileManager.default.removeItem(at: stateDirectory.appendingPathComponent(name))
        }
    }

    /// A stable port outside the range the system hands to outgoing connections, so it is
    /// still free each time the core restarts during the session.
    private static func pickPort() -> Int {
        let preferred = (10890...10990).first { $0 != Prefs.port && PortUtil.isFree(port: $0) }
        return preferred ?? (try? PortUtil.freePort()) ?? 10890
    }

    private func sessionCommand(port: Int, interface: String) async throws -> String {
        let core = core()
        let coreSHA256 = try await TunHelper.sha256(of: core)
        let config = try ConfigBuilder.tunForwarder(interfaceName: interface, corePort: port, logLevel: .warning).data()
        try prepareSessionFlags()
        return TunHelper.launchCommand(
            appPID: ProcessInfo.processInfo.processIdentifier, stateDirectory: stateDirectory,
            core: core, coreSHA256: coreSHA256, config: String(decoding: config, as: UTF8.self), rootDirectory: rootDirectory,
            killSwitchRules: KillSwitch.rules(tunInterface: interface), killSwitchAnchor: KillSwitch.anchor(name: AppPaths.dataFolderName),
            killSwitchMarker: KillSwitch.marker(name: AppPaths.dataFolderName)
        )
    }

    private func prepareSessionFlags() throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A helper that is gone left its TUN flag; the proxy and kill switch requests stay.
        if FileManager.default.fileExists(atPath: onFlag.path) { try FileManager.default.removeItem(at: onFlag) }
        try Data().write(to: sessionFlag, options: .atomic)
    }

    private func helperAppeared() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if helperIsAlive(rootDirectory) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// macOS handles administrator authentication; V2Mac never receives the password.
    static func runAsRoot(_ command: String) async -> LaunchResult {
        let prompt = String(localized: "V2Mac needs administrator access for TUN mode, the system proxy or the kill switch.")
        guard AdminConsent.confirm() else { return .cancelled }
        return await osascript(TunHelper.appleScript(command: command, prompt: prompt))
    }

    /// Pass the helper command through standard input rather than process arguments.
    static func osascript(_ source: String) async -> LaunchResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let errors = Pipe()
            let input = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = input
            process.terminationHandler = { finished in
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: .started)
                } else if text.contains("-128") {
                    continuation.resume(returning: .cancelled)
                } else {
                    let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: .failed(detail.isEmpty ? String(localized: "The administrator prompt failed.") : detail))
                }
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(source.utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }
}
