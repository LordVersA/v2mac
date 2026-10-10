// Share-link parsing follows the logic of XTLS/libXray `share/` (tag v26.9.30).
// libXray is MIT licensed, Copyright (c) 2023-2025 XTLS; the full licence text is in THIRD_PARTY.md.

import Foundation

public enum ShareLinkParser {
    public static let knownSchemes: Set<String> = [
        "vless", "vmess", "trojan", "ss", "hysteria2", "hy2",
        "socks", "socks5", "http", "https", "wireguard",
    ]

    /// Lowercased scheme when `line` starts with a supported share-link scheme.
    public static func knownScheme(of line: String) -> String? {
        guard let r = line.range(of: "://") else { return nil }
        let scheme = line[..<r.lowerBound].lowercased()
        return knownSchemes.contains(scheme) ? scheme : nil
    }

    /// Parses one share link into an Xray outbound profile.
    /// Throws `LinkSkip` with a human-readable reason when the entry is unusable.
    public static func parse(_ link: String) throws -> ParsedProfile {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = knownScheme(of: trimmed) else {
            throw LinkSkip("unsupported scheme")
        }
        var profile: ParsedProfile
        switch scheme {
        case "vless": profile = try parseVless(trimmed)
        case "vmess": profile = try parseVmess(trimmed)
        case "trojan": profile = try parseTrojan(trimmed)
        case "ss": profile = try parseShadowsocks(trimmed)
        case "hysteria2", "hy2": profile = try parseHysteria2(trimmed)
        case "socks", "socks5": profile = try parseSocks(trimmed)
        case "http", "https": profile = try parseHTTP(trimmed)
        case "wireguard": profile = try parseWireguard(trimmed)
        default: throw LinkSkip("unsupported scheme")
        }
        profile.originalLink = trimmed
        return profile
    }

    // MARK: Helpers

    private static func url(_ link: String) throws -> RawURL {
        guard let u = RawURL(link) else { throw LinkSkip("malformed link") }
        return u
    }

    private static func outbound(
        _ protocolName: String,
        settings: JSONValue,
        stream: StreamResult?
    ) -> JSONValue {
        var o: JSONValue = ["protocol": .string(protocolName), "settings": settings]
        if let stream { o = o.setting("streamSettings", to: stream.json) }
        return o
    }

    private static func profile(
        name: String,
        protocolName: String,
        address: String,
        port: Int,
        stream: StreamResult?,
        config: JSONValue,
        extraWarnings: [String] = []
    ) -> ParsedProfile {
        ParsedProfile(
            name: name,
            kind: .outbound,
            protocolName: protocolName,
            address: address,
            port: port,
            transport: stream?.transport ?? "",
            security: stream?.security ?? "none",
            config: config,
            warnings: (stream?.warnings ?? []) + extraWarnings
        )
    }

    // MARK: VLESS

    private static func parseVless(_ link: String) throws -> ParsedProfile {
        let u = try url(link)
        let address = try u.validatedHost()
        let port = try u.port()
        guard let id = u.decodedUserinfo, !id.isEmpty else { throw LinkSkip("missing UUID") }
        let stream = try StreamBuilder.build(StreamParams(query: u.query), defaultSecurity: "none")
        let settings = compact([
            "address": .string(address),
            "port": .number(Double(port)),
            "id": .string(id),
            "encryption": .string(u.query["encryption"] ?? "none"),
            "flow": u.query["flow"].map { .string($0) },
        ])
        var warnings: [String] = []
        if stream.security == "none", (u.query["encryption"] ?? "none") == "none" {
            warnings.append("Xray refuses VLESS without TLS, REALITY or encryption; this server will fail to start")
        }
        return profile(
            name: u.displayName(address: address, port: port),
            protocolName: "vless", address: address, port: port, stream: stream,
            config: outbound("vless", settings: settings, stream: stream),
            extraWarnings: warnings
        )
    }

    // MARK: VMess

    private static func parseVmess(_ link: String) throws -> ParsedProfile {
        guard let u = RawURL(link) else { throw LinkSkip("malformed link") }
        if u.userinfo != nil { return try parseVmessURL(u) }
        return try parseVmessBase64(u)
    }

    private static func parseVmessURL(_ u: RawURL) throws -> ParsedProfile {
        let address = try u.validatedHost()
        let port = try u.port()
        guard var id = u.decodedUserinfo, !id.isEmpty else { throw LinkSkip("missing UUID") }
        if let colon = id.firstIndex(of: ":") { id = String(id[..<colon]) }
        let stream = try StreamBuilder.build(StreamParams(query: u.query), defaultSecurity: "none")
        let settings: JSONValue = [
            "address": .string(address),
            "port": .number(Double(port)),
            "id": .string(id),
            "security": .string(u.query["encryption"] ?? u.query["scy"] ?? "auto"),
        ]
        return profile(
            name: u.displayName(address: address, port: port),
            protocolName: "vmess", address: address, port: port, stream: stream,
            config: outbound("vmess", settings: settings, stream: stream)
        )
    }

    /// v2rayN form: `vmess://base64({"v":"2","ps":..,"add":..,...})`.
    private static func parseVmessBase64(_ u: RawURL) throws -> ParsedProfile {
        var payload = u.afterScheme
        if let q = payload.firstIndex(of: "?") { payload = String(payload[..<q]) }
        guard let text = Base64Tolerant.decodeString(payload),
              let json = try? JSONValue.parse(Data(text.utf8)),
              case .object(let f) = json
        else { throw LinkSkip("invalid vmess payload") }

        func string(_ key: String) -> String? {
            switch f[key] {
            case .string(let s)?: let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t
            case .number(let n)?: return String(Int(n))
            default: return nil
            }
        }

        guard let address = string("add") else { throw LinkSkip("missing server address") }
        guard let portText = string("port"), let port = Int(portText), (1...65535).contains(port) else {
            throw LinkSkip("invalid or missing port")
        }
        guard let id = string("id") else { throw LinkSkip("missing UUID") }

        var p = StreamParams()
        p.network = string("net") ?? ""
        p.security = string("tls") ?? ""
        p.sni = string("sni")
        p.alpn = string("alpn")
        p.fp = string("fp")
        p.host = string("host")
        let type = string("type")
        switch p.network.lowercased() {
        case "grpc", "gun":
            p.serviceName = string("path")
            p.mode = type
        case "kcp", "mkcp":
            p.seed = string("path")
            p.headerType = type
        case "xhttp", "splithttp":
            p.path = string("path")
            p.mode = (type == "none") ? nil : type
        default:
            p.path = string("path")
            p.headerType = type
        }

        let stream = try StreamBuilder.build(p, defaultSecurity: "none")
        let settings: JSONValue = [
            "address": .string(address),
            "port": .number(Double(port)),
            "id": .string(id),
            "security": .string(string("scy") ?? "auto"),
        ]
        return profile(
            name: string("ps") ?? "\(address):\(port)",
            protocolName: "vmess", address: address, port: port, stream: stream,
            config: outbound("vmess", settings: settings, stream: stream)
        )
    }

    // MARK: Trojan

    private static func parseTrojan(_ link: String) throws -> ParsedProfile {
        let u = try url(link)
        let address = try u.validatedHost()
        let port = try u.port()
        guard let password = u.decodedUserinfo, !password.isEmpty else { throw LinkSkip("missing password") }
        let stream = try StreamBuilder.build(StreamParams(query: u.query), defaultSecurity: "tls")
        let settings: JSONValue = [
            "address": .string(address),
            "port": .number(Double(port)),
            "password": .string(password),
        ]
        return profile(
            name: u.displayName(address: address, port: port),
            protocolName: "trojan", address: address, port: port, stream: stream,
            config: outbound("trojan", settings: settings, stream: stream)
        )
    }

    // MARK: Shadowsocks

    private static func parseShadowsocks(_ link: String) throws -> ParsedProfile {
        let u = try url(link)
        let method: String, password: String, address: String, port: Int
        var query = u.query

        if u.userinfo != nil {
            // SIP002: userinfo is base64(method:password) or plain method:password.
            address = try u.validatedHost()
            port = try u.port()
            let info = u.userinfo ?? ""
            let decoded: String
            if info.contains(":") {
                decoded = info.removingPercentEncoding ?? info
            } else if let b = Base64Tolerant.decodeString(info.removingPercentEncoding ?? info) {
                decoded = b
            } else {
                throw LinkSkip("invalid shadowsocks credentials")
            }
            guard let colon = decoded.firstIndex(of: ":") else { throw LinkSkip("invalid shadowsocks credentials") }
            method = String(decoded[..<colon])
            password = String(decoded[decoded.index(after: colon)...])
        } else {
            // Legacy: base64(method:password@host:port)
            var payload = u.afterScheme
            if let q = payload.firstIndex(of: "?") {
                query = LinkQuery(String(payload[payload.index(after: q)...]))
                payload = String(payload[..<q])
            }
            if payload.hasSuffix("/") { payload.removeLast() }
            guard let text = Base64Tolerant.decodeString(payload),
                  let at = text.lastIndex(of: "@"),
                  let colon = text.firstIndex(of: ":"), colon < at
            else { throw LinkSkip("invalid shadowsocks payload") }
            method = String(text[..<colon])
            password = String(text[text.index(after: colon)..<at])
            guard let hp = RawURL("ss://\(text[text.index(after: at)...])") else {
                throw LinkSkip("invalid shadowsocks payload")
            }
            address = try hp.validatedHost()
            port = try hp.port()
        }

        guard !method.isEmpty, !password.isEmpty else { throw LinkSkip("invalid shadowsocks credentials") }
        var params = StreamParams(query: query)
        if let plugin = query["plugin"] { try applyShadowsocksPlugin(plugin, to: &params) }

        let stream = try StreamBuilder.build(params, defaultSecurity: "none")
        let settings: JSONValue = [
            "address": .string(address),
            "port": .number(Double(port)),
            "method": .string(method),
            "password": .string(password),
        ]
        return profile(
            name: u.displayName(address: address, port: port),
            protocolName: "shadowsocks", address: address, port: port, stream: stream,
            config: outbound("shadowsocks", settings: settings, stream: stream)
        )
    }

    /// Xray runs no SIP003 plugins, but the common ones are transports it has itself: v2ray-plugin
    /// is WebSocket (or gRPC) with optional TLS, simple-obfs in HTTP mode is the raw HTTP header.
    /// `plugin` is `name;key=value;flag` (SIP002).
    private static func applyShadowsocksPlugin(_ plugin: String, to p: inout StreamParams) throws {
        var parts = plugin.split(separator: ";").map(String.init)
        guard !parts.isEmpty else { return }
        let name = parts.removeFirst().lowercased()
        var options: [String: String] = [:]
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            options[pair[0].lowercased()] = pair.count > 1 ? String(pair[1]) : ""
        }

        switch name {
        case "v2ray-plugin", "xray-plugin":
            let mode = options["mode"]?.lowercased() ?? "websocket"
            switch mode {
            case "websocket":
                p.network = "ws"
                p.path = options["path"] ?? "/"
            case "grpc":
                p.network = "grpc"
                p.serviceName = options["servicename"] ?? "GunService"
            default:
                throw LinkSkip("shadowsocks plugin mode \"\(mode)\" is not supported")
            }
            p.host = options["host"]
            if options["tls"] != nil {
                p.security = "tls"
                p.sni = options["host"]
            }
        case "obfs-local", "simple-obfs":
            let obfs = options["obfs"]?.lowercased() ?? ""
            guard obfs == "http" else { throw LinkSkip("shadowsocks plugin obfs \"\(obfs)\" is not supported") }
            p.network = "raw"
            p.headerType = "http"
            p.host = options["obfs-host"]
            p.path = options["obfs-uri"]
        default:
            throw LinkSkip("shadowsocks plugin \"\(name)\" is not supported")
        }
    }

    // MARK: Hysteria 2

    private static func parseHysteria2(_ link: String) throws -> ParsedProfile {
        let u = try url(link)
        let address = try u.validatedHost()

        // Authority port may be "443", "443,5000-6000" or "20000-30000".
        guard let portText = u.portText else { throw LinkSkip("invalid or missing port") }
        var segments = csv(portText)
        guard !segments.isEmpty else { throw LinkSkip("invalid or missing port") }
        let first = segments.removeFirst()
        let port: Int
        if let single = Int(first) {
            port = single
        } else if let dash = first.firstIndex(of: "-"), let start = Int(first[..<dash]) {
            port = start
            segments.insert(first, at: 0)
        } else {
            throw LinkSkip("invalid or missing port")
        }
        guard (1...65535).contains(port) else { throw LinkSkip("invalid or missing port") }
        if let mport = u.query["mport"] { segments += csv(mport) }

        // Hysteria's pin is the leaf certificate's SHA-256 in hex, usually written with colons.
        var pin: String?
        if let raw = u.query["pinsha256"] {
            let hex = raw.lowercased().filter { $0 != ":" }
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { throw LinkSkip("invalid pinSHA256") }
            pin = hex
        }

        // A pinned certificate is accepted whoever issued it, so `insecure` changes nothing then.
        let insecure = pin == nil && u.query.flag("insecure", "allowinsecure")
        let warnings = insecure ? [StreamBuilder.insecureWarning] : []

        var hysteria: [String: JSONValue] = [
            "version": 2,
            "auth": .string(u.decodedUserinfo ?? ""),
        ]
        if !segments.isEmpty {
            hysteria["udphop"] = ["port": .string(segments.joined(separator: ",")), "interval": 30]
        }

        let alpn = csv(u.query["alpn"])
        var stream: [String: JSONValue] = [
            "network": "hysteria",
            "security": "tls",
            "tlsSettings": compact([
                "serverName": u.query["sni"].map { .string($0) },
                "alpn": .array((alpn.isEmpty ? ["h3"] : alpn).map { .string($0) }),
                "pinnedPeerCertSha256": pin.map { .string($0) },
                InsecureTLS.flag: insecure ? true : nil,
            ]),
            "hysteriaSettings": .object(hysteria),
        ]
        if let obfs = u.query["obfs"] {
            guard obfs.lowercased() == "salamander" else { throw LinkSkip("unsupported obfs \"\(obfs)\"") }
            let pw = u.query["obfs-password"] ?? ""
            stream["finalmask"] = ["udp": [["type": "salamander", "settings": ["password": .string(pw)]]]]
        }

        let settings: JSONValue = [
            "version": 2,
            "address": .string(address),
            "port": .number(Double(port)),
        ]
        let config: JSONValue = [
            "protocol": "hysteria",
            "settings": settings,
            "streamSettings": .object(stream),
        ]
        return ParsedProfile(
            name: u.displayName(address: address, port: port),
            kind: .outbound,
            protocolName: "hysteria",
            address: address,
            port: port,
            transport: "hysteria",
            security: "tls",
            config: config,
            warnings: warnings
        )
    }

    // MARK: SOCKS / HTTP

    private static func credentials(from u: RawURL, allowBase64: Bool) -> (user: String, pass: String)? {
        guard let info = u.userinfo, !info.isEmpty else { return nil }
        let decoded = info.removingPercentEncoding ?? info
        if let colon = decoded.firstIndex(of: ":") {
            return (String(decoded[..<colon]), String(decoded[decoded.index(after: colon)...]))
        }
        if allowBase64, let b = Base64Tolerant.decodeString(decoded), let colon = b.firstIndex(of: ":") {
            return (String(b[..<colon]), String(b[b.index(after: colon)...]))
        }
        return (decoded, "")
    }

    private static func parseSocks(_ link: String) throws -> ParsedProfile {
        let u = try url(link)
        let address = try u.validatedHost()
        let port = try u.port()
        let creds = credentials(from: u, allowBase64: true)
        let settings = compact([
            "address": .string(address),
            "port": .number(Double(port)),
            "user": creds.map { .string($0.user) },
            "pass": creds.map { .string($0.pass) },
        ])
        return profile(
            name: u.displayName(address: address, port: port),
            protocolName: "socks", address: address, port: port, stream: nil,
            config: outbound("socks", settings: settings, stream: nil)
        )
    }

    private static func parseHTTP(_ link: String) throws -> ParsedProfile {
        let u = try url(link)
        let address = try u.validatedHost()
        let port = try u.port()
        let creds = credentials(from: u, allowBase64: false)
        let settings = compact([
            "address": .string(address),
            "port": .number(Double(port)),
            "user": creds.map { .string($0.user) },
            "pass": creds.map { .string($0.pass) },
        ])
        var stream: StreamResult?
        if u.scheme == "https" {
            var p = StreamParams()
            p.security = "tls"
            p.sni = isIPAddress(address) ? nil : address
            stream = try StreamBuilder.build(p, defaultSecurity: "tls")
        }
        return profile(
            name: u.displayName(address: address, port: port),
            protocolName: "http", address: address, port: port, stream: stream,
            config: outbound("http", settings: settings, stream: stream)
        )
    }

    // MARK: WireGuard

    private static func parseWireguard(_ link: String) throws -> ParsedProfile {
        let u = try url(link)
        let address = try u.validatedHost()
        let port = try u.port()
        guard let secret = u.decodedUserinfo, !secret.isEmpty else { throw LinkSkip("missing WireGuard private key") }
        guard let publicKey = u.query["publickey"] else { throw LinkSkip("missing WireGuard public key") }

        let addresses = csv(u.query["address"]).map { entry -> String in
            if entry.contains("/") { return entry }
            return entry.contains(":") ? "\(entry)/128" : "\(entry)/32"
        }
        guard !addresses.isEmpty else { throw LinkSkip("missing WireGuard interface address") }

        var warnings: [String] = []
        var reserved: JSONValue?
        if let text = u.query["reserved"] {
            let ints = csv(text).compactMap { Int($0) }
            if ints.count == 3, ints.allSatisfy({ (0...255).contains($0) }) {
                reserved = .array(ints.map { .number(Double($0)) })
            } else {
                warnings.append("Ignored an invalid \"reserved\" value")
            }
        }

        let endpoint = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
        let allowed = csv(u.query["allowedips"])
        let peer = compact([
            "publicKey": .string(publicKey),
            "preSharedKey": u.query["presharedkey"].map { .string($0) },
            "endpoint": .string(endpoint),
            "allowedIPs": .array((allowed.isEmpty ? ["0.0.0.0/0", "::/0"] : allowed).map { .string($0) }),
        ])
        let settings = compact([
            "secretKey": .string(secret),
            "address": .array(addresses.map { .string($0) }),
            "peers": [peer],
            "mtu": u.query["mtu"].flatMap { Int($0) }.map { .number(Double($0)) },
            "reserved": reserved,
        ])
        return profile(
            name: u.displayName(address: address, port: port),
            protocolName: "wireguard", address: address, port: port, stream: nil,
            config: outbound("wireguard", settings: settings, stream: nil),
            extraWarnings: warnings
        )
    }
}
