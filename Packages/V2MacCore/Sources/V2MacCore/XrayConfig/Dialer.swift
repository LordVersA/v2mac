import Foundation

/// A range as Xray writes it: `100-200`, or a single number.
public enum RangeText {
    public static func isValid(_ text: String) -> Bool {
        let parts = text.filter { !$0.isWhitespace }.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 5 && $0.allSatisfy(\.isASCIIDigit) }) else {
            return false
        }
        if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]), low > high { return false }
        return true
    }

    /// `text` without spaces when it is a valid range, otherwise `fallback`.
    static func normalised(_ text: String, default fallback: String) -> String {
        isValid(text) ? text.filter { !$0.isWhitespace } : fallback
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Splits the start of each connection into small pieces, so a filter that reads only the
/// first packet does not see the server name.
public struct FragmentSettings: Sendable, Hashable {
    public enum Packets: String, Sendable, CaseIterable, Identifiable {
        /// Only the TLS ClientHello, split into several TLS records.
        case tlsHello = "tlshello"
        /// The first three writes, split at the TCP level.
        case firstPackets = "1-3"
        public var id: String { rawValue }
    }

    public static let defaultLength = "100-200"
    public static let defaultInterval = "10-20"

    public var packets: Packets
    /// Size of each piece in bytes.
    public var length: String
    /// Pause between pieces in milliseconds.
    public var interval: String

    public init(packets: Packets = .tlsHello, length: String = defaultLength, interval: String = defaultInterval) {
        self.packets = packets
        self.length = RangeText.normalised(length, default: Self.defaultLength)
        self.interval = RangeText.normalised(interval, default: Self.defaultInterval)
    }
}

/// Random packets sent ahead of each UDP flow.
public struct NoiseSettings: Sendable, Hashable {
    public static let defaultPacket = "10-20"
    public static let defaultDelay = "10-16"

    /// Size of the random packet in bytes.
    public var packet: String
    /// Pause after it in milliseconds.
    public var delay: String

    public init(packet: String = defaultPacket, delay: String = defaultDelay) {
        self.packet = RangeText.normalised(packet, default: Self.defaultPacket)
        self.delay = RangeText.normalised(delay, default: Self.defaultDelay)
    }
}

/// How servers are dialled; both parts are off unless the user turns them on.
public struct DialerSettings: Sendable, Hashable {
    public var fragment: FragmentSettings?
    public var noise: NoiseSettings?

    public init(fragment: FragmentSettings? = nil, noise: NoiseSettings? = nil) {
        self.fragment = fragment
        self.noise = noise
    }

    public var isEmpty: Bool { fragment == nil && noise == nil }
}

public enum DNSQueryStrategy: String, Sendable, CaseIterable, Identifiable {
    case useIP = "UseIP", useIPv4 = "UseIPv4", useIPv6 = "UseIPv6"
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .useIP: "IPv4 and IPv6"
        case .useIPv4: "IPv4 only"
        case .useIPv6: "IPv6 only"
        }
    }
}

/// The core's own resolver, used for routing decisions and for traffic that goes direct.
public struct DNSSettings: Sendable, Hashable {
    public static let defaultServers = ConfigBuilder.dohServers

    public var servers: [String]
    public var queryStrategy: DNSQueryStrategy

    public init(servers: [String] = defaultServers, queryStrategy: DNSQueryStrategy = .useIP) {
        let usable = servers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }
        self.servers = usable.isEmpty ? Self.defaultServers : usable
        self.queryStrategy = queryStrategy
    }

    /// Servers typed as one line or several, separated by commas or line breaks.
    public static func servers(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline }).map(String.init)
    }
}

extension ConfigBuilder {
    public static let dialerTag = "v2mac-dialer"
    public static let apiTag = "api"

    /// Protocols that dial a remote server through `streamSettings`. WireGuard has none, and
    /// the rest never leave this Mac or are the dialer's own kind.
    private static let dialedProtocols: Set<String> = ["vless", "vmess", "trojan", "shadowsocks", "socks", "http", "hysteria"]

    /// The `freedom` outbound that carries the fragment and noise settings, or nil when both are off.
    static func dialerOutbound(_ settings: DialerSettings) -> JSONValue? {
        guard !settings.isEmpty else { return nil }
        var body: JSONValue = [:]
        if let fragment = settings.fragment {
            body = body.setting("fragment", to: [
                "packets": .string(fragment.packets.rawValue),
                "length": .string(fragment.length),
                "interval": .string(fragment.interval),
            ])
        }
        if let noise = settings.noise {
            body = body.setting("noises", to: [["type": "rand", "packet": .string(noise.packet), "delay": .string(noise.delay)]])
        }
        return ["tag": .string(dialerTag), "protocol": "freedom", "settings": body]
    }

    /// Makes a proxy outbound connect through the dialer outbound. Left alone: outbounds that
    /// already chain through another one, servers on this Mac, and protocols that do not dial.
    static func dialing(_ outbound: JSONValue, through settings: DialerSettings) -> JSONValue {
        guard !settings.isEmpty, dialedProtocols.contains(outbound["protocol"]?.stringValue ?? "") else { return outbound }
        if let address = serverAddress(of: outbound), isLoopback(address) { return outbound }
        if let tag = outbound["proxySettings"]?["tag"]?.stringValue, !tag.isEmpty { return outbound }
        let stream = outbound["streamSettings"] ?? [:]
        let sockopt = stream["sockopt"] ?? [:]
        if let existing = sockopt["dialerProxy"]?.stringValue, !existing.isEmpty { return outbound }
        return outbound.setting("streamSettings", to: stream.setting("sockopt", to: sockopt.setting("dialerProxy", to: .string(dialerTag))))
    }

    /// A server's outbound as it runs: tagged `proxy`, dialled as the settings say, and in TUN
    /// mode bound to the physical interface. Also what a live switch puts in place of the old one.
    public static func proxyOutbound(_ outbound: JSONValue, options: RunOptions) -> JSONValue {
        let proxy = dialing(InsecureTLS.stripping(outbound).setting("tag", to: .string(proxyTag)), through: options.dialer)
        return options.tun.map { binding(proxy, to: $0.outboundInterface) } ?? proxy
    }

    /// Loopback API used to swap the proxy outbound without restarting the core.
    static func apiSection(port: Int) -> JSONValue {
        ["tag": .string(apiTag), "listen": .string("127.0.0.1:\(port)"), "services": ["HandlerService"]]
    }

    static func dnsSection(_ settings: DNSSettings) -> JSONValue {
        [
            "servers": .array(settings.servers.map { .string($0) }),
            "queryStrategy": .string(settings.queryStrategy.rawValue),
            "enableParallelQuery": true,
        ]
    }

    /// `dialing` applied to a full config, adding the dialer outbound when something uses it.
    static func dialingOutbounds(of config: JSONValue, through settings: DialerSettings) -> JSONValue {
        guard let dialer = dialerOutbound(settings), case .array(let outbounds)? = config["outbounds"],
              !outbounds.contains(where: { $0["tag"]?.stringValue == dialerTag }) else { return config }
        let wired = outbounds.map { dialing($0, through: settings) }
        guard wired != outbounds else { return config }
        return config.setting("outbounds", to: .array(wired + [dialer]))
    }
}
