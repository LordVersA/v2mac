import AppIntents
import AppKit
import notify

/// Spec 12.4: what the Control Center switch and the app share. This file is part of both the
/// app and its widget extension. The system may run the switch's intent in either process; in
/// the extension it reaches the app through Darwin notifications, which carry a number each:
/// the app publishes whether it is connected, the switch asks it to connect or disconnect.
enum ControlBridge {
    static let kind = "io.github.lordversa.v2mac.connection"

    /// The app's bundle id, also when read in the extension (`<app>.control`).
    static var appID: String {
        let id = Bundle.main.bundleIdentifier ?? "io.github.lordversa.v2mac"
        return id.hasSuffix(".control") ? String(id.dropLast(".control".count)) : id
    }

    private static var stateName: String { appID + ".control.state" }
    static var requestName: String { appID + ".control.request" }

    /// Set by the app; in the extension it stays nil.
    @MainActor static var handler: ((Bool) -> Void)?

    /// Read in the extension: the app holds the name while it runs, so an app that is not
    /// running reads as off.
    static var isConnected: Bool { state(of: stateName) == 1 }

    /// The app says whether it is connected (or connecting).
    static func publish(connected: Bool) {
        setState(of: stateName, to: connected ? 1 : 0)
    }

    // MARK: Desktop widget

    static let widgetKind = "io.github.lordversa.v2mac.status"

    /// What the widget shows besides on/off. The app keeps it in its own defaults; the sandboxed
    /// extension reads that domain through a read-only exception in its entitlements.
    struct Status: Equatable {
        enum Phase: String { case off, connecting, connected, failed }
        var phase: Phase
        var server: String
        var exit: String
    }

    private static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == appID ? .standard : UserDefaults(suiteName: appID) ?? .standard
    }

    static var status: Status {
        get {
            let saved = defaults.dictionary(forKey: "widgetStatus") as? [String: String] ?? [:]
            var phase = saved["phase"].flatMap(Status.Phase.init) ?? .off
            // The app was quit or crashed while connected: it no longer holds the state name.
            if phase != .failed, !isConnected { phase = .off }
            return Status(phase: phase, server: saved["server"] ?? "", exit: phase == .off ? "" : saved["exit"] ?? "")
        }
        set { defaults.set(["phase": newValue.phase.rawValue, "server": newValue.server, "exit": newValue.exit], forKey: "widgetStatus") }
    }

    /// A request: the time it was made, doubled, plus one for "connect".
    @MainActor static func request(connect: Bool) {
        if let handler { return handler(connect) }
        setState(of: requestName, to: UInt64(Date().timeIntervalSince1970) * 2 + (connect ? 1 : 0))
        notify_post(requestName)
        // Not running: open it, and it connects (`v2mac://connect` is the one action a link can ask for).
        if connect, NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty,
           let url = URL(string: "v2mac://connect") {
            NSWorkspace.shared.open(url)
        }
    }

    /// In the app: a request made in the last half minute, or nil.
    static func pendingRequest() -> Bool? {
        let value = state(of: requestName)
        guard value > 0, Date().timeIntervalSince1970 - Double(value / 2) < 30 else { return nil }
        setState(of: requestName, to: 0)
        return value % 2 == 1
    }

    /// Tokens stay registered for the life of the process, so a published state lasts.
    nonisolated(unsafe) private static var tokens: [String: Int32] = [:]
    private static let lock = NSLock()

    private static func token(_ name: String) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if let token = tokens[name] { return token }
        var token: Int32 = 0
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return nil }
        tokens[name] = token
        return token
    }

    private static func state(of name: String) -> UInt64 {
        var value: UInt64 = 0
        if let token = token(name) { notify_get_state(token, &value) }
        return value
    }

    private static func setState(of name: String, to value: UInt64) {
        if let token = token(name) { notify_set_state(token, value) }
    }
}

/// The switch's action. Hidden from Shortcuts, which has its own connect actions.
struct SetConnectionIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn V2Mac On or Off"
    static let isDiscoverable = false

    @Parameter(title: "Connected") var value: Bool

    init() {}

    init(value: Bool) { self.value = value }

    @MainActor func perform() async throws -> some IntentResult {
        ControlBridge.request(connect: value)
        return .result()
    }
}
