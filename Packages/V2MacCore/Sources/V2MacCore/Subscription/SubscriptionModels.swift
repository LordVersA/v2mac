import Foundation

public struct SubscriptionMetadata: Sendable, Equatable {
    /// `profile-title`, else the `content-disposition` filename. Callers fall back to the URL host.
    public var title: String?
    public var updateIntervalHours: Int?
    public var usedBytes: Int64?
    public var totalBytes: Int64?
    public var expiresAt: Date?
    public var uploadBytes: Int64?
    public var downloadBytes: Int64?
    /// `support-url` and `profile-web-page-url`; only http(s) links are kept.
    public var supportURL: URL?
    public var webPageURL: URL?

    public init(
        title: String? = nil,
        updateIntervalHours: Int? = nil,
        usedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        expiresAt: Date? = nil,
        uploadBytes: Int64? = nil,
        downloadBytes: Int64? = nil,
        supportURL: URL? = nil,
        webPageURL: URL? = nil
    ) {
        self.title = title
        self.updateIntervalHours = updateIntervalHours
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.expiresAt = expiresAt
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.supportURL = supportURL
        self.webPageURL = webPageURL
    }
}

public struct SkippedEntry: Sendable, Equatable {
    /// 1-based line (link lists) or element number (JSON arrays).
    public var index: Int
    public var reason: String
}

public struct SubscriptionResult: Sendable {
    public var profiles: [ParsedProfile]
    public var skipped: [SkippedEntry]
    public var metadata: SubscriptionMetadata
}

public enum SubscriptionError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case http(Int)
    case tooLarge
    case network(String)
    case unrecognisedFormat
    case unsupportedFormat(String)
    case noServers(skipped: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The subscription URL is not valid."
        case .http(let code): "The server answered HTTP \(code)."
        case .tooLarge: "The subscription is larger than 10 MB."
        case .network(let message): message
        case .unrecognisedFormat: "Unrecognised subscription format."
        case .unsupportedFormat(let name): "\(name) subscriptions are not supported."
        case .noServers(let skipped):
            skipped > 0 ? "No usable servers (\(skipped) skipped)." : "The subscription contains no servers."
        }
    }
}
