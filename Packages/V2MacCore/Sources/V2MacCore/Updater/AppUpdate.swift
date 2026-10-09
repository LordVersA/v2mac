import Foundation

public struct AppRelease: Sendable, Equatable {
    public var tag: String
    public var pageURL: URL
    public var version: String { VersionCompare.normalized(tag) }
}

/// Reads the latest release of the app's own repository (spec 11.3). Never installs anything.
public enum AppUpdateChecker {
    public static func latest(repository: String, downloader: FileDownloader) async throws -> AppRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw CoreUpdateError.malformedResponse
        }
        return try parse(try await downloader.download(url))
    }

    static func parse(_ data: Data) throws -> AppRelease {
        struct Release: Decodable { var tag_name: String; var html_url: URL }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw CoreUpdateError.malformedResponse
        }
        return AppRelease(tag: release.tag_name, pageURL: release.html_url)
    }

    /// The release when it is newer than `currentVersion`.
    public static func newer(than currentVersion: String, repository: String, downloader: FileDownloader) async throws -> AppRelease? {
        let release = try await latest(repository: repository, downloader: downloader)
        return VersionCompare.isNewer(release.tag, than: currentVersion) ? release : nil
    }
}
