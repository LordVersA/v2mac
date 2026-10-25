import CryptoKit
import Foundation

/// The one sandbox release a V2Mac build accepts (sandbox plan: "Versions"). The pin is the trust:
/// the release's manifest and, before every launch, the helper's executable must match it.
public struct SandboxPin: Codable, Sendable, Equatable {
    /// The release's `files.json` (`SandboxManifest`).
    public var url: URL
    /// SHA-256 of the manifest, lowercase hex.
    public var sha256: String
    /// SHA-256 of `V2Mac Sandbox.app/Contents/MacOS/V2Mac Sandbox`.
    public var executableSHA256: String
    /// What a first install downloads: every file's zip.
    public var size: Int64
    /// The release's version, shown when it updates an installed sandbox.
    public var version: String?

    public init(url: URL, sha256: String, executableSHA256: String, size: Int64, version: String? = nil) {
        self.url = url
        self.sha256 = sha256
        self.executableSHA256 = executableSHA256
        self.size = size
        self.version = version
    }
}

public enum SandboxInstallError: Error, Sendable, Equatable, LocalizedError {
    case checksumMismatch
    case unpackFailed
    case helperChanged

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch: String(localized: "The downloaded sandbox does not match the one this V2Mac expects.")
        case .unpackFailed: String(localized: "The downloaded sandbox could not be unpacked.")
        case .helperChanged: String(localized: "The sandbox helper on disk was changed. Remove the sandbox and download it again.")
        }
    }
}

/// A sandbox release file by file (sandbox repo, docs/delta-updates.md), written by its
/// `Scripts/package.sh` and pinned by `SandboxPin.sha256`. Every source is checked against it before use.
public struct SandboxManifest: Codable, Sendable, Equatable {
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
}

/// Layout of `<data>/sandbox/` and the steps that fill it.
public struct SandboxFiles: Sendable {
    public var root: URL
    public init(root: URL) { self.root = root }

    public static let appName = "V2Mac Sandbox.app"
    public var app: URL { root.appendingPathComponent(Self.appName, isDirectory: true) }
    public var executable: URL { app.appendingPathComponent("Contents/MacOS/V2Mac Sandbox") }
    /// Partial and finished downloads, named by their SHA-256, kept between attempts for resuming.
    public var downloads: URL { root.appendingPathComponent("download", isDirectory: true) }
    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// Fetches the pinned manifest and plans every file against the installed bundle.
    public func plan(_ pin: SandboxPin, download: ResumableDownload) async throws -> [(file: SandboxManifest.File, step: SandboxManifest.Step)] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("files.json")
        try? fm.removeItem(at: file) // a leftover would be resumed, not replaced
        defer { try? fm.removeItem(at: file) }
        try await download.fetch(pin.url, to: file, expectedSize: Int64(SandboxManifest.maxSize))
        guard try Self.sha256(of: file) == pin.sha256 else { throw SandboxInstallError.checksumMismatch }
        let manifest = try SandboxManifest(data: Data(contentsOf: file))
        var installed: [String: String] = [:]
        for entry in manifest.files {
            let url = app.appendingPathComponent(entry.path)
            guard (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular else { continue }
            installed[entry.path] = try? Self.sha256(of: url)
        }
        return manifest.plan(installed: installed)
    }

    /// Builds the pinned release in `staging/` file by file (unchanged files copied, patches where they
    /// apply, the rest in full), checks it and puts it in place of the installed helper, which stays
    /// until every check has passed. A failed patch falls back to that file's zip.
    public func install(_ pin: SandboxPin, download: ResumableDownload,
                        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        let fm = FileManager.default
        let steps = try await plan(pin, download: download)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        let staged = SandboxFiles(root: staging)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        var total = SandboxManifest.downloadSize(steps)
        var done: Int64 = 0
        func fetch(_ source: SandboxManifest.Source) async throws -> URL {
            let file = downloads.appendingPathComponent(source.sha256)
            let (base, sum) = (done, total)
            try await download.fetch(URL(string: source.url, relativeTo: pin.url)!.absoluteURL, to: file, expectedSize: source.size) { p in
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
            let target = staged.app.appendingPathComponent(file.path)
            let installed = app.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            func full() async throws {
                let unpacked = staging.appendingPathComponent("unpack", isDirectory: true)
                try? fm.removeItem(at: unpacked)
                defer { try? fm.removeItem(at: unpacked) }
                let zip = try await fetch(file.zip)
                guard try await CoreUpdater.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else {
                    throw SandboxInstallError.unpackFailed
                }
                let out = unpacked.appendingPathComponent(target.lastPathComponent)
                guard (try? fm.attributesOfItem(atPath: out.path)[.type] as? FileAttributeType) == .typeRegular,
                      try Self.sha256(of: out) == file.sha256 else { throw SandboxInstallError.checksumMismatch }
                try fm.moveItem(at: out, to: target)
            }
            switch step {
            case .copy:
                try fm.copyItem(at: installed, to: target) // an APFS clone
            case .patch(let patch):
                do {
                    let diff = try await fetch(patch)
                    guard try await CoreUpdater.run("/usr/bin/bspatch", [installed.path, target.path, diff.path]).status == 0,
                          try Self.sha256(of: target) == file.sha256 else { throw SandboxInstallError.checksumMismatch }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? fm.removeItem(at: target)
                    total += file.zip.size
                    try await full()
                }
            case .full:
                try await full()
            }
            try fm.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: target.path)
        }
        try staged.verify(pin)
        try? fm.removeItem(at: app)
        try fm.moveItem(at: staged.app, to: app)
        try? fm.removeItem(at: downloads)
        try? fm.removeItem(at: root.appendingPathComponent("download.part")) // from the whole-zip releases
    }

    /// Run before every launch: the executable on disk must still be the pinned one.
    public func verify(_ pin: SandboxPin) throws {
        guard (try? Self.sha256(of: executable)) == pin.executableSHA256 else { throw SandboxInstallError.helperChanged }
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Default RAM cap (sandbox plan: "Resources"): a quarter of the Mac's memory, 2–8 GB.
    public static func defaultRAMCapMB(physicalMemory: UInt64) -> Int {
        min(max(Int(physicalMemory >> 20) / 4, 2048), 8192)
    }
}

/// Downloads a large file into `destination`, continuing a partial file with a `Range` request.
/// Each route is tried in order (spec 11); the partial file survives a failure for the next attempt.
public struct ResumableDownload: Sendable {
    public var routes: [FetchRoute]
    public var timeout: TimeInterval

    public init(routes: [FetchRoute], timeout: TimeInterval = 60) {
        self.routes = routes.isEmpty ? [.direct] : routes
        self.timeout = timeout
    }

    public func fetch(_ url: URL, to destination: URL, expectedSize: Int64,
                      onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        var lastError: Error = DownloadError.network("No route available.")
        for route in routes {
            do {
                return try await fetch(url, to: destination, expectedSize: expectedSize, route: route, onProgress: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func fetch(_ url: URL, to destination: URL, expectedSize: Int64, route: FetchRoute,
                       onProgress: (@Sendable (DownloadProgress) -> Void)?) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) { fm.createFile(atPath: destination.path, contents: nil) }
        let have = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        if have >= expectedSize, expectedSize > 0 { return }
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let writer = try Writer(file: destination, have: have, limit: expectedSize, onProgress: onProgress)
        let session = SessionFactory.make(route: route, timeout: timeout, delegate: writer)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Delegate callbacks arrive one at a time on the session's serial queue.
    private final class Writer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        let limit: Int64
        let onProgress: (@Sendable (DownloadProgress) -> Void)?
        var continuation: CheckedContinuation<Void, Error>?
        private var written: Int64
        private var failure: Error?
        private var lastReport = ContinuousClock.now

        init(file: URL, have: Int64, limit: Int64, onProgress: (@Sendable (DownloadProgress) -> Void)?) throws {
            handle = try FileHandle(forWritingTo: file)
            written = have
            self.limit = limit
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard BoundedFetch.allowsRedirect(from: response.url, to: request.url) else {
                failure = URLError(.appTransportSecurityRequiresSecureConnection)
                task.cancel()
                return completionHandler(nil)
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 206: break
            case 200: // the server ignored the Range: start over
                written = 0
            default:
                failure = DownloadError.http(status)
                return completionHandler(.cancel)
            }
            do {
                try handle.truncate(atOffset: UInt64(written))
                try handle.seekToEnd()
            } catch {
                failure = error
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            written += Int64(data.count)
            guard written <= limit else {
                failure = DownloadError.tooLarge
                return dataTask.cancel()
            }
            do { try handle.write(contentsOf: data) } catch {
                failure = error
                return dataTask.cancel()
            }
            if let onProgress, ContinuousClock.now - lastReport >= .milliseconds(100) {
                lastReport = .now
                onProgress(DownloadProgress(received: written, total: limit))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            guard let continuation else { return }
            self.continuation = nil
            if let error = failure ?? error { return continuation.resume(throwing: error) }
            onProgress?(DownloadProgress(received: written, total: limit))
            continuation.resume()
        }
    }
}
