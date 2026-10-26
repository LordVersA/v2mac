import Foundation

/// One of the user's routing rules, version 2 (spec 8.6). Rules are checked top to bottom, before the
/// mode's own rules, and the first match wins. Any item matching fires the rule (OR); every condition
/// under "Only when" must hold as well (AND).
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public enum Action: Codable, Sendable, Hashable {
        case proxy, direct, block
        /// Through one server or a group of servers instead of the connected one.
        case via(Via)
    }

    public struct Via: Codable, Sendable, Hashable {
        public enum Target: Codable, Sendable, Hashable { case server(UUID), group(UUID) }
        public var target: Target
        /// The server's or group's name when the rule was made, for export and an unresolved target.
        public var name: String
        /// When the target fails, use the connected server instead of failing closed.
        public var fallsBack = false

        public init(target: Target, name: String, fallsBack: Bool = false) {
            self.target = target
            self.name = name
            self.fallsBack = fallsBack
        }
    }

    /// An app (any form `AppMatchers` reads), a host entry (any form `RuleMatchers` reads) or a country code.
    public enum Item: Codable, Sendable, Hashable {
        case app(String), host(String), country(String)
    }

    public enum Network: String, Codable, Sendable, CaseIterable { case tcp, udp }
    /// Protocols the core recognises by sniffing.
    public enum Sniffed: String, Codable, Sendable, CaseIterable { case bittorrent, quic, tls, http }

    public struct OnlyWhen: Codable, Sendable, Hashable {
        /// Xray's port list: `443`, `1000-2000`, `53,443,8000-8100`.
        public var ports = ""
        public var network: Network?
        public var protocols: [Sniffed] = []
        /// App entries; the rule applies to traffic from these apps only.
        public var apps: [String] = []

        public init(ports: String = "", network: Network? = nil, protocols: [Sniffed] = [], apps: [String] = []) {
            self.ports = ports
            self.network = network
            self.protocols = protocols
            self.apps = apps
        }

        public var isEmpty: Bool { ports.trimmingCharacters(in: .whitespaces).isEmpty && network == nil && protocols.isEmpty && apps.isEmpty }

        /// Digits, ranges and commas only, each port in 1...65535.
        public static func validPorts(_ text: String) -> Bool {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.allSatisfy { part in
                let ends = part.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
                guard (1...2).contains(ends.count), ends.count == part.split(separator: "-", omittingEmptySubsequences: false).count else { return false }
                return ends.allSatisfy { (1...65535).contains($0) } && ends.first! <= ends.last!
            }
        }
    }

    public var id = UUID()
    public var name: String
    public var enabled = true
    public var action: Action
    public var items: [Item] = []
    public var only = OnlyWhen()

    public init(id: UUID = UUID(), name: String, action: Action, items: [Item] = [], only: OnlyWhen = OnlyWhen(), enabled: Bool = true) {
        self.id = id
        self.name = name
        self.action = action
        self.items = items
        self.only = only
        self.enabled = enabled
    }

    public var appItems: [String] { items.compactMap { if case .app(let v) = $0 { v } else { nil } } }
    public var hostItems: [String] { items.compactMap { if case .host(let v) = $0 { v } else { nil } } }
    public var countryItems: [String] { items.compactMap { if case .country(let v) = $0 { v } else { nil } } }

    public var needsApps: Bool { !appItems.isEmpty || !only.apps.isEmpty }

    // MARK: Storage

    private struct Stored: Codable { var version = 2; var rules: [Rule] }

    /// The ordered list as stored under `rules`; nil when the text is not a v2 list.
    public static func decode(_ json: String) -> [Rule]? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(json.utf8)), stored.version == 2 else { return nil }
        return stored.rules
    }

    public static func encode(_ rules: [Rule]) -> String {
        (try? JSONEncoder().encode(Stored(rules: rules))).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"version":2,"rules":[]}"#
    }

    // MARK: Migration

    /// One old rule becomes one new rule that routes exactly the same traffic: hosts become items, apps
    /// become items when the rule has no hosts and an "Only when" condition when it has.
    public init(migrating old: CustomRule) {
        let hosts = RuleMatchers(parsing: old.hosts)
        let apps = Self.appEntries(old.apps)
        // Invalid hosts stay as items: they compile to nothing, as before, and the window can show them.
        let hostItems = (hosts.domains + hosts.ips + hosts.invalid).map(Item.host)
        if hostItems.isEmpty {
            self.init(id: old.id, name: old.name, action: Action(old.action), items: apps.map(Item.app), enabled: old.enabled)
        } else {
            self.init(id: old.id, name: old.name, action: Action(old.action), items: hostItems, only: OnlyWhen(apps: apps), enabled: old.enabled)
        }
    }

    /// The entries of an app list, split as `AppMatchers` splits them.
    static func appEntries(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline || $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: Compiling

    /// The rule as adjacent Xray rules sending to `target` (`outboundTag` or `balancerTag` and its
    /// value): one for app items, one for domains, one for IPs, each with the "Only when" fields.
    /// Empty when nothing in it can match, so a rule never widens to all traffic by accident.
    func xrayRules(apps installed: [InstalledApp], siteTags: Set<String>, target: (key: String, tag: String)) -> [JSONValue] {
        var conditions: JSONValue = [:]
        let ports = only.ports.replacingOccurrences(of: " ", with: "")
        if !ports.isEmpty {
            guard OnlyWhen.validPorts(ports) else { return [] }
            conditions = conditions.setting("port", to: .string(ports))
        }
        if let network = only.network { conditions = conditions.setting("network", to: .string(network.rawValue)) }
        if !only.protocols.isEmpty { conditions = conditions.setting("protocol", to: .array(only.protocols.map { .string($0.rawValue) })) }
        if !only.apps.isEmpty {
            let processes = AppMatchers(parsing: only.apps.joined(separator: "\n"), apps: installed).processes
            // Apps that are all missing must not turn into a condition every app meets.
            guard !processes.isEmpty else { return [] }
            conditions = conditions.setting("process", to: .array(processes.map { .string($0) }))
        }
        func rule(_ key: String?, _ values: [String]) -> JSONValue {
            var out = JSONValue.object(conditions.objectValue ?? [:]).setting("type", to: "field")
            // A rule's own matcher wins over the same "Only when" field (app items over "Only when" apps).
            if let key { out = out.setting(key, to: .array(values.map { .string($0) })) }
            return out.setting(target.key, to: .string(target.tag))
        }
        if items.isEmpty { return only.isEmpty ? [] : [rule(nil, [])] }
        var out: [JSONValue] = []
        // shortcut: "Only when" apps do not narrow app items; intersect them if users ask for it.
        let processes = AppMatchers(parsing: appItems.joined(separator: "\n"), apps: installed).processes
        if !processes.isEmpty { out.append(rule("process", processes)) }
        let countries = countryItems.flatMap { CountryRuleOptions().rules(for: $0, siteTags: siteTags) }
        let hosts = RuleMatchers(parsing: (hostItems + countries).joined(separator: "\n"))
        if !hosts.domains.isEmpty { out.append(rule("domain", hosts.domains)) }
        if !hosts.ips.isEmpty { out.append(rule("ip", hosts.ips)) }
        return out
    }
}

extension Rule.Action {
    init(_ old: CustomRule.Action) {
        switch old {
        case .proxy: self = .proxy
        case .direct: self = .direct
        case .block: self = .block
        }
    }

    /// Proxy, Direct or Block; nil for Via.
    public var basic: CustomRule.Action? {
        switch self {
        case .proxy: .proxy
        case .direct: .direct
        case .block: .block
        case .via: nil
        }
    }
}

extension Rule {
    /// The list to use: the v2 `rules` value, or the 1.1 `customRuleList` migrated when there is none
    /// yet. The old value is never written, so going back to 1.1 finds the rules from before the upgrade.
    public static func list(v2: String?, v1: String?) -> [Rule] {
        if let v2, let rules = decode(v2) { return rules }
        return CustomRule.decode(v1 ?? "[]").map(Rule.init(migrating:))
    }
}

/// A named rule set, version 2 (spec 8.6).
public struct RuleProfileV2: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var rules: [Rule]

    public init(id: UUID = UUID(), name: String, rules: [Rule]) {
        self.id = id
        self.name = name
        self.rules = rules
    }

    /// Keeps the profile's id, so the active profile stays active.
    public init(migrating old: RuleProfile) {
        self.init(id: old.id, name: old.name, rules: old.rules.map(Rule.init(migrating:)))
    }

    private struct Stored: Codable { var version = 2; var profiles: [RuleProfileV2] }

    public static func decode(_ json: String) -> [RuleProfileV2]? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(json.utf8)), stored.version == 2 else { return nil }
        return stored.profiles
    }

    public static func encode(_ profiles: [RuleProfileV2]) -> String {
        (try? JSONEncoder().encode(Stored(profiles: profiles))).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"version":2,"profiles":[]}"#
    }

    /// As `Rule.list`: v2 when present, else the 1.1 profiles migrated.
    public static func list(v2: String?, v1: String?) -> [RuleProfileV2] {
        if let v2, let profiles = decode(v2) { return profiles }
        return RuleProfile.decode(v1 ?? "[]").map(RuleProfileV2.init(migrating:))
    }
}
