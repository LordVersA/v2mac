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

    /// Events worth a notification (spec 12.8); `AppModel` turns them into one.
    enum Notice {
        case updateFailed(group: String, message: String)
        case serversChanged(group: String, added: Int, removed: Int, activeRemoved: Bool)
        case expiry(group: String, level: UsageAlert.Expiry, expiresAt: Date)
        case traffic(group: String, level: UsageAlert.Traffic, used: Int64, total: Int64)
    }
    @ObservationIgnored var onNotice: @MainActor (Notice) -> Void = { _ in }

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
        let (groupID, added) = try await store.addManual(result.profiles, groupName: ServerGroup.manualName)
        guard added > 0 else { throw AddSubscriptionError.alreadyAdded }
        return groupID
    }

    /// `scheduled` marks an automatic update: only those announce a failure or changed servers,
    /// since a manual update shows both in the window.
    func update(groupID: UUID, viaProxy: Bool, scheduled: Bool = false) async {
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
            let summary = try await store.apply(outcome, to: groupID, viaProxy: viaProxy, activeProfileID: connection.activeServer?.id)
            guard let summary else { return }
            if scheduled, summary.added + summary.removed > 0 {
                onNotice(.serversChanged(group: summary.groupName, added: summary.added, removed: summary.removed, activeRemoved: summary.activeRemoved))
            }
            checkUsage(groupID: groupID, name: summary.groupName, used: summary.usedBytes, total: summary.totalBytes, expiresAt: summary.expiresAt)
        } catch {
            // Announced for the first failure only; the scheduler retries every 15 minutes.
            if scheduled, group.lastUpdateError == nil {
                onNotice(.updateFailed(group: group.name, message: error.localizedDescription))
            }
            try? await store.recordFailure(groupID: groupID, message: error.localizedDescription)
        }
    }

    /// Announces an expiry or traffic level the first time a subscription reaches it.
    private func checkUsage(groupID: UUID, name: String, used: Int64?, total: Int64?, expiresAt: Date?, now: Date = Date()) {
        if let expiresAt {
            let level = UsageAlert.expiry(expiresAt: expiresAt, now: now)
            let step = UsageAlert.step(
                level: level.rawValue, subject: "\(Int(expiresAt.timeIntervalSince1970))",
                marker: Prefs.usageMarker("notifiedExpiry", group: groupID)
            )
            Prefs.setUsageMarker(step.marker, "notifiedExpiry", group: groupID)
            if step.notify { onNotice(.expiry(group: name, level: level, expiresAt: expiresAt)) }
        }
        if let used, let total, total > 0 {
            let level = UsageAlert.traffic(used: used, total: total)
            let step = UsageAlert.step(
                level: level.rawValue, subject: "\(total)",
                marker: Prefs.usageMarker("notifiedTraffic", group: groupID)
            )
            Prefs.setUsageMarker(step.marker, "notifiedTraffic", group: groupID)
            if step.notify { onNotice(.traffic(group: name, level: level, used: used, total: total)) }
        }
    }

    /// An expiry date comes closer without any update, so every group is looked at on each tick.
    func checkAllUsage() {
        for group in (try? container.mainContext.fetch(FetchDescriptor<ServerGroup>())) ?? [] where !group.isManual {
            checkUsage(groupID: group.id, name: group.name, used: group.usedBytes, total: group.totalBytes, expiresAt: group.expiresAt)
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
        checkAllUsage()
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
        for group in due { await update(groupID: group.id, viaProxy: viaProxy, scheduled: true) }
    }

    func updateAll(viaProxy: Bool) async {
        let ids = ((try? container.mainContext.fetch(FetchDescriptor<ServerGroup>())) ?? []).map(\.id)
        await withTaskGroup(of: Void.self) { tasks in
            for id in ids { tasks.addTask { await self.update(groupID: id, viaProxy: viaProxy) } }
        }
    }
}
