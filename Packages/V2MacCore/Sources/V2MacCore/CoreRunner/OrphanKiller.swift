import Darwin
import Foundation

enum OrphanKiller {
    /// Terminates the process recorded in `pidFile` if (and only if) its
    /// executable is one of `allowedExecutables`. Never matches by name.
    @discardableResult
    static func terminateOrphan(pidFile: URL, allowedExecutables: [URL]) -> Bool {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              kill(pid, 0) == 0,
              let path = executablePath(of: pid)
        else { return false }

        let actual = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let allowed = allowedExecutables.map { $0.resolvingSymlinksInPath().path }
        guard allowed.contains(actual) else { return false }

        kill(pid, SIGTERM)
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { return true }
            usleep(50_000)
        }
        kill(pid, SIGKILL)
        return true
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
