import Foundation

/// Servers from other clients' configs (Clash / Mihomo YAML, sing-box JSON), turned into share
/// links so `ShareLinkParser` builds the outbound exactly as it would for a pasted link.
enum ForeignConfig {
    /// A Clash or Mihomo config: its `proxies` list.
    static func clashProxies(_ root: JSONValue) -> ([ParsedProfile], [SkippedEntry]) {
        convert(root["proxies"]?.arrayValue ?? [], link: clashLink)
    }

    /// A sing-box config: its proxy `outbounds`.
    static func singBoxOutbounds(_ root: JSONValue) -> ([ParsedProfile], [SkippedEntry]) {
        let local: Set<String> = ["direct", "block", "dns", "selector", "urltest"]
        return convert((root["outbounds"]?.arrayValue ?? []).filter { !local.contains($0["type"]?.stringValue ?? "") }, link: singBoxLink)
    }

    private static func convert(_ items: [JSONValue], link: (JSONValue) throws -> String) -> ([ParsedProfile], [SkippedEntry]) {
        var profiles: [ParsedProfile] = []
        var skipped: [SkippedEntry] = []
        for (i, item) in items.enumerated() {
            do {
                profiles.append(try ShareLinkParser.parse(try link(item)))
            } catch let skip as LinkSkip {
                skipped.append(SkippedEntry(index: i + 1, reason: skip.reason))
            } catch {
                skipped.append(SkippedEntry(index: i + 1, reason: error.localizedDescription))
            }
        }
        return (profiles, skipped)
    }

    // MARK: Clash

    static func clashLink(_ p: JSONValue) throws -> String {
        let type = text(p["type"]).lowercased()
        var q: [(String, String?)] = []
        let tls = p["tls"]?.boolValue == true
        let sni = text(p["servername"] ?? p["sni"])
        func stream() {
            let network = text(p["network"]).lowercased()
            q.append(("type", network.isEmpty ? "tcp" : network == "h2" ? "http" : network))
            switch network {
            case "ws":
                q.append(("path", text(p["ws-opts"]?["path"])))
                q.append(("host", text(p["ws-opts"]?["headers"]?["Host"] ?? p["ws-opts"]?["headers"]?["host"])))
            case "grpc":
                q.append(("serviceName", text(p["grpc-opts"]?["grpc-service-name"])))
            case "h2":
                q.append(("path", text(p["h2-opts"]?["path"])))
                q.append(("host", (p["h2-opts"]?["host"]?.arrayValue ?? []).map(text).joined(separator: ",")))
            case "xhttp":
                q.append(("path", text(p["xhttp-opts"]?["path"])))
                q.append(("host", text(p["xhttp-opts"]?["host"])))
                q.append(("mode", text(p["xhttp-opts"]?["mode"])))
            default: break
            }
            if let reality = p["reality-opts"] {
                q += [("security", "reality"), ("pbk", text(reality["public-key"])), ("sid", text(reality["short-id"]))]
            } else if tls || type == "trojan" {
                q.append(("security", "tls"))
            }
            q += [("sni", sni), ("fp", text(p["client-fingerprint"])),
                  ("alpn", (p["alpn"]?.arrayValue ?? []).map(text).joined(separator: ","))]
            if p["skip-cert-verify"]?.boolValue == true { q.append(("allowInsecure", "1")) }
        }
        let user: String
        let scheme: String
        switch type {
        case "vless":
            scheme = "vless"; user = text(p["uuid"])
            q += [("encryption", "none"), ("flow", text(p["flow"]))]
            stream()
        case "vmess":
            scheme = "vmess"; user = text(p["uuid"])
            q.append(("encryption", text(p["cipher"])))
            stream()
        case "trojan":
            scheme = "trojan"; user = text(p["password"])
            stream()
        case "ss":
            scheme = "ss"; user = Data("\(text(p["cipher"])):\(text(p["password"]))".utf8).base64EncodedString()
            if let plugin = p["plugin"]?.stringValue, let opts = p["plugin-opts"] {
                switch plugin {
                case "obfs":
                    q.append(("plugin", "obfs-local;obfs=\(text(opts["mode"]))" + optional("obfs-host", opts["host"])))
                case "v2ray-plugin", "xray-plugin":
                    q.append(("plugin", "v2ray-plugin;mode=\(text(opts["mode"]).isEmpty ? "websocket" : text(opts["mode"]))"
                              + optional("host", opts["host"]) + optional("path", opts["path"]) + (opts["tls"]?.boolValue == true ? ";tls" : "")))
                default:
                    throw LinkSkip(String(localized: "shadowsocks plugin \"\(plugin)\" is not supported"))
                }
            }
        case "hysteria2":
            scheme = "hysteria2"; user = text(p["password"])
            q += [("sni", sni), ("obfs", text(p["obfs"])), ("obfs-password", text(p["obfs-password"])), ("mport", text(p["ports"]))]
            if p["skip-cert-verify"]?.boolValue == true { q.append(("insecure", "1")) }
        case "socks5", "http":
            scheme = type == "http" ? (tls ? "https" : "http") : "socks"
            let name = text(p["username"])
            user = name.isEmpty ? "" : "\(name):\(text(p["password"]))"
        default:
            throw LinkSkip(String(localized: "\(type.isEmpty ? "unknown" : type) servers are not supported"))
        }
        return try build(scheme: scheme, user: user, host: text(p["server"]), port: text(p["port"]), query: q, name: text(p["name"]))
    }

    private static func optional(_ key: String, _ value: JSONValue?) -> String {
        let v = text(value)
        return v.isEmpty ? "" : ";\(key)=\(v)"
    }

    // MARK: sing-box

    static func singBoxLink(_ o: JSONValue) throws -> String {
        let type = text(o["type"]).lowercased()
        var q: [(String, String?)] = []
        let tls = o["tls"]
        func stream() {
            let transport = o["transport"]
            let network = text(transport?["type"]).lowercased()
            q.append(("type", network.isEmpty ? "tcp" : network))
            q += [("path", text(transport?["path"])), ("serviceName", text(transport?["service_name"])),
                  ("host", text(transport?["headers"]?["Host"] ?? transport?["host"]?[0] ?? transport?["host"]))]
            if let reality = tls?["reality"], reality["enabled"]?.boolValue == true {
                q += [("security", "reality"), ("pbk", text(reality["public_key"])), ("sid", text(reality["short_id"]))]
            } else if tls?["enabled"]?.boolValue == true {
                q.append(("security", "tls"))
            }
            q += [("sni", text(tls?["server_name"])), ("fp", text(tls?["utls"]?["fingerprint"])),
                  ("alpn", (tls?["alpn"]?.arrayValue ?? []).map(text).joined(separator: ","))]
            if tls?["insecure"]?.boolValue == true { q.append(("allowInsecure", "1")) }
        }
        let scheme: String, user: String
        switch type {
        case "vless":
            scheme = "vless"; user = text(o["uuid"])
            q += [("encryption", "none"), ("flow", text(o["flow"]))]
            stream()
        case "vmess":
            scheme = "vmess"; user = text(o["uuid"])
            q.append(("encryption", text(o["security"])))
            stream()
        case "trojan":
            scheme = "trojan"; user = text(o["password"])
            stream()
        case "shadowsocks":
            scheme = "ss"; user = Data("\(text(o["method"])):\(text(o["password"]))".utf8).base64EncodedString()
        case "hysteria2":
            scheme = "hysteria2"; user = text(o["password"])
            q += [("sni", text(tls?["server_name"])), ("obfs", text(o["obfs"]?["type"])), ("obfs-password", text(o["obfs"]?["password"]))]
            if tls?["insecure"]?.boolValue == true { q.append(("insecure", "1")) }
        case "socks", "http":
            scheme = type
            let name = text(o["username"])
            user = name.isEmpty ? "" : "\(name):\(text(o["password"]))"
        default:
            throw LinkSkip(String(localized: "\(type.isEmpty ? "unknown" : type) servers are not supported"))
        }
        return try build(scheme: scheme, user: user, host: text(o["server"]), port: text(o["server_port"]), query: q, name: text(o["tag"]))
    }

    // MARK: Shared

    /// A YAML or JSON scalar as text: YAML reads `443` and an all-digit password as numbers.
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        default: ""
        }
    }

    private static func build(scheme: String, user: String, host: String, port: String, query: [(String, String?)], name: String) throws -> String {
        guard !host.isEmpty, !port.isEmpty else { throw LinkSkip(String(localized: "invalid or missing port")) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let pairs = query.compactMap { key, value in value.flatMap { $0.isEmpty ? nil : "\(key)=\(esc($0))" } }
        let authority = host.contains(":") ? "[\(host)]" : host
        let userinfo = user.isEmpty ? "" : (scheme == "socks" || scheme == "http" || scheme == "https"
            ? user.split(separator: ":", maxSplits: 1).map { esc(String($0)) }.joined(separator: ":") : esc(user)) + "@"
        return "\(scheme)://\(userinfo)\(authority):\(port)" + (pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")) + "#" + esc(name)
    }
}
