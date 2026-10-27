import CryptoKit
import Foundation

/// An app bundle's release file by file: the Secure Sandbox's (sandbox repo, docs/delta-updates.md, pinned by
/// `SandboxPin.sha256`) and V2Mac's own (docs/app-auto-update.md, signed with `AppInstaller.updateKey`), written
/// by each repo's packaging script. Every source is checked against it before use.
public struct BundleManifest: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        /// A file name beside the manifest.
        public var url: String
        public var sha256: String
        public var size: Int64
        /// Patches only: SHA-256 of the installed file this bsdiff patch applies to.
        public var from: String?
    }

    public struct File: Codable, Sendable, Equatable {
        /// Inside the bundle, e.g. `Contents/Resources/rootfs.erofs`.
        public var path: String
        public var sha256: String
        public var size: Int64
        public var executable: Bool
        public var zip: Source
        public var patches: [Source]
    }

    public enum Step: Sendable, Equatable {
        /// The installed file already is the new one.
        case copy
        case patch(Source)
        case full
    }

    public var version: String
    public var files: [File]

    public static let maxSize = 1 << 20

    /// Decodes and refuses anything that could leave the bundle or the release's folder.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        let hex = { (s: String) in s.count == 64 && s.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase } }
        let name = { (s: String) in
            !s.isEmpty && !s.hasPrefix(".") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
        let pathOK = { (p: String) in
            let parts = p.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count > 1 && parts[0] == "Contents" && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
        }
        let sources = files.flatMap { [$0.zip] + $0.patches }
        guard Set(files.map(\.path)).count == files.count,
              files.allSatisfy({ pathOK($0.path) && hex($0.sha256) && $0.size >= 0 && $0.zip.from == nil }),
              files.allSatisfy({ $0.patches.allSatisfy { $0.from.map(hex) == true } }),
              sources.allSatisfy({ name($0.url) && hex($0.sha256) && $0.size > 0 && $0.size <= 4 << 30 })
        else { throw SandboxInstallError.checksumMismatch }
    }

    /// For each file, from the SHA-256 of its installed copy (none when missing): copy it, patch it,
    /// or download it in full.
    public func plan(installed: [String: String]) -> [(file: File, step: Step)] {
        files.map { file in
            guard let have = installed[file.path] else { return (file, .full) }
            if have == file.sha256 { return (file, .copy) }
            return (file, file.patches.first { $0.from == have }.map(Step.patch) ?? .full)
        }
    }

    public static func downloadSize(_ plan: [(file: File, step: Step)]) -> Int64 {
        plan.reduce(0) { sum, item in
            switch item.step {
            case .copy: sum
            case .patch(let patch): sum + patch.size
            case .full: sum + item.file.zip.size
            }
        }
    }

    /// Each file's current copy and its SHA-256: the one in `installed`, or `alternates[path]` when that one
    /// already is the new file (V2Mac's separately fetched `core/xray`).
    public func current(in installed: URL, alternates: [String: URL] = [:]) -> [String: (url: URL, sha256: String)] {
        let fm = FileManager.default
        var out: [String: (url: URL, sha256: String)] = [:]
        for file in files {
            let candidates = ([installed.appendingPathComponent(file.path)] + [alternates[file.path]].compactMap { $0 })
                .compactMap { url -> (url: URL, sha256: String)? in
                    guard (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular else { return nil }
                    return (try? Self.sha256(of: url)).map { (url, $0) }
                }
            out[file.path] = candidates.first { $0.sha256 == file.sha256 } ?? candidates.first
        }
        return out
    }

    /// Builds this release at `target` (whose folder must exist) file by file: unchanged files copied from
    /// `installed`, patches where they apply, the rest downloaded in full from beside `release` (the manifest's
    /// URL). Downloads are kept in `downloads`, named by SHA-256, so a later attempt resumes them. A failed
    /// patch falls back to that file's zip. Every result is checked against the manifest.
    public func build(at target: URL, from installed: URL, alternates: [String: URL] = [:], release: URL,
                      downloads: URL, download: ResumableDownload,
                      onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        let fm = FileManager.default
        let current = current(in: installed, alternates: alternates)
        let steps = plan(installed: current.mapValues(\.sha256))
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let unpacked = target.deletingLastPathComponent().appendingPathComponent("unpack", isDirectory: true)
        var total = Self.downloadSize(steps)
        var done: Int64 = 0
        func fetch(_ source: Source) async throws -> URL {
            let file = downloads.appendingPathComponent(source.sha256)
            let (base, sum) = (done, total)
            try await download.fetch(URL(string: source.url, relativeTo: release)!.absoluteURL, to: file, expectedSize: source.size) { p in
                onProgress?(DownloadProgress(received: base + p.received, total: sum))
            }
            done += source.size
            guard try Self.sha256(of: file) == source.sha256 else {
                try? fm.removeItem(at: file)
                throw SandboxInstallError.checksumMismatch
            }
            return file
        }
        for (file, step) in steps {
            let out = target.appendingPathComponent(file.path)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            func full() async throws {
                try? fm.removeItem(at: unpacked)
                defer { try? fm.removeItem(at: unpacked) }
                let zip = try await fetch(file.zip)
                guard try await CoreUpdater.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else {
                    throw SandboxInstallError.unpackFailed
                }
                let result = unpacked.appendingPathComponent(out.lastPathComponent)
                guard (try? fm.attributesOfItem(atPath: result.path)[.type] as? FileAttributeType) == .typeRegular,
                      try Self.sha256(of: result) == file.sha256 else { throw SandboxInstallError.checksumMismatch }
                try fm.moveItem(at: result, to: out)
            }
            switch step {
            case .copy:
                try fm.copyItem(at: current[file.path]!.url, to: out) // an APFS clone
            case .patch(let patch):
                do {
                    let diff = try await fetch(patch)
                    guard try await CoreUpdater.run("/usr/bin/bspatch", [current[file.path]!.url.path, out.path, diff.path]).status == 0,
                          try Self.sha256(of: out) == file.sha256 else { throw SandboxInstallError.checksumMismatch }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? fm.removeItem(at: out)
                    total += file.zip.size
                    try await full()
                }
            case .full:
                try await full()
            }
            try fm.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: out.path)
        }
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
