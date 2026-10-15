import Foundation
import Observation
import V2MacCore

/// Spec 9.9. While the switch is on and a connection is wanted, the root helper points the
/// system's web, secure web and SOCKS proxies at the local port; it turns them off again on
/// disconnect and when the app quits or stops.
@MainActor @Observable
final class SystemProxyController {
    private(set) var isEnabled = Prefs.systemProxy
    /// Where the system's settings point now; the badge next to the switch.
    private(set) var status: SystemProxyState = .none
    private(set) var failure: String?
    private let session: TunController

    init(session: TunController) {
        self.session = session
    }

    private var flag: URL { session.stateDirectory.appendingPathComponent(SystemProxy.flag) }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        Prefs.systemProxy = on
        failure = nil
    }

    /// Points the system proxy at `port`.
    func apply(port: Int) async {
        guard isEnabled else { return }
        try? "\(port)\n".write(to: flag, atomically: true, encoding: .utf8)
        switch await session.startSession() {
        case .started:
            failure = nil
        case .cancelled:
            failure = String(localized: "Administrator access was cancelled, so the system proxy was not set.")
            clear()
        case .failed(let message):
            failure = String(localized: "The system proxy could not be set: \(message)")
            clear()
        }
    }

    /// The helper turns the proxies off within a moment.
    func clear() {
        try? FileManager.default.removeItem(at: flag)
    }

    func refresh(port: Int) {
        let now = SystemProxy.state(port: port)
        if now != status { status = now }
    }
}
