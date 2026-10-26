import Foundation

extension Rule.Item {
    /// What a token shows itself as in the Rules window.
    public enum Kind: String, Sendable, CaseIterable {
        case app, domain, exact, keyword, regex, ip, country, service, invalid
    }

    public var kind: Kind {
        switch self {
        case .app: return .app
        case .country: return .country
        case .host(let text):
            let lower = text.lowercased()
            if lower.hasPrefix("full:") { return .exact }
            if lower.hasPrefix("domain:") || lower.hasPrefix("dotless:") { return .domain }
            if lower.hasPrefix("keyword:") { return .keyword }
            if lower.hasPrefix("regexp:") { return .regex }
            if lower.hasPrefix("geosite:") || lower.hasPrefix("geoip:") || lower.hasPrefix("ext:") { return .service }
            if RuleMatchers.isIP(text) { return .ip }
            return .invalid
        }
    }

    /// The token's text without the prefix its kind already says.
    public var text: String {
        switch self {
        case .app(let v), .country(let v): return v
        case .host(let v):
            for prefix in ["domain:", "full:", "keyword:", "regexp:"] where v.lowercased().hasPrefix(prefix) { return String(v.dropFirst(prefix.count)) }
            return v
        }
    }

    /// The same text read as another kind (a token's kind menu); nil when it cannot be that kind.
    public func changing(to kind: Kind) -> Rule.Item? {
        Self.item(text, as: kind)
    }

    /// `text` as an item of `kind`.
    public static func item(_ text: String, as kind: Kind) -> Rule.Item? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        switch kind {
        case .app: return .app(t)
        case .country: return GeoTags.isCountry(t) ? .country(t.lowercased()) : nil
        case .domain: return RuleMatchers.domainName(t).map { .host("domain:" + $0) }
        case .exact: return RuleMatchers.domainName(t).map { .host("full:" + $0) }
        case .keyword: return t.contains(where: \.isWhitespace) ? nil : .host("keyword:" + t.lowercased())
        case .regex: return (try? Regex(t)) == nil ? nil : .host("regexp:" + t)
        case .ip: return RuleMatchers.isIP(t) ? .host(t) : nil
        case .service: return GeoLists.key(t) == nil ? nil : .host(t.lowercased())
        case .invalid: return nil
        }
    }

    /// Typed or pasted text as items, in every form `RuleMatchers` reads (one or many lines, Clash
    /// lines, hosts files, ranges); `skipped` names what could not be read.
    public static func parse(_ text: String) -> (items: [Rule.Item], skipped: [String]) {
        let m = RuleMatchers(parsing: text)
        return ((m.domains + m.ips).map(Rule.Item.host), m.invalid)
    }
}

/// A starting point for a new rule (spec 8.6): an ordinary rule filled from the geo lists the core
/// has and the apps on this Mac. Nothing links the rule to its template afterwards.
public struct RuleTemplate: Sendable, Identifiable, Hashable {
    public enum ID: String, Sendable, CaseIterable { case ai, developer, apple, social, streaming, region, torrents, ads }
    public var id: ID
    public var action: Rule.Action
    /// Geo lists, used when the files have them.
    public var lists: [String]
    /// Bundle ids, used when the app is installed.
    public var apps: [String]
    public var only = Rule.OnlyWhen()

    public var name: String {
        switch id {
        case .ai: String(localized: "AI services")
        case .developer: String(localized: "Developer tools")
        case .apple: String(localized: "Apple services")
        case .social: String(localized: "Social & chat")
        case .streaming: String(localized: "Streaming")
        case .region: String(localized: "Region sites direct")
        case .torrents: String(localized: "Torrents direct")
        case .ads: String(localized: "Ads & trackers")
        }
    }

    public static let all: [RuleTemplate] = [
        RuleTemplate(id: .ai, action: .proxy, lists: ["geosite:openai", "geosite:anthropic", "geosite:category-ai-!cn", "geosite:google-gemini", "geosite:perplexity"],
                     apps: ["com.openai.chat", "com.anthropic.claudefordesktop", "ai.perplexity.mac"]),
        RuleTemplate(id: .developer, action: .proxy, lists: ["geosite:github", "geosite:gitlab", "geosite:docker", "geosite:npmjs", "geosite:stackexchange", "geosite:jetbrains", "geosite:google-dev"],
                     apps: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.github.GitHubClient", "com.docker.docker"]),
        RuleTemplate(id: .apple, action: .direct, lists: ["geosite:apple", "geosite:icloud", "geosite:apple-cn"], apps: []),
        RuleTemplate(id: .social, action: .proxy, lists: ["geosite:telegram", "geoip:telegram", "geosite:whatsapp", "geosite:instagram", "geosite:facebook", "geosite:twitter", "geosite:discord", "geosite:signal"],
                     apps: ["ru.keepcoder.Telegram", "org.telegram.desktop", "net.whatsapp.WhatsApp", "com.hnc.Discord", "org.whispersystems.signal-desktop"]),
        RuleTemplate(id: .streaming, action: .proxy, lists: ["geosite:youtube", "geosite:netflix", "geosite:spotify", "geosite:twitch", "geosite:disney", "geosite:hulu"],
                     apps: ["com.spotify.client"]),
        RuleTemplate(id: .region, action: .direct, lists: [], apps: []),
        RuleTemplate(id: .torrents, action: .direct, lists: [], apps: [], only: .init(protocols: [.bittorrent])),
        RuleTemplate(id: .ads, action: .block, lists: ["geosite:category-ads-all"], apps: []),
    ]

    /// The rule: lists the files have (`available`), installed apps, and for the region template the
    /// chosen region packs' lists. Torrents match by the sniffed protocol.
    public func rule(available: Set<String>, installed: [InstalledApp], regions: [RegionRoute] = []) -> Rule {
        let ids = Set(installed.map { $0.bundleID.lowercased() })
        let appItems = apps.filter { ids.contains($0.lowercased()) }.map(Rule.Item.app)
        var listItems = lists.filter(available.contains).map(Rule.Item.host)
        if id == .region { listItems = regions.flatMap { $0.domainRules + $0.ipRules }.map(Rule.Item.host) }
        return Rule(name: name, action: action, items: appItems + listItems, only: only)
    }
}
