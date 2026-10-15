import Foundation
import SystemConfiguration

/// Spec 9.9. Where the system's proxy settings point, for the badge next to the switch.
public enum SystemProxyState: Sendable, Equatable {
    /// Set, and every enabled proxy is this app's local port.
    case ours
    /// Something else is set: another address or port, or automatic configuration.
    case other
    /// No proxy is set.
    case none
}

public enum SystemProxy {
    /// Present while the app wants the system proxy set; it holds the port.
    public static let flag = "proxy.on"

    /// The settings in effect now (those of the primary network service).
    public static func state(port: Int) -> SystemProxyState {
        state(of: SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:], port: port)
    }

    public static func state(of proxies: [String: Any], port: Int) -> SystemProxyState {
        func on(_ key: String) -> Bool { (proxies[key] as? Int) == 1 }
        var other = on("ProxyAutoConfigEnable") || on("ProxyAutoDiscoveryEnable")
        var ours = false
        for kind in ["HTTP", "HTTPS", "SOCKS"] where on("\(kind)Enable") {
            let host = (proxies["\(kind)Proxy"] as? String ?? "").lowercased()
            if ["127.0.0.1", "localhost", "::1"].contains(host), (proxies["\(kind)Port"] as? Int) == port {
                ours = true
            } else {
                other = true
            }
        }
        return other ? .other : (ours ? .ours : .none)
    }
}
