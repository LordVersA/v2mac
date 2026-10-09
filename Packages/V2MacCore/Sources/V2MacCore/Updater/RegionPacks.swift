import CryptoKit
import Foundation

public struct RegionPackFile: Codable, Sendable, Equatable {
    public var url: URL
    public var file: String
    public var tags: [String]
}

/// One entry of the bundled `RegionPacks.json`. Adding a region is a data change.
public struct RegionPackDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var attribution: String
    public var geosite: RegionPackFile
    public var geoip: RegionPackFile

    public var route: RegionRoute {
        RegionRoute(geositeFile: geosite.file, geositeTags: geosite.tags, geoipFile: geoip.file, geoipTags: geoip.tags)
    }

    public static func decodeList(_ data: Data) throws -> [RegionPackDefinition] {
        try JSONDecoder().decode([RegionPackDefinition].self, from: data)
    }
}

public enum DownloadError: Error, Sendable, Equatable, LocalizedError {
    case http(Int)
    case tooLarge
    case checksumMalformed
    case checksumMismatch(file: String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): "The server answered HTTP \(code)."
        case .tooLarge: "The download is larger than allowed."
        case .checksumMalformed: "The published checksum could not be read."
        case .checksumMismatch(let file): "Checksum mismatch for \(file); the download was discarded."
        case .network(let message): message
        }
    }
}

/// Downloads a file, trying each route in order (spec 11: local proxy first, then direct).
public struct FileDownloader: Sendable {
    public var routes: [FetchRoute]
    public var timeout: TimeInterval
    public var maxBytes: Int

    public init(routes: [FetchRoute], timeout: TimeInterval = 60, maxBytes: Int = 64 * 1024 * 1024) {
        self.routes = routes.isEmpty ? [.direct] : routes
        self.timeout = timeout
        self.maxBytes = maxBytes
    }

    public func download(_ url: URL) async throws -> Data {
        var lastError: Error = DownloadError.network("No route available.")
        for route in routes {
            do {
                return try await download(url, route: route)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func download(_ url: URL, route: FetchRoute) async throws -> Data {
        let session = SessionFactory.make(route: route, timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse else { throw DownloadError.network("Invalid response.") }
            guard (200..<300).contains(http.statusCode) else { throw DownloadError.http(http.statusCode) }
            if http.expectedContentLength > Int64(maxBytes) { throw DownloadError.tooLarge }
            var data = Data()
            for try await chunk in bytes {
                data.append(chunk)
                if data.count > maxBytes { throw DownloadError.tooLarge }
            }
            return data
        } catch let error as DownloadError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw DownloadError.network(error.localizedDescription)
        }
    }
}

public enum RegionPackInstaller {
    /// First whitespace-separated token of a `<hex>  path` line.
    public static func parseChecksum(_ data: Data) throws -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard let token = text.split(whereSeparator: { $0.isWhitespace }).first,
              token.count == 64, token.allSatisfy(\.isHexDigit)
        else { throw DownloadError.checksumMalformed }
        return token.lowercased()
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads and verifies both files, then moves them into `assetDirectory`.
    /// Nothing is written unless both pass.
    public static func install(_ pack: RegionPackDefinition, assetDirectory: URL, downloader: FileDownloader) async throws {
        var verified: [(file: String, data: Data)] = []
        for source in [pack.geosite, pack.geoip] {
            let data = try await downloader.download(source.url)
            let sumURL = URL(string: source.url.absoluteString + ".sha256sum")!
            let expected = try parseChecksum(try await downloader.download(sumURL))
            guard sha256(data) == expected else { throw DownloadError.checksumMismatch(file: source.file) }
            verified.append((source.file, data))
        }

        let fm = FileManager.default
        try fm.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        for item in verified {
            let target = assetDirectory.appendingPathComponent(item.file)
            let tmp = assetDirectory.appendingPathComponent(".\(item.file).tmp")
            try item.data.write(to: tmp)
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        }
    }

    public static func isInstalled(_ pack: RegionPackDefinition, assetDirectory: URL) -> Bool {
        [pack.geosite.file, pack.geoip.file].allSatisfy {
            FileManager.default.fileExists(atPath: assetDirectory.appendingPathComponent($0).path)
        }
    }

    public static func remove(_ pack: RegionPackDefinition, assetDirectory: URL) {
        for file in [pack.geosite.file, pack.geoip.file] {
            try? FileManager.default.removeItem(at: assetDirectory.appendingPathComponent(file))
        }
    }
}
