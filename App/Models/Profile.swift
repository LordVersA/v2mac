import Foundation
import SwiftData
import V2MacCore

enum DelayState: String, Sendable {
    case untested, ok, timeout, invalid
    /// TCP ping does not apply (UDP-based servers, custom configs).
    case na
}

@Model
final class Profile {
    @Attribute(.unique) var id: UUID
    var group: ServerGroup?
    var sortIndex: Int
    var name: String
    var kindRaw: String
    var protocolName: String
    var address: String
    var port: Int
    var transport: String
    var security: String
    var configJSON: Data
    var originalLink: String?
    var fingerprint: String
    var warnings: [String] = []
    var isStale: Bool = false
    var delayMs: Int?
    var delayStateRaw: String = DelayState.untested.rawValue
    var delayKindRaw: String?
    var delayTestedAt: Date?

    init(parsed: ParsedProfile, sortIndex: Int, group: ServerGroup?) {
        id = UUID()
        self.group = group
        self.sortIndex = sortIndex
        name = parsed.name
        kindRaw = parsed.kind.rawValue
        protocolName = parsed.protocolName
        address = parsed.address
        port = parsed.port
        transport = parsed.transport
        security = parsed.security
        configJSON = (try? parsed.config.data()) ?? Data()
        originalLink = parsed.originalLink
        fingerprint = parsed.fingerprint
        warnings = parsed.warnings
    }

    /// Refresh fields from a re-fetched entry while keeping identity and delay results.
    func update(from parsed: ParsedProfile, sortIndex: Int) {
        self.sortIndex = sortIndex
        name = parsed.name
        originalLink = parsed.originalLink
        warnings = parsed.warnings
        isStale = false
    }
}

extension Profile {
    var kind: ProfileKind { ProfileKind(rawValue: kindRaw) ?? .outbound }
    var delayState: DelayState {
        get { DelayState(rawValue: delayStateRaw) ?? .untested }
        set { delayStateRaw = newValue.rawValue }
    }
    var config: JSONValue? { try? JSONValue.parse(configJSON) }

    /// `protocol · transport · security`, leaving out the uninteresting defaults.
    var typeSummary: String {
        if kind == .custom { return "custom" }
        let parts = [protocolName, transport, security == "none" ? "" : security]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Plain-value snapshot of a profile for tables and lists.
struct ServerRow: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let typeSummary: String
    let address: String
    let delayMs: Int?
    let delayState: DelayState
    let delayKind: String?
    let hasWarnings: Bool
    let isStale: Bool
    let groupOrder: Int
    let sortIndex: Int

    init(_ p: Profile) {
        id = p.id
        name = p.name
        typeSummary = p.typeSummary
        address = p.address
        delayMs = p.delayMs
        delayState = p.delayState
        delayKind = p.delayKindRaw
        hasWarnings = !p.warnings.isEmpty
        isStale = p.isStale
        groupOrder = p.group?.sortIndex ?? 0
        sortIndex = p.sortIndex
    }

    /// Untested and failed rows sort last.
    var delaySortKey: Int {
        delayState == .ok ? (delayMs ?? Int.max) : Int.max
    }
}

/// Everything the connection controller needs, detached from SwiftData.
struct ActiveServer: Sendable, Equatable {
    let id: UUID
    let name: String
    let groupName: String
    let kind: ProfileKind
    let config: JSONValue

    @MainActor
    init?(_ p: Profile) {
        guard let config = p.config else { return nil }
        id = p.id
        name = p.name
        groupName = p.group?.name ?? ""
        kind = p.kind
        self.config = config
    }
}
