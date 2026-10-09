import Darwin
import Foundation

/// A skipped or rejected share link. Never fails a whole subscription.
public struct LinkSkip: Error, Sendable, Equatable, LocalizedError {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Query parameters with case-insensitive keys; empty values read as absent.
struct LinkQuery: Sendable {
    private var values: [String: String] = [:]

    init(_ raw: String = "") {
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).lowercased()
            let value = parts.count > 1 ? String(parts[1]) : ""
            if values[key] == nil {
                values[key] = value.removingPercentEncoding ?? value
            }
        }
    }

    subscript(key: String) -> String? {
        guard let v = values[key.lowercased()]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }

    func flag(_ keys: String...) -> Bool {
        keys.contains { key in
            guard let v = self[key]?.lowercased() else { return false }
            return v == "1" || v == "true"
        }
    }
}

/// Minimal tolerant URL splitter. Foundation's URL rejects many real-world
/// share links (unencoded names, odd characters), so this does it by hand.
struct RawURL: Sendable {
    var scheme: String
    var userinfo: String?
    var host: String
    var portText: String?
    var query: LinkQuery
    var fragment: String?
    /// Everything between `://` and `#`, query included.
    var afterScheme: String

    init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = s.range(of: "://") else { return nil }
        let scheme = s[..<sep.lowerBound].lowercased()
        guard !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        self.scheme = scheme

        var rest = String(s[sep.upperBound...])
        if let hash = rest.firstIndex(of: "#") {
            let raw = String(rest[rest.index(after: hash)...])
            fragment = raw.removingPercentEncoding ?? raw
            rest = String(rest[..<hash])
        }
        afterScheme = rest

        var queryString = ""
        if let q = rest.firstIndex(of: "?") {
            queryString = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        query = LinkQuery(queryString)

        var authority = rest
        if let slash = rest.firstIndex(of: "/") { authority = String(rest[..<slash]) }

        var hostPort = authority
        if let at = authority.lastIndex(of: "@") {
            userinfo = String(authority[..<at])
            hostPort = String(authority[authority.index(after: at)...])
        }

        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let tail = hostPort[hostPort.index(after: close)...]
            if tail.hasPrefix(":") { portText = String(tail.dropFirst()) }
        } else if let colon = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<colon])
            portText = String(hostPort[hostPort.index(after: colon)...])
        } else {
            host = hostPort
        }
    }

    var decodedUserinfo: String? {
        userinfo.map { $0.removingPercentEncoding ?? $0 }
    }

    /// Validated TCP/UDP port from `portText`.
    func port() throws -> Int {
        guard let text = portText, let p = Int(text), (1...65535).contains(p) else {
            throw LinkSkip("invalid or missing port")
        }
        return p
    }

    func validatedHost() throws -> String {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { throw LinkSkip("missing server address") }
        return h
    }

    /// Fragment, or `host:port` when the link has no name.
    func displayName(address: String, port: Int) -> String {
        if let f = fragment?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty { return f }
        return address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

enum Base64Tolerant {
    /// Standard and URL-safe alphabets; missing padding and whitespace tolerated.
    static func decode(_ string: String) -> Data? {
        var s = string.filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    static func decodeString(_ string: String) -> String? {
        guard let data = decode(string) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

func isIPAddress(_ s: String) -> Bool {
    var v4 = in_addr()
    var v6 = in6_addr()
    return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
}

func csv(_ s: String?) -> [String] {
    (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Builds an object, dropping nil values.
func compact(_ pairs: KeyValuePairs<String, JSONValue?>) -> JSONValue {
    var o: [String: JSONValue] = [:]
    for (k, v) in pairs { if let v { o[k] = v } }
    return .object(o)
}
