import Foundation

/// A server a Via rule can exit through (spec 8.6): a share link's outbound or a full config.
public struct ViaServer: Sendable, Hashable {
    public var config: JSONValue
    public var kind: ProfileKind

    public init(config: JSONValue, kind: ProfileKind) {
        self.config = config
        self.kind = kind
    }
}

/// Where a Via target's traffic goes in the config.
public struct ViaRoute: Sendable, Hashable {
    /// The balancer (a group) or the outbound (one server).
    public var tag: String
    public var isBalancer: Bool
    /// A balancer over the same servers that uses the connected server when they all fail.
    public var fallbackBalancer: String?

    public init(tag: String, isBalancer: Bool, fallbackBalancer: String? = nil) {
        self.tag = tag
        self.isBalancer = isBalancer
        self.fallbackBalancer = fallbackBalancer
    }
}

extension ConfigBuilder {
    /// Prefixes of the outbounds Via targets exit through; the observatory probes them all.
    static let viaGroupPrefix = "via-g", viaServerPrefix = "via-s"
    static let probeURL = "https://www.gstatic.com/generate_204"

    struct ViaSections {
        var outbounds: [JSONValue] = []
        var balancers: [JSONValue] = []
        var routes: [Rule.Via.Target: ViaRoute] = [:]
        /// Each target's server outbounds, for its status.
        var members: [Rule.Via.Target: [String]] = [:]
        var observatory: JSONValue? {
            outbounds.isEmpty ? nil : ["subjectSelector": [.string(viaGroupPrefix), .string(viaServerPrefix)],
                                       "probeURL": .string(probeURL), "probeInterval": "30s", "enableConcurrency": true]
        }
    }

    /// Outbounds, balancers and routes for every Via target an active rule uses. Each target's
    /// servers are tagged `<base>-m<i>`, their dialer chains `via-hop-<n>-<i>-<tag>`, so a balancer's
    /// `<base>-m` prefix takes its servers and nothing else. Every balancer has a `fallbackTag`:
    /// without one the core sends traffic to its first outbound when all servers are down (spec 8.6, R0).
    static func viaSections(plan: RoutingPlan, custom: CustomRules, options: RunOptions, proxy: String = proxyTag, block: String = blockTag) -> ViaSections {
        var out = ViaSections()
        guard plan != .direct else { return out }
        var targets: [Rule.Via.Target] = []
        var fallsBack = Set<Rule.Via.Target>()
        for rule in custom.rules where rule.enabled {
            guard case .via(let via) = rule.action, let servers = custom.viaServers[via.target], !servers.isEmpty else { continue }
            if !targets.contains(via.target) { targets.append(via.target) }
            if via.fallsBack { fallsBack.insert(via.target) }
        }
        for (n, target) in targets.enumerated() {
            let isGroup = if case .group = target { true } else { false }
            let base = (isGroup ? viaGroupPrefix : viaServerPrefix) + String(n)
            for (i, server) in (custom.viaServers[target] ?? []).enumerated() {
                out.outbounds += viaOutbounds(server, tag: "\(base)-m\(i)", hopPrefix: "via-hop-\(n)-\(i)-", options: options)
                out.members[target, default: []].append("\(base)-m\(i)")
            }
            func balancer(_ tag: String, fallback: String) -> JSONValue {
                ["tag": .string(tag), "selector": [.string(base + "-m")], "strategy": ["type": "leastPing"], "fallbackTag": .string(fallback)]
            }
            if isGroup { out.balancers.append(balancer(base, fallback: block)) }
            if fallsBack.contains(target) { out.balancers.append(balancer(base + "-fb", fallback: proxy)) }
            out.routes[target] = ViaRoute(tag: isGroup ? base : base + "-m0", isBalancer: isGroup,
                                          fallbackBalancer: fallsBack.contains(target) ? base + "-fb" : nil)
        }
        return out
    }

    /// One server's outbound tagged `tag`, plus, for a full config, the outbounds its first proxy
    /// outbound reaches through `dialerProxy` or `proxySettings`, renamed under `hopPrefix`.
    /// The config's own routing, inbounds and other outbounds are ignored.
    static func viaOutbounds(_ server: ViaServer, tag: String, hopPrefix: String, options: RunOptions) -> [JSONValue] {
        func prepared(_ o: JSONValue) -> JSONValue {
            let dialed = dialing(InsecureTLS.stripping(o), through: options.dialer)
            return options.boundInterface.map { binding(dialed, to: $0) } ?? dialed
        }
        guard server.kind == .custom else { return [prepared(server.config.setting("tag", to: .string(tag)))] }
        let all = server.config["outbounds"]?.arrayValue ?? []
        guard let first = all.first(where: { !["freedom", "blackhole", "dns", "loopback"].contains($0["protocol"]?.stringValue ?? "") }) else { return [] }
        let byTag = Dictionary(all.compactMap { o in o["tag"]?.stringValue.map { ($0, o) } }, uniquingKeysWith: { a, _ in a })
        func next(_ o: JSONValue) -> String? {
            [o["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue, o["proxySettings"]?["tag"]?.stringValue].compactMap { $0 }.first { !$0.isEmpty }
        }
        func renamed(_ o: JSONValue, as newTag: String) -> JSONValue {
            var o = o.setting("tag", to: .string(newTag))
            if let hop = o["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue, byTag[hop] != nil {
                let stream = o["streamSettings"] ?? [:]
                o = o.setting("streamSettings", to: stream.setting("sockopt", to: (stream["sockopt"] ?? [:]).setting("dialerProxy", to: .string(hopPrefix + hop))))
            }
            if let hop = o["proxySettings"]?["tag"]?.stringValue, byTag[hop] != nil {
                o = o.setting("proxySettings", to: (o["proxySettings"] ?? [:]).setting("tag", to: .string(hopPrefix + hop)))
            }
            return prepared(o)
        }
        var out = [renamed(first, as: tag)]
        var seen = Set([first["tag"]?.stringValue ?? ""])
        var current = first
        while let hop = next(current), let o = byTag[hop], seen.insert(hop).inserted {
            out.append(renamed(o, as: hopPrefix + hop))
            current = o
        }
        return out
    }
}

extension CustomRules {
    /// Server addresses the Via targets of active rules dial, for the kill switch (spec 9.8).
    public var viaHosts: [String] {
        let used = Set(rules.filter(\.enabled).compactMap { if case .via(let v) = $0.action { v.target } else { nil } })
        return Array(Set(used.flatMap { viaServers[$0] ?? [] }.flatMap { KillSwitch.hosts(in: $0.config, kind: $0.kind) })).sorted()
    }
}

/// How a Via target's servers are doing, from the core's observatory (spec 8.6).
public struct ViaHealth: Sendable, Hashable {
    public var alive: Int
    public var dead: Int
    public var total: Int

    /// Every server has been probed and none answers: the rule's traffic fails (or falls back).
    public var allFailing: Bool { total > 0 && dead == total }

    /// Targets with at least one probed server; ones not probed yet are left out.
    public static func of(_ observatory: [String: Bool], members: [Rule.Via.Target: [String]]) -> [Rule.Via.Target: ViaHealth] {
        members.compactMapValues { tags in
            let known = tags.compactMap { observatory[$0] }
            return known.isEmpty ? nil : ViaHealth(alive: known.filter { $0 }.count, dead: known.filter { !$0 }.count, total: tags.count)
        }
    }
}

extension ConfigBuilder {
    /// The server outbounds of each Via target an active rule uses in `plan`.
    public static func viaMembers(plan: RoutingPlan, custom: CustomRules) -> [Rule.Via.Target: [String]] {
        viaSections(plan: plan, custom: custom, options: RunOptions(metricsPort: 0)).members
    }
}
