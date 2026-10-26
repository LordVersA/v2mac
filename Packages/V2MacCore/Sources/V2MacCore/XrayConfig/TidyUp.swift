import Foundation

/// One change Tidy Up offers for a rule list (spec 8.6). None of them changes where traffic goes,
/// except `collapseApps`, which drops matches by executable name outside the app.
public struct TidySuggestion: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Move `from`'s items into `into` (the earlier rule) and delete `from`; the rule is renamed `name`.
        case merge(into: UUID, from: UUID, name: String)
        /// Items that never match: local names and addresses the built-in rule sends direct first.
        case dropCovered(rule: UUID, items: [Rule.Item])
        /// Several spellings of one app, replaced by its bundle id.
        case collapseApps(rule: UUID, items: [String], into: String)
        /// Items written twice in one rule.
        case dropDuplicates(rule: UUID, items: [Rule.Item])
        /// A rule identical to an earlier one, which therefore never matches.
        case dropRule(UUID, sameAs: UUID)
    }

    public var kind: Kind
    public var id: Self { self }
}

public enum TidyUp {
    public static func suggestions(for rules: [Rule], apps installed: [InstalledApp]) -> [TidySuggestion] {
        var out: [TidySuggestion] = []
        // Identical rules: the later one never matches.
        var dropped = Set<UUID>()
        for (i, rule) in rules.enumerated() where rule.enabled {
            if let earlier = rules[..<i].first(where: { $0.enabled && $0.action == rule.action && $0.items == rule.items && $0.only == rule.only }) {
                out.append(.init(kind: .dropRule(rule.id, sameAs: earlier.id)))
                dropped.insert(rule.id)
            }
        }
        for rule in rules where !dropped.contains(rule.id) {
            var seen = Set<Rule.Item>(), twice: [Rule.Item] = []
            for item in rule.items where !seen.insert(item).inserted { twice.append(item) }
            if !twice.isEmpty { out.append(.init(kind: .dropDuplicates(rule: rule.id, items: twice))) }
            let covered = rule.items.filter(isCoveredByBuiltIns)
            if !covered.isEmpty { out.append(.init(kind: .dropCovered(rule: rule.id, items: covered))) }
            out += collapses(rule, installed: installed)
        }
        out += merges(rules.filter { !dropped.contains($0.id) })
        return out
    }

    /// Applies the chosen suggestions in order; one whose rule or items are gone is passed over.
    public static func apply(_ chosen: [TidySuggestion], to rules: [Rule]) -> [Rule] {
        var rules = rules
        func edit(_ id: UUID, _ change: (inout Rule) -> Void) {
            if let i = rules.firstIndex(where: { $0.id == id }) { change(&rules[i]) }
        }
        for suggestion in chosen {
            switch suggestion.kind {
            case .dropRule(let id, _):
                rules.removeAll { $0.id == id }
            case .dropDuplicates(let id, let items):
                edit(id) { rule in
                    for item in items { if let last = rule.items.lastIndex(of: item), rule.items.firstIndex(of: item) != last { rule.items.remove(at: last) } }
                }
            case .dropCovered(let id, let items):
                edit(id) { $0.items.removeAll(where: items.contains) }
            case .collapseApps(let id, let items, let bundleID):
                edit(id) { rule in
                    guard let first = rule.items.firstIndex(where: { if case .app(let a) = $0 { items.contains(a) } else { false } }) else { return }
                    rule.items.removeAll { if case .app(let a) = $0 { items.contains(a) } else { false } }
                    rule.items.insert(.app(bundleID), at: min(first, rule.items.count))
                }
            case .merge(let into, let from, let name):
                guard let source = rules.first(where: { $0.id == from }), rules.contains(where: { $0.id == into }) else { continue }
                edit(into) { rule in
                    rule.items += source.items.filter { !rule.items.contains($0) }
                    rule.name = name
                }
                rules.removeAll { $0.id == from }
            }
        }
        return rules
    }

    // MARK: Built-ins

    /// Local names and private addresses: the built-in Local network rule sends them direct before any rule.
    static func isCoveredByBuiltIns(_ item: Rule.Item) -> Bool {
        guard case .host(let text) = item else { return false }
        let m = RuleMatchers(parsing: text)
        if let ip = m.ips.first, m.domains.isEmpty {
            if ip == "geoip:private" { return true }
            return privateRanges.contains { contains($0, ip) }
        }
        guard let domain = m.domains.first, m.ips.isEmpty else { return false }
        let lower = domain.lowercased()
        for local in CustomRules.localNames {
            if lower == local { return true }
            guard local.hasPrefix("domain:") else { continue }
            let suffix = String(local.dropFirst(7))
            for prefix in ["domain:", "full:"] where lower.hasPrefix(prefix) {
                let name = lower.dropFirst(prefix.count)
                if name == suffix || name.hasSuffix("." + suffix) { return true }
            }
        }
        return false
    }

    /// What `geoip:private` holds, in the forms users write.
    static let privateRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16",
                                "100.64.0.0/10", "fc00::/7", "fe80::/10", "::1/128"]

    /// Whether CIDR `inner` lies inside CIDR `outer`.
    static func contains(_ outer: String, _ inner: String) -> Bool {
        func split(_ s: String) -> (String, Int?) {
            let p = s.split(separator: "/")
            return (String(p[0]), p.count == 2 ? Int(p[1]) : nil)
        }
        let (o, op) = split(outer), (i, ip) = split(inner)
        guard let (_, o4) = GeoLists.number(o), let (_, i4) = GeoLists.number(i), o4 == i4, let op else { return false }
        // Narrower or equal, and its first address inside.
        return (ip ?? (i4 ? 32 : 128)) >= op && RuleTester.ipMatches(outer, i, geo: GeoLists())
    }

    // MARK: Apps

    /// App items of one rule that all mean one installed app, collapsed to its bundle id.
    static func collapses(_ rule: Rule, installed: [InstalledApp]) -> [TidySuggestion] {
        var byApp: [String: [String]] = [:]
        var order: [String] = []
        for entry in rule.appItems {
            let found = Set(AppMatchers.processes(for: entry, apps: installed))
            let folders = found.filter { $0.hasSuffix(".app/") }
            guard folders.count == 1, let folder = folders.first,
                  let app = installed.first(where: { $0.path + "/" == folder || $0.path == folder }) else { continue }
            // The bare name also matches a process of that name elsewhere; that is the one thing collapsing drops.
            let name = (app.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            guard found.subtracting([folder, name]).isEmpty else { continue }
            if byApp[app.bundleID] == nil { order.append(app.bundleID) }
            byApp[app.bundleID, default: []].append(entry)
        }
        return order.compactMap { id in
            byApp[id]!.count > 1 ? TidySuggestion(kind: .collapseApps(rule: rule.id, items: byApp[id]!, into: id)) : nil
        }
    }

    // MARK: Merging

    /// "App - X" and "Host - X": one with apps only, one with hosts only, the same action and conditions,
    /// and a name that is the same once the words app/apps/host/hosts/domains are left out. Only rules
    /// with nothing between them that routes elsewhere, so moving the later one's items up changes nothing.
    static func merges(_ rules: [Rule]) -> [TidySuggestion] {
        var out: [TidySuggestion] = []
        var used = Set<UUID>()
        for (i, a) in rules.enumerated() where a.enabled && !used.contains(a.id) {
            let key = baseName(a.name)
            guard !key.isEmpty else { continue }
            for b in rules[(i + 1)...] where b.enabled && !used.contains(b.id) {
                if b.action == a.action, b.only == a.only, baseName(b.name) == key, isAppsOnly(a) != isAppsOnly(b),
                   isAppsOnly(a) || isHostsOnly(a), isAppsOnly(b) || isHostsOnly(b) {
                    out.append(.init(kind: .merge(into: a.id, from: b.id, name: displayName(a.name))))
                    used.formUnion([a.id, b.id])
                    break
                }
                // A rule in between that is on and routes elsewhere could match first.
                if b.enabled && b.action != a.action { break }
            }
        }
        return out
    }

    static func isAppsOnly(_ r: Rule) -> Bool { !r.items.isEmpty && r.items.allSatisfy(\.isApp) }
    static func isHostsOnly(_ r: Rule) -> Bool { !r.items.isEmpty && !r.items.contains(where: \.isApp) }

    static let kindWords: Set<String> = ["app", "apps", "host", "hosts", "domain", "domains", "site", "sites", "ip", "ips"]

    static func words(_ name: String) -> [Substring] {
        name.split { !$0.isLetter && !$0.isNumber }
    }

    static func baseName(_ name: String) -> String {
        words(name).filter { !kindWords.contains($0.lowercased()) }.joined(separator: " ").lowercased()
    }

    /// The name without the kind words, as the user wrote the rest.
    static func displayName(_ name: String) -> String {
        words(name).filter { !kindWords.contains($0.lowercased()) }.joined(separator: " ")
    }
}

extension Rule.Item {
    public var isApp: Bool { if case .app = self { true } else { false } }
}
