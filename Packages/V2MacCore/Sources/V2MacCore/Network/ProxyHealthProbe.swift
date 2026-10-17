import Foundation

/// Tests the running proxy with an HTTP response. It never retries over a direct connection.
public enum ProxyHealthProbe {
    /// With `warm`, a first request opens the connection and only the second one is timed,
    /// so the result is one round trip rather than every handshake on the way.
    public static func measure(route: FetchRoute, url: URL, timeout: TimeInterval, warm: Bool = false) async -> LatencyOutcome {
        guard case .proxy = route, isSuitable(url) else { return .invalid(String(localized: "Use a public HTTP or HTTPS test URL.")) }
        let session = SessionFactory.make(route: route, timeout: timeout, resourceTimeout: timeout, delegate: ResponseHeadersOnly())
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpShouldHandleCookies = false
            if warm {
                // Read it to the end, so the connection is free to reuse.
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return .timeout }
            }
            let start = ContinuousClock.now
            let (_, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return .timeout }
            let elapsed = ContinuousClock.now - start
            return .ok(ms: max(1, Int((elapsed / .milliseconds(1)).rounded())))
        } catch {
            return .timeout
        }
    }

    /// URLSession bypasses SOCKS for local/private destinations; those cannot verify a proxy.
    public static func isSuitable(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.contains(":") { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }),
                  parts.map(String.init).joined(separator: ".") == host else { return false }
        }
        if parts.count == 4 {
            let a = parts[0], b = parts[1]
            return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                     (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) ||
                     (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)))
        }
        return host.contains(".")
    }
}

/// Measure the first public response; never follow a redirect to a destination SOCKS bypasses.
private final class ResponseHeadersOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
