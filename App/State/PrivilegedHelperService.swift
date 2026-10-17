import AppKit
import Foundation
import Observation
import os
import ServiceManagement
import V2MacCore

@MainActor @Observable
final class PrivilegedHelperService {
    static let shared = PrivilegedHelperService()
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorMessage: String?
    let teamIdentifier = PeerCodeSigning.teamIdentifier()
    var isSupported: Bool { teamIdentifier != nil }
    @ObservationIgnored private let service = SMAppService.daemon(plistName: PrivilegedHelperIdentity.plistName)
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var synchronizer: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopError: String?

    func refresh() { status = service.status }

    @discardableResult
    func register() -> Bool {
        guard isSupported else { return false }
        refresh()
        if status == .enabled { errorMessage = nil; return true }
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return false }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Enable the privileged helper?")
        alert.informativeText = String(localized: "macOS will ask you to approve a background helper for TUN mode, the system proxy and the kill switch. Approval stays in System Settings across app restarts. The helper changes network settings only when V2Mac requests it. V2Mac never receives your administrator password. You can remove the helper here later.")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try service.register()
            refresh()
            errorMessage = nil
            if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            return status == .enabled
        } catch {
            refresh()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func unregister() async {
        if let error = await endSession() { errorMessage = error; return }
        do {
            try await service.unregister()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        refresh()
    }

    func startSession(port: Int, interfaceName: String, snapshot: @escaping @MainActor () -> PrivilegedSessionState,
                      onFailure: @escaping @MainActor (String) -> Void) async -> TunController.LaunchResult {
        generation += 1
        let current = generation
        refresh()
        if status == .notFound {
            let message = String(localized: "The privileged helper is missing. Reinstall V2Mac.")
            errorMessage = message
            return .failed(message)
        }
        if status == .notRegistered, !register() {
            if status != .requiresApproval, errorMessage == nil { return .cancelled }
        }
        guard status == .enabled else {
            let message = errorMessage ?? String(localized: "Approve V2Mac's privileged helper in System Settings → General → Login Items & Extensions, then reconnect.")
            errorMessage = message
            return .failed(message)
        }
        guard generation == current else { return .cancelled }
        do {
            guard let teamIdentifier else { throw CocoaError(.executableNotLoadable) }
            try PrivilegedSessionState.validate(port: port, interfaceName: interfaceName)
            let state = try JSONEncoder().encode(snapshot())
            connection?.invalidate()
            let connection = NSXPCConnection(machServiceName: PrivilegedHelperIdentity.serviceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
            connection.setCodeSigningRequirement(try PeerCodeSigning.requirement(identifier: PrivilegedHelperIdentity.serviceName, team: teamIdentifier))
            connection.resume()
            self.connection = connection
            let error = await call { $0.startSession(port: port, interfaceName: interfaceName, state: state, withReply: $1) }
            guard generation == current else { connection.invalidate(); return .cancelled }
            if let error {
                connection.invalidate()
                self.connection = nil
                errorMessage = error
                return .failed(error)
            }
            errorMessage = nil
            stopError = nil
            synchronizer?.cancel()
            synchronizer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, let self, generation == current else { return }
                    do {
                        let state = try JSONEncoder().encode(snapshot())
                        if let error = await call({ $0.updateSession(state: state, withReply: $1) }) {
                            throw NSError(domain: "V2MacPrivilegedHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        errorMessage = error.localizedDescription
                        self.connection?.invalidate()
                        self.connection = nil
                        onFailure(error.localizedDescription)
                        return
                    }
                }
            }
            return .started
        } catch {
            errorMessage = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func endSession() async -> String? {
        generation += 1
        synchronizer?.cancel()
        synchronizer = nil
        guard let connection else { return stopError }
        let error = await call { $0.stopSession(withReply: $1) }
        connection.invalidate()
        if self.connection === connection {
            self.connection = nil
            stopError = error
            if let error { errorMessage = error }
        }
        return error
    }

    /// Reply, transport error and timeout compete to resume exactly one continuation.
    private func call(_ operation: (PrivilegedHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        guard let connection else { return String(localized: "The privileged helper connection is unavailable.") }
        return await withCheckedContinuation { continuation in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<String?, Never>?>(initialState: continuation)
            let finish: @Sendable (String?) -> Void = { error in
                let continuation = pending.withLock { value in let old = value; value = nil; return old }
                continuation?.resume(returning: error)
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ finish($0.localizedDescription) }) as? PrivilegedHelperProtocol else {
                finish(String(localized: "The privileged helper connection is unavailable."))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                finish(String(localized: "The privileged helper did not answer."))
            }
            operation(proxy, finish)
        }
    }
}
