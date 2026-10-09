import Foundation

public struct TrafficSnapshot: Sendable, Equatable {
    public var uplink: Int64
    public var downlink: Int64
    public var date: Date

    public init(uplink: Int64, downlink: Int64, date: Date = Date()) {
        self.uplink = uplink
        self.downlink = downlink
        self.date = date
    }
}

public struct TrafficRate: Sendable, Equatable {
    public var upBytesPerSecond: Double
    public var downBytesPerSecond: Double

    public static let zero = TrafficRate(upBytesPerSecond: 0, downBytesPerSecond: 0)
}

extension TrafficSnapshot {
    /// Rate between two snapshots. Counter resets (core restart) yield zero.
    public func rate(since previous: TrafficSnapshot) -> TrafficRate {
        let dt = date.timeIntervalSince(previous.date)
        guard dt > 0, uplink >= previous.uplink, downlink >= previous.downlink else { return .zero }
        return TrafficRate(
            upBytesPerSecond: Double(uplink - previous.uplink) / dt,
            downBytesPerSecond: Double(downlink - previous.downlink) / dt
        )
    }
}

public enum StatsError: Error, Sendable, Equatable {
    case badResponse
}

/// Reads traffic counters from Xray's metrics endpoint (`/debug/vars`).
public struct StatsClient: Sendable {
    private let url: URL
    private let inboundTags: [String]
    private let session: URLSession

    public init(port: Int, inboundTags: [String] = ConfigBuilder.trafficInboundTags) {
        self.url = URL(string: "http://127.0.0.1:\(port)/debug/vars")!
        self.inboundTags = inboundTags
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func snapshot() async throws -> TrafficSnapshot {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StatsError.badResponse }
        return try Self.parse(data, inboundTags: inboundTags)
    }

    /// Sums the counters of `inboundTags`. Missing counters (no traffic yet) read as zero.
    public static func parse(_ data: Data, inboundTags: [String], now: Date = Date()) throws -> TrafficSnapshot {
        guard let root = try? JSONValue.parse(data), case .object = root else { throw StatsError.badResponse }
        var up = 0.0, down = 0.0
        for tag in inboundTags {
            let entry = root["stats"]?["inbound"]?[tag]
            up += entry?["uplink"]?.doubleValue ?? 0
            down += entry?["downlink"]?.doubleValue ?? 0
        }
        return TrafficSnapshot(uplink: Int64(up), downlink: Int64(down), date: now)
    }

    public static func parse(_ data: Data, inboundTag: String, now: Date = Date()) throws -> TrafficSnapshot {
        try parse(data, inboundTags: [inboundTag], now: now)
    }
}
