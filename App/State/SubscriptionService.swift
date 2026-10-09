import Foundation
import Observation
import SwiftData
import V2MacCore

enum AddSubscriptionError: LocalizedError {
    case duplicate(UUID)
    case needsConnection
    case notAConfig
    case alreadyAdded

    var errorDescription: String? {
        switch self {
        case .notAConfig: "This is not a share link or an Xray config."
        case .alreadyAdded: "These configs are already in Custom Configs."
        case .duplicate: "This subscription is already added."
        case .needsConnection: "Connect first to fetch through the proxy."
        }
    }
}

/// A fetched subscription plus the User-Agent that produced it.
struct FetchOutcome: Sendable {
    var result: SubscriptionResult
    var userAgent: String?
    var probed: Bool
}

extension SubscriptionMetadata {
    /// The provider sent traffic or expiry information.
    var hasUsageInfo: Bool { usedBytes != nil || totalBytes != nil || expiresAt != nil }
}

@MainActor @Observable
final class SubscriptionService {
    /// Client names many panels recognise before they send usage headers. Tried only when the
    /// default User-Agent gets none, and only once per subscription.
    private static let compatibleAgents = ["Happ/1.0", "Hiddify/2.0", "Streisand/1.0", "v2box/1.0"]

    private(set) var updatingGroupIDs: Set<UUID> = []

    private let container: ModelContainer
    private let store: SubscriptionStore
    private let connection: ConnectionController
    private var schedulerTask: Task<Void, Never>?

    init(container: ModelContainer, connection: ConnectionController) {
        self.container = container
        self.store = SubscriptionStore(modelContainer: container)
        self.connection = connection
    }

    /// Fetches with the remembered or default User-Agent. When the response carries no usage
    /// info, other client User-Agents are tried once, and the first that makes the provider send
    /// it is remembered for this subscription. A User-Agent set by hand in Settings is never replaced.
    private func fetch(url: URL, route: FetchRoute, rememberedAgent: String?, alreadyProbed: Bool) async throws -> FetchOutcome {
        let first = try await SubscriptionFetcher(userAgent: rememberedAgent ?? Prefs.userAgent).fetch(url: url, route: route)
        let customised = !(UserDefaults.standard.string(forKey: "userAgent") ?? "").isEmpty
        if first.metadata.hasUsageInfo || rememberedAgent != nil || alreadyProbed || customised {
            return FetchOutcome(result: first, userAgent: rememberedAgent, probed: alreadyProbed || first.metadata.hasUsageInfo)
        }
        for agent in Self.compatibleAgents {
            if let alternative = try? await SubscriptionFetcher(userAgent: agent).fetch(url: url, route: route),
               alternative.metadata.hasUsageInfo, !alternative.profiles.isEmpty {
                return FetchOutcome(result: alternative, userAgent: agent, probed: true)
            }
        }
        return FetchOutcome(result: first, userAgent: nil, probed: true)
    }

    private func route(viaProxy: Bool) throws -> FetchRoute {
        guard viaProxy else { return .direct }
        guard connection.isRunning else { throw AddSubscriptionError.needsConnection }
        return .localProxy(port: connection.port)
    }

    private func existingGroupID(url: String) -> UUID? {
        let groups = try? container.mainContext.fetch(FetchDescriptor<ServerGroup>())
        return groups?.first { $0.subscriptionURL == url }?.id
    }

    /// Fetches first; the group is created only on success.
    func add(urlString: String, name: String, viaProxy: Bool) async throws -> UUID {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw SubscriptionError.invalidURL }
        if let existing = existingGroupID(url: trimmed) { throw AddSubscriptionError.duplicate(existing) }

        let route = try route(viaProxy: viaProxy)
        let outcome = try await fetch(url: url, route: route, rememberedAgent: nil, alreadyProbed: false)
        let result = outcome.result
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupName = !typed.isEmpty ? typed : (result.metadata.title ?? url.host ?? "Subscription")
        return try await store.createGroup(url: trimmed, name: groupName, outcome: outcome, viaProxy: viaProxy)
    }

    /// Adds pasted share links or Xray JSON (one or many) to the Custom Configs group.
    func addCustom(text: String) async throws -> UUID {
        let result: SubscriptionResult
        do {
            result = try SubscriptionParser.parse(text: text)
        } catch SubscriptionError.unrecognisedFormat {
            throw AddSubscriptionError.notAConfig
        }
        let (groupID, added) = try await store.addManual(result.profiles, groupName: "Custom Configs")
        guard added > 0 else { throw AddSubscriptionError.alreadyAdded }
        return groupID
    }

    func update(groupID: UUID, viaProxy: Bool) async {
        guard !updatingGroupIDs.contains(groupID) else { return }
        guard let group = try? container.mainContext.fetch(
            FetchDescriptor<ServerGroup>(predicate: #Predicate { $0.id == groupID })
        ).first, let url = URL(string: group.subscriptionURL) else { return }

        updatingGroupIDs.insert(groupID)
        defer { updatingGroupIDs.remove(groupID) }
        do {
            let outcome = try await fetch(
                url: url, route: try route(viaProxy: viaProxy),
                rememberedAgent: group.userAgent, alreadyProbed: group.userAgentProbed
            )
            try await store.apply(outcome, to: groupID, viaProxy: viaProxy, activeProfileID: connection.activeServer?.id)
        } catch {
            try? await store.recordFailure(groupID: groupID, message: error.localizedDescription)
        }
    }

    /// Refreshes due groups shortly after launch, then every 15 minutes (spec 6.5).
    func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.updateDueGroups()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func updateDueGroups(now: Date = Date()) async {
        guard Prefs.autoUpdateSubscriptions else { return }
        let viaProxy = Prefs.subscriptionUpdateViaProxy
        // Via-proxy updates wait silently for a running core.
        if viaProxy && !connection.isRunning { return }
        let groups = (try? container.mainContext.fetch(FetchDescriptor<ServerGroup>())) ?? []
        let due = groups.filter { group in
            guard group.autoUpdateEnabled, !group.isManual else { return false }
            guard let last = group.lastUpdatedAt else { return true }
            let hours = group.serverIntervalHours ?? Prefs.defaultIntervalHours
            return now.timeIntervalSince(last) >= Double(hours) * 3600
        }
        for group in due { await update(groupID: group.id, viaProxy: viaProxy) }
    }

    func updateAll(viaProxy: Bool) async {
        let ids = ((try? container.mainContext.fetch(FetchDescriptor<ServerGroup>())) ?? []).map(\.id)
        await withTaskGroup(of: Void.self) { tasks in
            for id in ids { tasks.addTask { await self.update(groupID: id, viaProxy: viaProxy) } }
        }
    }
}
