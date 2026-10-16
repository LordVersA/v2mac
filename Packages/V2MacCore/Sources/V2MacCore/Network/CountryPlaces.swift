import Foundation

/// A point in each country, read offline from the system's `zone.tab` (the first time zone city
/// listed for a country code), so placing a site's country on the map asks no service.
public enum CountryPlaces {
    public static let systemFile = URL(fileURLWithPath: "/usr/share/zoneinfo/zone.tab")

    /// Latitude and longitude by two-letter code, uppercased.
    public static func read(_ text: String) -> [String: (latitude: Double, longitude: Double)] {
        var out: [String: (latitude: Double, longitude: Double)] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, out[String(fields[0])] == nil, let point = iso6709(String(fields[1])) else { continue }
            out[String(fields[0])] = point
        }
        return out
    }

    /// `+5230+01322` or `+513030-0000731`: ±DDMM[SS] then ±DDDMM[SS].
    static func iso6709(_ text: String) -> (latitude: Double, longitude: Double)? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func angle(_ part: Substring, degreeDigits: Int) -> Double? {
            let sign: Double = part.first == "-" ? -1 : 1
            let digits = part.dropFirst()
            guard digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4, digits.allSatisfy(\.isNumber) else { return nil }
            let values = [digits.prefix(degreeDigits), digits.dropFirst(degreeDigits).prefix(2), digits.dropFirst(degreeDigits + 2)]
                .map { Double($0) ?? 0 }
            return sign * (values[0] + values[1] / 60 + values[2] / 3600)
        }
        guard let lat = angle(text[..<split], degreeDigits: 2), let lon = angle(text[split...], degreeDigits: 3) else { return nil }
        return (lat, lon)
    }
}
