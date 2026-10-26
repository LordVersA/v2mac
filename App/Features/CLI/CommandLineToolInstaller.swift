import AppKit
import Foundation

@MainActor @Observable
final class CommandLineToolInstaller {
    enum State { case absent, installed, occupied }
    private let link = URL(fileURLWithPath: "/usr/local/bin/v2mac")
    var error: String?

    var state: State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil else { return .absent }
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return .occupied }
        let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.resolvingSymlinksInPath()
        if resolved == embedded.resolvingSymlinksInPath() { return .installed }
        return recognizedV2MacLink(resolved) ? .absent : .occupied
    }

    func install() { change(installing: true) }
    func remove() { change(installing: false) }

    private var embedded: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/v2mac") }

    private func recognizedV2MacLink(_ url: URL) -> Bool {
        url.lastPathComponent == "v2mac" && url.deletingLastPathComponent().lastPathComponent == "Helpers"
            && url.path.contains("V2Mac.app/Contents/Helpers/")
    }

    private func change(installing: Bool) {
        error = nil
        guard state != .occupied else { error = String(localized: "/usr/local/bin/v2mac belongs to another program and was not changed."); return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.isWritableFile(atPath: link.deletingLastPathComponent().path) {
                if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                    let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.resolvingSymlinksInPath()
                    guard resolved == embedded.resolvingSymlinksInPath() || recognizedV2MacLink(resolved) else { throw CocoaError(.fileWriteFileExists) }
                    try fm.removeItem(at: link)
                }
                if installing { try fm.createSymbolicLink(at: link, withDestinationURL: embedded) }
            } else {
                let current = shell(embedded.path)
                let target = shell(link.path)
                let recognized = "case \"$(/usr/bin/readlink \(target) 2>/dev/null)\" in *V2Mac.app/Contents/Helpers/v2mac) /bin/rm \(target);; esac"
                let command = installing
                    ? "\(recognized); if [ ! -e \(target) ] && [ ! -L \(target) ]; then /bin/ln -s \(current) \(target); else exit 73; fi"
                    : "if [ \"$(/usr/bin/readlink \(target) 2>/dev/null)\" = \(current) ]; then /bin/rm \(target); else exit 73; fi"
                var scriptError: NSDictionary?
                NSAppleScript(source: "do shell script \(quoted(command)) with administrator privileges")?.executeAndReturnError(&scriptError)
                if let scriptError { throw NSError(domain: "NSAppleScriptErrorDomain", code: scriptError[NSAppleScript.errorNumber] as? Int ?? -1, userInfo: [NSLocalizedDescriptionKey: scriptError[NSAppleScript.errorMessage] as? String ?? "Administrator access was denied."]) }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func shell(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
