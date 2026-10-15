/// What the local proxy should do if a requested system tunnel cannot run.
/// Neither option installs a firewall or blocks direct traffic after the TUN disappears.
public enum TunFailurePolicy: String, CaseIterable, Sendable {
    case continueProxy
    case stopProxy

    public var stopsProxy: Bool { self == .stopProxy }
    public var title: String {
        switch self {
        case .continueProxy: String(localized: "Keep local proxy running")
        case .stopProxy: String(localized: "Stop connection")
        }
    }
}
