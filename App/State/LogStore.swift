import Foundation
import Observation

/// In-memory ring buffer of core output and app events. Nothing is written to disk.
@MainActor @Observable
final class LogStore {
    /// A line with an id that stays the same when older lines are dropped from the buffer.
    struct Line: Identifiable, Sendable {
        let id: Int
        let text: String
    }

    private(set) var lines: [Line] = []
    private let limit = 5000
    private var nextID = 0
    /// Lines not yet in `lines`. They are moved in together a moment later, so a busy core
    /// redraws the log a few times a second instead of once per line.
    @ObservationIgnored private var pending: [String] = []

    func append(_ line: String) {
        pending.append(line)
        guard pending.count == 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.flush()
        }
    }

    private func flush() {
        let start = nextID
        nextID += pending.count
        var all = lines
        all.append(contentsOf: pending.enumerated().map { Line(id: start + $0.offset, text: $0.element) })
        pending.removeAll()
        if all.count > limit { all.removeFirst(all.count - limit) }
        lines = all
    }

    func clear() {
        pending.removeAll()
        lines.removeAll()
    }
}
