import CryptoKit
import Foundation

public enum ProfileKind: String, Sendable, Codable {
    case outbound
    case custom
}

public struct ParsedProfile: Sendable, Hashable {
    public var name: String
    public var kind: ProfileKind
    /// vless, vmess, trojan, shadowsocks, hysteria, wireguard, socks, http.
    /// For `.custom` it is the protocol of the config's proxy outbound, or "custom" when there is none.
    public var protocolName: String
    public var address: String
    public var port: Int
    /// raw, xhttp, ws, grpc, httpupgrade, kcp, hysteria
    public var transport: String
    /// none, tls, reality
    public var security: String
    /// The outbound object, or the full Xray config for `.custom`.
    public var config: JSONValue
    public var originalLink: String?
    public var fingerprint: String
    public var warnings: [String]

    public init(
        name: String,
        kind: ProfileKind,
        protocolName: String,
        address: String,
        port: Int,
        transport: String,
        security: String,
        config: JSONValue,
        originalLink: String? = nil,
        warnings: [String] = []
    ) {
        self.name = name
        self.kind = kind
        self.protocolName = protocolName
        self.address = address
        self.port = port
        self.transport = transport
        self.security = security
        self.config = config
        self.originalLink = originalLink
        self.warnings = warnings
        self.fingerprint = Self.fingerprint(kind: kind, config: config)
    }

    /// SHA-256 (hex) of the config with sorted keys and naming fields removed,
    /// so two entries that differ only in display name share a fingerprint.
    public static func fingerprint(kind: ProfileKind, config: JSONValue) -> String {
        var normalised = config
        switch kind {
        case .outbound:
            normalised = normalised.removing("tag")
        case .custom:
            normalised = normalised.removing("remarks")
            if case .array(var outbounds)? = normalised["outbounds"], !outbounds.isEmpty {
                outbounds[0] = outbounds[0].removing("tag")
                normalised = normalised.setting("outbounds", to: .array(outbounds))
            }
        }
        let data = (try? normalised.data()) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
