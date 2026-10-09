import Foundation
import Network
import os

public struct TCPPingTarget: Sendable {
    public var id: UUID
    public var host: String
    public var port: Int

    public init(id: UUID, host: String, port: Int) {
        self.id = id
        self.host = host
        self.port = port
    }
}

/// Secondary latency measure: time to complete a TCP handshake with the server itself.
public enum TCPPing {
    public static func run(
        _ targets: [TCPPingTarget],
        timeout: TimeInterval = 3,
        concurrency: Int = 32,
        onResult: @escaping @Sendable (LatencyResult) async -> Void
    ) async {
        await withTaskGroup(of: LatencyResult.self) { group in
            var next = 0
            func launch() {
                guard next < targets.count else { return }
                let target = targets[next]
                next += 1
                group.addTask { LatencyResult(id: target.id, outcome: await ping(target, timeout: timeout)) }
            }
            for _ in 0..<min(max(1, concurrency), targets.count) { launch() }
            while let result = await group.next() {
                await onResult(result)
                if Task.isCancelled { group.cancelAll(); continue }
                launch()
            }
        }
    }

    static func ping(_ target: TCPPingTarget, timeout: TimeInterval) async -> LatencyOutcome {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: target.port)), !target.host.isEmpty else { return .timeout }
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "v2mac.tcpping")
        let clock = ContinuousClock()
        let start = clock.now

        return await withCheckedContinuation { (continuation: CheckedContinuation<LatencyOutcome, Never>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ outcome: LatencyOutcome) {
                let already = finished.withLock { done -> Bool in
                    let was = done
                    done = true
                    return was
                }
                guard !already else { return }
                connection.cancel()
                continuation.resume(returning: outcome)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.ok(ms: max(1, Int(((clock.now - start) / .milliseconds(1)).rounded()))))
                case .failed, .cancelled:
                    finish(.timeout)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.timeout) }
        }
    }
}
