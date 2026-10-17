import Foundation
import Network

/// What the core needs while TUN mode is on: a loopback port the TUN forwarder feeds, the
/// physical interface its own connections must leave through so they do not re-enter the TUN,
/// and the network's resolvers, which look up the server's own name on that interface.
public struct TunLink: Sendable, Hashable {
    public var port: Int
    public var outboundInterface: String
    public var resolvers: [String]

    /// Used when the network names no resolver the core can reach.
    public static let fallbackResolvers = ["1.1.1.1", "8.8.8.8"]

    public init(port: Int, outboundInterface: String, resolvers: [String] = []) {
        self.port = port
        self.outboundInterface = outboundInterface
        self.resolvers = resolvers.isEmpty ? Self.fallbackResolvers : resolvers
    }
}

extension ConfigBuilder {
    public static let tunInboundTag = "tun-in"
    /// Inbounds that carry user traffic; rules and traffic counters cover all of them.
    public static let trafficInboundTags = [inboundTag, tunInboundTag]

    /// Loopback SOCKS inbound that receives everything the TUN forwarder captures.
    static func tunInbound(port: Int) -> JSONValue {
        [
            "tag": .string(tunInboundTag),
            "listen": "127.0.0.1",
            "port": .number(Double(port)),
            "protocol": "socks",
            "settings": ["auth": "noauth", "udp": true],
            "sniffing": [
                "enabled": true,
                "routeOnly": true,
                "destOverride": ["http", "tls", "quic"],
            ],
        ]
    }

    static func inbounds(for options: RunOptions) -> JSONValue {
        var list = [mixedInbound(options.inbound)]
        if let tun = options.tun { list.append(tunInbound(port: tun.port)) }
        return .array(list)
    }

    /// Pins an outbound's connections to `interface`. An interface the config already names,
    /// and outbounds that never dial out or dial this Mac, are left alone.
    public static func binding(_ outbound: JSONValue, to interface: String) -> JSONValue {
        guard case .object = outbound else { return outbound }
        switch outbound["protocol"]?.stringValue {
        case "blackhole", "dns", "loopback": return outbound
        default: break
        }
        if let address = serverAddress(of: outbound), isLoopback(address) { return outbound }
        let stream = outbound["streamSettings"] ?? [:]
        let sockopt = stream["sockopt"] ?? [:]
        if let existing = sockopt["interface"]?.stringValue, !existing.isEmpty { return outbound }
        return outbound.setting("streamSettings", to: stream.setting("sockopt", to: sockopt.setting("interface", to: .string(interface))))
    }

    /// `binding` applied to every outbound of a full config.
    public static func bindingOutbounds(of config: JSONValue, to interface: String) -> JSONValue {
        guard case .array(let outbounds)? = config["outbounds"] else { return config }
        return config.setting("outbounds", to: .array(outbounds.map { binding($0, to: interface) }))
    }

    static func serverAddress(of outbound: JSONValue) -> String? {
        let settings = outbound["settings"]
        return settings?["address"]?.stringValue
            ?? settings?["vnext"]?[0]?["address"]?.stringValue
            ?? settings?["servers"]?[0]?["address"]?.stringValue
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    /// Config for the privileged forwarder: a TUN interface that takes over the system routes
    /// and hands every connection to the core on `corePort`. It is the only config that runs
    /// as root, so it carries nothing from a server or a subscription.
    public static func tunForwarder(interfaceName: String, corePort: Int, logLevel: XrayLogLevel = .warning) -> JSONValue {
        [
            "log": ["loglevel": .string(logLevel.rawValue), "access": "none"],
            "inbounds": [[
                "tag": "tun",
                "protocol": "tun",
                "settings": [
                    "name": .string(interfaceName),
                    "mtu": 1500,
                    "autoSystemRoutingTable": ["0.0.0.0/0", "::/0"],
                    "autoOutboundsInterface": "auto",
                ],
                // Not route-only: the name an app asked for replaces the address it resolved,
                // so the core routes by domain and a poisoned DNS answer does no harm.
                "sniffing": ["enabled": true, "destOverride": ["http", "tls", "quic"]],
            ]],
            // Everything goes to the core, DNS included (see `tunDNS`): nothing here leaves directly.
            "outbounds": [[
                "tag": "core",
                "protocol": "socks",
                "settings": ["address": "127.0.0.1", "port": .number(Double(corePort))],
                // `autoOutboundsInterface` would bind this to the physical interface, and UDP
                // to loopback bound there is dropped: DNS and every other UDP flow got lost.
                "streamSettings": ["sockopt": ["interface": "lo0"]],
            ]],
        ]
    }

    public static let tunDNSTag = "v2mac-dns-out"
    static let bootstrapTag = "v2mac-bootstrap"
    static let bootstrapDNSTag = "v2mac-bootstrap-dns"

    /// Spec 9.5, DNS. Every lookup that enters the TUN, whichever resolver it was sent to, is
    /// answered by the core's own resolver, which asks through the proxy like any other traffic.
    /// The core cannot use the system resolver for its server's own name: that lookup would come
    /// back through the TUN and wait for the server it is trying to find. So outbounds that dial
    /// a name resolve it with the core's resolver, which asks the network's resolvers for exactly
    /// those names, on the physical interface. A `localhost` resolver would loop the same way and
    /// is dropped.
    static func tunDNS(_ config: JSONValue, tun: TunLink) -> JSONValue {
        guard case .array(let outbounds)? = config["outbounds"] else { return config }
        let names = Array(Set(outbounds.flatMap(dialedNames))).sorted()
        // Freedom outbounds that others dial through resolve those servers' names for them.
        let dialers = Set(outbounds.compactMap { $0["streamSettings"]?["sockopt"]?["dialerProxy"]?.stringValue })
        var wired = outbounds.map { outbound -> JSONValue in
            let isDialer = outbound["protocol"]?.stringValue == "freedom" && dialers.contains(outbound["tag"]?.stringValue ?? "")
            return dialedNames(outbound).isEmpty && !isDialer ? outbound : resolvingWithCore(outbound)
        }
        wired.append(["tag": .string(tunDNSTag), "protocol": "dns"])

        var dns = config["dns"] ?? ["queryStrategy": "UseIP", "enableParallelQuery": true]
        var servers = (dns["servers"]?.arrayValue ?? []).filter { server in
            (server.stringValue ?? server["address"]?.stringValue)?.lowercased() != "localhost"
        }
        if servers.isEmpty { servers = dohServers.map { .string($0) } }
        var rules: [JSONValue] = [["type": "field", "inboundTag": .array([.string(tunInboundTag)]), "port": "53", "outboundTag": .string(tunDNSTag)]]
        if !names.isEmpty {
            let only: JSONValue = .array(names.map { .string("full:\($0)") })
            servers = tun.resolvers.map { ["address": .string($0), "domains": only, "skipFallback": true, "tag": .string(bootstrapDNSTag)] } + servers
            wired.append(binding(["tag": .string(bootstrapTag), "protocol": "freedom"], to: tun.outboundInterface))
            rules.insert(["type": "field", "inboundTag": .array([.string(bootstrapDNSTag)]), "outboundTag": .string(bootstrapTag)], at: 0)
        }
        dns = dns.setting("servers", to: .array(servers))

        let routing = config["routing"] ?? [:]
        let userRules = (routing["rules"]?.arrayValue ?? []).compactMap { rule -> JSONValue? in
            guard !(rule["process"]?.arrayValue ?? []).isEmpty else { return rule }
            // The SOCKS forwarder loses app identity; reject its inbound before Xray's process lookup.
            let tags = (rule["inboundTag"]?.arrayValue).flatMap { $0.isEmpty ? nil : $0 } ?? [.string(inboundTag)]
            let directTags = tags.filter { $0 != .string(tunInboundTag) }
            guard !directTags.isEmpty else { return nil }
            return rule.setting("inboundTag", to: .array(directTags))
        }
        return config
            .setting("outbounds", to: .array(wired))
            .setting("dns", to: dns)
            .setting("routing", to: routing.setting("rules", to: .array(rules + userRules)))
    }

    /// Server names an outbound dials, IP addresses and this Mac's own names left out.
    static func dialedNames(_ outbound: JSONValue) -> [String] {
        dialedHosts(outbound).filter { IPv4Address($0) == nil && IPv6Address($0) == nil }
    }

    /// Server addresses an outbound dials, names and IP addresses, this Mac's own left out.
    static func dialedHosts(_ outbound: JSONValue) -> [String] {
        let settings = outbound["settings"]
        var hosts = [settings?["address"]?.stringValue]
        for list in ["vnext", "servers"] { hosts += (settings?[list]?.arrayValue ?? []).map { $0["address"]?.stringValue } }
        // WireGuard: "host:port" or "[v6]:port".
        hosts += (settings?["peers"]?.arrayValue ?? []).map { peer in
            peer["endpoint"]?.stringValue.map { endpoint in
                let host = endpoint.hasPrefix("[") ? String(endpoint.dropFirst().prefix { $0 != "]" }) : String(endpoint.prefix { $0 != ":" })
                return host
            }
        }
        return hosts.compactMap { $0 }.filter { !$0.isEmpty && !isLoopback($0) }
    }

    /// Makes an outbound resolve the names it dials with the core's resolver (IPv4 first).
    static func resolvingWithCore(_ outbound: JSONValue) -> JSONValue {
        let stream = outbound["streamSettings"] ?? [:]
        let sockopt = stream["sockopt"] ?? [:]
        if let existing = sockopt["domainStrategy"]?.stringValue, existing != "AsIs" { return outbound }
        return outbound.setting("streamSettings", to: stream.setting("sockopt", to: sockopt.setting("domainStrategy", to: "UseIPv4v6")))
    }
}
