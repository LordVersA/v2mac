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
    /// Only traffic matching a Proxy rule goes through the proxy; the rest goes direct.
    case rulesOnly
}

public enum RoutingMode: String, Sendable, CaseIterable, Identifiable {
    case global, bypassRegions, direct, rulesOnly
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .global: String(localized: "Global")
        case .bypassRegions: String(localized: "Bypass Regions")
        case .direct: String(localized: "Direct")
        case .rulesOnly: String(localized: "Rules Only")
        }
    }
}

extension ConfigBuilder {
    /// Two resolvers queried in parallel: a single blocked or filtered DoH endpoint
    /// (Cloudflare's stalls on some networks) would otherwise add ~4 s to every new domain.
    static let dohServers = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]

    static func routingSections(for plan: RoutingPlan, custom: CustomRules = CustomRules()) -> (routing: JSONValue, dns: JSONValue?) {
        let privateRule: JSONValue = ["type": "field", "ruleTag": .string(RuleTag.privateIPs), "ip": ["geoip:private"], "outboundTag": .string(directTag)]
        func rules(_ domains: [String], _ ips: [String], to tag: String) -> [JSONValue] {
            var out: [JSONValue] = []
            if !domains.isEmpty { out.append(["type": "field", "domain": .array(domains.map { .string($0) }), "outboundTag": .string(tag)]) }
            if !ips.isEmpty { out.append(["type": "field", "ip": .array(ips.map { .string($0) }), "outboundTag": .string(tag)]) }
            return out
        }
        // Direct mode keeps only the user's block rules: nothing there should reach the proxy.
        var customRules: [JSONValue] = []
        var hasCustomIPs = false
        for rule in custom.rules where rule.enabled && (plan != .direct || rule.action == .block) {
            let made = rule.xrayRules(apps: custom.installedApps, siteTags: custom.siteTags, target: custom.target(of: rule.action))
                .enumerated().map { $1.setting("ruleTag", to: .string(RuleTag.user(rule.id, part: $0))) }
            hasCustomIPs = hasCustomIPs || made.contains { $0["ip"] != nil }
            customRules += made
        }
        // This Mac and the LAN always go direct, before any rule: a proxy rule for an app must not
        // send its localhost traffic to the server's own localhost.
        let localNames: JSONValue = ["type": "field", "ruleTag": .string(RuleTag.localNames), "domain": .array(CustomRules.localNames.map { .string($0) }), "outboundTag": .string(directTag)]
        // Direct mode keeps everything off the server, the proxy port included.
        if let route = custom.proxyClientsRoute, plan != .direct {
            customRules.insert(["type": "field", "ruleTag": .string(RuleTag.proxyPort), "inboundTag": [.string(inboundTag)], "outboundTag": .string(route.tag)], at: 0)
        }
        if plan != .direct || !customRules.isEmpty { customRules.insert(contentsOf: [localNames, privateRule], at: 0) }
        if custom.blockQUIC { customRules.insert(["type": "field", "ruleTag": .string(RuleTag.quic), "network": "udp", "port": "443", "outboundTag": .string(blockTag)], at: 0) }

        var tail: [JSONValue] = []
        var hasIPRules = hasCustomIPs
        switch plan {
        case .direct:
            let strategy: JSONValue = hasCustomIPs ? "IPOnDemand" : "AsIs"
            return (["domainStrategy": strategy, "rules": .array(customRules + RuleTag.mode([["type": "field", "network": "tcp,udp", "outboundTag": .string(directTag)]]))], nil)
        case .bypass(let routes) where !routes.isEmpty:
            for route in routes { tail += rules(route.domainRules, route.ipRules, to: directTag) }
            hasIPRules = true
        case .rulesOnly:
            // The exit check's sources go through the server, so it reports the server's country.
            let lookup: JSONValue = .array(ExitLookup.sources.compactMap { $0.host.map { .string("full:" + $0) } })
            tail = [["type": "field", "domain": lookup, "outboundTag": .string(proxyTag)],
                    ["type": "field", "network": "tcp,udp", "outboundTag": .string(directTag)]]
        case .bypass, .global: break
        }
        if let route = custom.unmatchedRoute {
            tail = tail.filter { $0["network"] == nil } + [["type": "field", "ruleTag": .string(RuleTag.unmatched), "network": "tcp,udp", "outboundTag": .string(route.tag)]]
        }
        guard hasIPRules else { return (["domainStrategy": "AsIs", "rules": .array(customRules + RuleTag.mode(tail))], nil) }
        // The core's own DoH lookups would otherwise follow the catch-all out of the tunnel.
        if plan == .rulesOnly {
            let resolvers: JSONValue = .array(dohServers.compactMap { URL(string: $0)?.host.map { .string($0) } })
            tail.insert(["type": "field", "ip": resolvers, "outboundTag": .string(proxyTag)], at: 0)
        }
        // Without this, non-matching domains would be resolved by the local resolver,
        // leaking queries and risking a false `geoip:private` match on poisoned networks.
        let dns: JSONValue = [
            "servers": .array(dohServers.map { .string($0) }),
            "queryStrategy": "UseIP",
            "enableParallelQuery": true,
        ]
        return (["domainStrategy": hasCustomIPs ? "IPOnDemand" : "IPIfNonMatch", "rules": .array(customRules + RuleTag.mode(tail))], dns)
    }

    /// Full config for an `outbound` profile in any routing mode.
    public static func build(outbound: JSONValue, options: RunOptions, routing plan: RoutingPlan, custom: CustomRules = CustomRules()) throws -> JSONValue {
        guard case .object = outbound else { throw ConfigBuilderError.outboundNotAnObject }
        let sections = routingSections(for: plan, custom: custom)
        var direct: JSONValue = ["tag": .string(directTag), "protocol": "freedom"]
        // Direct traffic is resolved by the chosen servers too, not by the system resolver.
        if let dns = options.dns { direct = direct.setting("settings", to: ["domainStrategy": .string(dns.queryStrategy.rawValue)]) }
        // Present whenever the settings are on, so a live switch can dial through it as well.
        var extras = dialerOutbound(options.dialer).map { [$0] } ?? []
        if let interface = options.boundInterface {
            direct = binding(direct, to: interface)
            extras = extras.map { binding($0, to: interface) }
        }
        var config: JSONValue = [
            "log": logSection(options),
            "stats": [:],
            "policy": statsPolicy,
            "metrics": metricsSection(port: options.metricsPort),
            "inbounds": inbounds(for: options),
            "outbounds": .array((warpExitOutbound(options).map { [$0] } ?? []) + [
                proxyOutbound(outbound, options: options),
                direct,
                ["tag": .string(blockTag), "protocol": "blackhole"],
            ] + extras),
            "routing": sections.routing,
        ]
        if let dns = options.dns.map(dnsSection) ?? sections.dns { config = config.setting("dns", to: dns) }
        if let port = options.apiPort { config = config.setting("api", to: apiSection(port: port)) }
        if let tun = options.tun { config = tunDNS(config, tun: tun) }
        return blockingLoopback(of: config, when: options.inbound.allowLAN)
    }

    /// Spec 8.2: run a full Xray config as written, replacing only inbounds, log, metrics and stats,
    /// and dropping its `api` section, which could open a control port to the network.
    /// In TUN mode its outbounds are also bound to the physical interface and its DNS is set up
    /// as `tunDNS` describes. Fragment and noise settings are added to proxy outbounds that have
    /// no dialer of their own, and the DNS setting applies only when the config brings no `dns` section.
    /// When a plan is supplied, app routing precedes the imported rules; latency probes omit it.
    public static func buildCustom(config: JSONValue, options: RunOptions, routing plan: RoutingPlan? = nil,
                                   custom: CustomRules = CustomRules()) throws -> JSONValue {
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
            .removing("api")
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
        if let interface = options.boundInterface { out = bindingOutbounds(of: out, to: interface) }

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
        if let plan {
            out = try applyingRouting(to: out, plan: plan, custom: custom, options: options)
        }
        if let tun = options.tun { out = tunDNS(out, tun: tun) }
        return blockingLoopback(of: out, when: options.inbound.allowLAN)
    }

    /// App rules run first; imported rules and the original default outbound remain the fallback.
    private static func applyingRouting(to config: JSONValue, plan: RoutingPlan, custom: CustomRules, options: RunOptions) throws -> JSONValue {
        var outbounds = config["outbounds"]?.arrayValue ?? []
        guard !outbounds.isEmpty else { throw CoreError.startFailed(String(localized: "This config has no outbound for routing.")) }
        var used = Set(outbounds.compactMap { $0["tag"]?.stringValue })
        func unused(_ base: String) -> String {
            var tag = base
            var suffix = 0
            while used.contains(tag) { suffix += 1; tag = "\(base)-\(suffix)" }
            used.insert(tag)
            return tag
        }
        let proxyIndex = outbounds.firstIndex { !["freedom", "blackhole", "dns", "loopback"].contains($0["protocol"]?.stringValue ?? "") } ?? 0
        let existing = outbounds[proxyIndex]["tag"]?.stringValue
        let proxy = existing.flatMap { $0.isEmpty ? nil : $0 } ?? unused("v2mac-proxy")
        outbounds[proxyIndex] = outbounds[proxyIndex].setting("tag", to: .string(proxy))
        let direct = unused("v2mac-direct"), block = unused("v2mac-block")
        var directOutbound: JSONValue = ["tag": .string(direct), "protocol": "freedom"]
        if let dns = options.dns { directOutbound = directOutbound.setting("settings", to: ["domainStrategy": .string(dns.queryStrategy.rawValue)]) }
        if let interface = options.boundInterface { directOutbound = binding(directOutbound, to: interface) }
        outbounds += [directOutbound, ["tag": .string(block), "protocol": "blackhole"]]
        let targets = [proxyTag: proxy, directTag: direct, blockTag: block]
        let sections = routingSections(for: plan, custom: custom)
        let prefix = (sections.routing["rules"]?.arrayValue ?? []).map { rule in
            guard let target = targets[rule["outboundTag"]?.stringValue ?? ""] else { return rule }
            return rule.setting("outboundTag", to: .string(target))
        }
        var routing = config["routing"] ?? [:]
        let strategy = sections.routing["domainStrategy"]
        // Preserve the imported resolver strategy unless app IP rules need resolution too.
        if strategy == "IPIfNonMatch" || strategy == "IPOnDemand" {
            // Resolve at the IP rule, before an imported catch-all can win the first pass.
            routing = routing.setting("domainStrategy", to: "IPOnDemand")
        } else if routing["domainStrategy"] == nil {
            routing = routing.setting("domainStrategy", to: strategy ?? "AsIs")
        }
        routing = routing.setting("rules", to: .array(prefix + (routing["rules"]?.arrayValue ?? [])))
        var out = config.setting("outbounds", to: .array(outbounds)).setting("routing", to: routing)
        if out["dns"] == nil, let dns = sections.dns { out = out.setting("dns", to: dns) }
        return out
    }
}

/// `ruleTag`s of the rules V2Mac writes, so the tester can say which rule matched. Xray wants them unique.
public enum RuleTag {
    public static let localNames = "v2mac-local-names"
    public static let privateIPs = "v2mac-private"
    public static let quic = "v2mac-quic"
    public static let proxyPort = "v2mac-proxy-port"
    public static let unmatched = "v2mac-unmatched"
    public static let modePrefix = "v2mac-mode-"

    static func user(_ id: UUID, part: Int) -> String { "rule-\(id.uuidString)-\(part)" }

    /// The user rule a tag belongs to.
    public static func ruleID(_ tag: String) -> UUID? {
        guard tag.hasPrefix("rule-") else { return nil }
        return UUID(uuidString: String(tag.dropFirst(5).prefix(36)))
    }

    /// The mode's own rules; the unmatched catch-all keeps its tag.
    static func mode(_ rules: [JSONValue]) -> [JSONValue] {
        rules.enumerated().map { $1["ruleTag"] == nil ? $1.setting("ruleTag", to: .string(modePrefix + String($0))) : $1 }
    }
}
