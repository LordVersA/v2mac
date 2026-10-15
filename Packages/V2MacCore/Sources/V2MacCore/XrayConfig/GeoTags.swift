import Foundation

/// The list names in a `geoip.dat` or `geosite.dat` file, for the rule builder (spec 8.6).
/// Both files are a protobuf list whose entries start with their name (field 1).
public enum GeoTags {
    public static func read(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        var i = 0
        var tags: [String] = []
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < bytes.count, shift < 64 {
                let byte = bytes[i]
                i += 1
                value |= Int(byte & 0x7f) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard varint() == 0x0a, let length = varint(), length >= 0, i + length <= bytes.count else { break }
            let end = i + length
            if varint() == 0x0a, let nameLength = varint(), nameLength >= 0, i + nameLength <= end,
               let name = String(bytes: bytes[i..<i + nameLength], encoding: .utf8) {
                tags.append(name.lowercased())
            }
            i = end
        }
        return tags
    }

    public static func read(contentsOf url: URL) -> [String] {
        (try? Data(contentsOf: url, options: .mappedIfSafe)).map(read) ?? []
    }

    /// Two-letter tags are countries; the rest (`cloudflare`, `telegram`, `private`…) are named lists.
    public static func isCountry(_ tag: String) -> Bool {
        tag.count == 2 && tag.allSatisfy { $0.isASCII && $0.isLetter }
    }
}

/// What the rule builder writes for one country.
public struct CountryRuleOptions: Sendable, Equatable {
    /// `geoip:<code>`: the country's address ranges.
    public var ipRanges = true
    /// `domain:<tld>`: every name under the country's top-level domain.
    public var topLevelDomain = true
    /// `geosite:category-<code>` and `geosite:<code>`, when the site file has them.
    public var knownSites = true

    public init(ipRanges: Bool = true, topLevelDomain: Bool = true, knownSites: Bool = true) {
        self.ipRanges = ipRanges
        self.topLevelDomain = topLevelDomain
        self.knownSites = knownSites
    }

    public func rules(for code: String, siteTags: Set<String>) -> [String] {
        let code = code.lowercased()
        var out: [String] = []
        if ipRanges { out.append("geoip:\(code)") }
        if topLevelDomain { out.append("domain:\(Self.topLevelDomain(of: code))") }
        if knownSites {
            for tag in ["category-\(code)", code] where siteTags.contains(tag) { out.append("geosite:\(tag)") }
        }
        return out
    }

    /// The ISO code is the country's TLD except for the United Kingdom.
    static func topLevelDomain(of code: String) -> String { code == "gb" ? "uk" : code }
}
