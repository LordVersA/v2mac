import Foundation

public struct CoreRelease: Sendable, Equatable {
    public var tag: String
    public var publishedAt: Date?
    public var assetURL: URL
    public var checksumURL: URL

    public var version: String { VersionCompare.normalized(tag) }

    public init(tag: String, publishedAt: Date?, assetURL: URL, checksumURL: URL) {
        self.tag = tag
        self.publishedAt = publishedAt
        self.assetURL = assetURL
        self.checksumURL = checksumURL
    }
}

public enum CoreUpdateError: Error, Sendable, Equatable, LocalizedError {
    case noRelease
    case malformedResponse
    case checksumMissing
    case unpackFailed
    case missingFile(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noRelease: "No macOS arm64 build was found in the latest releases."
        case .malformedResponse: "GitHub's answer could not be read."
        case .checksumMissing: "The release has no SHA-256 checksum."
        case .unpackFailed: "The downloaded archive could not be unpacked."
        case .missingFile(let name): "The archive does not contain \(name)."
        case .verificationFailed(let detail): "The new core failed its self-test: \(detail)"
        }
    }
}

public enum VersionCompare {
    /// "v26.9.30" and "Xray 26.9.30 (go1…)" both become "26.9.30".
    public static func normalized(_ text: String) -> String {
        let scanner = text.drop { !$0.isNumber }
        return String(scanner.prefix { $0.isNumber || $0 == "." })
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalized(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalized(current).split(separator: ".").map { Int($0) ?? 0 }
        guard !a.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

public enum CoreUpdater {
    public static let assetName = "Xray-macos-arm64-v8a.zip"
    static let apiURL = URL(string: "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=10")!
    static let atomURL = URL(string: "https://github.com/XTLS/Xray-core/releases.atom")!

    // MARK: Discover

    /// Newest release by publish date, pre-releases included. Falls back to the Atom
    /// feed when the API is rate limited (HTTP 403/429).
    public static func discover(downloader: FileDownloader) async throws -> CoreRelease {
        do {
            return try parseAPI(try await downloader.download(apiURL))
        } catch DownloadError.http(let code) where code == 403 || code == 429 {
            return try parseAtom(try await downloader.download(atomURL))
        }
    }

    static func parseAPI(_ data: Data) throws -> CoreRelease {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        struct Release: Decodable {
            var tag_name: String
            var published_at: Date?
            var draft: Bool?
            var assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let releases = try? decoder.decode([Release].self, from: data) else {
            throw CoreUpdateError.malformedResponse
        }
        let candidates = releases
            .filter { $0.draft != true }
            .sorted { ($0.published_at ?? .distantPast) > ($1.published_at ?? .distantPast) }
        for release in candidates {
            guard let zip = release.assets.first(where: { $0.name == assetName }) else { continue }
            let dgst = release.assets.first { $0.name == assetName + ".dgst" }?.browser_download_url
                ?? URL(string: zip.browser_download_url.absoluteString + ".dgst")!
            return CoreRelease(tag: release.tag_name, publishedAt: release.published_at, assetURL: zip.browser_download_url, checksumURL: dgst)
        }
        throw CoreUpdateError.noRelease
    }

    static func parseAtom(_ data: Data) throws -> CoreRelease {
        let text = String(decoding: data, as: UTF8.self)
        let formatter = ISO8601DateFormatter()
        var best: (tag: String, date: Date?)?
        for entry in text.components(separatedBy: "<entry>").dropFirst() {
            guard let tag = firstMatch(#"/releases/tag/([^"<]+)""#, in: entry) else { continue }
            let date = firstMatch(#"<updated>([^<]+)</updated>"#, in: entry).flatMap(formatter.date(from:))
            if best == nil || (date ?? .distantPast) > (best?.date ?? .distantPast) { best = (tag, date) }
        }
        guard let best else { throw CoreUpdateError.noRelease }
        let base = "https://github.com/XTLS/Xray-core/releases/download/\(best.tag)/\(assetName)"
        return CoreRelease(
            tag: best.tag,
            publishedAt: best.date,
            assetURL: URL(string: base)!,
            checksumURL: URL(string: base + ".dgst")!
        )
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// The `SHA2-256=` value of a `.dgst` file.
    public static func parseDigest(_ data: Data) throws -> String {
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let lower = line.lowercased().replacingOccurrences(of: " ", with: "")
            for prefix in ["sha2-256=", "sha256="] where lower.hasPrefix(prefix) {
                let value = String(lower.dropFirst(prefix.count))
                if value.count == 64, value.allSatisfy(\.isHexDigit) { return value }
            }
        }
        throw CoreUpdateError.checksumMissing
    }

    // MARK: Install

    public struct Installed: Sendable, Equatable {
        public var version: String
    }

    /// Downloads, verifies, unpacks and self-tests the release, then moves the binary into
    /// `coreDirectory` and the geo files into `assetDirectory`. Nothing is touched unless every
    /// check passes. `currentConfig`, when given, is also run through `xray run -test`.
    public static func install(
        _ release: CoreRelease,
        downloader: FileDownloader,
        coreDirectory: URL,
        assetDirectory: URL,
        currentConfig: URL? = nil
    ) async throws -> Installed {
        let zip = try await downloader.download(release.assetURL)
        let expected = try parseDigest(try await downloader.download(release.checksumURL))
        guard RegionPackInstaller.sha256(zip) == expected else {
            throw DownloadError.checksumMismatch(file: assetName)
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("v2mac-core-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }

        let zipURL = work.appendingPathComponent("core.zip")
        try zip.write(to: zipURL)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard try await run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpacked.path]).status == 0 else {
            throw CoreUpdateError.unpackFailed
        }

        let binary = unpacked.appendingPathComponent("xray")
        guard fm.fileExists(atPath: binary.path) else { throw CoreUpdateError.missingFile("xray") }
        for name in ["geoip.dat", "geosite.dat"] where !fm.fileExists(atPath: unpacked.appendingPathComponent(name).path) {
            throw CoreUpdateError.missingFile(name)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        _ = try? await run("/usr/bin/xattr", ["-cr", unpacked.path])

        let versionRun = try await run(binary.path, ["version"])
        guard versionRun.status == 0, let version = versionRun.output.split(separator: "\n").first.map(String.init) else {
            throw CoreUpdateError.verificationFailed("it does not start on this Mac")
        }

        var configs: [URL] = []
        let probe = work.appendingPathComponent("probe.json")
        let probeConfig = try ConfigBuilder.build(
            outbound: ["protocol": "freedom", "tag": "proxy"],
            options: RunOptions(inbound: InboundSettings(port: 10808), metricsPort: 10809),
            routing: .global
        )
        try probeConfig.data(pretty: true).write(to: probe)
        configs.append(probe)
        if let currentConfig, fm.fileExists(atPath: currentConfig.path) { configs.append(currentConfig) }
        for config in configs {
            let test = try await run(binary.path, ["run", "-test", "-c", config.path],
                                     environment: ["XRAY_LOCATION_ASSET": unpacked.path])
            guard test.status == 0 else {
                throw CoreUpdateError.verificationFailed(test.output.split(separator: "\n").last.map(String.init) ?? "config test failed")
            }
        }

        try fm.createDirectory(at: coreDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: assetDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try replace(binary, in: coreDirectory)
        for name in ["geoip.dat", "geosite.dat"] {
            try replace(unpacked.appendingPathComponent(name), in: assetDirectory)
        }
        return Installed(version: VersionCompare.normalized(version))
    }

    private static func replace(_ source: URL, in directory: URL) throws {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(source.lastPathComponent)
        let staged = directory.appendingPathComponent(".\(source.lastPathComponent).new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        // A symlink to the bundle is replaced, never written through.
        if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { try fm.removeItem(at: target) }
        _ = try fm.replaceItemAt(target, withItemAt: staged)
    }

    /// Deletes the updated core and geo copies; the caller restores the bundle symlinks.
    public static func revert(coreDirectory: URL, assetDirectory: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: coreDirectory.appendingPathComponent("xray"))
        for name in ["geoip.dat", "geosite.dat"] {
            let url = assetDirectory.appendingPathComponent(name)
            let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            if type == .typeRegular { try? fm.removeItem(at: url) }
        }
    }

    // MARK: Process helper

    static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
