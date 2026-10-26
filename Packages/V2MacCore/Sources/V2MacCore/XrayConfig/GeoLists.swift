import Foundation

/// Every list of a set of geo files, with its contents, for the rule search and the tester (spec 8.6).
/// Keys are `<file>:<list>`, lowercased; `geosite:x` and `geoip:x` read `geosite.dat` and `geoip.dat`.
public struct GeoLists: Sendable {
    public struct SiteEntry: Sendable, Hashable {
        public enum Kind: Int, Sendable { case keyword = 0, regex = 1, domain = 2, full = 3 }
        public var kind: Kind
        public var value: String
    }

    public private(set) var sites: [String: [SiteEntry]] = [:]
    /// Sorted, merged ranges per list.
    private var ips: [String: [ClosedRange<UInt128>]] = [:]
    private var v6Lists: [String: [ClosedRange<UInt128>]] = [:]

    public init() {}

    /// `siteFiles` and `ipFiles` by file name (`geosite.dat`, `region-ir-geoip.dat`).
    public init(siteFiles: [String: Data], ipFiles: [String: Data]) {
        for (file, data) in siteFiles {
            for (name, body) in Self.entries(data) {
                var list: [SiteEntry] = []
                var r = GeoIPIndex.Reader(bytes: body)
                while let (field, domain) = r.message() {
                    guard field == 2 else { continue }
                    var d = GeoIPIndex.Reader(bytes: domain)
                    var kind = SiteEntry.Kind.keyword, value = ""
                    while let (f, wire) = d.key() {
                        if wire == 0, let v = d.varint() { if f == 1 { kind = SiteEntry.Kind(rawValue: v) ?? .keyword } }
                        else if wire == 2, let v = d.chunk() { if f == 2 { value = String(decoding: v, as: UTF8.self) } }
                        else { break }
                    }
                    list.append(SiteEntry(kind: kind, value: value.lowercased()))
                }
                sites["\(file.lowercased()):\(name)"] = list
            }
        }
        for (file, data) in ipFiles {
            for (name, body) in Self.entries(data) {
                var v4: [ClosedRange<UInt128>] = [], v6: [ClosedRange<UInt128>] = []
                var r = GeoIPIndex.Reader(bytes: body)
                while let (field, cidr) = r.message() {
                    guard field == 2 else { continue }
                    var c = GeoIPIndex.Reader(bytes: cidr)
                    var ip: ArraySlice<UInt8> = [], prefix = 0
                    while let (f, wire) = c.key() {
                        if wire == 2, let v = c.chunk() { if f == 1 { ip = v } }
                        else if wire == 0, let v = c.varint() { if f == 2 { prefix = v } }
                        else { break }
                    }
                    let bits = ip.count * 8
                    guard bits == 32 || bits == 128, (0...bits).contains(prefix) else { continue }
                    let start = ip.reduce(UInt128(0)) { $0 << 8 | UInt128($1) }
                    let host = bits - prefix
                    let range = start...(host == 128 ? .max : start | ((UInt128(1) << host) - 1))
                    if bits == 32 { v4.append(range) } else { v6.append(range) }
                }
                ips["\(file.lowercased()):\(name)"] = Self.merged(v4)
                v6Lists["\(file.lowercased()):\(name)"] = Self.merged(v6)
            }
        }
    }

    /// The core's own files plus downloaded region packs, by file name, from one folder each.
    public init(folders: [URL]) {
        var site: [String: Data] = [:], ip: [String: Data] = [:]
        for folder in folders {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "dat" {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                // ponytail: as in `RuleMatchers`, geoip files are told apart by "ip" in the name.
                if url.lastPathComponent.lowercased().contains("ip") { ip[url.lastPathComponent] = data } else { site[url.lastPathComponent] = data }
            }
        }
        self.init(siteFiles: site, ipFiles: ip)
    }

    /// The list a rule entry names: `geosite:x`, `geoip:x` or `ext:<file>:<x>`.
    static func key(_ entry: String) -> String? {
        let lower = entry.lowercased()
        if lower.hasPrefix("geosite:") { return "geosite.dat:" + lower.dropFirst(8).split(separator: "@").first.map(String.init)! }
        if lower.hasPrefix("geoip:") { return "geoip.dat:" + lower.dropFirst(6) }
        if lower.hasPrefix("ext:") {
            let parts = lower.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return "\(parts[1]):\(parts[2].split(separator: "@").first ?? "")"
        }
        return nil
    }

    /// Whether `host` is in the site list `key`; nil when the list is not loaded.
    func site(_ key: String, contains host: String) -> String? {
        sites[key]?.first { Self.matches($0, host) }.map(\.value)
    }

    static func matches(_ entry: SiteEntry, _ host: String) -> Bool {
        switch entry.kind {
        case .keyword: host.contains(entry.value)
        case .full: host == entry.value
        case .domain: host == entry.value || host.hasSuffix("." + entry.value)
        case .regex: (try? Regex(entry.value)).map { host.contains($0) } ?? false
        }
    }

    /// Whether `address` is in the address list `key`.
    func ipList(_ key: String, contains address: String) -> Bool {
        guard let (value, isV4) = Self.number(address), let list = isV4 ? ips[key] : v6Lists[key] else { return false }
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].lowerBound <= value { low = mid + 1 } else { high = mid }
        }
        return low > 0 && list[low - 1].contains(value)
    }

    public var isEmpty: Bool { sites.isEmpty && ips.isEmpty }

    static func number(_ address: String) -> (UInt128, Bool)? {
        var a4 = in_addr(), a6 = in6_addr()
        if inet_pton(AF_INET, address, &a4) == 1 { return (UInt128(UInt32(bigEndian: a4.s_addr)), true) }
        guard inet_pton(AF_INET6, address, &a6) == 1 else { return nil }
        return (withUnsafeBytes(of: a6) { $0.reduce(UInt128(0)) { $0 << 8 | UInt128($1) } }, false)
    }

    /// The top-level entries of a geo file: name and the whole entry.
    private static func entries(_ data: Data) -> [(String, ArraySlice<UInt8>)] {
        var out: [(String, ArraySlice<UInt8>)] = []
        var reader = GeoIPIndex.Reader(bytes: [UInt8](data)[...])
        while let (field, entry) = reader.message(), field == 1 {
            var inner = GeoIPIndex.Reader(bytes: entry)
            if let (f, name) = inner.message(), f == 1 { out.append((String(decoding: name, as: UTF8.self).lowercased(), entry)) }
        }
        return out
    }

    private static func merged(_ ranges: [ClosedRange<UInt128>]) -> [ClosedRange<UInt128>] {
        var out: [ClosedRange<UInt128>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, last.upperBound == .max || r.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else { out.append(r) }
        }
        return out
    }
}
