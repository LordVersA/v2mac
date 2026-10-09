import Foundation
import SwiftData
import V2MacCore

/// Background writer for subscription data (spec 6.4 reconcile).
@ModelActor
actor SubscriptionStore {
    func createGroup(url: String, name: String, outcome: FetchOutcome, viaProxy: Bool) throws -> UUID {
        let all = try modelContext.fetch(FetchDescriptor<ServerGroup>())
        let group = ServerGroup(name: name, subscriptionURL: url, sortIndex: (all.map(\.sortIndex).max() ?? -1) + 1)
        modelContext.insert(group)
        reconcile(group, with: outcome.result, viaProxy: viaProxy, activeProfileID: nil)
        group.userAgent = outcome.userAgent
        group.userAgentProbed = outcome.probed
        try modelContext.save()
        return group.id
    }

    /// Appends pasted configs to the one group without a subscription URL, creating it on first use.
    /// Configs the group already has are left alone. Returns the group and how many were new.
    func addManual(_ parsed: [ParsedProfile], groupName: String) throws -> (groupID: UUID, added: Int) {
        let all = try modelContext.fetch(FetchDescriptor<ServerGroup>())
        let group: ServerGroup
        if let existing = all.first(where: \.isManual) {
            group = existing
        } else {
            // Kept ahead of the subscriptions, whose indexes start at 0.
            group = ServerGroup(name: groupName, subscriptionURL: "", sortIndex: -1)
            group.autoUpdateEnabled = false
            modelContext.insert(group)
        }
        var known = Set(group.profiles.map(\.fingerprint))
        var nextIndex = (group.profiles.map(\.sortIndex).max() ?? -1) + 1
        var added = 0
        for profile in parsed where known.insert(profile.fingerprint).inserted {
            modelContext.insert(Profile(parsed: profile, sortIndex: nextIndex, group: group))
            nextIndex += 1
            added += 1
        }
        try modelContext.save()
        return (group.id, added)
    }

    func apply(_ outcome: FetchOutcome, to groupID: UUID, viaProxy: Bool, activeProfileID: UUID?) throws {
        guard let group = try fetchGroup(groupID) else { return }
        reconcile(group, with: outcome.result, viaProxy: viaProxy, activeProfileID: activeProfileID)
        group.userAgent = outcome.userAgent
        group.userAgentProbed = outcome.probed
        try modelContext.save()
    }

    /// A failed fetch never touches the group's servers.
    func recordFailure(groupID: UUID, message: String) throws {
        guard let group = try fetchGroup(groupID) else { return }
        group.lastUpdateError = message
        try modelContext.save()
    }

    private func fetchGroup(_ id: UUID) throws -> ServerGroup? {
        try modelContext.fetch(FetchDescriptor<ServerGroup>(predicate: #Predicate { $0.id == id })).first
    }

    private func reconcile(_ group: ServerGroup, with result: SubscriptionResult, viaProxy: Bool, activeProfileID: UUID?) {
        let existing = group.profiles.sorted { $0.sortIndex < $1.sortIndex }
        var byFingerprint: [String: [Profile]] = [:]
        for p in existing { byFingerprint[p.fingerprint, default: []].append(p) }

        var reused = Set<UUID>()
        for (index, parsed) in result.profiles.enumerated() {
            if let match = byFingerprint[parsed.fingerprint]?.first {
                byFingerprint[parsed.fingerprint]?.removeFirst()
                match.update(from: parsed, sortIndex: index)
                reused.insert(match.id)
            } else {
                modelContext.insert(Profile(parsed: parsed, sortIndex: index, group: group))
            }
        }

        for old in existing where !reused.contains(old.id) {
            if old.id == activeProfileID {
                old.isStale = true
                old.sortIndex = result.profiles.count + 1000
            } else {
                modelContext.delete(old)
            }
        }

        let m = result.metadata
        group.serverIntervalHours = m.updateIntervalHours ?? group.serverIntervalHours
        // A response without usage headers keeps the last known account info instead of blanking it.
        if m.hasUsageInfo {
            group.usedBytes = m.usedBytes
            group.totalBytes = m.totalBytes
            group.expiresAt = m.expiresAt
            group.uploadBytes = m.uploadBytes
            group.downloadBytes = m.downloadBytes
        }
        group.supportURL = m.supportURL?.absoluteString ?? group.supportURL
        group.webPageURL = m.webPageURL?.absoluteString ?? group.webPageURL
        group.lastUpdatedAt = Date()
        group.lastUpdateViaProxy = viaProxy
        group.lastSkippedCount = result.skipped.count
        group.lastUpdateError = nil
    }
}
