import Foundation

/// Spec 12.8: when a subscription's expiry date or traffic quota is worth a notification, and
/// the bookkeeping that keeps each warning to one notification.
public enum UsageAlert {
    public enum Expiry: Int, Sendable, Comparable {
        case none, soon, lastDay, expired

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Traffic: Int, Sendable, Comparable {
        case none, low, nearlyOut, out

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public static let soonDays = 3

    public static func expiry(expiresAt: Date?, now: Date = Date()) -> Expiry {
        guard let expiresAt else { return .none }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= 24 * 3600 { return .lastDay }
        if remaining <= Double(soonDays) * 24 * 3600 { return .soon }
        return .none
    }

    /// Whole days left, rounded up; 0 once expired.
    public static func daysLeft(expiresAt: Date, now: Date = Date()) -> Int {
        max(0, Int((expiresAt.timeIntervalSince(now) / (24 * 3600)).rounded(.up)))
    }

    /// A missing or zero total means the plan has no quota.
    public static func traffic(used: Int64?, total: Int64?) -> Traffic {
        guard let used, let total, total > 0 else { return .none }
        let fraction = Double(used) / Double(total)
        if fraction >= 1 { return .out }
        if fraction >= 0.95 { return .nearlyOut }
        if fraction >= 0.8 { return .low }
        return .none
    }

    /// `marker` is what the previous call returned for this subscription. A level is announced
    /// once, and again only after it rises or `subject` changes (a renewed date, a new quota).
    /// The returned marker also records a level that fell, so the next rise is announced.
    public static func step(level: Int, subject: String, marker: String?) -> (notify: Bool, marker: String) {
        let next = "\(subject)|\(level)"
        guard level > 0 else { return (false, next) }
        var previousLevel = 0
        if let marker, let bar = marker.lastIndex(of: "|"), marker[..<bar] == subject {
            previousLevel = Int(marker[marker.index(after: bar)...]) ?? 0
        }
        return (level > previousLevel, next)
    }
}
