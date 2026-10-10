import Foundation

/// Transport and security parameters shared by every link scheme.
struct StreamParams: Sendable {
    var network = ""
    var security = ""
    var sni, fp, alpn, pbk, sid, spx, pqv, ech, pcs, vcn: String?
    var path, host, serviceName, mode, headerType, seed, extra, authority: String?
    var insecure = false

    init() {}

    init(query q: LinkQuery) {
        network = q["type"] ?? ""
        security = q["security"] ?? ""
        sni = q["sni"] ?? q["peer"]
        fp = q["fp"]
        alpn = q["alpn"]
        pbk = q["pbk"]
        sid = q["sid"]
        spx = q["spx"]
        pqv = q["pqv"]
        ech = q["ech"]
        pcs = q["pcs"]
        vcn = q["vcn"]
        path = q["path"]
        host = q["host"]
        serviceName = q["servicename"]
        mode = q["mode"]
        headerType = q["headertype"]
        seed = q["seed"]
        extra = q["extra"]
        authority = q["authority"]
        insecure = q.flag("allowinsecure", "insecure")
    }
}

struct StreamResult: Sendable {
    var json: JSONValue
    var transport: String
    var security: String
    var warnings: [String]
}

enum StreamBuilder {
    static let insecureWarning =
        "The link asks to skip the certificate check (allowInsecure). This server connects only while \"Allow insecure servers\" is on in Settings → Connection, unless its certificate is valid"

    static func build(_ p: StreamParams, defaultSecurity: String) throws -> StreamResult {
        var warnings: [String] = []
        let transport = try canonicalTransport(p.network)
        let security = try canonicalSecurity(p.security, default: defaultSecurity)

        var stream: [String: JSONValue] = ["network": .string(transport)]

        switch security {
        case "tls":
            stream["security"] = "tls"
            stream["tlsSettings"] = tlsSettings(p, transport: transport)
        case "reality":
            guard let pbk = p.pbk else { throw LinkSkip("REALITY link has no public key (pbk)") }
            stream["security"] = "reality"
            stream["realitySettings"] = compact([
                "serverName": p.sni.map { .string($0) },
                "fingerprint": .string(p.fp ?? "chrome"),
                "publicKey": .string(pbk),
                "shortId": .string(p.sid ?? ""),
                "spiderX": p.spx.map { .string($0) },
                "mldsa65Verify": p.pqv.map { .string($0) },
            ])
        default:
            break
        }
        if p.insecure, p.pcs == nil { warnings.append(insecureWarning) }

        switch transport {
        case "raw":
            if p.headerType?.lowercased() == "http" {
                let hosts = csv(p.host)
                let request = compact([
                    "version": "1.1",
                    "method": "GET",
                    "path": .array(csv(p.path ?? "/").map { .string($0) }),
                    "headers": hosts.isEmpty ? nil : .object(["Host": .array(hosts.map { .string($0) })]),
                ])
                stream["rawSettings"] = ["header": ["type": "http", "request": request]]
            }
        case "ws":
            stream["wsSettings"] = compact([
                "path": p.path.map { .string($0) },
                "host": p.host.map { .string($0) },
            ])
        case "grpc":
            stream["grpcSettings"] = compact([
                "serviceName": .string(p.serviceName ?? p.path ?? ""),
                "multiMode": p.mode?.lowercased() == "multi" ? true : nil,
                "authority": p.authority.map { .string($0) },
            ])
        case "httpupgrade":
            stream["httpupgradeSettings"] = compact([
                "path": p.path.map { .string($0) },
                "host": p.host.map { .string($0) },
            ])
        case "xhttp":
            var extra: JSONValue?
            if let text = p.extra {
                if let parsed = try? JSONValue.parse(Data(text.utf8)), case .object = parsed {
                    extra = parsed
                } else {
                    warnings.append("Ignored an invalid xhttp \"extra\" value")
                }
            }
            stream["xhttpSettings"] = compact([
                "path": p.path.map { .string($0) },
                "host": p.host.map { .string($0) },
                "mode": p.mode.map { .string($0) },
                "extra": extra,
            ])
        case "kcp":
            let header = p.headerType?.lowercased()
            stream["kcpSettings"] = compact([
                "header": (header == nil || header == "none") ? nil : ["type": .string(header ?? "")],
                "seed": p.seed.map { .string($0) },
            ])
        default:
            break
        }

        return StreamResult(json: .object(stream), transport: transport, security: security, warnings: warnings)
    }

    static func canonicalTransport(_ raw: String) throws -> String {
        switch raw.lowercased() {
        case "", "tcp", "raw": return "raw"
        case "kcp", "mkcp": return "kcp"
        case "ws", "websocket": return "ws"
        case "grpc", "gun": return "grpc"
        case "httpupgrade": return "httpupgrade"
        case "xhttp", "splithttp": return "xhttp"
        case "h2", "http", "quic": throw LinkSkip("transport removed from Xray")
        default: throw LinkSkip("unsupported transport \"\(raw)\"")
        }
    }

    static func canonicalSecurity(_ raw: String, default fallback: String) throws -> String {
        switch raw.lowercased() {
        case "": return fallback
        case "none": return "none"
        case "tls", "xtls": return "tls"
        case "reality": return "reality"
        default: throw LinkSkip("unsupported security \"\(raw)\"")
        }
    }

    private static func tlsSettings(_ p: StreamParams, transport: String) -> JSONValue {
        var serverName = p.sni
        if serverName == nil, ["ws", "httpupgrade", "xhttp"].contains(transport), let h = p.host, !isIPAddress(h) {
            serverName = csv(h).first
        }
        let alpn = csv(p.alpn)
        return compact([
            "serverName": serverName.map { .string($0) },
            "fingerprint": p.fp.map { .string($0) },
            "alpn": alpn.isEmpty ? nil : .array(alpn.map { .string($0) }),
            "pinnedPeerCertSha256": p.pcs.map { .string($0) },
            // Kept for `InsecureTLS`; it is removed before the core sees the outbound.
            InsecureTLS.flag: p.insecure && p.pcs == nil ? true : nil,
            "verifyPeerCertByName": p.vcn.map { .string($0) },
            "echConfigList": p.ech.map { .string($0) },
        ])
    }
}
