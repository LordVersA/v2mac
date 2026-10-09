import Foundation
import Network

public enum FetchRoute: Sendable, Equatable {
    /// Plain `URLSession`.
    case direct
    /// Through the running core's local SOCKS5 listener.
    case proxy(host: String, port: Int, username: String?, password: String?)

    public static func localProxy(port: Int, username: String? = nil, password: String? = nil) -> FetchRoute {
        .proxy(host: "127.0.0.1", port: port, username: username, password: password)
    }
}

public struct SubscriptionFetcher: Sendable {
    public var userAgent: String
    public var timeout: TimeInterval
    public var maxBytes: Int

    public init(userAgent: String, timeout: TimeInterval = 15, maxBytes: Int = 10 * 1024 * 1024) {
        self.userAgent = userAgent
        self.timeout = timeout
        self.maxBytes = maxBytes
    }

    /// Downloads the raw body and response headers (any 2xx accepted, redirects followed).
    public func download(url: URL, route: FetchRoute) async throws -> (body: Data, headers: [String: String]) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            throw SubscriptionError.invalidURL
        }
        let session = SessionFactory.make(route: route, timeout: timeout)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw SubscriptionError.network("Invalid response.") }
            guard (200..<300).contains(http.statusCode) else { throw SubscriptionError.http(http.statusCode) }
            if http.expectedContentLength > Int64(maxBytes) { throw SubscriptionError.tooLarge }

            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxBytes { throw SubscriptionError.tooLarge }
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
            }
            return (body, headers)
        } catch let error as SubscriptionError {
            throw error
        } catch let error as URLError {
            throw SubscriptionError.network(error.localizedDescription)
        }
    }

    public func fetch(url: URL, route: FetchRoute) async throws -> SubscriptionResult {
        let (body, headers) = try await download(url: url, route: route)
        return try SubscriptionParser.parse(body: body, headers: headers)
    }
}
