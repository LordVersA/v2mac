import Foundation
import os

/// Collects stdout/stderr of the core: splits into lines, keeps a short tail,
/// detects the readiness line and forwards every line to the log stream.
final class ProcessOutput: Sendable {
    private struct State {
        var partial: [Int: Data] = [:]
        var recent: [String] = []
        var readySeen = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sink: @Sendable (String) -> Void
    private let tailLimit = 100

    init(sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    var readySeen: Bool { state.withLock { $0.readySeen } }
    var recentLines: [String] { state.withLock { $0.recent } }

    func ingest(_ data: Data, stream: Int) {
        let lines: [String] = state.withLock { s in
            var lines: [String] = []
            var buffer = s.partial[stream, default: Data()]
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
            s.partial[stream] = buffer
            return lines
        }
        emit(lines)
    }

    func flush(stream: Int) {
        let lines: [String] = state.withLock { s in
            var lines: [String] = []
            if let rest = s.partial[stream], !rest.isEmpty {
                lines.append(String(decoding: rest, as: UTF8.self))
            }
            s.partial[stream] = nil
            return lines
        }
        emit(lines)
    }

    private func emit(_ raw: [String]) {
        for var entry in raw {
            if entry.hasSuffix("\r") { entry.removeLast() }
            if entry.isEmpty { continue }
            let line = entry
            let ready = CoreOutputParser.indicatesReady(line)
            state.withLock { s in
                s.recent.append(line)
                if s.recent.count > tailLimit { s.recent.removeFirst(s.recent.count - tailLimit) }
                if ready { s.readySeen = true }
            }
            sink(line)
        }
    }
}
