import Foundation

/// What is wrong with a draft, one line per field, in the order of the form.
public struct DraftError: Error, Sendable, Equatable, LocalizedError {
    public var problems: [String]
    public init(_ problems: [String]) { self.problems = problems }
    public var errorDescription: String? { problems.joined(separator: "\n") }
}

/// A server as the fields of the editing form (spec 12.7): read from a stored outbound, changed
/// by the user, and built back into an outbound. Every field is text, as it is typed.
///
/// Whatever the form has no field for (`sockopt`, extra transport options, …) is carried over
/// from the outbound the draft was read from, as long as the protocol stays the same.
public struct ServerDraft: Sendable, Hashable {
    public enum Proto: String, Sendable, CaseIterable, Identifiable {
        case vless, vmess, trojan, shadowsocks, hysteria, wireguard, socks, http

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .vless: "VLESS"
            case .vmess: "VMess"
            case .trojan: "Trojan"
            case .shadowsocks: "Shadowsocks"
            case .hysteria: "Hysteria 2"
            case .wireguard: "WireGuard"
            case .socks: "SOCKS5"
            case .http: "HTTP"
            }
        }

        /// Protocols that run over a transport of choice, with optional TLS or REALITY and Mux.
        public var hasStream: Bool {
            switch self {
            case .vless, .vmess, .trojan, .shadowsocks: true
            case .hysteria, .wireguard, .socks, .http: false
            }
        }

        var defaultPort: String {
            switch self {
            case .vless, .vmess, .trojan, .hysteria: "443"
            case .shadowsocks: "8388"
            case .wireguard: "51820"
            case .socks: "1080"
            case .http: "8080"
            }
        }
    }

    // MARK: Choices offered by the form

    public static let flows = ["", "xtls-rprx-vision", "xtls-rprx-vision-udp443"]
    public static let vmessSecurities = ["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"]
    public static let shadowsocksMethods = [
        "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305", "none",
    ]
    public static let transports = ["raw", "ws", "grpc", "httpupgrade", "xhttp", "kcp"]
    public static let securities = ["none", "tls", "reality"]
    public static let fingerprints = ["", "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"]
    public static let xhttpModes = ["", "auto", "packet-up", "stream-up", "stream-one"]
    public static let kcpHeaders = ["none", "srtp", "utp", "wechat-video", "dtls", "wireguard", "dns"]
    public static let udp443Policies = ["reject", "allow", "skip"]

    // MARK: Fields

    public var name = ""
    public var proto = Proto.vless
    public var address = ""
    public var port = "443"

    /// VLESS and VMess user id.
    public var id = ""
    public var flow = ""
    public var encryption = "none"
    public var vmessSecurity = "auto"
    /// Trojan and Shadowsocks password, Hysteria auth, SOCKS and HTTP password.
    public var password = ""
    public var method = "aes-256-gcm"
    public var username = ""

    public var transport = "raw"
    /// `none` or `http` for raw, one of `kcpHeaders` for mKCP.
    public var headerType = "none"
    public var host = ""
    public var path = ""
    public var serviceName = ""
    public var authority = ""
    public var grpcMulti = false
    public var xhttpMode = ""
    /// JSON object, as text.
    public var xhttpExtra = ""
    public var kcpSeed = ""

    public var security = "none"
    public var sni = ""
    public var fingerprint = ""
    /// Comma separated.
    public var alpn = ""
    public var allowInsecure = false
    public var pinnedCert = ""
    public var verifyName = ""
    public var ech = ""
    public var realityPublicKey = ""
    public var realityShortID = ""
    public var realitySpiderX = ""
    public var realityMldsa = ""

    /// Hysteria port hopping: `5000-6000,7000`.
    public var hopPorts = ""
    public var hopInterval = "30"
    public var obfs = false
    public var obfsPassword = ""

    public var wgSecretKey = ""
    /// Comma separated.
    public var wgAddresses = ""
    public var wgPublicKey = ""
    public var wgPreSharedKey = ""
    public var wgAllowedIPs = ""
    public var wgMTU = ""
    /// Three numbers, comma separated.
    public var wgReserved = ""
    public var wgKeepAlive = ""

    public var muxEnabled = false
    public var muxConcurrency = "8"
    public var xudpConcurrency = "16"
    public var xudpProxyUDP443 = "reject"

    /// The outbound this draft was read from.
    var base: JSONValue?

    public init(proto: Proto = .vless) {
        self.proto = proto
        port = proto.defaultPort
        if proto == .trojan { security = "tls" }
    }

    /// The port and security a new server of another protocol starts with, unless they were typed.
    public mutating func protocolChanged(from old: Proto) {
        if port == old.defaultPort || port.isEmpty { port = proto.defaultPort }
        if proto == .http, security == "reality" { security = "none" }
    }

    // MARK: Reading an outbound

    /// Nil when the outbound's protocol is not one the form knows.
    public init?(outbound: JSONValue, name: String) {
        guard let proto = outbound["protocol"]?.stringValue.flatMap({ Proto(rawValue: $0.lowercased()) }) else { return nil }
        self.proto = proto
        self.name = name
        base = outbound

        // Xray's older layout nests the server in `vnext` or `servers`, and the user in `users`.
        let settings = outbound["settings"]
        let server = settings?["vnext"]?[0] ?? settings?["servers"]?[0] ?? settings
        let user = server?["users"]?[0] ?? server
        address = Self.text(server?["address"])
        port = Self.text(server?["port"])
        let stream = outbound["streamSettings"]

        switch proto {
        case .vless:
            id = Self.text(user?["id"])
            flow = Self.text(user?["flow"])
            encryption = Self.text(user?["encryption"], default: "none")
        case .vmess:
            id = Self.text(user?["id"])
            vmessSecurity = Self.text(user?["security"], default: "auto")
        case .trojan:
            password = Self.text(server?["password"])
        case .shadowsocks:
            method = Self.text(server?["method"])
            password = Self.text(server?["password"])
        case .socks, .http:
            username = Self.text(user?["user"])
            password = Self.text(user?["pass"])
        case .hysteria:
            let hysteria = stream?["hysteriaSettings"]
            password = Self.text(hysteria?["auth"])
            hopPorts = Self.text(hysteria?["udphop"]?["port"])
            hopInterval = Self.text(hysteria?["udphop"]?["interval"], default: "30")
            if let mask = stream?["finalmask"]?["udp"]?[0], mask["type"]?.stringValue == "salamander" {
                obfs = true
                obfsPassword = Self.text(mask["settings"]?["password"])
            }
        case .wireguard:
            wgSecretKey = Self.text(settings?["secretKey"])
            wgAddresses = Self.list(settings?["address"])
            wgMTU = Self.text(settings?["mtu"])
            wgReserved = Self.list(settings?["reserved"])
            let peer = settings?["peers"]?[0]
            wgPublicKey = Self.text(peer?["publicKey"])
            wgPreSharedKey = Self.text(peer?["preSharedKey"])
            wgAllowedIPs = Self.list(peer?["allowedIPs"])
            wgKeepAlive = Self.text(peer?["keepAlive"])
            // `[2001:db8::1]:51820` or `host:51820`.
            if let endpoint = RawURL("wg://" + Self.text(peer?["endpoint"])) {
                address = endpoint.host
                port = endpoint.portText ?? ""
            }
        }

        readSecurity(stream)
        if proto.hasStream { readTransport(stream) }

        if let mux = outbound["mux"], mux["enabled"]?.boolValue == true {
            muxEnabled = true
            muxConcurrency = Self.text(mux["concurrency"], default: "8")
            xudpConcurrency = Self.text(mux["xudpConcurrency"], default: "16")
            xudpProxyUDP443 = Self.text(mux["xudpProxyUDP443"], default: "reject")
        }
    }

    private mutating func readSecurity(_ stream: JSONValue?) {
        security = (try? StreamBuilder.canonicalSecurity(Self.text(stream?["security"]), default: "none")) ?? "none"
        switch security {
        case "tls":
            let tls = stream?["tlsSettings"]
            sni = Self.text(tls?["serverName"])
            fingerprint = Self.text(tls?["fingerprint"])
            alpn = Self.list(tls?["alpn"])
            allowInsecure = tls?[InsecureTLS.flag]?.boolValue == true
            pinnedCert = Self.list(tls?[InsecureTLS.pin])
            verifyName = Self.text(tls?["verifyPeerCertByName"])
            ech = Self.text(tls?["echConfigList"])
        case "reality":
            let reality = stream?["realitySettings"]
            sni = Self.text(reality?["serverName"])
            fingerprint = Self.text(reality?["fingerprint"])
            realityPublicKey = Self.text(reality?["publicKey"])
            realityShortID = Self.text(reality?["shortId"])
            realitySpiderX = Self.text(reality?["spiderX"])
            realityMldsa = Self.text(reality?["mldsa65Verify"])
        default:
            break
        }
    }

    private mutating func readTransport(_ stream: JSONValue?) {
        transport = (try? StreamBuilder.canonicalTransport(Self.text(stream?["network"]))) ?? "raw"
        switch transport {
        case "ws":
            let ws = stream?["wsSettings"]
            path = Self.text(ws?["path"])
            host = Self.text(ws?["host"] ?? ws?["headers"]?["Host"])
        case "grpc":
            let grpc = stream?["grpcSettings"]
            serviceName = Self.text(grpc?["serviceName"])
            authority = Self.text(grpc?["authority"])
            grpcMulti = grpc?["multiMode"]?.boolValue == true
        case "httpupgrade":
            let upgrade = stream?["httpupgradeSettings"]
            path = Self.text(upgrade?["path"])
            host = Self.text(upgrade?["host"])
        case "xhttp":
            let xhttp = stream?["xhttpSettings"] ?? stream?["splithttpSettings"]
            path = Self.text(xhttp?["path"])
            host = Self.text(xhttp?["host"])
            xhttpMode = Self.text(xhttp?["mode"])
            if let extra = xhttp?["extra"], let data = try? extra.data(pretty: true) {
                xhttpExtra = String(decoding: data, as: UTF8.self)
            }
        case "kcp":
            let kcp = stream?["kcpSettings"]
            headerType = Self.text(kcp?["header"]?["type"], default: "none")
            kcpSeed = Self.text(kcp?["seed"])
        default:
            let header = (stream?["rawSettings"] ?? stream?["tcpSettings"])?["header"]
            if header?["type"]?.stringValue == "http" {
                headerType = "http"
                path = Self.list(header?["request"]?["path"])
                host = Self.list(header?["request"]?["headers"]?["Host"])
            }
        }
    }

    private static func text(_ value: JSONValue?, default fallback: String = "") -> String {
        switch value {
        case .string(let s)?: s.isEmpty ? fallback : s
        case .number(let n)? where n == n.rounded(): String(Int(n))
        default: fallback
        }
    }

    /// An array (or a single value) as comma separated text.
    private static func list(_ value: JSONValue?) -> String {
        guard let items = value?.arrayValue else { return text(value) }
        return items.map { text($0) }.filter { !$0.isEmpty }.joined(separator: ",")
    }

    // MARK: Checking

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func string(_ s: String) -> JSONValue? {
        let t = trimmed(s)
        guard !t.isEmpty else { return Optional<JSONValue>.none }
        return .string(t)
    }

    private static func integer(_ s: String) -> JSONValue? {
        Int(trimmed(s)).map { .number(Double($0)) }
    }

    private static func strings(_ s: String) -> JSONValue? {
        let items = csv(s)
        guard !items.isEmpty else { return Optional<JSONValue>.none }
        return .array(items.map { .string($0) })
    }

    private var portNumber: Int? {
        guard let p = Int(Self.trimmed(port)), (1...65535).contains(p) else { return nil }
        return p
    }

    private var hysteriaPin: String {
        Self.trimmed(pinnedCert).lowercased().filter { $0 != ":" }
    }

    private var extraObject: JSONValue? {
        guard let parsed = try? JSONValue.parse(Data(Self.trimmed(xhttpExtra).utf8)), case .object = parsed else { return nil }
        return parsed
    }

    private var reservedBytes: [Int]? {
        let parts = csv(wgReserved)
        let numbers = parts.compactMap { Int($0) }
        guard parts.count == 3, numbers.count == 3, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return numbers
    }

    /// Empty when the draft can be saved.
    public func problems() -> [String] {
        var found: [String] = []
        func require(_ value: String, _ message: String) {
            if Self.trimmed(value).isEmpty { found.append(message) }
        }
        func number(_ value: String, _ message: String) {
            if !Self.trimmed(value).isEmpty, Int(Self.trimmed(value)) == nil { found.append(message) }
        }

        require(address, "Enter the server address.")
        if portNumber == nil { found.append("The port must be a number from 1 to 65535.") }

        switch proto {
        case .vless, .vmess:
            require(id, "Enter the user ID (UUID).")
        case .trojan:
            require(password, "Enter the password.")
        case .shadowsocks:
            require(method, "Choose the encryption method.")
            require(password, "Enter the password.")
        case .hysteria:
            let pin = hysteriaPin
            if !pin.isEmpty, pin.count != 64 || !pin.allSatisfy(\.isHexDigit) {
                found.append("The certificate pin must be a SHA-256 hash: 64 hexadecimal digits.")
            }
            if !csv(hopPorts).isEmpty, Int(Self.trimmed(hopInterval)) == nil {
                found.append("The port hopping interval must be a number of seconds.")
            }
        case .wireguard:
            require(wgSecretKey, "Enter the private key.")
            require(wgPublicKey, "Enter the server's public key.")
            if csv(wgAddresses).isEmpty { found.append("Enter at least one interface address.") }
            number(wgMTU, "The MTU must be a number.")
            number(wgKeepAlive, "Keep-alive must be a number of seconds.")
            if !csv(wgReserved).isEmpty, reservedBytes == nil {
                found.append("Reserved must be three numbers from 0 to 255, separated by commas.")
            }
        case .socks, .http:
            break
        }

        if proto.hasStream {
            if security == "reality" { require(realityPublicKey, "Enter the REALITY public key.") }
            if transport == "xhttp", !Self.trimmed(xhttpExtra).isEmpty, extraObject == nil {
                found.append("The XHTTP extra options must be a JSON object.")
            }
            if muxEnabled {
                if Int(Self.trimmed(muxConcurrency)) == nil { found.append("Mux connections must be a number.") }
                if Int(Self.trimmed(xudpConcurrency)) == nil { found.append("XUDP connections must be a number.") }
            }
        }
        return found
    }

    // MARK: Building the outbound

    /// Lays values over `base`: a key with a value is set, a key without one is removed, and
    /// keys that are not named stay as they were.
    private func overlay(_ base: JSONValue?, _ pairs: KeyValuePairs<String, JSONValue?>) -> JSONValue {
        var object = base?.objectValue ?? [:]
        for (key, value) in pairs {
            // A `nil` written in the list can arrive as JSON null, which no outbound here uses.
            if let value, value != JSONValue.null {
                object[key] = value
            } else {
                object.removeValue(forKey: key)
            }
        }
        return .object(object)
    }

    private func nonEmpty(_ value: JSONValue) -> JSONValue? {
        guard value.objectValue?.isEmpty == false else { return Optional<JSONValue>.none }
        return value
    }

    /// The Xray outbound, without a tag. Call `problems()` first: fields that fail there are
    /// written as they are.
    public func outbound() -> JSONValue {
        let none: JSONValue? = nil
        let base = base?["protocol"]?.stringValue?.lowercased() == proto.rawValue ? base : nil
        let old = base?["settings"]
        let address = JSONValue.string(Self.trimmed(address))
        let port = JSONValue.number(Double(portNumber ?? 0))
        var result = overlay(base, ["protocol": .string(proto.rawValue)])

        switch proto {
        case .vless:
            let encryption = Self.trimmed(encryption)
            result = result.setting("settings", to: overlay(old, [
                "vnext": none, "address": address, "port": port,
                "id": .string(Self.trimmed(id)),
                "encryption": .string(encryption.isEmpty ? "none" : encryption),
                "flow": Self.string(flow),
            ]))
        case .vmess:
            result = result.setting("settings", to: overlay(old, [
                "vnext": none, "address": address, "port": port,
                "id": .string(Self.trimmed(id)),
                "security": .string(Self.trimmed(vmessSecurity).isEmpty ? "auto" : Self.trimmed(vmessSecurity)),
            ]))
        case .trojan:
            result = result.setting("settings", to: overlay(old, [
                "servers": none, "address": address, "port": port, "password": .string(password),
            ]))
        case .shadowsocks:
            result = result.setting("settings", to: overlay(old, [
                "servers": none, "address": address, "port": port,
                "method": .string(Self.trimmed(method)), "password": .string(password),
            ]))
        case .socks, .http:
            let hasLogin = !username.isEmpty || !password.isEmpty
            result = result.setting("settings", to: overlay(old, [
                "servers": none, "address": address, "port": port,
                "user": hasLogin ? .string(username) : nil,
                "pass": hasLogin ? .string(password) : nil,
            ]))
        case .hysteria:
            result = result.setting("settings", to: overlay(old, ["version": 2, "address": address, "port": port]))
        case .wireguard:
            let host = Self.trimmed(self.address)
            let endpoint = host.contains(":") ? "[\(host)]:\(portNumber ?? 0)" : "\(host):\(portNumber ?? 0)"
            let addresses = csv(wgAddresses).map { entry -> String in
                if entry.contains("/") { return entry }
                return entry.contains(":") ? "\(entry)/128" : "\(entry)/32"
            }
            let allowed = csv(wgAllowedIPs)
            let peer = overlay(old?["peers"]?[0], [
                "publicKey": .string(Self.trimmed(wgPublicKey)),
                "preSharedKey": Self.string(wgPreSharedKey),
                "endpoint": .string(endpoint),
                "allowedIPs": .array((allowed.isEmpty ? ["0.0.0.0/0", "::/0"] : allowed).map { .string($0) }),
                "keepAlive": Self.integer(wgKeepAlive),
            ])
            result = result.setting("settings", to: overlay(old, [
                "secretKey": .string(Self.trimmed(wgSecretKey)),
                "address": .array(addresses.map { .string($0) }),
                "peers": [peer],
                "mtu": Self.integer(wgMTU),
                "reserved": reservedBytes.map { .array($0.map { .number(Double($0)) }) },
            ]))
        }

        let oldStream = base?["streamSettings"]
        switch proto {
        case .vless, .vmess, .trojan, .shadowsocks:
            result = overlay(result, ["streamSettings": streamSettings(oldStream), "mux": mux(base?["mux"])])
        case .hysteria:
            result = result.setting("streamSettings", to: hysteriaStream(oldStream))
        case .http:
            result = overlay(result, ["streamSettings": httpStream(oldStream)])
        case .socks, .wireguard:
            break
        }
        return result
    }

    private func mux(_ old: JSONValue?) -> JSONValue? {
        guard muxEnabled else { return Optional<JSONValue>.none }
        return overlay(old, [
            "enabled": true,
            "concurrency": Self.integer(muxConcurrency),
            "xudpConcurrency": Self.integer(xudpConcurrency),
            "xudpProxyUDP443": Self.string(xudpProxyUDP443),
        ])
    }

    private func tlsSettings(_ old: JSONValue?) -> JSONValue {
        let isHysteria = proto == .hysteria
        let pin = isHysteria ? hysteriaPin : Self.trimmed(pinnedCert)
        var alpn = Self.strings(alpn)
        if isHysteria, alpn == nil { alpn = ["h3"] }
        return overlay(old, [
            "serverName": Self.string(sni),
            "fingerprint": isHysteria ? old?["fingerprint"] : Self.string(fingerprint),
            "alpn": alpn,
            InsecureTLS.pin: pin.isEmpty ? nil : .string(pin),
            // A pinned certificate is accepted whoever issued it, so the flag adds nothing then.
            InsecureTLS.flag: allowInsecure && pin.isEmpty ? true : nil,
            "verifyPeerCertByName": isHysteria ? old?["verifyPeerCertByName"] : Self.string(verifyName),
            "echConfigList": isHysteria ? old?["echConfigList"] : Self.string(ech),
        ])
    }

    private func streamSettings(_ old: JSONValue?) -> JSONValue {
        let none: JSONValue? = nil
        let fingerprint = Self.trimmed(fingerprint)
        var stream = overlay(old, [
            "network": .string(transport),
            "security": security == "none" ? nil : .string(security),
            "tlsSettings": security == "tls" ? tlsSettings(old?["tlsSettings"]) : nil,
            "realitySettings": security == "reality" ? overlay(old?["realitySettings"], [
                "serverName": Self.string(sni),
                "fingerprint": .string(fingerprint.isEmpty ? "chrome" : fingerprint),
                "publicKey": .string(Self.trimmed(realityPublicKey)),
                "shortId": .string(Self.trimmed(realityShortID)),
                "spiderX": Self.string(realitySpiderX),
                "mldsa65Verify": Self.string(realityMldsa),
            ]) : nil,
            // Only the transport in use keeps its options; the two older names go for good.
            "rawSettings": none, "tcpSettings": none, "wsSettings": none, "grpcSettings": none,
            "httpupgradeSettings": none, "xhttpSettings": none, "splithttpSettings": none, "kcpSettings": none,
        ])

        switch transport {
        case "ws":
            stream = stream.setting("wsSettings", to: overlay(old?["wsSettings"], [
                "path": Self.string(path), "host": Self.string(host),
            ]))
        case "grpc":
            stream = stream.setting("grpcSettings", to: overlay(old?["grpcSettings"], [
                "serviceName": .string(Self.trimmed(serviceName)),
                "multiMode": grpcMulti ? true : nil,
                "authority": Self.string(authority),
            ]))
        case "httpupgrade":
            stream = stream.setting("httpupgradeSettings", to: overlay(old?["httpupgradeSettings"], [
                "path": Self.string(path), "host": Self.string(host),
            ]))
        case "xhttp":
            stream = stream.setting("xhttpSettings", to: overlay(old?["xhttpSettings"] ?? old?["splithttpSettings"], [
                "path": Self.string(path), "host": Self.string(host),
                "mode": Self.string(xhttpMode), "extra": extraObject,
            ]))
        case "kcp":
            stream = stream.setting("kcpSettings", to: overlay(old?["kcpSettings"], [
                "header": headerType == "none" || headerType.isEmpty ? nil : ["type": .string(headerType)],
                "seed": Self.string(kcpSeed),
            ]))
        default:
            let oldRaw = old?["rawSettings"] ?? old?["tcpSettings"]
            var header: JSONValue?
            if headerType == "http" {
                let oldRequest = oldRaw?["header"]?["request"]
                let paths = csv(path)
                let headers = overlay(oldRequest?["headers"], ["Host": Self.strings(host)])
                header = ["type": "http", "request": overlay(oldRequest, [
                    "version": oldRequest?["version"] ?? "1.1",
                    "method": oldRequest?["method"] ?? "GET",
                    "path": .array((paths.isEmpty ? ["/"] : paths).map { .string($0) }),
                    "headers": nonEmpty(headers),
                ])]
            }
            if let raw = nonEmpty(overlay(oldRaw, ["header": header])) {
                stream = stream.setting("rawSettings", to: raw)
            }
        }
        return stream
    }

    private func hysteriaStream(_ old: JSONValue?) -> JSONValue {
        let hops = csv(hopPorts)
        let udphop: JSONValue? = hops.isEmpty ? nil : overlay(old?["hysteriaSettings"]?["udphop"], [
            "port": .string(hops.joined(separator: ",")),
            "interval": Self.integer(hopInterval) ?? 30,
        ])
        let mask: JSONValue? = obfs
            ? ["udp": [["type": "salamander", "settings": ["password": .string(obfsPassword)]]]]
            : nil
        return overlay(old, [
            "network": "hysteria",
            "security": "tls",
            "tlsSettings": tlsSettings(old?["tlsSettings"]),
            "hysteriaSettings": overlay(old?["hysteriaSettings"], [
                "version": 2, "auth": .string(password), "udphop": udphop,
            ]),
            "finalmask": mask,
        ])
    }

    /// An HTTP proxy is reached in the clear or inside TLS; it has no other stream options.
    private func httpStream(_ old: JSONValue?) -> JSONValue? {
        guard security == "tls" else {
            let rest = overlay(old, ["security": nil, "tlsSettings": nil, "realitySettings": nil])
            guard rest.objectValue.map({ Set($0.keys) })?.isSubset(of: ["network"]) == false else {
                return Optional<JSONValue>.none
            }
            return rest
        }
        return overlay(old, [
            "network": "raw", "security": "tls",
            "tlsSettings": tlsSettings(old?["tlsSettings"]), "realitySettings": nil,
        ])
    }

    // MARK: Result

    /// The name as typed, or `host:port`.
    public var displayName: String {
        let typed = Self.trimmed(name)
        if !typed.isEmpty { return typed }
        let host = Self.trimmed(address)
        return host.contains(":") ? "[\(host)]:\(Self.trimmed(port))" : "\(host):\(Self.trimmed(port))"
    }

    /// The server as it is stored. Throws `DraftError` with what has to be filled in first.
    public func profile() throws -> ParsedProfile {
        let problems = problems()
        guard problems.isEmpty else { throw DraftError(problems) }
        let config = outbound()

        var warnings: [String] = []
        if config["streamSettings"]?["tlsSettings"]?[InsecureTLS.flag]?.boolValue == true {
            warnings.append(StreamBuilder.insecureWarning)
        }
        let encryption = Self.trimmed(encryption)
        if proto == .vless, security == "none", encryption.isEmpty || encryption == "none" {
            warnings.append("Xray refuses VLESS without TLS, REALITY or encryption; this server will fail to start")
        }

        let stream = config["streamSettings"]
        var profile = ParsedProfile(
            name: displayName,
            kind: .outbound,
            protocolName: proto.rawValue,
            address: Self.trimmed(address),
            port: portNumber ?? 0,
            transport: proto == .socks || proto == .wireguard ? "" : (stream?["network"]?.stringValue ?? ""),
            security: proto == .socks || proto == .wireguard ? "none" : (stream?["security"]?.stringValue ?? "none"),
            config: config,
            warnings: warnings
        )
        profile.originalLink = ShareLinkWriter.link(for: self, describing: config)
        return profile
    }
}
