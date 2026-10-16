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
        case .global: String(localized: "Global")
        case .bypassRegions: String(localized: "Bypass Regions")
        case .direct: String(localized: "Direct")
        }
    }
}

extension ConfigBuilder {
    /// Two resolvers queried in parallel: a single blocked or filtered DoH endpoint
    /// (Cloudflare's stalls on some networks) would otherwise add ~4 s to every new domain.
    static let dohServers = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]

    static func routingSections(for plan: RoutingPlan, custom: CustomRules = CustomRules()) -> (routing: JSONValue, dns: JSONValue?) {
        let privateRule: JSONValue = ["type": "field", "ip": ["geoip:private"], "outboundTag": .string(directTag)]
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
            let hosts = RuleMatchers(parsing: rule.hosts)
            let hasApps = !rule.apps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let apps = AppMatchers(parsing: rule.apps, apps: custom.installedApps).processes
            // A rule whose apps are all missing must not turn into a rule for every app.
            if hasApps, apps.isEmpty { continue }
            var made = rules(hosts.domains, hosts.ips, to: rule.tag)
            if hasApps {
                let process: JSONValue = .array(apps.map { .string($0) })
                made = made.isEmpty && hosts.invalid.isEmpty
                    ? [["type": "field", "process": process, "outboundTag": .string(rule.tag)]]
                    : made.map { $0.setting("process", to: process) }
            }
            hasCustomIPs = hasCustomIPs || !hosts.ips.isEmpty
            customRules += made
        }
        // This Mac and the LAN always go direct, before any rule: a proxy rule for an app must not
        // send its localhost traffic to the server's own localhost.
        let localNames: JSONValue = ["type": "field", "domain": .array(CustomRules.localNames.map { .string($0) }), "outboundTag": .string(directTag)]
        // Direct mode keeps everything off the server, the proxy port included.
        if custom.proxyClientsSkipRules, plan != .direct {
            customRules.insert(["type": "field", "inboundTag": [.string(inboundTag)], "outboundTag": .string(proxyTag)], at: 0)
        }
        if plan != .direct || !customRules.isEmpty { customRules.insert(contentsOf: [localNames, privateRule], at: 0) }
        if custom.blockQUIC { customRules.insert(["type": "field", "network": "udp", "port": "443", "outboundTag": .string(blockTag)], at: 0) }

        var tail: [JSONValue] = []
        var hasIPRules = hasCustomIPs
        switch plan {
        case .direct:
            let strategy: JSONValue = hasCustomIPs ? "IPIfNonMatch" : "AsIs"
            return (["domainStrategy": strategy, "rules": .array(customRules + [["type": "field", "network": "tcp,udp", "outboundTag": .string(directTag)]])], nil)
        case .bypass(let routes) where !routes.isEmpty:
            for route in routes { tail += rules(route.domainRules, route.ipRules, to: directTag) }
            hasIPRules = true
        case .bypass, .global: break
        }
        guard hasIPRules else { return (["domainStrategy": "AsIs", "rules": .array(customRules + tail)], nil) }
        // Without this, non-matching domains would be resolved by the local resolver,
        // leaking queries and risking a false `geoip:private` match on poisoned networks.
        let dns: JSONValue = [
            "servers": .array(dohServers.map { .string($0) }),
            "queryStrategy": "UseIP",
            "enableParallelQuery": true,
        ]
        return (["domainStrategy": "IPIfNonMatch", "rules": .array(customRules + tail)], dns)
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
        if let tun = options.tun { out = tunDNS(out, tun: tun) }
        return blockingLoopback(of: out, when: options.inbound.allowLAN)
    }
}
