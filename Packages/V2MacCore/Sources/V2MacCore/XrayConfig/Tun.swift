import Foundation

/// What the core needs while TUN mode is on: a loopback port the TUN forwarder feeds, and the
/// physical interface its own connections must leave through so they do not re-enter the TUN.
public struct TunLink: Sendable, Hashable {
    public var port: Int
    public var outboundInterface: String

    public init(port: Int, outboundInterface: String) {
        self.port = port
        self.outboundInterface = outboundInterface
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
            "outbounds": [
                [
                    "tag": "core",
                    "protocol": "socks",
                    "settings": ["address": "127.0.0.1", "port": .number(Double(corePort))],
                ],
                ["tag": .string(directTag), "protocol": "freedom"],
            ],
            // DNS stays on the path it had before the TUN came up. Through the core it would
            // deadlock: the core needs the resolver to find its own server.
            "routing": ["rules": [["type": "field", "port": "53", "outboundTag": .string(directTag)]]],
        ]
    }
}
