import Foundation

/// One connection to ask the tester about.
public struct RouteQuery: Sendable, Hashable {
    /// The domain name, when the target is a name.
    public var host: String?
    /// The target address, or the addresses `host` resolves to (needed for IP rules).
    public var ips: [String]
    public var port: Int
    public var network: Rule.Network
    /// The full path of the app's executable.
    public var process: String?
    public var sniffed: Rule.Sniffed?
    public var inbound: String

    public init(host: String? = nil, ips: [String] = [], port: Int = 443, network: Rule.Network = .tcp,
                process: String? = nil, sniffed: Rule.Sniffed? = nil, inbound: String = ConfigBuilder.inboundTag) {
        self.host = host?.lowercased()
        self.ips = ips
        self.port = port
        self.network = network
        self.process = process
        self.sniffed = sniffed
        self.inbound = inbound
    }
}

public struct RouteAnswer: Sendable, Hashable {
    /// Position in the routing rules.
    public var index: Int
    public var ruleTag: String?
    /// `outboundTag`, or the balancer's tag for a Via group.
    public var outbound: String?
    public var balancer: String?
    /// The entry that matched (`keyword:github`, `geoip:private`), when one did.
    public var matched: String?
}

/// Where a connection goes, from the routing section of a config (spec 8.6), evaluated as the core
/// does: in order, first match wins, with its `domainStrategy`. Pure, so it is tested here.
public enum RuleTester {
    /// nil when nothing matches: the core then uses its first outbound.
    public static func route(_ q: RouteQuery, routing: JSONValue, geo: GeoLists) -> RouteAnswer? {
        let rules = routing["rules"]?.arrayValue ?? []
        let strategy = routing["domainStrategy"]?.stringValue ?? "AsIs"
        func pass(resolve: Bool) -> RouteAnswer? {
            for (index, rule) in rules.enumerated() {
                if let matched = match(rule, q, ipsUsable: q.host == nil || resolve, geo: geo) {
                    return RouteAnswer(index: index, ruleTag: rule["ruleTag"]?.stringValue, outbound: rule["outboundTag"]?.stringValue,
                                       balancer: rule["balancerTag"]?.stringValue, matched: matched.isEmpty ? nil : matched)
                }
            }
            return nil
        }
        switch strategy {
        case "IPOnDemand": return pass(resolve: true)
        case "IPIfNonMatch": return pass(resolve: false) ?? (q.ips.isEmpty ? nil : pass(resolve: true))
        default: return pass(resolve: false)
        }
    }

    /// The entry that matched ("" when only conditions were checked), or nil.
    static func match(_ rule: JSONValue, _ q: RouteQuery, ipsUsable: Bool, geo: GeoLists) -> String? {
        var matched = ""
        if let ports = rule["port"]?.stringValue, !inPorts(q.port, ports) { return nil }
        if let network = rule["network"]?.stringValue, !network.split(separator: ",").contains(Substring(q.network.rawValue)) { return nil }
        if let tags = rule["inboundTag"]?.arrayValue, !tags.contains(.string(q.inbound)) { return nil }
        if let protocols = rule["protocol"]?.arrayValue {
            guard let sniffed = q.sniffed, protocols.contains(.string(sniffed.rawValue)) else { return nil }
        }
        if let processes = rule["process"]?.arrayValue {
            guard let path = q.process, let hit = processes.compactMap(\.stringValue).first(where: { processMatches($0, path) }) else { return nil }
            matched = hit
        }
        if let domains = rule["domain"]?.arrayValue {
            guard let host = q.host, let hit = domains.compactMap(\.stringValue).first(where: { domainMatches($0, host, geo: geo) }) else { return nil }
            matched = hit
        }
        if let ips = rule["ip"]?.arrayValue {
            guard ipsUsable, let hit = ips.compactMap(\.stringValue).first(where: { entry in q.ips.contains { ipMatches(entry, $0, geo: geo) } }) else { return nil }
            matched = hit
        }
        return matched
    }

    static func inPorts(_ port: Int, _ list: String) -> Bool {
        list.split(separator: ",").contains { part in
            let ends = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let low = ends.first, let high = ends.last else { return false }
            return (low...max(low, high)).contains(port)
        }
    }

    static func processMatches(_ entry: String, _ path: String) -> Bool {
        if entry.hasSuffix("/") { return path.hasPrefix(entry) }
        if entry.hasPrefix("/") { return path == entry }
        return (path as NSString).lastPathComponent == entry
    }

    static func domainMatches(_ entry: String, _ host: String, geo: GeoLists) -> Bool {
        let lower = entry.lowercased()
        func value(_ prefix: String) -> String { String(lower.dropFirst(prefix.count)) }
        if lower.hasPrefix("domain:") { let d = value("domain:"); return host == d || host.hasSuffix("." + d) }
        if lower.hasPrefix("full:") { return host == value("full:") }
        if lower.hasPrefix("keyword:") { return host.contains(value("keyword:")) }
        if lower.hasPrefix("regexp:") { return (try? Regex(String(entry.dropFirst(7)))).map { host.contains($0) } ?? false }
        if lower.hasPrefix("dotless:") { return !host.contains(".") && host.contains(value("dotless:")) }
        if let key = GeoLists.key(entry) { return geo.site(key, contains: host) != nil }
        return host.contains(lower)
    }

    static func ipMatches(_ entry: String, _ address: String, geo: GeoLists) -> Bool {
        var entry = entry.lowercased()
        if entry.hasPrefix("geoip:!") { entry = "geoip:" + entry.dropFirst(7); return !ipMatches(entry, address, geo: geo) }
        if let key = GeoLists.key(entry) { return geo.ipList(key, contains: address) }
        let parts = entry.split(separator: "/")
        guard let (base, isV4) = GeoLists.number(String(parts[0])), let (value, sameFamily) = GeoLists.number(address), isV4 == sameFamily else { return false }
        let bits = isV4 ? 32 : 128
        let prefix = parts.count == 2 ? Int(parts[1]) ?? bits : bits
        let host = bits - prefix
        guard host < 128 else { return true }
        let mask = ~((UInt128(1) << host) - 1) & (isV4 ? UInt128(UInt32.max) : .max)
        return base & mask == value & mask
    }
}
