import Darwin
import Foundation

/// One `accepted` line of Xray's access log: who connected, to which host, and where it went.
public struct SeenConnection: Sendable, Equatable {
    public var sourcePort: Int?
    /// A domain or an IP address, without the port.
    public var host: String
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
        // Drop the port; an IPv6 address comes as `[addr]:port`.
        if target.hasPrefix("["), let end = target.firstIndex(of: "]") {
            target = String(target[target.index(after: target.startIndex)..<end])
        } else if target.filter({ $0 == ":" }).count == 1, let colon = target.lastIndex(of: ":") {
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

/// Which process owns each local TCP socket connected to the proxy port, by the socket's local port.
/// Only this user's processes can be read; others are simply not in the result.
public enum SocketOwners {
    public static func scan(proxyPort: Int) -> [Int: String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [Int: String] = [:]
        for pid in pids.prefix(Int(max(found, 0))) where pid > 0 && pid != getpid() {
            for port in proxyClientPorts(pid: pid, proxyPort: proxyPort) {
                if let path = path(of: pid) { out[port] = path }
            }
        }
        return out
    }

    static func proxyClientPorts(pid: pid_t, proxyPort: Int) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard used > 0 else { return [] }
        var ports: [Int] = []
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == MemoryLayout<socket_fdinfo>.size, info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let remote = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)))
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            if remote == proxyPort { ports.append(local) }
        }
        return ports
    }

    static func path(of pid: pid_t) -> String? {
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
