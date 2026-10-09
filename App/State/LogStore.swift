import Foundation
import Observation

/// In-memory ring buffer of core output and app events. Nothing is written to disk.
@MainActor @Observable
final class LogStore {
    private(set) var lines: [String] = []
    private let limit = 5000

    func append(_ line: String) {
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    func clear() { lines.removeAll() }
}
