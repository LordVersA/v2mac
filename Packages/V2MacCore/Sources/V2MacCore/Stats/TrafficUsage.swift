import Foundation

/// Bytes through the proxy: this session's (from the user's connect to the next one) and a
/// total kept across launches until the user resets it (spec 12.8).
public struct TrafficUsage: Sendable, Equatable, Codable {
    public var sessionUp: Int64 = 0
    public var sessionDown: Int64 = 0
    public var sessionStart: Date?
    public var totalUp: Int64 = 0
    public var totalDown: Int64 = 0
    public var totalSince: Date?

    public init() {}

    public var session: Int64 { sessionUp + sessionDown }
    public var total: Int64 { totalUp + totalDown }

    public mutating func add(up: Int64, down: Int64, now: Date = Date()) {
        guard up > 0 || down > 0 else { return }
        sessionUp += up
        sessionDown += down
        totalUp += up
        totalDown += down
        if totalSince == nil { totalSince = now }
    }

    public mutating func startSession(at date: Date = Date()) {
        sessionUp = 0
        sessionDown = 0
        sessionStart = date
    }

    public mutating func resetTotal(at date: Date = Date()) {
        totalUp = 0
        totalDown = 0
        totalSince = date
    }
}

extension TrafficSnapshot {
    /// Bytes counted since `previous`. A new core starts its counters at zero, so after a
    /// reset (or with no previous reading) everything in this snapshot is new.
    public func bytes(since previous: TrafficSnapshot?) -> (up: Int64, down: Int64) {
        guard let previous, uplink >= previous.uplink, downlink >= previous.downlink else { return (uplink, downlink) }
        return (uplink - previous.uplink, downlink - previous.downlink)
    }
}
