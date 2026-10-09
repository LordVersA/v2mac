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
