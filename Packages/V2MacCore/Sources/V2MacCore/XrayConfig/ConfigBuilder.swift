import Foundation

public struct InboundSettings: Sendable, Hashable {
    public var port: Int
    public var allowLAN: Bool
    public var username: String?
    public var password: String?

    public init(port: Int = 10808, allowLAN: Bool = false, username: String? = nil, password: String? = nil) {
        self.port = port
        self.allowLAN = allowLAN
        self.username = username
        self.password = password
    }

    public var listenAddress: String { allowLAN ? "0.0.0.0" : "127.0.0.1" }

    public var hasCredentials: Bool {
        !(username ?? "").isEmpty && !(password ?? "").isEmpty
    }
}

public enum XrayLogLevel: String, Sendable, CaseIterable {
    case none, error, warning, info, debug
}

public struct RunOptions: Sendable, Hashable {
    public var inbound: InboundSettings
    public var logLevel: XrayLogLevel
    public var logConnections: Bool
    public var metricsPort: Int

    public init(
        inbound: InboundSettings = InboundSettings(),
        logLevel: XrayLogLevel = .warning,
        logConnections: Bool = false,
        metricsPort: Int
    ) {
        self.inbound = inbound
        self.logLevel = logLevel
        self.logConnections = logConnections
        self.metricsPort = metricsPort
    }
}

public enum ConfigBuilderError: Error, Sendable, Equatable {
    case outboundNotAnObject
}

public enum ConfigBuilder {
    public static let inboundTag = "mixed-in"
    public static let proxyTag = "proxy"
    public static let directTag = "direct"
    public static let blockTag = "block"
    public static let metricsTag = "metrics"

    public static func mixedInbound(_ s: InboundSettings) -> JSONValue {
        var settings: JSONValue = ["udp": true]
        if s.hasCredentials {
            settings = settings
                .setting("auth", to: "password")
                .setting("accounts", to: [["user": .string(s.username ?? ""), "pass": .string(s.password ?? "")]])
        } else {
            settings = settings.setting("auth", to: "noauth")
        }
        return [
            "tag": .string(inboundTag),
            "listen": .string(s.listenAddress),
            "port": .number(Double(s.port)),
            "protocol": "mixed",
            "settings": settings,
            "sniffing": [
                "enabled": true,
                "routeOnly": true,
                "destOverride": ["http", "tls", "quic"],
            ],
        ]
    }

    static func logSection(_ o: RunOptions) -> JSONValue {
        var log: JSONValue = ["loglevel": .string(o.logLevel.rawValue)]
        if !o.logConnections { log = log.setting("access", to: "none") }
        return log
    }

    static var statsPolicy: JSONValue {
        ["system": ["statsInboundUplink": true, "statsInboundDownlink": true]]
    }

    static func metricsSection(port: Int) -> JSONValue {
        ["tag": .string(metricsTag), "listen": .string("127.0.0.1:\(port)")]
    }

    /// Global mode: private addresses go direct, everything else through `outbound`.
    public static func buildGlobal(outbound: JSONValue, options: RunOptions) throws -> JSONValue {
        try build(outbound: outbound, options: options, routing: .global)
    }
}
