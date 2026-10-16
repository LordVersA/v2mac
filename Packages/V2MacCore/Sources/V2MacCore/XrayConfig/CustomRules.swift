import Foundation

/// One of the user's own routing rules (spec 8.6). Rules are checked top to bottom, before the
/// mode's own rules, and the first match wins. A rule with apps and hosts needs both to match.
public struct CustomRule: Codable, Sendable, Hashable, Identifiable {
    public enum Action: String, Codable, Sendable, CaseIterable { case proxy, direct, block }

    public var id = UUID()
    public var name: String
    public var enabled = true
    public var action: Action
    /// One app per line or `;`: a name, `Name.app`, a bundle id, `*word*` or a full path.
    public var apps = ""
    /// One host entry per line, in the forms `RuleMatchers` reads.
    public var hosts = ""

    public init(name: String, action: Action, apps: String = "", hosts: String = "", enabled: Bool = true) {
        self.name = name
        self.action = action
        self.apps = apps
        self.hosts = hosts
        self.enabled = enabled
    }

    var tag: String {
        switch action {
        case .proxy: ConfigBuilder.proxyTag
        case .direct: ConfigBuilder.directTag
        case .block: ConfigBuilder.blockTag
        }
    }

    /// The ordered list as stored in `UserDefaults`; unreadable text gives no rules.
    public static func decode(_ json: String) -> [CustomRule] {
        (try? JSONDecoder().decode([CustomRule].self, from: Data(json.utf8))) ?? []
    }

    public static func encode(_ rules: [CustomRule]) -> String {
        (try? JSONEncoder().encode(rules)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// The three lists of earlier versions, in the order they were applied: block, proxy, direct.
    public static func migrating(proxy: String, direct: String, block: String) -> [CustomRule] {
        [CustomRule(name: String(localized: "Block"), action: .block, hosts: block),
         CustomRule(name: String(localized: "Proxy"), action: .proxy, hosts: proxy),
         CustomRule(name: String(localized: "Direct"), action: .direct, hosts: direct)]
            .filter { !$0.hosts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// An installed or running app, for matching app entries that name a bundle, a bundle id or a pattern.
public struct InstalledApp: Sendable, Hashable {
    /// The `.app` folder.
    public var path: String
    public var bundleID: String

    public init(path: String, bundleID: String) {
        self.path = path
        self.bundleID = bundleID
    }

    public var name: String { (path as NSString).lastPathComponent.lowercased() }
}

/// The user's rules plus what the config needs to turn them into Xray rules.
public struct CustomRules: Sendable, Equatable, Hashable {
    public var rules: [CustomRule]
    /// Looked up by the app only when some rule names apps.
    public var installedApps: [InstalledApp]
    /// Refuse QUIC, so browsers fall back to TCP and their host names reach the rules.
    public var blockQUIC: Bool

    public init(rules: [CustomRule] = [], installedApps: [InstalledApp] = [], blockQUIC: Bool = false) {
        self.rules = rules
        self.installedApps = installedApps
        self.blockQUIC = blockQUIC
    }

    public var needsApps: Bool { rules.contains { $0.enabled && !$0.apps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// Local names that never leave the Mac or the LAN go direct, whatever the rules say.
    static let localNames = ["full:localhost", "domain:localhost", "domain:local", "domain:test", "domain:internal",
                             "domain:lan", "domain:home.arpa", "dotless:"]
}

/// App entries turned into Xray `process` values: names, absolute paths, and folders ending in `/`.
public struct AppMatchers: Sendable, Equatable {
    public var processes: [String] = []
    /// Entries that match no app; they are left out.
    public var unmatched: [String] = []

    public init(parsing text: String, apps: [InstalledApp]) {
        for raw in text.split(whereSeparator: { $0.isNewline || $0 == ";" || $0 == "," }) {
            let entry = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if entry.isEmpty || entry.hasPrefix("#") { continue }
            let found = Self.processes(for: entry, apps: apps)
            if found.isEmpty { unmatched.append(entry) }
            for value in found where !processes.contains(value) { processes.append(value) }
        }
    }

    static func processes(for entry: String, apps: [InstalledApp]) -> [String] {
        let lower = entry.lowercased()
        // A bundle's folder catches its helpers too (Xray matches a path prefix ending in `/`).
        func folders(_ match: (InstalledApp) -> Bool) -> [String] { apps.filter(match).map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" } }
        if entry.hasPrefix("/") || entry.hasPrefix("~") {
            let path = (entry as NSString).expandingTildeInPath
            return [path.hasSuffix(".app") ? path + "/" : path]
        }
        if lower.hasPrefix("*") || lower.hasSuffix("*") {
            let word = lower.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard !word.isEmpty else { return [] }
            return folders { $0.name.contains(word) || $0.bundleID.lowercased().contains(word) }
        }
        if lower.hasSuffix(".app") { return folders { $0.name == lower } }
        // A reverse-DNS name is a bundle id; a lone word is an executable name, as Proxifier reads it.
        if lower.contains(".") {
            let byID = folders { $0.bundleID.lowercased() == lower }
            return byID.isEmpty ? [entry] : byID
        }
        return [entry] + folders { $0.name == lower + ".app" }
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
            for token in line.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
                if let blocks = Self.range(String(token)) { blocks.forEach { add(.ip($0), from: String(token)) }; continue }
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
        if lower.count > 2, lower.hasPrefix("*"), lower.hasSuffix("*") {
            let word = lower.dropFirst().dropLast()
            return word.contains("*") ? nil : .domain("keyword:" + word)
        }
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

    /// `a-b` (both IPv4 or both IPv6) as the fewest CIDR blocks covering exactly that range.
    static func range(_ token: String) -> [String]? {
        let ends = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard ends.count == 2, let (low, bits) = number(ends[0]), let (high, bits2) = number(ends[1]), bits == bits2, low <= high else { return nil }
        var out: [String] = []
        var start = low
        while true {
            // The biggest block aligned at `start` that ends at or before `high`.
            func fits(_ k: Int) -> Bool { k == 128 ? start == 0 && high == .max : high - start >= (UInt128(1) << k) - 1 }
            var k = start == 0 ? bits : min(bits, start.trailingZeroBitCount)
            while !fits(k) { k -= 1 }
            out.append("\(text(start, bits: bits))/\(bits - k)")
            if k == 128 { break }
            let last = start + (UInt128(1) << k) - 1
            if last == high { break }
            start = last + 1
        }
        return out
    }

    private static func number(_ address: String) -> (UInt128, Int)? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return (UInt128(UInt32(bigEndian: v4.s_addr)), 32) }
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
        return (withUnsafeBytes(of: v6) { $0.reduce(UInt128(0)) { $0 << 8 | UInt128($1) } }, 128)
    }

    private static func text(_ value: UInt128, bits: Int) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if bits == 32 {
            var v4 = in_addr(s_addr: UInt32(value).bigEndian)
            inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count))
        } else {
            var bytes = (0..<16).map { UInt8(truncatingIfNeeded: value >> (8 * (15 - $0))) }
            inet_ntop(AF_INET6, &bytes, &buffer, socklen_t(buffer.count))
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
