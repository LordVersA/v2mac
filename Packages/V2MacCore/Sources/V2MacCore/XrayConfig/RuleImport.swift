import Foundation

/// Routing rules from another client, read as V2Mac rules (spec 8.6): V2Mac's own export, Proxifier
/// (`.ppx`), Clash / Mihomo YAML, sing-box JSON, Xray / v2rayN / v2rayNG rule JSON and Shadowrocket /
/// Surge `.conf`. Rules keep their order; neighbouring lines with the same route become one rule.
/// Ports, networks and sniffed protocols become "Only when" conditions; anything else that narrows a
/// rule (`invert`, `OR`, `NOT`, an address and a domain that must both match) skips it.
public struct RuleImport: Sendable, Equatable {
    public enum Format: String, Sendable {
        case v2mac = "V2Mac", proxifier = "Proxifier", clash = "Clash", singBox = "sing-box", xray = "v2rayN / Xray", surge = "Shadowrocket / Surge"
    }

    public var format: Format
    public var rules: [Rule] = []
    /// Rules left out, as written in the file.
    public var skipped: [String] = []
    public var blockQUIC = false

    public init(data: Data) throws {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FEFF}"]))
        if let own = Rule.decode(text) {
            format = .v2mac
            rules = own
        } else if text.hasPrefix("<") {
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

    static let hostTypes: Set<String> = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "IP-CIDR", "IP-CIDR6", "GEOIP", "GEOSITE"]

    /// Clash and Surge share one line form: `TYPE,value,POLICY[,options]`, and
    /// `AND,((TYPE,value),(TYPE,value)),POLICY`.
    private mutating func lines(_ lines: [String]) {
        for line in lines where !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("//") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let type = fields[0].uppercased()
            // The fallback belongs to the routing mode and "Everything else".
            if type == "MATCH" || type == "FINAL" { continue }
            if type == "AND" { and(line); continue }
            guard fields.count >= 3, !fields[1].isEmpty else { skipped.append(line); continue }
            var rule = Rule(name: fields[2], action: Self.action(policy: fields[2]))
            guard Self.condition(type, fields[1], into: &rule) else { skipped.append(line); continue }
            append(rule)
        }
    }

    /// `AND` with conditions V2Mac has: at most one host or app condition, plus ports and a network.
    private mutating func and(_ line: String) {
        guard let close = line.lastIndex(of: ")"), let comma = line[close...].firstIndex(of: ",") else { skipped.append(line); return }
        let policy = line[line.index(after: comma)...].split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let parts = line[..<close].matches(of: /\(([^()]+)\)/).map { String($0.output.1) }
        var rule = Rule(name: policy, action: Self.action(policy: policy))
        let matchers = parts.filter { Self.hostTypes.contains($0.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).uppercased() } ?? "") }
        guard !policy.isEmpty, !parts.isEmpty, matchers.count <= 1 else { skipped.append(line); return }
        for part in parts {
            let f = part.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count == 2, Self.condition(f[0].uppercased(), f[1], into: &rule, inAnd: true) else { skipped.append(line); return }
        }
        append(rule)
    }

    /// Adds one Clash condition to `rule`; false when V2Mac has no such condition.
    private static func condition(_ type: String, _ value: String, into rule: inout Rule, inAnd: Bool = false) -> Bool {
        switch type {
        case "PROCESS-NAME", "PROCESS-PATH":
            // Inside AND an app narrows the other conditions; alone it is the rule's item.
            if !inAnd { rule.items = [.app(value)] } else if rule.only.apps.isEmpty { rule.only.apps = [value] } else { return false }
        case _ where hostTypes.contains(type):
            let m = RuleMatchers(parsing: "\(type),\(value)")
            guard m.invalid.isEmpty else { return false }
            let entries = m.domains + m.ips
            guard !entries.isEmpty else { return false }
            rule.items += entries.map(Rule.Item.host)
        case "DST-PORT":
            let ports = value.replacingOccurrences(of: "/", with: ",")
            guard Rule.OnlyWhen.validPorts(ports), rule.only.ports.isEmpty else { return false }
            rule.only.ports = ports
        case "NETWORK":
            guard let network = Rule.Network(rawValue: value.lowercased()), rule.only.network == nil else { return false }
            rule.only.network = network
        default:
            return false
        }
        return true
    }

    private mutating func singBox(_ root: JSONValue) {
        var routes: [String: Rule.Action] = [:]
        for outbound in root["outbounds"]?.arrayValue ?? [] {
            let type = outbound["type"]?.stringValue ?? ""
            routes[outbound["tag"]?.stringValue ?? ""] = type == "direct" ? .direct : type == "block" ? .block : .proxy
        }
        for rule in root["route"]?["rules"]?.arrayValue ?? [] {
            let action: Rule.Action?
            switch rule["action"]?.stringValue ?? "route" {
            case "route": action = routes[rule["outbound"]?.stringValue ?? ""]
            case "reject": action = .block
            default: action = nil
            }
            func list(_ key: String) -> [String] {
                let values = rule[key]?.arrayValue ?? rule[key].map { [$0] } ?? []
                return values.compactMap { $0.stringValue ?? $0.intValue.map(String.init) }
            }
            let hosts = list("domain").map { "full:" + $0 } + list("domain_suffix").map { "domain:" + $0.trimmingPrefix(".") }
                + list("domain_keyword").map { "keyword:" + $0 } + list("domain_regex").map { "regexp:" + $0 }
                + list("ip_cidr") + list("geosite").map { "geosite:" + $0 } + list("geoip").map { "geoip:" + $0 }
            let apps = list("process_name") + list("process_path")
            let name = rule["outbound"]?.stringValue ?? rule["action"]?.stringValue ?? ""
            let only = Self.only(ports: list("port") + list("port_range").map { $0.replacingOccurrences(of: ":", with: "-") },
                                 networks: list("network"), protocols: list("protocol"))
            guard let action, let only, !hosts.isEmpty || !apps.isEmpty, !Self.narrows(rule, beyond: Self.singBoxKeys) else {
                // DNS hijacks, sniffing and rule sets have no V2Mac counterpart.
                if rule["outbound"]?.stringValue != "dns-out", rule["protocol"]?.stringValue != "dns" { skipped.append(Self.describe(rule)) }
                continue
            }
            rules.append(Self.rule(name: name, action: action, apps: apps, hosts: hosts, only: only))
        }
    }

    private mutating func xray(_ list: JSONValue) {
        for rule in list.arrayValue ?? [] {
            func strings(_ key: String) -> [String] { rule[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
            let hosts = strings("domain") + strings("ip")
            let apps = strings("process")
            let tag = rule["outboundTag"]?.stringValue ?? ""
            let ports = rule["port"]?.stringValue ?? rule["port"]?.intValue.map(String.init) ?? ""
            let only = Self.only(ports: ports.isEmpty ? [] : [ports], networks: (rule["network"]?.stringValue ?? "").split(separator: ",").map(String.init),
                                 protocols: strings("protocol"))
            // Xray needs both a domain and an address to match; V2Mac would take either.
            guard !tag.isEmpty, let only, !hosts.isEmpty || !apps.isEmpty || !only.isEmpty, strings("domain").isEmpty || strings("ip").isEmpty,
                  !Self.narrows(rule, beyond: Self.xrayKeys) else { skipped.append(rule["remarks"]?.stringValue ?? Self.describe(rule)); continue }
            let action: Rule.Action = switch tag.lowercased() {
            case "direct": .direct
            case "block", "blackhole", "reject": .block
            default: .proxy
            }
            var made = Self.rule(name: rule["remarks"]?.stringValue ?? tag, action: action, apps: apps, hosts: hosts, only: only)
            made.enabled = rule["enabled"]?.boolValue ?? true
            rules.append(made)
        }
    }

    /// Hosts are items and apps narrow them, as in a migrated rule; apps alone are items.
    static func rule(name: String, action: Rule.Action, apps: [String], hosts: [String], only: Rule.OnlyWhen) -> Rule {
        let m = RuleMatchers(parsing: hosts.joined(separator: "\n"))
        let items = (m.domains + m.ips + m.invalid).map(Rule.Item.host)
        var only = only
        if !items.isEmpty { only.apps = apps }
        return Rule(name: name, action: action, items: items.isEmpty ? apps.map(Rule.Item.app) : items, only: only)
    }

    /// nil when a value has no V2Mac counterpart: a protocol the core does not sniff, a bad port.
    static func only(ports: [String], networks: [String], protocols: [String]) -> Rule.OnlyWhen? {
        var only = Rule.OnlyWhen()
        let networks = Set(networks.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        if networks.count == 1 {
            guard let network = Rule.Network(rawValue: networks.first!) else { return nil }
            only.network = network
        } else if !networks.isSubset(of: ["tcp", "udp"]) { return nil }
        let sniffed = protocols.map { Rule.Sniffed(rawValue: $0.lowercased()) }
        guard !sniffed.contains(nil) else { return nil }
        only.protocols = sniffed.compactMap { $0 }
        let portList = ports.joined(separator: ",").replacingOccurrences(of: " ", with: "")
        guard portList.isEmpty || Rule.OnlyWhen.validPorts(portList) else { return nil }
        only.ports = portList
        return only
    }

    /// Adds to the last rule when it has the same route, kind and conditions, so a long list stays readable.
    private mutating func append(_ rule: Rule) {
        if let last = rules.last, last.action == rule.action, last.name == rule.name, last.only == rule.only, !rule.items.isEmpty,
           last.appItems.isEmpty == rule.appItems.isEmpty, last.hostItems.isEmpty == rule.hostItems.isEmpty {
            rules[rules.count - 1].items += rule.items
        } else {
            rules.append(rule)
        }
    }

    private static let singBoxKeys: Set<String> = ["domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "geosite", "geoip",
                                                   "process_name", "process_path", "outbound", "action", "port", "port_range", "network", "protocol"]
    private static let xrayKeys: Set<String> = ["domain", "ip", "process", "outboundTag", "remarks", "enabled", "type", "id", "locked", "ruleTag",
                                                "port", "network", "protocol"]

    /// A condition V2Mac cannot express (`invert`, a source address, …): importing the rule
    /// without it would send more traffic its way than the file meant, so it is skipped.
    static func narrows(_ rule: JSONValue, beyond known: Set<String>) -> Bool {
        (rule.objectValue ?? [:]).contains { key, value in
            guard !known.contains(key) else { return false }
            switch value {
            case .null, .bool(false): return false
            case .string(let s): return !s.isEmpty
            case .array(let a): return !a.isEmpty
            default: return true
            }
        }
    }

    static func action(policy: String) -> Rule.Action {
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
