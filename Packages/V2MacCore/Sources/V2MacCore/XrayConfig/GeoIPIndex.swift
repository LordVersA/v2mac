import Darwin
import Foundation

/// The country of an IP address, from the core's own `geoip.dat` (spec 12.10), so the map places
/// a connection without asking any service. Only the two-letter country lists are read.
public struct GeoIPIndex: Sendable {
    private struct Range: Sendable { let start: UInt128, end: UInt128, code: Int }
    private var codes: [String] = []
    private var v4: [Range] = []
    private var v6: [Range] = []

    public init() {}

    /// `geoip.dat`: a protobuf list of entries (field 1), each a code (field 1) and CIDRs (field 2:
    /// address bytes in field 1, prefix length in field 2).
    public init(data: Data) {
        let bytes = [UInt8](data)
        var reader = Reader(bytes: bytes[...])
        while let (field, entry) = reader.message(), field == 1 {
            var inner = Reader(bytes: entry)
            var code: String?
            var cidrs: [ArraySlice<UInt8>] = []
            while let (f, value) = inner.message() {
                if f == 1 { code = String(decoding: value, as: UTF8.self).uppercased() }
                if f == 2 { cidrs.append(value) }
            }
            guard let code, GeoTags.isCountry(code) else { continue }
            codes.append(code)
            for cidr in cidrs {
                var r = Reader(bytes: cidr)
                var ip: ArraySlice<UInt8> = [], prefix = 0
                while let (f, wire) = r.key() {
                    if wire == 2, let value = r.chunk() { if f == 1 { ip = value } }
                    else if wire == 0, let value = r.varint() { if f == 2 { prefix = value } }
                    else { break }
                }
                let bits = ip.count * 8
                guard bits == 32 || bits == 128, (0...bits).contains(prefix) else { continue }
                let start = ip.reduce(UInt128(0)) { $0 << 8 | UInt128($1) }
                let host = bits - prefix
                let end = host == 128 ? UInt128.max : start | ((UInt128(1) << host) - 1)
                let range = Range(start: start, end: end, code: codes.count - 1)
                if bits == 32 { v4.append(range) } else { v6.append(range) }
            }
        }
        v4.sort { $0.start < $1.start }
        v6.sort { $0.start < $1.start }
    }

    public init(contentsOf url: URL) {
        self.init(data: (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data())
    }

    public var isEmpty: Bool { v4.isEmpty && v6.isEmpty }

    /// The two-letter code of the country that holds `address`, uppercased.
    public func country(of address: String) -> String? {
        var a4 = in_addr(), a6 = in6_addr()
        if inet_pton(AF_INET, address, &a4) == 1 {
            return find(UInt128(UInt32(bigEndian: a4.s_addr)), in: v4)
        }
        guard inet_pton(AF_INET6, address, &a6) == 1 else { return nil }
        return find(withUnsafeBytes(of: a6) { $0.reduce(UInt128(0)) { $0 << 8 | UInt128($1) } }, in: v6)
    }

    private func find(_ value: UInt128, in ranges: [Range]) -> String? {
        // The last range starting at or before the address; nested ranges are rare in these files.
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].start <= value { low = mid + 1 } else { high = mid }
        }
        guard low > 0, ranges[low - 1].end >= value else { return nil }
        return codes[ranges[low - 1].code]
    }

    private struct Reader {
        var bytes: ArraySlice<UInt8>

        mutating func varint() -> Int? {
            var value = 0, shift = 0
            while let byte = bytes.first, shift < 64 {
                bytes = bytes.dropFirst()
                value |= Int(byte & 0x7f) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            return nil
        }

        mutating func key() -> (field: Int, wire: Int)? {
            varint().map { ($0 >> 3, $0 & 7) }
        }

        mutating func chunk() -> ArraySlice<UInt8>? {
            guard let length = varint(), length >= 0, length <= bytes.count else { return nil }
            defer { bytes = bytes.dropFirst(length) }
            return bytes.prefix(length)
        }

        /// The next length-delimited field; other wire types are skipped.
        mutating func message() -> (Int, ArraySlice<UInt8>)? {
            while let (field, wire) = key() {
                switch wire {
                case 2: return chunk().map { (field, $0) }
                case 0: _ = varint()
                default: return nil
                }
            }
            return nil
        }
    }
}
