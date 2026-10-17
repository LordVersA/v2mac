import Foundation

/// Finds Cloudflare addresses that answer well from this network, for servers reached through
/// Cloudflare's CDN (spec 10.4). A random sample is TCP-pinged on the server's port; the fastest
/// are then tried as the server itself, with the server's name kept as SNI and Host.
public enum CleanIPScanner {
    /// cloudflare.com/ips-v4.
    public static let cloudflareRanges = [
        "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
        "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
        "162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
    ]

    /// Transports that Cloudflare's CDN carries.
    static let cdnTransports: Set<String> = ["ws", "grpc", "xhttp", "splithttp", "httpupgrade"]

    public struct Candidate: Sendable, Equatable, Identifiable {
        public var ip: String
        public var tcpMs: Int
        /// Delay through the server at this address, or nil when it did not answer.
        public var realMs: Int?
        public var id: String { ip }
    }

    public enum Phase: Sendable, Equatable {
        case pinging(done: Int, of: Int)
        case testing(done: Int, of: Int)
    }

    /// The server's own name, when its outbound can go through the CDN at another address.
    public static func hostName(of outbound: JSONValue) -> String? {
        let stream = outbound["streamSettings"]
        let network = (stream?["network"]?.stringValue ?? "").lowercased()
        guard cdnTransports.contains(network), stream?["security"]?.stringValue != "reality",
              ["vless", "vmess", "trojan"].contains(outbound["protocol"]?.stringValue ?? "") else { return nil }
        let candidates = [stream?["tlsSettings"]?["serverName"]?.stringValue, host(in: stream), endpoint(outbound)?.stringValue]
        return candidates.compactMap { $0 }.first { !$0.isEmpty && !RuleMatchers.isIP($0) }
    }

    private static func host(in stream: JSONValue?) -> String? {
        for key in ["wsSettings", "httpupgradeSettings", "xhttpSettings", "splithttpSettings"] {
            if let host = stream?[key]?["host"]?.stringValue, !host.isEmpty { return host }
        }
        return stream?["grpcSettings"]?["authority"]?.stringValue
    }

    private static func endpoint(_ outbound: JSONValue) -> JSONValue? {
        let settings = outbound["settings"]
        return settings?["vnext"]?[0]?["address"] ?? settings?["servers"]?[0]?["address"] ?? settings?["address"]
    }

    /// The outbound dialling `ip` instead of its address, with `name` written as SNI and Host
    /// wherever they were left to follow the address.
    public static func pointing(_ outbound: JSONValue, to ip: String, name: String) -> JSONValue {
        var settings = outbound["settings"] ?? [:]
        if case .array(var list)? = settings["vnext"] ?? settings["servers"], !list.isEmpty {
            let key = settings["vnext"] != nil ? "vnext" : "servers"
            list[0] = list[0].setting("address", to: .string(ip))
            settings = settings.setting(key, to: .array(list))
        } else {
            settings = settings.setting("address", to: .string(ip))
        }
        var stream = outbound["streamSettings"] ?? [:]
        let network = (stream["network"]?.stringValue ?? "").lowercased()
        if stream["security"]?.stringValue == "tls" {
            let tls = stream["tlsSettings"] ?? [:]
            if (tls["serverName"]?.stringValue ?? "").isEmpty { stream = stream.setting("tlsSettings", to: tls.setting("serverName", to: .string(name))) }
        }
        let key = network == "grpc" ? "grpcSettings" : "\(network)Settings"
        let field = network == "grpc" ? "authority" : "host"
        let transport = stream[key] ?? [:]
        if network != "grpc", (transport[field]?.stringValue ?? "").isEmpty {
            stream = stream.setting(key, to: transport.setting(field, to: .string(name)))
        }
        return outbound.setting("settings", to: settings).setting("streamSettings", to: stream)
    }

    /// `count` distinct addresses, one per /24 at most, spread over the ranges by their size.
    public static func sample(_ count: Int, from ranges: [String] = cloudflareRanges) -> [String] {
        let blocks: [(base: UInt32, size: UInt32)] = ranges.compactMap { range in
            let parts = range.split(separator: "/")
            guard parts.count == 2, let bits = UInt32(parts[1]), bits <= 24, let base = ipv4(String(parts[0])) else { return nil }
            return (base, UInt32(1) << (24 - bits))
        }
        let total = blocks.reduce(0) { $0 + Int($1.size) }
        guard total > 0 else { return [] }
        var picked = Set<UInt32>()
        while picked.count < min(count, total) {
            var n = UInt32(Int.random(in: 0..<total))
            for block in blocks {
                if n < block.size { picked.insert(block.base &+ n << 8); break }
                n -= block.size
            }
        }
        return picked.map { net in
            let host = net | UInt32.random(in: 1...254)
            return "\(host >> 24).\(host >> 16 & 255).\(host >> 8 & 255).\(host & 255)"
        }
    }

    private static func ipv4(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Pings `addresses`, tries the `keep` fastest through the server, and returns them best
    /// first: those that worked by delay, then the rest by ping.
    public static func scan(
        _ outbound: JSONValue,
        port: Int,
        addresses: [String],
        keep: Int = 16,
        interface: String? = nil,
        tester: RealDelayTester,
        onPhase: @escaping @Sendable (Phase) async -> Void
    ) async -> [Candidate] {
        guard let name = hostName(of: outbound) else { return [] }
        let ids = addresses.map { _ in UUID() }
        let byID = Dictionary(uniqueKeysWithValues: zip(ids, addresses))
        let pings = Box<[String: Int]>([:])
        let done = Box(0)
        await TCPPing.run(zip(ids, addresses).map { TCPPingTarget(id: $0, host: $1, port: port) }, timeout: 2, concurrency: 48, interface: interface) { result in
            if case .ok(let ms) = result.outcome, let ip = byID[result.id] { await pings.update { $0[ip] = ms; return () } }
            let n = await done.update { $0 += 1; return $0 }
            if n % 10 == 0 || n == addresses.count { await onPhase(.pinging(done: n, of: addresses.count)) }
        }
        if Task.isCancelled { return [] }
        var candidates = await pings.value.sorted { $0.value < $1.value }.prefix(keep).map { Candidate(ip: $0.key, tcpMs: $0.value) }
        guard !candidates.isEmpty else { return [] }

        let targets = candidates.map { LatencyTarget(id: UUID(), config: pointing(outbound, to: $0.ip, name: name), kind: .outbound) }
        let index = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($1.id, $0) })
        let delays = Box<[Int: Int]>([:])
        let tested = Box(0)
        await onPhase(.testing(done: 0, of: targets.count))
        await tester.run(targets) { result in
            if case .ok(let ms) = result.outcome, let i = index[result.id] { await delays.update { $0[i] = ms; return () } }
            await onPhase(.testing(done: await tested.update { $0 += 1; return $0 }, of: targets.count))
        }
        let measured = await delays.value
        for i in candidates.indices { candidates[i].realMs = measured[i] }
        return candidates.sorted { a, b in
            switch (a.realMs, b.realMs) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.tcpMs < b.tcpMs
            }
        }
    }

    private actor Box<Value: Sendable> {
        var value: Value
        init(_ value: Value) { self.value = value }
        @discardableResult func update<R: Sendable>(_ body: (inout Value) -> R) -> R { body(&value) }
    }
}

private extension CleanIPScanner.Candidate {
    init(ip: String, tcpMs: Int) { self.init(ip: ip, tcpMs: tcpMs, realMs: nil) }
}
