import Foundation

/// Writes the share link of a server made or changed in the editor, so that it can be copied
/// and shown as a QR code like one that came from a link.
enum ShareLinkWriter {
    /// Nil when a link cannot say what `config` says: read back by `ShareLinkParser` it has to
    /// give the same outbound. Mux is left out of that comparison, since no link carries it.
    static func link(for draft: ServerDraft, describing config: JSONValue) -> String? {
        guard let link = link(for: draft), let parsed = try? ShareLinkParser.parse(link) else { return nil }
        let same = ParsedProfile.fingerprint(kind: .outbound, config: parsed.config.removing("mux"))
            == ParsedProfile.fingerprint(kind: .outbound, config: config.removing("mux"))
        // The parser compares without the `allowInsecure` marker; the link must carry that too.
        return same && InsecureTLS.isRequested(by: parsed.config) == InsecureTLS.isRequested(by: config) ? link : nil
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func base64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    private static func authority(_ d: ServerDraft, port: String? = nil) -> String {
        let host = trimmed(d.address)
        return (host.contains(":") ? "[\(host)]" : host) + ":" + (port ?? trimmed(d.port))
    }

    private static func fragment(_ d: ServerDraft) -> String {
        let name = trimmed(d.name)
        return name.isEmpty ? "" : "#" + encoded(name)
    }

    private static func query(_ pairs: KeyValuePairs<String, String>) -> String {
        let parts = pairs.filter { !trimmed($0.value).isEmpty }.map { "\($0.key)=\(encoded(trimmed($0.value)))" }
        return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
    }

    /// Transport and security as the query parameters `StreamParams` reads.
    private static func streamPairs(_ d: ServerDraft, security: Bool = true) -> [(String, String)] {
        var pairs: [(String, String)] = [("type", d.transport == "raw" ? "tcp" : d.transport)]
        switch d.transport {
        case "ws", "httpupgrade":
            pairs += [("path", d.path), ("host", d.host)]
        case "grpc":
            pairs += [("serviceName", d.serviceName), ("mode", d.grpcMulti ? "multi" : ""), ("authority", d.authority)]
        case "xhttp":
            var extra = ""
            if let object = try? JSONValue.parse(Data(trimmed(d.xhttpExtra).utf8)), let data = try? object.data() {
                extra = String(decoding: data, as: UTF8.self)
            }
            pairs += [("path", d.path), ("host", d.host), ("mode", d.xhttpMode), ("extra", extra)]
        case "kcp":
            pairs += [("headerType", d.headerType == "none" ? "" : d.headerType), ("seed", d.kcpSeed)]
        default:
            if d.headerType == "http" { pairs += [("headerType", "http"), ("path", d.path), ("host", d.host)] }
        }
        guard security else { return pairs }
        pairs.append(("security", d.security))
        switch d.security {
        case "tls":
            pairs += [
                ("sni", d.sni), ("fp", d.fingerprint), ("alpn", d.alpn), ("pcs", d.pinnedCert),
                ("vcn", d.verifyName), ("ech", d.ech),
                ("allowInsecure", d.allowInsecure && trimmed(d.pinnedCert).isEmpty ? "1" : ""),
            ]
        case "reality":
            pairs += [
                ("sni", d.sni), ("fp", d.fingerprint), ("pbk", d.realityPublicKey), ("sid", d.realityShortID),
                ("spx", d.realitySpiderX), ("pqv", d.realityMldsa),
            ]
        default:
            break
        }
        return pairs
    }

    private static func query(_ pairs: [(String, String)]) -> String {
        let parts = pairs.filter { !trimmed($0.1).isEmpty }.map { "\($0.0)=\(encoded(trimmed($0.1)))" }
        return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
    }

    private static func link(for d: ServerDraft) -> String? {
        switch d.proto {
        case .vless:
            let pairs = [("encryption", trimmed(d.encryption).isEmpty ? "none" : d.encryption), ("flow", d.flow)] + streamPairs(d)
            return "vless://\(encoded(trimmed(d.id)))@\(authority(d))\(query(pairs))\(fragment(d))"
        case .vmess:
            return vmess(d)
        case .trojan:
            return "trojan://\(encoded(d.password))@\(authority(d))\(query(streamPairs(d)))\(fragment(d))"
        case .shadowsocks:
            let login = base64("\(trimmed(d.method)):\(d.password)")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let plain = d.transport == "raw" && d.headerType != "http" && d.security == "none"
            return "ss://\(login)@\(authority(d))\(plain ? "" : query(streamPairs(d)))\(fragment(d))"
        case .hysteria:
            let pin = trimmed(d.pinnedCert)
            return "hysteria2://\(encoded(d.password))@\(authority(d))" + query([
                "sni": d.sni,
                "alpn": trimmed(d.alpn) == "h3" ? "" : d.alpn,
                "pinSHA256": pin,
                "insecure": d.allowInsecure && pin.isEmpty ? "1" : "",
                "obfs": d.obfs ? "salamander" : "",
                "obfs-password": d.obfs ? d.obfsPassword : "",
                "mport": csv(d.hopPorts).joined(separator: ","),
            ]) + fragment(d)
        case .socks:
            let login = d.username.isEmpty && d.password.isEmpty ? "" : base64("\(d.username):\(d.password)") + "@"
            return "socks://\(login)\(authority(d))\(fragment(d))"
        case .http:
            let login = d.username.isEmpty && d.password.isEmpty ? "" : "\(encoded(d.username)):\(encoded(d.password))@"
            return "\(d.security == "tls" ? "https" : "http")://\(login)\(authority(d))\(fragment(d))"
        case .wireguard:
            return "wireguard://\(encoded(trimmed(d.wgSecretKey)))@\(authority(d))" + query([
                "publickey": d.wgPublicKey,
                "presharedkey": d.wgPreSharedKey,
                "address": csv(d.wgAddresses).joined(separator: ","),
                "allowedips": csv(d.wgAllowedIPs).joined(separator: ","),
                "mtu": d.wgMTU,
                "reserved": csv(d.wgReserved).joined(separator: ","),
            ]) + fragment(d)
        }
    }

    /// The v2rayN form, which every client reads, when it can hold the server; the URL form
    /// (with the same parameters as VLESS) for REALITY and the newer TLS options.
    private static func vmess(_ d: ServerDraft) -> String {
        let extras = [d.pinnedCert, d.verifyName, d.ech, d.authority, d.xhttpExtra].contains { !trimmed($0).isEmpty }
        guard d.security != "reality", !d.allowInsecure, !extras else {
            let pairs = [("encryption", d.vmessSecurity)] + streamPairs(d)
            return "vmess://\(encoded(trimmed(d.id)))@\(authority(d))\(query(pairs))\(fragment(d))"
        }
        var type = "none", path = trimmed(d.path), net = d.transport
        switch d.transport {
        case "grpc":
            type = d.grpcMulti ? "multi" : "gun"
            path = trimmed(d.serviceName)
        case "kcp":
            type = d.headerType
            path = trimmed(d.kcpSeed)
        case "xhttp":
            type = trimmed(d.xhttpMode).isEmpty ? "none" : d.xhttpMode
        case "raw":
            net = "tcp"
            type = d.headerType
        default:
            break
        }
        let fields: JSONValue = [
            "v": "2", "ps": .string(d.displayName), "add": .string(trimmed(d.address)), "port": .string(trimmed(d.port)),
            "id": .string(trimmed(d.id)), "aid": "0", "scy": .string(d.vmessSecurity), "net": .string(net),
            "type": .string(type), "host": .string(trimmed(d.host)), "path": .string(path),
            "tls": d.security == "tls" ? "tls" : "", "sni": .string(trimmed(d.sni)),
            "alpn": .string(trimmed(d.alpn)), "fp": .string(trimmed(d.fingerprint)),
        ]
        let json = (try? fields.data()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "vmess://" + base64(json)
    }
}
