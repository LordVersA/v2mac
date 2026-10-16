import Darwin
import Foundation

/// One `accepted` line of Xray's access log: who connected, to which host, and where it went.
public struct SeenConnection: Sendable, Equatable {
    public var sourcePort: Int?
    /// A domain or an IP address, without the port.
    public var host: String
    public var port: Int?
    public var inbound: String
    public var outbound: String

    /// `… from tcp:127.0.0.1:51973 accepted tcp:example.com:443 [mixed-in >> direct]`, also with
    /// `from 127.0.0.1:…` and `accepted http://example.com/path`.
    public init?(line: String) {
        guard let from = line.range(of: " from "), let accepted = line.range(of: " accepted ", range: from.upperBound..<line.endIndex),
              let open = line.range(of: " [", options: .backwards), open.lowerBound > accepted.upperBound,
              let close = line.range(of: "]", options: .backwards), close.lowerBound > open.upperBound else { return nil }
        let source = line[from.upperBound..<accepted.lowerBound]
        sourcePort = source.split(separator: ":").last.flatMap { Int($0) }
        var target = String(line[accepted.upperBound..<open.lowerBound])
        if let scheme = target.range(of: "://") {
            target = String(target[scheme.upperBound...].prefix { $0 != "/" })
        } else if target.hasPrefix("tcp:") || target.hasPrefix("udp:") {
            target.removeFirst(4)
        }
        // Split off the port; an IPv6 address comes as `[addr]:port`. A URL without one uses its scheme's.
        port = line[accepted.upperBound...].hasPrefix("http://") ? 80 : nil
        if target.hasPrefix("["), let end = target.firstIndex(of: "]") {
            port = Int(target[target.index(after: end)...].dropFirst())
            target = String(target[target.index(after: target.startIndex)..<end])
        } else if target.filter({ $0 == ":" }).count == 1, let colon = target.lastIndex(of: ":") {
            port = Int(target[target.index(after: colon)...])
            target = String(target[..<colon])
        }
        guard !target.isEmpty else { return nil }
        host = target.lowercased()
        let route = line[open.upperBound..<close.lowerBound].replacingOccurrences(of: ">>", with: "->")
        let parts = route.components(separatedBy: " -> ")
        inbound = parts.first ?? ""
        outbound = parts.count > 1 ? parts[1] : ""
    }
}

/// One TCP connection from an app to the proxy port, as `nettop` reports it: who owns it and how
/// many bytes went each way. `nettop` needs no privileges and lists every process's connections.
public struct ProxyFlow: Sendable, Equatable {
    /// The app's end: the source port the access log names.
    public var localPort: Int
    public var pid: Int32
    public var process: String
    public var sent: Int64
    public var received: Int64

    /// Every connection to `proxyPort` on this Mac, or none if `nettop` fails.
    public static func read(proxyPort: Int) async -> [ProxyFlow] {
        let args = ["-L", "1", "-m", "tcp", "-n", "-x", "-J", "bytes_in,bytes_out"]
        guard let out = try? await CoreUpdater.run("/usr/bin/nettop", args, timeout: .seconds(5)), out.status == 0 else { return [] }
        return parse(out.output, proxyPort: proxyPort)
    }

    /// `nettop -L 1 -J bytes_in,bytes_out` CSV: a process line (`curl.17295,in,out,`) followed by
    /// its connections (`tcp4 127.0.0.1:56187<->127.0.0.1:10808,in,out,`).
    static func parse(_ csv: String, proxyPort: Int) -> [ProxyFlow] {
        var out: [ProxyFlow] = []
        var owner: (name: String, pid: Int32)?
        for line in csv.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let first = fields.first, !first.isEmpty else { continue }
            guard first.contains("<->") else {
                if let dot = first.lastIndex(of: "."), let pid = Int32(first[first.index(after: dot)...]) {
                    owner = (String(first[..<dot]), pid)
                }
                continue
            }
            let ends = first.split(separator: " ").last?.components(separatedBy: "<->") ?? []
            guard let owner, ends.count == 2, fields.count >= 3,
                  let local = port(of: ends[0]), port(of: ends[1]) == proxyPort, local != proxyPort else { continue }
            out.append(ProxyFlow(localPort: local, pid: owner.pid, process: owner.name,
                                 sent: Int64(fields[2]) ?? 0, received: Int64(fields[1]) ?? 0))
        }
        return out
    }

    private static func port(of end: String) -> Int? {
        end.split(separator: ":").last.flatMap { Int($0) }
    }
}

public enum SocketOwners {
    public static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The outermost `.app` folder of an executable path, so helpers count as their app.
    public static func appBundle(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
