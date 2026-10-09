import Foundation

public struct AppRelease: Sendable, Equatable {
    public var tag: String
    public var pageURL: URL
    public var version: String { VersionCompare.normalized(tag) }
}

/// Reads the latest release of the app's own repository (spec 11.3). Never installs anything.
public enum AppUpdateChecker {
    /// Falls back to the Atom feed when the API cannot be read. It is often rate limited
    /// (HTTP 403/429) behind a proxy server's shared address.
    public static func latest(repository: String, downloader: FileDownloader) async throws -> AppRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest"),
              let atomURL = URL(string: "https://github.com/\(repository)/releases.atom") else {
            throw CoreUpdateError.malformedResponse
        }
        do {
            return try parse(try await downloader.download(url))
        } catch is DownloadError {
            return try parseAtom(try await downloader.download(atomURL))
        }
    }

    /// The highest version among the feed's release links.
    static func parseAtom(_ data: Data) throws -> AppRelease {
        let text = String(decoding: data, as: UTF8.self)
        var best: AppRelease?
        for entry in text.components(separatedBy: "<entry>").dropFirst() {
            guard let link = CoreUpdater.firstMatch(#"href="([^"]+/releases/tag/[^"]+)""#, in: entry),
                  let pageURL = URL(string: link) else { continue }
            let tag = pageURL.lastPathComponent.removingPercentEncoding ?? pageURL.lastPathComponent
            if best == nil || VersionCompare.isNewer(tag, than: best?.tag ?? "") {
                best = AppRelease(tag: tag, pageURL: pageURL)
            }
        }
        guard let best else { throw CoreUpdateError.noRelease }
        return best
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
