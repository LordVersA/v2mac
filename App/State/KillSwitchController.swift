import Foundation
import Observation
import V2MacCore

/// Spec 9.8. The block goes up before a connection starts and stays through restarts, crashes
/// and failures; only a disconnect, turning the setting off or quitting lifts it. The root
/// helper holds the rules, so they also outlive an app that stopped unexpectedly.
@MainActor @Observable
final class KillSwitchController {
    enum State: Equatable {
        case off
        case arming
        case armed
        /// A block nobody asked for any more: V2Mac stopped while it was up.
        case leftOver
        case failed(String)
    }

    private(set) var state: State = .off
    private let session: TunController
    private let marker: URL
    /// Addresses handed to the helper this session. The list only grows, so a server used or
    /// tested earlier stays reachable.
    @ObservationIgnored private var allowed: Set<String> = []
    /// Bumped by every arm and lift, so a slower earlier one does not set the state.
    @ObservationIgnored private var generation = 0

    /// Traffic outside the connection is refused right now.
    var isBlocking: Bool { state == .armed || state == .leftOver }

    init(session: TunController, marker: URL = KillSwitch.marker(name: AppPaths.dataFolderName)) {
        self.session = session
        self.marker = marker
        if FileManager.default.fileExists(atPath: marker.path) { state = .leftOver }
    }

    private var flag: URL { session.stateDirectory.appendingPathComponent(KillSwitch.flag) }
    private var allowFile: URL { session.stateDirectory.appendingPathComponent(KillSwitch.allowFile) }
    private var markerDate: Date? { (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date }

    /// Puts the block up with `hosts` reachable; true once the helper has it in place. Already
    /// up, it only adds the hosts.
    func arm(allowing hosts: [String]) async -> Bool {
        generation += 1
        let current = generation
        await add(hosts)
        if state == .armed, session.isSessionAlive, FileManager.default.fileExists(atPath: flag.path) { return true }
        state = .arming
        // A block left from before is replaced; the new one shows as a new marker.
        let before = markerDate
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        switch await session.startSession() {
        case .started: break
        case .cancelled: return fail("Administrator access was cancelled.", current)
        case .failed(let message): return fail(message, current)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, current == generation {
            if let date = markerDate, date != before {
                state = .armed
                return true
            }
            // The helper takes the request back when the rules cannot be loaded.
            if !FileManager.default.fileExists(atPath: flag.path) {
                let file = session.rootDirectory.appendingPathComponent(KillSwitch.errorFile)
                let detail = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                return fail(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The firewall rules could not be loaded.", current)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return current == generation ? fail("The firewall did not answer.", current) : false
    }

    /// Lets the core reach these servers while the block is up, for tests and new servers.
    func allow(_ hosts: [String]) async {
        guard state == .armed || state == .arming else { return }
        await add(hosts)
    }

    /// Lifts the block. A helper is needed for that: when the one that put it up is gone, a new
    /// one is started without the request, and it takes the rules away.
    func lift() async {
        generation += 1
        let current = generation
        try? FileManager.default.removeItem(at: flag)
        try? FileManager.default.removeItem(at: allowFile)
        allowed = []
        guard FileManager.default.fileExists(atPath: marker.path) else {
            state = .off
            return
        }
        if !session.isSessionAlive {
            guard case .started = await session.startSession() else {
                if current == generation { state = .leftOver }
                return
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, FileManager.default.fileExists(atPath: marker.path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard current == generation else { return }
        state = FileManager.default.fileExists(atPath: marker.path) ? .leftOver : .off
    }

    private func add(_ hosts: [String]) async {
        let new = Set(await KillSwitch.addresses(of: hosts)).subtracting(allowed)
        guard !new.isEmpty else { return }
        allowed.formUnion(new)
        try? (allowed.sorted().joined(separator: "\n") + "\n").write(to: allowFile, atomically: true, encoding: .utf8)
    }

    private func fail(_ message: String, _ current: Int) -> Bool {
        guard current == generation else { return false }
        try? FileManager.default.removeItem(at: flag)
        state = .failed(message)
        return false
    }
}
