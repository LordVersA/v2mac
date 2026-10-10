import Foundation

/// Where traffic through the proxy comes out (spec 9.6).
public struct ExitInfo: Sendable, Equatable {
    public var ip: String
    /// ISO 3166-1 alpha-2, upper case.
    public var countryCode: String?
    public var city: String?

    public init(ip: String, countryCode: String? = nil, city: String? = nil) {
        self.ip = ip
        self.countryCode = countryCode
        self.city = city
    }

    /// The flag emoji for the country code.
    public var flag: String? {
        guard let countryCode else { return nil }
        let scalars = countryCode.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : nil
    }

    public func countryName(locale: Locale = .current) -> String? {
        countryCode.flatMap { locale.localizedString(forRegionCode: $0) }
    }

    /// "Amsterdam, Netherlands", or whichever part is known.
    public func place(locale: Locale = .current) -> String? {
        let parts = [city, countryName(locale: locale)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

public enum ExitLookup {
    /// Asked in this order until one answers. The last one knows the country but no city.
    public static let sources: [URL] = [
        URL(string: "https://ipwho.is/")!,
        URL(string: "https://ipinfo.io/json")!,
        URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!,
    ]

    /// Reads any of the sources: JSON with `ip`, `country_code` (or a two-letter `country`)
    /// and `city`, or Cloudflare's `key=value` lines with `ip` and `loc`.
    static func parse(_ data: Data) -> ExitInfo? {
        var fields: [String: String] = [:]
        if let json = try? JSONValue.parse(data), case .object(let object) = json {
            if object["success"]?.boolValue == false { return nil }
            for (key, value) in object { if let text = value.stringValue { fields[key] = text } }
        } else {
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let pair = line.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
        }
        guard let ip = fields["ip"], isAddress(ip) else { return nil }
        let code = [fields["country_code"], fields["loc"], fields["country"]]
            .compactMap { $0?.uppercased() }
            .first { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
        let city = fields["city"].flatMap { $0.isEmpty ? nil : $0 }
        return ExitInfo(ip: ip, countryCode: code, city: city)
    }

    private static func isAddress(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 45 && text.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
    }

    /// Nil when no source answered through `route`: traffic is not getting out.
    public static func lookup(route: FetchRoute, timeout: TimeInterval = 6, sources: [URL] = sources) async -> ExitInfo? {
        let session = SessionFactory.make(route: route, timeout: timeout)
        defer { session.invalidateAndCancel() }
        for url in sources {
            if Task.isCancelled { return nil }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let info = parse(data) else { continue }
            return info
        }
        return nil
    }
}
