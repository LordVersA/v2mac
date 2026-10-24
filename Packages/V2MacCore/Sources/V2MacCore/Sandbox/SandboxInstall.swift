import CryptoKit
import Foundation

/// The one sandbox release a V2Mac build accepts (sandbox plan: "Versions"). The pin is the trust:
/// the archive and, before every launch, the helper's executable must match it.
public struct SandboxPin: Codable, Sendable, Equatable {
    public var url: URL
    /// SHA-256 of the zip, lowercase hex.
    public var sha256: String
    /// SHA-256 of `V2Mac Sandbox.app/Contents/MacOS/V2Mac Sandbox`.
    public var executableSHA256: String
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

/// Layout of `<data>/sandbox/` and the steps that fill it.
public struct SandboxFiles: Sendable {
    public var root: URL
    public init(root: URL) { self.root = root }

    public static let appName = "V2Mac Sandbox.app"
    public var app: URL { root.appendingPathComponent(Self.appName, isDirectory: true) }
    public var executable: URL { app.appendingPathComponent("Contents/MacOS/V2Mac Sandbox") }
    /// Partial download, kept between attempts for resuming.
    public var partial: URL { root.appendingPathComponent("download.part") }
    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// Checks the zip at `partial` against the pin, unpacks it and puts the helper in place.
    /// The old helper (if any) stays until the new one passes every check.
    public func install(_ pin: SandboxPin) async throws {
        guard try Self.sha256(of: partial) == pin.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw SandboxInstallError.checksumMismatch
        }
        let fm = FileManager.default
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        guard try await CoreUpdater.run("/usr/bin/ditto", ["-x", "-k", partial.path, staging.path]).status == 0 else {
            throw SandboxInstallError.unpackFailed
        }
        let staged = SandboxFiles(root: staging)
        guard staged.isInstalled else { throw SandboxInstallError.unpackFailed }
        try staged.verify(pin)
        try? fm.removeItem(at: app)
        try fm.moveItem(at: staged.app, to: app)
        try? fm.removeItem(at: partial)
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
