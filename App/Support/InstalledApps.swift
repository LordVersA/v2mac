import AppKit
import V2MacCore

/// Apps for app rules (spec 8.6): Xray matches process names and paths, not bundle ids,
/// so `Name.app`, bundle ids and `*word*` entries are looked up here at connect time.
enum InstalledApps {
    @MainActor static func all() async -> [InstalledApp] {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        return await Task.detached {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                           "/System/Library/CoreServices", home + "/Applications"]
            let found = folders.flatMap { folder in
                ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                    .filter { $0.hasSuffix(".app") }.map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
            }
            var seen = Set<String>()
            return (found + running).compactMap { url -> InstalledApp? in
                guard seen.insert(url.path).inserted else { return nil }
                return InstalledApp(path: url.path, bundleID: Bundle(url: url)?.bundleIdentifier ?? "")
            }
        }.value
    }
}
