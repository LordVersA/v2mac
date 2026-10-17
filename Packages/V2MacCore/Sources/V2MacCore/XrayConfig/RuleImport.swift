import Foundation

/// Routing rules from another client, read as V2Mac rules (spec 8.6): Proxifier (`.ppx`),
/// Clash / Mihomo YAML, sing-box JSON, Xray / v2rayN / v2rayNG rule JSON and Shadowrocket / Surge
/// `.conf`. Rules keep their order; neighbouring lines with the same route become one rule.
public struct RuleImport: Sendable, Equatable {
    public enum Format: String, Sendable { case proxifier = "Proxifier", clash = "Clash", singBox = "sing-box", xray = "v2rayN / Xray", surge = "Shadowrocket / Surge" }

    public var format: Format
    public var rules: [CustomRule] = []
    /// Rules left out, as written in the file.
    public var skipped: [String] = []
    public var blockQUIC = false

    public init(data: Data) throws {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FEFF}"]))
        if text.hasPrefix("<") {
            let profile = try ProxifierProfile(data: data)
            format = .proxifier
            rules = profile.rules
            skipped = profile.skipped
            blockQUIC = profile.blockQUIC
        } else if let json = try? JSONValue.parse(Data(text.utf8)) {
            if json["route"] != nil {
                format = .singBox
                singBox(json)
            } else {
                format = .xray
                xray(json["routing"]?["rules"] ?? json["rules"] ?? json)
            }
        } else if text.split(separator: "\n").contains(where: { $0.hasPrefix("rules:") }) {
            format = .clash
            let root = MiniYAML.parse(text)
            lines((root["rules"]?.arrayValue ?? []).map(ForeignConfig.text))
        } else {
            format = .surge
            var section = ""
            var ruleLines: [String] = []
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { section = line.lowercased(); continue }
                if section.isEmpty || section == "[rule]" { ruleLines.append(line) }
            }
            lines(ruleLines)
        }
        guard !rules.isEmpty || blockQUIC else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// Clash and Surge share one line form: `TYPE,value,POLICY[,options]`.
    private mutating func lines(_ lines: [String]) {
        for line in lines where !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("//") {
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let type = fields[0].uppercased()
            // The fallback belongs to the routing mode and "Unmatched traffic" setting.
            if type == "MATCH" || type == "FINAL" { continue }
            guard fields.count >= 3 else { skipped.append(line); continue }
            let action = Self.action(policy: fields[2])
            switch type {
            case "PROCESS-NAME", "PROCESS-PATH":
                append(action, name: fields[2], apps: fields[1])
            case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "IP-CIDR", "IP-CIDR6", "GEOIP", "GEOSITE":
                append(action, name: fields[2], hosts: "\(fields[0]),\(fields[1])")
            default:
                skipped.append(line)
            }
        }
    }

    private mutating func singBox(_ root: JSONValue) {
        var routes: [String: CustomRule.Action] = [:]
        for outbound in root["outbounds"]?.arrayValue ?? [] {
            let type = outbound["type"]?.stringValue ?? ""
            routes[outbound["tag"]?.stringValue ?? ""] = type == "direct" ? .direct : type == "block" ? .block : .proxy
        }
        for rule in root["route"]?["rules"]?.arrayValue ?? [] {
            let action: CustomRule.Action?
            switch rule["action"]?.stringValue ?? "route" {
            case "route": action = routes[rule["outbound"]?.stringValue ?? ""]
            case "reject": action = .block
            default: action = nil
            }
            func list(_ key: String) -> [String] { rule[key]?.arrayValue?.compactMap(\.stringValue) ?? rule[key]?.stringValue.map { [$0] } ?? [] }
            let hosts = list("domain").map { "full:" + $0 } + list("domain_suffix").map { "domain:" + $0.trimmingPrefix(".") }
                + list("domain_keyword").map { "keyword:" + $0 } + list("domain_regex").map { "regexp:" + $0 }
                + list("ip_cidr") + list("geosite").map { "geosite:" + $0 } + list("geoip").map { "geoip:" + $0 }
            let apps = list("process_name") + list("process_path")
            let name = rule["outbound"]?.stringValue ?? rule["action"]?.stringValue ?? ""
            guard let action, !hosts.isEmpty || !apps.isEmpty else {
                // DNS hijacks, sniffing and rule sets have no V2Mac counterpart.
                if rule["outbound"]?.stringValue != "dns-out", rule["protocol"]?.stringValue != "dns" { skipped.append(Self.describe(rule)) }
                continue
            }
            rules.append(CustomRule(name: name, action: action, apps: apps.joined(separator: "\n"), hosts: hosts.joined(separator: "\n")))
        }
    }

    private mutating func xray(_ list: JSONValue) {
        for rule in list.arrayValue ?? [] {
            func strings(_ key: String) -> [String] { rule[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
            let hosts = strings("domain") + strings("ip")
            let apps = strings("process")
            let tag = rule["outboundTag"]?.stringValue ?? ""
            guard !tag.isEmpty, !hosts.isEmpty || !apps.isEmpty else { skipped.append(rule["remarks"]?.stringValue ?? Self.describe(rule)); continue }
            let action: CustomRule.Action = switch tag.lowercased() {
            case "direct": .direct
            case "block", "blackhole", "reject": .block
            default: .proxy
            }
            rules.append(CustomRule(name: rule["remarks"]?.stringValue ?? tag, action: action, apps: apps.joined(separator: "\n"),
                                    hosts: hosts.joined(separator: "\n"), enabled: rule["enabled"]?.boolValue ?? true))
        }
    }

    /// Adds to the last rule when it has the same route and kind, so a long list stays readable.
    private mutating func append(_ action: CustomRule.Action, name: String, apps: String = "", hosts: String = "") {
        if let last = rules.last, last.action == action, last.name == name, last.apps.isEmpty == apps.isEmpty, last.hosts.isEmpty == hosts.isEmpty {
            if !apps.isEmpty { rules[rules.count - 1].apps += "\n" + apps }
            if !hosts.isEmpty { rules[rules.count - 1].hosts += "\n" + hosts }
        } else {
            rules.append(CustomRule(name: name, action: action, apps: apps, hosts: hosts))
        }
    }

    static func action(policy: String) -> CustomRule.Action {
        switch policy.uppercased() {
        case "DIRECT": .direct
        case "REJECT", "REJECT-DROP", "REJECT-TINY", "REJECT-NO-DROP": .block
        // Any other name is a proxy group: with one server, that is the proxy.
        default: .proxy
        }
    }

    private static func describe(_ rule: JSONValue) -> String {
        (try? rule.data()).map { String(decoding: $0, as: UTF8.self) }.map { $0.count > 80 ? $0.prefix(80) + "…" : $0 } ?? ""
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self }
}
