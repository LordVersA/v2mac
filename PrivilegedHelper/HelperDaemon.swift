import CryptoKit
import Darwin
import Foundation
import V2MacCore

/// Serializes sessions by UID. All request files and executable copies are root-owned.
final class HelperCoordinator: @unchecked Sendable {
    private final class Session {
        let token: UUID
        let process: Process
        let directory: URL
        var stopping = false
        var state: PrivilegedSessionState
        var completions: [@Sendable (String?) -> Void] = []

        init(token: UUID, process: Process, directory: URL, state: PrivilegedSessionState) {
            self.token = token
            self.process = process
            self.directory = directory
            self.state = state
        }
    }

    private let queue = DispatchQueue(label: "v2mac.privileged-sessions")
    private var sessions: [uid_t: Session] = [:]
    private var clients: Set<UUID> = []
    private var isShuttingDown = false
    private let appBundle: URL
    private let team: String

    init(appBundle: URL, team: String) {
        self.appBundle = appBundle
        self.team = team
    }

    func connected(_ token: UUID) { queue.async { self.clients.insert(token) } }

    func disconnected(uid: uid_t, token: UUID) {
        queue.async {
            guard self.clients.remove(token) != nil else { return }
            guard let session = self.sessions[uid], session.token == token else { return }
            // A lost client preserves an armed kill switch, matching crash protection.
            if session.process.isRunning { session.process.terminate() }
        }
    }

    func start(uid: uid_t, pid: pid_t, token: UUID, port: Int, interface: String, data: Data,
               attempts: Int = 50, reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            var preparedDirectory: URL?
            do {
                guard !self.isShuttingDown, self.clients.contains(token), uid != 0, pid > 1 else { throw CocoaError(.executableLoad) }
                try PrivilegedSessionState.validate(port: port, interfaceName: interface)
                let state = try PrivilegedSessionState.decode(data)
                if let previous = self.sessions.values.first {
                    guard attempts > 0, previous.stopping || !self.clients.contains(previous.token) else { throw CocoaError(.executableLoad) }
                    self.queue.asyncAfter(deadline: .now() + 0.1) {
                        self.start(uid: uid, pid: pid, token: token, port: port, interface: interface, data: data,
                                   attempts: attempts - 1, reply: reply)
                    }
                    return
                }
                guard !NetworkInterfaces.exists(interface) else { throw CocoaError(.coderInvalidValue) }
                let fm = FileManager.default
                let root = TunHelper.rootDirectory(name: PrivilegedHelperIdentity.dataFolderName, uid: uid)
                let deadline = Date.now.addingTimeInterval(5)
                while TunHelper.isAlive(rootDirectory: root), Date.now < deadline { Thread.sleep(forTimeInterval: 0.1) }
                guard !TunHelper.isAlive(rootDirectory: root) else { throw CocoaError(.executableLoad) }
                let directory = URL(fileURLWithPath: "/var/run/\(PrivilegedHelperIdentity.dataFolderName)-privileged-\(uid)", isDirectory: true)
                if fm.fileExists(atPath: directory.path) {
                    let attributes = try fm.attributesOfItem(atPath: directory.path)
                    guard attributes[.type] as? FileAttributeType == .typeDirectory,
                          attributes[.ownerAccountID] as? Int == 0 else { throw CocoaError(.fileWriteNoPermission) }
                    try fm.removeItem(at: directory)
                }
                try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                preparedDirectory = directory
                let copiedCore = directory.appendingPathComponent("xray")
                try fm.copyItem(at: self.appBundle.appendingPathComponent("Contents/Helpers/xray"), to: copiedCore)
                guard try fm.attributesOfItem(atPath: copiedCore.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw CocoaError(.executableNotLoadable)
                }
                try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o700], ofItemAtPath: copiedCore.path)
                // Validate the root-owned copy, so a source swap cannot become root execution.
                try PeerCodeSigning.validate(copiedCore, identifier: PrivilegedHelperIdentity.appIdentifier + ".xray", team: self.team)
                let hash = SHA256.hash(data: try Data(contentsOf: copiedCore)).map { String(format: "%02x", $0) }.joined()
                let requests = directory.appendingPathComponent("requests", isDirectory: true)
                try fm.createDirectory(at: requests, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try state.write(to: requests)
                try Data().write(to: requests.appendingPathComponent(TunHelper.sessionFlag))
                let config = try ConfigBuilder.tunForwarder(interfaceName: interface, corePort: port, logLevel: .warning).data()
                let name = PrivilegedHelperIdentity.dataFolderName
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", TunHelper.script, "v2mac-managed-session", "\(pid)", requests.path, copiedCore.path, hash,
                                     String(decoding: config, as: UTF8.self), TunHelper.rootDirectory(name: name, uid: uid).path,
                                     KillSwitch.rules(tunInterface: interface), KillSwitch.anchor(name: name), KillSwitch.marker(name: name, uid: uid).path]
                process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root", "LC_ALL": "C"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let coordinator = self
                process.terminationHandler = { [weak coordinator] _ in coordinator?.finished(uid: uid, token: token) }
                let session = Session(token: token, process: process, directory: directory, state: state)
                self.sessions[uid] = session
                do { try process.run() }
                catch { self.sessions.removeValue(forKey: uid); throw error }
                reply(nil)
            } catch {
                if let preparedDirectory { try? FileManager.default.removeItem(at: preparedDirectory) }
                reply(error.localizedDescription)
            }
        }
    }

    func update(uid: uid_t, token: UUID, data: Data, reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                guard let session = self.sessions[uid], session.token == token, !session.stopping,
                      session.process.isRunning else { throw CocoaError(.executableLoad) }
                let next = try PrivilegedSessionState.decode(data)
                let requests = session.directory.appendingPathComponent("requests")
                if next.killSwitchEnabled, session.state.killSwitchEnabled,
                   !FileManager.default.fileExists(atPath: requests.appendingPathComponent(KillSwitch.flag).path) {
                    let error = TunHelper.rootDirectory(name: PrivilegedHelperIdentity.dataFolderName, uid: uid).appendingPathComponent(KillSwitch.errorFile)
                    reply((try? String(contentsOf: error, encoding: .utf8)) ?? "The firewall rules could not be loaded.")
                    return
                }
                if next != session.state { try next.write(to: requests); session.state = next }
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    func stop(uid: uid_t, token: UUID, reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            guard let session = self.sessions[uid], session.token == token else { reply(nil); return }
            session.completions.append(reply)
            self.stop(session)
        }
    }

    private func stop(_ session: Session) {
        guard !session.stopping else { return }
        session.stopping = true
        do {
            let requests = session.directory.appendingPathComponent("requests")
            try PrivilegedSessionState(tunEnabled: false, proxyPort: nil, killSwitchEnabled: false, allowedAddresses: []).write(to: requests)
            try FileManager.default.removeItem(at: requests.appendingPathComponent(TunHelper.sessionFlag))
            if session.process.isRunning { session.process.terminate() }
        } catch {
            if session.process.isRunning { session.process.terminate() }
            let completions = session.completions
            session.completions = []
            completions.forEach { $0(error.localizedDescription) }
        }
    }

    private func finished(uid: uid_t, token: UUID) {
        queue.async {
            guard let session = self.sessions[uid], session.token == token else { return }
            self.sessions.removeValue(forKey: uid)
            try? FileManager.default.removeItem(at: session.directory)
            session.completions.forEach { $0(nil) }
            if self.isShuttingDown, self.sessions.isEmpty { exit(EXIT_SUCCESS) }
        }
    }

    func shutdown() {
        queue.async {
            self.isShuttingDown = true
            if self.sessions.isEmpty { exit(EXIT_SUCCESS) }
            self.sessions.values.forEach { self.stop($0) }
        }
    }

    func exitIfIdle() {
        queue.async {
            if self.clients.isEmpty, self.sessions.isEmpty { exit(EXIT_SUCCESS) }
        }
    }
}

final class HelperSession: NSObject, PrivilegedHelperProtocol, @unchecked Sendable {
    let uid: uid_t
    let pid: pid_t
    let token = UUID()
    let coordinator: HelperCoordinator

    init(uid: uid_t, pid: pid_t, coordinator: HelperCoordinator) {
        self.uid = uid
        self.pid = pid
        self.coordinator = coordinator
    }

    func startSession(port: Int, interfaceName: String, state: Data, withReply reply: @escaping @Sendable (String?) -> Void) {
        coordinator.start(uid: uid, pid: pid, token: token, port: port, interface: interfaceName, data: state, reply: reply)
    }

    func updateSession(state: Data, withReply reply: @escaping @Sendable (String?) -> Void) {
        coordinator.update(uid: uid, token: token, data: state, reply: reply)
    }

    func stopSession(withReply reply: @escaping @Sendable (String?) -> Void) {
        coordinator.stop(uid: uid, token: token, reply: reply)
    }
}

final class HelperListener: NSObject, NSXPCListenerDelegate {
    let coordinator: HelperCoordinator
    init(coordinator: HelperCoordinator) { self.coordinator = coordinator }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        let session = HelperSession(uid: connection.effectiveUserIdentifier, pid: connection.processIdentifier, coordinator: coordinator)
        coordinator.connected(session.token)
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [coordinator] in coordinator.disconnected(uid: session.uid, token: session.token) }
        connection.interruptionHandler = { [coordinator] in coordinator.disconnected(uid: session.uid, token: session.token) }
        connection.resume()
        return true
    }
}

@main enum PrivilegedHelperMain {
    static func main() {
        guard let executable = Bundle.main.executableURL else { exit(EXIT_FAILURE) }
        let appBundle = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // Packaging check is safe to run without registering or elevating the helper.
        if CommandLine.arguments.contains("--check-bundle") {
            let plist = appBundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(PrivilegedHelperIdentity.plistName)")
            guard Bundle(url: appBundle)?.bundleIdentifier == PrivilegedHelperIdentity.appIdentifier,
                  FileManager.default.fileExists(atPath: plist.path),
                  FileManager.default.isExecutableFile(atPath: appBundle.appendingPathComponent("Contents/Helpers/xray").path),
                  (try? PeerCodeSigning.requirement(identifier: PrivilegedHelperIdentity.appIdentifier, team: "TESTTEAM12")) != nil
            else { exit(EXIT_FAILURE) }
            print("Privileged helper bundle layout and signing requirement are valid.")
            return
        }
        guard geteuid() == 0, let team = PeerCodeSigning.teamIdentifier() else { exit(EXIT_FAILURE) }
        let coordinator = HelperCoordinator(appBundle: appBundle, team: team)
        let delegate = HelperListener(coordinator: coordinator)
        let listener = NSXPCListener(machServiceName: PrivilegedHelperIdentity.serviceName)
        do {
            listener.setConnectionCodeSigningRequirement(try PeerCodeSigning.requirement(identifier: PrivilegedHelperIdentity.appIdentifier, team: team))
        } catch { exit(EXIT_FAILURE) }
        listener.delegate = delegate
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signals = [SIGTERM, SIGINT].map { signal in
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
            source.setEventHandler { listener.invalidate(); coordinator.shutdown() }
            source.resume()
            return source
        }
        let idle = DispatchSource.makeTimerSource(queue: .global())
        idle.schedule(deadline: .now() + 30, repeating: 30)
        idle.setEventHandler { coordinator.exitIfIdle() }
        idle.resume()
        listener.resume()
        withExtendedLifetime((delegate, signals, idle)) { RunLoop.main.run() }
    }
}
