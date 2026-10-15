import Foundation

/// The user's own routing rules (spec 8.6): one text per outbound, one entry per line.
/// They come before the mode's own rules, block first, then proxy, then direct.
public struct CustomRules: Sendable, Equatable, Hashable {
    public var proxy: String
    public var direct: String
    public var block: String

    public init(proxy: String = "", direct: String = "", block: String = "") {
        self.proxy = proxy
        self.direct = direct
        self.block = block
    }

    /// Text and outbound tag, in the order the rules are written into the config.
    var lists: [(text: String, tag: String)] {
        [(block, ConfigBuilder.blockTag), (proxy, ConfigBuilder.proxyTag), (direct, ConfigBuilder.directTag)]
    }
}

/// One list of rules turned into Xray `domain` and `ip` entries.
///
/// Accepted, one or more per line (comma or space separated), `#` or `//` starting a comment:
/// - Xray: `domain:`, `full:`, `keyword:`, `regexp:`, `geosite:`, `geoip:`, `ext:<file>:<tag>`
/// - IP addresses and CIDR ranges
/// - plain domains and `*.`/`+.`/`.` wildcards, matching the domain and its subdomains
/// - Clash lines: `DOMAIN-SUFFIX,example.com[,policy]`, `DOMAIN`, `DOMAIN-KEYWORD`,
///   `DOMAIN-REGEX`, `IP-CIDR`, `IP-CIDR6`, `GEOIP`, `GEOSITE` (the policy is ignored)
/// - hosts files (`0.0.0.0 ads.example.com`) and Adblock domains (`||ads.example.com^`)
public struct RuleMatchers: Sendable, Equatable {
    public var domains: [String] = []
    public var ips: [String] = []
    /// Entries that match none of the formats; they are left out.
    public var invalid: [String] = []

    public init(parsing text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix("!") || line.isEmpty { continue }
            // Clash rule-provider payloads: `- DOMAIN-SUFFIX,x` or `- '+.x'`.
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
            if let entry = Self.clash(line) { add(entry, from: line); continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // A hosts file line: an address, then the names it pins.
            if fields.count >= 2, Self.isIP(fields[0]), !Self.isIP(fields[1]), !line.contains(",") {
                for name in fields.dropFirst() { add(Self.domainName(name).map { .domain("full:" + $0) }, from: name) }
                continue
            }
            for token in line.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
                add(Self.entry(String(token)), from: String(token))
            }
        }
    }

    enum Entry { case domain(String), ip(String) }

    private mutating func add(_ entry: Entry?, from source: String) {
        switch entry {
        case .domain(let value): if !domains.contains(value) { domains.append(value) }
        case .ip(let value): if !ips.contains(value) { ips.append(value) }
        case nil: invalid.append(source)
        }
    }

    static func entry(_ token: String) -> Entry? {
        let lower = token.lowercased()
        for prefix in ["domain:", "full:", "keyword:", "regexp:", "geosite:", "dotless:"] where lower.hasPrefix(prefix) {
            return token.count > prefix.count ? .domain(prefix + token.dropFirst(prefix.count)) : nil
        }
        if lower.hasPrefix("geoip:") { return token.count > 6 ? .ip("geoip:" + lower.dropFirst(6)) : nil }
        if lower.hasPrefix("ext:") {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
            // ponytail: geoip files are told apart by name, as every published one has "ip" in it.
            return parts[1].lowercased().contains("ip") ? .ip(token) : .domain(token)
        }
        if lower.hasPrefix("||") {
            return domainEntry(String(token.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "^")))
        }
        if isIP(token) { return .ip(token) }
        return domainEntry(token)
    }

    static func clash(_ line: String) -> Entry? {
        let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2 else { return nil }
        let value = fields[1]
        switch fields[0].uppercased() {
        case "DOMAIN": return domainName(value).map { .domain("full:" + $0) }
        case "DOMAIN-SUFFIX": return domainEntry(value)
        case "DOMAIN-KEYWORD": return value.isEmpty ? nil : .domain("keyword:" + value)
        case "DOMAIN-REGEX": return value.isEmpty ? nil : .domain("regexp:" + value)
        case "IP-CIDR", "IP-CIDR6": return isIP(value) ? .ip(value) : nil
        case "GEOIP": return value.isEmpty ? nil : .ip("geoip:" + value.lowercased())
        case "GEOSITE": return value.isEmpty ? nil : .domain("geosite:" + value.lowercased())
        default: return nil
        }
    }

    /// `example.com`, `*.example.com`, `+.example.com` and `.example.com` all become `domain:example.com`.
    static func domainEntry(_ token: String) -> Entry? {
        domainName(token).map { .domain("domain:" + $0) }
    }

    static func domainName(_ token: String) -> String? {
        var name = token.lowercased()
        var isWildcard = false
        for wildcard in ["*.", "+.", "."] where name.hasPrefix(wildcard) { name.removeFirst(wildcard.count); isWildcard = true; break }
        if name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        // A lone word is more likely a typo or prose than a host; `.ir` or `full:host` say so explicitly.
        guard labels.count > 1 || isWildcard, !name.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return name
    }

    /// An IPv4 or IPv6 address, with or without a `/prefix`.
    static func isIP(_ token: String) -> Bool {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let address = String(parts[0])
        var v4 = in_addr(), v6 = in6_addr()
        let max: Int
        if inet_pton(AF_INET, address, &v4) == 1 { max = 32 }
        else if inet_pton(AF_INET6, address, &v6) == 1 { max = 128 }
        else { return false }
        guard parts.count == 2 else { return true }
        return Int(parts[1]).map { (0...max).contains($0) } ?? false
    }
}
