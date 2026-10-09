import Foundation
import SwiftData

@Model
final class ServerGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var subscriptionURL: String
    var sortIndex: Int
    var createdAt: Date
    var autoUpdateEnabled: Bool = true
    var serverIntervalHours: Int?
    var lastUpdatedAt: Date?
    var lastUpdateViaProxy: Bool?
    var lastUpdateError: String?
    var lastSkippedCount: Int = 0
    var usedBytes: Int64?
    var totalBytes: Int64?
    var expiresAt: Date?
    var uploadBytes: Int64?
    var downloadBytes: Int64?
    /// A client User-Agent that made this provider send its usage headers (found automatically).
    var userAgent: String?
    /// True once the automatic User-Agent search has run, so it is not repeated on every update.
    var userAgentProbed: Bool = false
    var supportURL: String?
    var webPageURL: String?
    @Relationship(deleteRule: .cascade, inverse: \Profile.group)
    var profiles: [Profile] = []

    init(name: String, subscriptionURL: String, sortIndex: Int) {
        id = UUID()
        self.name = name
        self.subscriptionURL = subscriptionURL
        self.sortIndex = sortIndex
        createdAt = Date()
    }
}

extension ServerGroup {
    static let manualName = "Custom Configs"

    /// The group for pasted configs: it has no subscription to update from.
    var isManual: Bool { subscriptionURL.isEmpty }
}
