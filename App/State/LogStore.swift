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

    func append(_ line: String) {
        lines.append(Line(id: nextID, text: line))
        nextID += 1
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    func clear() { lines.removeAll() }
}
