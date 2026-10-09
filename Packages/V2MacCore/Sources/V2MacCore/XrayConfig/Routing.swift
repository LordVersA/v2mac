import Foundation

/// Geo rules from one downloaded region pack, as `ext:<file>:<tag>` references.
public struct RegionRoute: Sendable, Equatable, Hashable {
    public var domainRules: [String]
    public var ipRules: [String]

    public init(geositeFile: String, geositeTags: [String], geoipFile: String, geoipTags: [String]) {
        domainRules = geositeTags.map { "ext:\(geositeFile):\($0)" }
        ipRules = geoipTags.map { "ext:\(geoipFile):\($0)" }
    }
}

public enum RoutingPlan: Sendable, Equatable {
    case global
    /// Private and region traffic goes direct. An empty list behaves like `.global`.
    case bypass([RegionRoute])
    case direct
}

public enum RoutingMode: String, Sendable, CaseIterable, Identifiable {
    case global, bypassRegions, direct
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .global: "Global"
        case .bypassRegions: "Bypass Regions"
        case .direct: "Direct"
        }
    }
}

extension ConfigBuilder {
    /// Two resolvers queried in parallel: a single blocked or filtered DoH endpoint
    /// (Cloudflare's stalls on some networks) would otherwise add ~4 s to every new domain.
    static let dohServers = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]

    static func routingSections(for plan: RoutingPlan) -> (routing: JSONValue, dns: JSONValue?) {
        let privateRule: JSONValue = ["type": "field", "ip": ["geoip:private"], "outboundTag": .string(directTag)]
        switch plan {
        case .direct:
            return (["domainStrategy": "AsIs", "rules": [["type": "field", "network": "tcp,udp", "outboundTag": .string(directTag)]]], nil)
        case .bypass(let routes) where !routes.isEmpty:
            var rules: [JSONValue] = [privateRule]
            for route in routes {
                if !route.domainRules.isEmpty {
                    rules.append(["type": "field", "domain": .array(route.domainRules.map { .string($0) }), "outboundTag": .string(directTag)])
                }
                if !route.ipRules.isEmpty {
                    rules.append(["type": "field", "ip": .array(route.ipRules.map { .string($0) }), "outboundTag": .string(directTag)])
                }
            }
            // Without this, non-matching domains would be resolved by the local resolver,
            // leaking queries and risking a false `geoip:private` match on poisoned networks.
            let dns: JSONValue = [
                "servers": .array(dohServers.map { .string($0) }),
                "queryStrategy": "UseIP",
                "enableParallelQuery": true,
            ]
            return (["domainStrategy": "IPIfNonMatch", "rules": .array(rules)], dns)
        case .bypass, .global:
            return (["domainStrategy": "AsIs", "rules": [privateRule]], nil)
        }
    }

    /// Full config for an `outbound` profile in any routing mode.
    public static func build(outbound: JSONValue, options: RunOptions, routing plan: RoutingPlan) throws -> JSONValue {
        guard case .object = outbound else { throw ConfigBuilderError.outboundNotAnObject }
        let sections = routingSections(for: plan)
        var direct: JSONValue = ["tag": .string(directTag), "protocol": "freedom"]
        // Direct traffic is resolved by the chosen servers too, not by the system resolver.
        if let dns = options.dns { direct = direct.setting("settings", to: ["domainStrategy": .string(dns.queryStrategy.rawValue)]) }
        // Present whenever the settings are on, so a live switch can dial through it as well.
        var extras = dialerOutbound(options.dialer).map { [$0] } ?? []
        if let tun = options.tun {
            direct = binding(direct, to: tun.outboundInterface)
            extras = extras.map { binding($0, to: tun.outboundInterface) }
        }
        var config: JSONValue = [
            "log": logSection(options),
            "stats": [:],
            "policy": statsPolicy,
            "metrics": metricsSection(port: options.metricsPort),
            "inbounds": inbounds(for: options),
            "outbounds": .array([
                proxyOutbound(outbound, options: options),
                direct,
                ["tag": .string(blockTag), "protocol": "blackhole"],
            ] + extras),
            "routing": sections.routing,
        ]
        if let dns = options.dns.map(dnsSection) ?? sections.dns { config = config.setting("dns", to: dns) }
        if let port = options.apiPort { config = config.setting("api", to: apiSection(port: port)) }
        return config
    }

    /// Spec 8.2: run a full Xray config as written, replacing only inbounds, log, metrics and stats.
    /// In TUN mode its outbounds are also bound to the physical interface. Fragment and noise
    /// settings are added to proxy outbounds that have no dialer of their own, and the DNS
    /// setting applies only when the config brings no `dns` section.
    public static func buildCustom(config: JSONValue, options: RunOptions) throws -> JSONValue {
        guard case .object = config else { throw ConfigBuilderError.outboundNotAnObject }

        var proxyInboundTags = Set<String>()
        var otherInboundTags = Set<String>()
        for inbound in config["inbounds"]?.arrayValue ?? [] {
            guard let tag = inbound["tag"]?.stringValue else { continue }
            switch inbound["protocol"]?.stringValue {
            case "socks", "http", "mixed": proxyInboundTags.insert(tag)
            default: otherInboundTags.insert(tag)
            }
        }

        var out = config
            .setting("inbounds", to: inbounds(for: options))
            .setting("log", to: logSection(options))
            .setting("metrics", to: metricsSection(port: options.metricsPort))
            .setting("stats", to: config["stats"] ?? [:])

        // Merge the two stats flags into any existing policy.
        var policy = config["policy"] ?? [:]
        var system = policy["system"] ?? [:]
        system = system.setting("statsInboundUplink", to: true).setting("statsInboundDownlink", to: true)
        policy = policy.setting("system", to: system)
        out = out.setting("policy", to: policy)

        out = dialingOutbounds(of: out, through: options.dialer)
        if let dns = options.dns, config["dns"] == nil { out = out.setting("dns", to: dnsSection(dns)) }
        if let tun = options.tun { out = bindingOutbounds(of: out, to: tun.outboundInterface) }

        if let routing = config["routing"], case .array(let rules)? = routing["rules"] {
            var rewritten: [JSONValue] = []
            for rule in rules {
                guard case .array(let tags)? = rule["inboundTag"] else { rewritten.append(rule); continue }
                var newTags: [JSONValue] = []
                for tag in tags {
                    guard let name = tag.stringValue else { continue }
                    if proxyInboundTags.contains(name) {
                        // TUN traffic follows the rules written for the config's own proxy inbounds.
                        let ours = options.tun == nil ? [inboundTag] : trafficInboundTags
                        for tag in ours where !newTags.contains(.string(tag)) { newTags.append(.string(tag)) }
                    } else if otherInboundTags.contains(name) {
                        continue // that inbound no longer exists
                    } else {
                        newTags.append(tag)
                    }
                }
                if newTags.isEmpty { continue }
                rewritten.append(rule.setting("inboundTag", to: .array(newTags)))
            }
            out = out.setting("routing", to: routing.setting("rules", to: .array(rewritten)))
        }
        return out
    }
}
