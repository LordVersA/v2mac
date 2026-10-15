import CoreFoundation
import Foundation

/// Spec 12.9. A `.v2m` file: the base64 text of a JSON object with the subscriptions, their
/// servers (so a restore works offline), the pasted configs, favorites and settings.
public struct Backup: Codable, Sendable, Equatable {
    public static let format = "v2mac-backup"
    public static let fileExtension = "v2m"

    public var format = Backup.format
    public var version = 1
    public var app: String
    public var created: Date
    public var groups: [Group]
    public var settings: [String: JSONValue]

    public init(app: String, created: Date = Date(), groups: [Group], settings: [String: JSONValue]) {
        self.app = app
        self.created = created
        self.groups = groups
        self.settings = settings
    }

    public struct Group: Codable, Sendable, Equatable {
        public var name: String
        /// Empty for Custom Configs.
        public var subscriptionURL: String
        public var autoUpdate: Bool
        public var intervalHours: Int?
        public var color: String?
        public var userAgent: String?
        public var servers: [Server]

        public init(name: String, subscriptionURL: String, autoUpdate: Bool, intervalHours: Int?, color: String?,
                    userAgent: String?, servers: [Server]) {
            self.name = name
            self.subscriptionURL = subscriptionURL
            self.autoUpdate = autoUpdate
            self.intervalHours = intervalHours
            self.color = color
            self.userAgent = userAgent
            self.servers = servers
        }
    }

    public struct Server: Codable, Sendable, Equatable {
        public var profile: ParsedProfile
        public var favorite: Bool

        public init(profile: ParsedProfile, favorite: Bool) {
            self.profile = profile
            self.favorite = favorite
        }

        enum CodingKeys: String, CodingKey {
            case name, kind, protocolName, address, port, transport, security, config, link, warnings, favorite
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            profile = ParsedProfile(
                name: try c.decode(String.self, forKey: .name), kind: try c.decode(ProfileKind.self, forKey: .kind),
                protocolName: try c.decode(String.self, forKey: .protocolName), address: try c.decode(String.self, forKey: .address),
                port: try c.decode(Int.self, forKey: .port), transport: try c.decode(String.self, forKey: .transport),
                security: try c.decode(String.self, forKey: .security), config: try c.decode(JSONValue.self, forKey: .config),
                originalLink: try c.decodeIfPresent(String.self, forKey: .link),
                warnings: try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
            )
            favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(profile.name, forKey: .name)
            try c.encode(profile.kind, forKey: .kind)
            try c.encode(profile.protocolName, forKey: .protocolName)
            try c.encode(profile.address, forKey: .address)
            try c.encode(profile.port, forKey: .port)
            try c.encode(profile.transport, forKey: .transport)
            try c.encode(profile.security, forKey: .security)
            try c.encode(profile.config, forKey: .config)
            try c.encodeIfPresent(profile.originalLink, forKey: .link)
            if !profile.warnings.isEmpty { try c.encode(profile.warnings, forKey: .warnings) }
            if favorite { try c.encode(true, forKey: .favorite) }
        }
    }

    public enum ReadError: LocalizedError {
        case notABackup, newerVersion

        public var errorDescription: String? {
            switch self {
            case .notABackup: String(localized: "This is not a V2Mac backup.")
            case .newerVersion: String(localized: "This backup was made by a newer V2Mac. Update V2Mac to restore it.")
            }
        }
    }

    /// The file's contents.
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self).base64EncodedData(options: [.lineLength76Characters, .endLineWithLineFeed])
    }

    public static func read(_ data: Data) throws -> Backup {
        guard let json = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else { throw ReadError.notABackup }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The format and version first, so a newer file says so instead of failing to decode.
        struct Head: Decodable { let format: String; let version: Int }
        guard let head = try? decoder.decode(Head.self, from: json), head.format == format else { throw ReadError.notABackup }
        guard head.version <= 1 else { throw ReadError.newerVersion }
        do { return try decoder.decode(Backup.self, from: json) } catch { throw ReadError.notABackup }
    }

    // MARK: Settings

    /// A preferences value as JSON: booleans, numbers, strings, and lists and dictionaries of them.
    public static func json(fromPreference value: Any) -> JSONValue? {
        switch value {
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: .string(string)
        case let list as [Any]: .array(list.compactMap(json(fromPreference:)))
        case let dictionary as [String: Any]: .object(dictionary.compactMapValues(json(fromPreference:)))
        default: nil
        }
    }

    /// The other way: whole numbers come back as `Int`, so `integer(forKey:)` reads them.
    public static func preference(from value: JSONValue) -> Any? {
        switch value {
        case .bool(let bool): bool
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? Int(number) : number
        case .string(let string): string
        case .array(let list): list.compactMap(preference(from:))
        case .object(let dictionary): dictionary.compactMapValues(preference(from:))
        case .null: nil
        }
    }
}

