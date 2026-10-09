import Foundation
import Observation
import SwiftData
import V2MacCore

enum AddSubscriptionError: LocalizedError {
    case duplicate(UUID)
    case needsConnection

    var errorDescription: String? {
        switch self {
        case .duplicate: "This subscription is already added."
        case .needsConnection: "Connect first to fetch through the proxy."
        }
    }
}

@MainActor @Observable
final class SubscriptionService {
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

    private var fetcher: SubscriptionFetcher { SubscriptionFetcher(userAgent: Prefs.userAgent) }

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
        let result = try await fetcher.fetch(url: url, route: route)
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupName = !typed.isEmpty ? typed : (result.metadata.title ?? url.host ?? "Subscription")
        return try await store.createGroup(url: trimmed, name: groupName, result: result, viaProxy: viaProxy)
    }

    func update(groupID: UUID, viaProxy: Bool) async {
        guard !updatingGroupIDs.contains(groupID) else { return }
        guard let group = try? container.mainContext.fetch(
            FetchDescriptor<ServerGroup>(predicate: #Predicate { $0.id == groupID })
        ).first, let url = URL(string: group.subscriptionURL) else { return }

        updatingGroupIDs.insert(groupID)
        defer { updatingGroupIDs.remove(groupID) }
        do {
            let result = try await fetcher.fetch(url: url, route: try route(viaProxy: viaProxy))
            try await store.apply(result, to: groupID, viaProxy: viaProxy, activeProfileID: connection.activeServer?.id)
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
            guard group.autoUpdateEnabled else { return false }
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
