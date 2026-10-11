import Foundation

/// Decisions use only fresh HTTP response measurements, never persisted delays or TCP pings.
public struct AutoSelectionPolicy: Sendable {
    public enum Reason: Sendable { case initial, faster, fallback }

    public private(set) var manualOverride = false
    public private(set) var consecutiveFailures = 0
    private var lastSwitch: Date?
    private var unavailableUntil: [UUID: Date] = [:]
    public let switchCooldown: TimeInterval
    public let failureCooldown: TimeInterval

    public init(switchCooldown: TimeInterval = 60, failureCooldown: TimeInterval = 120) {
        self.switchCooldown = switchCooldown
        self.failureCooldown = failureCooldown
    }

    public mutating func selectManually() {
        manualOverride = true
        consecutiveFailures = 0
        lastSwitch = nil
        unavailableUntil = [:]
    }

    /// Two consecutive failed live HTTP requests are needed before trying another server.
    public mutating func recordHealth(_ outcome: LatencyOutcome) -> Bool {
        if case .ok = outcome { consecutiveFailures = 0 } else { consecutiveFailures += 1 }
        return consecutiveFailures >= 2
    }

    public mutating func didSwitch(at now: Date) {
        lastSwitch = now
        consecutiveFailures = 0
    }

    /// `results` is in group order; fallback takes the first responding peer in that order.
    public mutating func choose(
        results: [LatencyResult], currentID: UUID, reason: Reason, now: Date
    ) -> UUID? {
        unavailableUntil = unavailableUntil.filter { $0.value > now }
        if reason == .fallback {
            manualOverride = false
            unavailableUntil[currentID] = now.addingTimeInterval(failureCooldown)
        }
        if reason != .initial, let lastSwitch, now.timeIntervalSince(lastSwitch) < switchCooldown { return nil }
        if manualOverride, reason != .fallback { return nil }
        let responding = results.compactMap { result -> (id: UUID, ms: Int)? in
            guard unavailableUntil[result.id] == nil, case .ok(let ms) = result.outcome, ms > 0 else { return nil }
            return (result.id, ms)
        }
        let candidate = reason == .fallback ? responding.first : responding.min { $0.ms < $1.ms }
        guard let candidate, candidate.id != currentID else { return nil }
        if reason == .faster {
            guard let current = responding.first(where: { $0.id == currentID }),
                  current.ms - candidate.ms >= max(100, Int(Double(current.ms) * 0.25)) else { return nil }
        }
        return candidate.id
    }
}
