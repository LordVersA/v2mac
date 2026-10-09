import Darwin
import Foundation
import Testing
@testable import V2MacCore

extension Tag {
    @Tag static var integration: Self
}

enum TestSupport {
    /// <repo>/Vendor/core, resolved from this file's location.
    static let vendorCore: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Vendor/core")
    }()

    static var xray: URL { vendorCore.appendingPathComponent("xray") }
    static var coreAvailable: Bool { FileManager.default.isExecutableFile(atPath: xray.path) }

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Holds a listening socket on a loopback port until `release()`.
    final class PortHolder: @unchecked Sendable {
        let port: Int
        private let fd: Int32

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard ok, listen(fd, 8) == 0 else { throw CoreError.startFailed("holder failed") }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            self.fd = fd
            port = Int(UInt16(bigEndian: bound.sin_port))
        }

        func release() { close(fd) }
    }
}

/// Minimal thread-safe accumulator for results delivered from concurrent callbacks.
final class OSLockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ initial: Value) { stored = initial }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

extension OSLockedBox where Value == [LatencyResult] {
    func append(_ r: LatencyResult) { mutate { $0.append(r) } }
}
