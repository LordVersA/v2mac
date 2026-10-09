import Foundation
import Network
import os

/// Tiny loopback HTTP server for fetcher tests.
final class TestHTTPServer: Sendable {
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    typealias Responder = @Sendable (_ path: String) -> Response

    let port: Int
    private let listener: NWListener
    private let lastUserAgent = OSAllocatedUnfairLock<String?>(initialState: nil)

    var userAgent: String? { lastUserAgent.withLock { $0 } }

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start(_ responder: @escaping Responder) async throws -> TestHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let box = OSAllocatedUnfairLock<TestHTTPServer?>(initialState: nil)
        let agent = OSAllocatedUnfairLock<String?>(initialState: nil)
        _ = agent

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let lines = request.components(separatedBy: "\r\n")
                let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                if let ua = lines.first(where: { $0.lowercased().hasPrefix("user-agent:") }) {
                    let value = ua.dropFirst("user-agent:".count).trimmingCharacters(in: .whitespaces)
                    box.withLock { $0 }?.lastUserAgent.withLock { $0 = value }
                }
                let r = responder(path)
                var head = "HTTP/1.1 \(r.status) X\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
                for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
                head += "\r\n"
                var out = Data(head.utf8)
                out.append(r.body)
                connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
            }
        }

        let port: Int = try await withCheckedThrowingContinuation { cont in
            let done = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if done.withLock({ let was = $0; $0 = true; return was }) { return }
                    cont.resume(returning: Int(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    if done.withLock({ let was = $0; $0 = true; return was }) { return }
                    cont.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let server = TestHTTPServer(listener: listener, port: port)
        box.withLock { $0 = server }
        return server
    }

    func stop() { listener.cancel() }
}
