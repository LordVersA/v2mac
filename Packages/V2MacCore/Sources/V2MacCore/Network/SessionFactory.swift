import Foundation
import Network

enum SessionFactory {
    /// Ephemeral session for the given route. Note that URLSession never proxies
    /// loopback or private destinations, whatever the configuration says.
    static func make(route: FetchRoute, timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        if case .proxy(let host, let port, let user, let pass) = route,
           let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) {
            let proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(host), port: nwPort))
            if let user, let pass, !user.isEmpty { proxy.applyCredential(username: user, password: pass) }
            config.proxyConfigurations = [proxy]
        }
        return URLSession(configuration: config)
    }
}
