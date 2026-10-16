import Foundation

/// One app or host entry as the simple rule editor shows it: a line of a rule's `apps` or `hosts`.
public struct RuleEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case app, host }
    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    /// Also the drag payload: `app:<entry>` or `host:<entry>`.
    public var id: String { kind.rawValue + ":" + text }

    public init?(id: String) {
        guard let colon = id.firstIndex(of: ":"), let kind = Kind(rawValue: String(id[..<colon])) else { return nil }
        let text = String(id[id.index(after: colon)...])
        guard !text.isEmpty else { return nil }
        self.init(kind, text)
    }
}

/// The simple editor's view of the ordered list (spec 8.6): every entry of the enabled rules that match apps only or hosts only, and moves that keep the list consistent.
public enum SimpleRules {
    /// The six rules the simple editor writes to, at the top of the list so they win.
    public static func ruleID(_ kind: RuleEntry.Kind, _ action: CustomRule.Action) -> UUID {
        let n = switch action {
        case .proxy: kind == .host ? 1 : 3
        case .direct: kind == .host ? 2 : 4
        case .block: kind == .host ? 5 : 6
        }
        return UUID(uuidString: "00000000-5143-4D50-0000-00000000000\(n)")!
    }

    static func split(_ field: String) -> [String] {
        field.split(whereSeparator: { $0.isNewline || $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
    }

    /// A rule with apps and hosts needs both, so it is not one column's entries; it is left to Advanced.
    static func isSimple(_ rule: CustomRule) -> Bool {
        split(rule.apps).isEmpty != split(rule.hosts).isEmpty
    }

    public static func entries(_ rules: [CustomRule], action: CustomRule.Action) -> [RuleEntry] {
        var out: [RuleEntry] = []
        for rule in rules where rule.enabled && rule.action == action && isSimple(rule) {
            for app in split(rule.apps) { out.append(RuleEntry(.app, app)) }
            for host in split(rule.hosts) { out.append(RuleEntry(.host, host)) }
        }
        var seen = Set<RuleEntry>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The name of the first rule each entry of `entries(_:action:)` comes from, by entry id.
    public static func ruleNames(_ rules: [CustomRule], action: CustomRule.Action) -> [String: String] {
        var out: [String: String] = [:]
        for rule in rules where rule.enabled && rule.action == action && isSimple(rule) {
            for app in split(rule.apps) where out[RuleEntry(.app, app).id] == nil { out[RuleEntry(.app, app).id] = rule.name }
            for host in split(rule.hosts) where out[RuleEntry(.host, host).id] == nil { out[RuleEntry(.host, host).id] = rule.name }
        }
        return out
    }

    /// Takes `moved` out of every rule with only apps or only hosts and, unless `action` is nil, adds
    /// them to the simple editor's rule for that action. Rules left empty by the move are removed.
    public static func move(_ moved: [RuleEntry], to action: CustomRule.Action?, in rules: [CustomRule]) -> [CustomRule] {
        let texts = Dictionary(grouping: moved, by: \.kind).mapValues { Set($0.map { $0.text.lowercased() }) }
        var out: [CustomRule] = []
        for var rule in rules {
            guard isSimple(rule) else { out.append(rule); continue }
            let apps = split(rule.apps), hosts = split(rule.hosts)
            let keptApps = apps.filter { !(texts[.app]?.contains($0.lowercased()) ?? false) }
            let keptHosts = hosts.filter { !(texts[.host]?.contains($0.lowercased()) ?? false) }
            if keptApps.count == apps.count && keptHosts.count == hosts.count { out.append(rule); continue }
            if keptApps.isEmpty && keptHosts.isEmpty { continue }
            rule.apps = keptApps.joined(separator: "\n")
            rule.hosts = keptHosts.joined(separator: "\n")
            out.append(rule)
        }
        guard let action else { return out }
        for kind in [RuleEntry.Kind.host, .app] {
            let add = moved.filter { $0.kind == kind }.map(\.text)
            guard !add.isEmpty else { continue }
            let id = ruleID(kind, action)
            if let index = out.firstIndex(where: { $0.id == id }) {
                let field = kind == .app ? out[index].apps : out[index].hosts
                let joined = (split(field) + add).joined(separator: "\n")
                if kind == .app { out[index].apps = joined } else { out[index].hosts = joined }
                out[index].enabled = true
            } else {
                var rule = CustomRule(name: name(kind, action), action: action)
                rule.id = id
                if kind == .app { rule.apps = add.joined(separator: "\n") } else { rule.hosts = add.joined(separator: "\n") }
                // Sites first, then apps after the editor's other rules: a site picked for one column
                // wins over its app's column.
                let ours = Set([RuleEntry.Kind.host, .app].flatMap { kind in CustomRule.Action.allCases.map { ruleID(kind, $0) } })
                out.insert(rule, at: kind == .host ? 0 : out.prefix { ours.contains($0.id) }.count)
            }
        }
        return out
    }

    /// The action of the first enabled rule with only hosts that names `host`: as written, by
    /// keyword, or as a parent domain. Geo lists and regular expressions are not checked.
    public static func action(forHost host: String, in rules: [CustomRule]) -> CustomRule.Action? {
        let host = host.lowercased()
        for rule in rules where rule.enabled && split(rule.apps).isEmpty {
            let parsed = RuleMatchers(parsing: rule.hosts)
            for domain in parsed.domains {
                let value = domain.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                let hit = switch domain.split(separator: ":").first ?? "" {
                case "domain": host == value || host.hasSuffix("." + value)
                case "full": host == value
                case "keyword": host.contains(value)
                default: false
                }
                if hit { return rule.action }
            }
            if parsed.ips.contains(host) { return rule.action }
        }
        return nil
    }

    /// The action of the first enabled rule with only apps that names the app at `path`.
    public static func action(forApp path: String, bundleID: String, in rules: [CustomRule]) -> CustomRule.Action? {
        let app = InstalledApp(path: path, bundleID: bundleID)
        let folder = path.hasSuffix(".app") ? path + "/" : path
        for rule in rules where rule.enabled && split(rule.hosts).isEmpty {
            let processes = AppMatchers(parsing: rule.apps, apps: [app]).processes
            if processes.contains(folder) || processes.contains((path as NSString).lastPathComponent) { return rule.action }
        }
        return nil
    }

    static func name(_ kind: RuleEntry.Kind, _ action: CustomRule.Action) -> String {
        switch (kind, action) {
        case (.host, .proxy): String(localized: "Sites through the proxy")
        case (.host, .direct): String(localized: "Sites direct")
        case (.host, .block): String(localized: "Sites blocked")
        case (.app, .proxy): String(localized: "Apps through the proxy")
        case (.app, .direct): String(localized: "Apps direct")
        case (.app, .block): String(localized: "Apps blocked")
        }
    }
}

/// Seen hosts and apps folded into groups by name, so `www.google.com`, `google.de` and
/// `googleapis.com` sit under one `google` row that a `*google*` entry covers.
public enum EntryGroups {
    /// Second-level labels under a country code (`co.uk`, `com.au`).
    static let countrySecondLevel: Set<String> = ["co", "com", "net", "org", "gov", "ac", "edu", "or", "ne", "go"]

    /// The name part of a host's registered domain, or nil for an IP address.
    // shortcut: a short list instead of the Public Suffix List; good enough for grouping, not for security.
    public static func brand(ofHost host: String) -> String? {
        if RuleMatchers.isIP(host) { return nil }
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return labels.first }
        var index = labels.count - 2
        if labels.count >= 3, labels[labels.count - 1].count == 2, countrySecondLevel.contains(labels[index]) { index -= 1 }
        return labels[index]
    }

    /// The vendor part of a bundle id (`com.google.Chrome` → `google`).
    public static func brand(ofBundleID id: String) -> String? {
        let parts = id.lowercased().split(separator: ".")
        return parts.count >= 3 ? String(parts[1]) : nil
    }

    /// Group keys for `brands`: a brand that contains a shorter brand of 4+ letters joins it.
    public static func keys(for brands: Set<String>) -> [String: String] {
        let roots = brands.filter { $0.count >= 4 }.sorted { $0.count < $1.count }
        var out: [String: String] = [:]
        for brand in brands { out[brand] = roots.first { brand != $0 && brand.contains($0) } ?? brand }
        return out
    }
}

/// A named set of custom rules (spec 8.6); one is active and its rules are `customRuleList`.
public struct RuleProfile: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var rules: [CustomRule]

    public init(name: String, rules: [CustomRule]) {
        self.name = name
        self.rules = rules
    }

    public static func decode(_ json: String) -> [RuleProfile] {
        (try? JSONDecoder().decode([RuleProfile].self, from: Data(json.utf8))) ?? []
    }

    public static func encode(_ profiles: [RuleProfile]) -> String {
        (try? JSONEncoder().encode(profiles)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
