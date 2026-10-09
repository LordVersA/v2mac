import Darwin
import Foundation

public enum PortUtil {
    private static func makeAddress(host: String, port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        return addr
    }

    private static func bind(fd: Int32, host: String, port: Int) -> Bool {
        var addr = makeAddress(host: host, port: port)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// True when nothing is listening on `port` and it can be bound on `host`.
    public static func isFree(port: Int, host: String = "127.0.0.1") -> Bool {
        guard (1...65535).contains(port) else { return false }
        if canConnect(port: port) { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        return bind(fd: fd, host: host, port: port)
    }

    /// Asks the kernel for a free loopback port, then releases it.
    public static func freePort() throws -> Int {
        try freePorts(1)[0]
    }

    /// `count` distinct free loopback ports. All sockets are held open together so the
    /// kernel cannot hand out the same port twice, then released.
    public static func freePorts(_ count: Int) throws -> [Int] {
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        var ports: [Int] = []
        for _ in 0..<count {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CoreError.startFailed("Could not create a socket.") }
            fds.append(fd)
            guard bind(fd: fd, host: "127.0.0.1", port: 0) else {
                throw CoreError.startFailed("Could not find a free port.")
            }
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len) == 0
                }
            }
            guard ok else { throw CoreError.startFailed("Could not find a free port.") }
            ports.append(Int(UInt16(bigEndian: addr.sin_port)))
        }
        return ports
    }

    /// Loopback TCP connect; returns true when something accepts.
    public static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = makeAddress(host: "127.0.0.1", port: port)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
