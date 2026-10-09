import Foundation

public enum CoreState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

public enum CoreError: Error, Sendable, Equatable, LocalizedError {
    case coreNotFound(String)
    case portInUse(Int)
    case alreadyRunning
    case cancelled
    case startFailed(String)
    case exitedBeforeReady(code: Int32, detail: String?)
    case readyTimeout

    public var errorDescription: String? {
        switch self {
        case .coreNotFound:
            "Xray core not found. Reinstall the app or revert to the bundled core."
        case .portInUse(let port):
            "Port \(port) is already in use."
        case .alreadyRunning:
            "The core is already running."
        case .cancelled:
            "Start was cancelled."
        case .startFailed(let message):
            message
        case .exitedBeforeReady(let code, let detail):
            detail ?? "Xray exited during startup (exit \(code))."
        case .readyTimeout:
            "Xray did not become ready in time."
        }
    }
}

enum CoreOutputParser {
    /// Extracts the most useful failure message from recent core output.
    static func failureDetail(from lines: [String]) -> String? {
        if lines.contains(where: { $0.contains("address already in use") }) {
            return nil
        }
        if let line = lines.last(where: { $0.contains("Failed to start:") }) {
            if let r = line.range(of: " > ", options: .backwards) {
                return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if let r = line.range(of: "Failed to start:") {
                return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    static func indicatesPortBusy(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("address already in use") }
    }

    static func indicatesReady(_ line: String) -> Bool {
        line.contains("core: Xray") && line.contains("started")
    }
}
