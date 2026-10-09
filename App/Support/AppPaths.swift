import Foundation
import V2MacCore

enum AppPaths {
    static let dataDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("v2mac", isDirectory: true)

    static var assetsDirectory: URL { dataDirectory.appendingPathComponent("assets", isDirectory: true) }
    static var runDirectory: URL { dataDirectory.appendingPathComponent("run", isDirectory: true) }
    static var coreDirectory: URL { dataDirectory.appendingPathComponent("core", isDirectory: true) }
    static var storeURL: URL { dataDirectory.appendingPathComponent("default.store") }

    static var bundledCore: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/xray")
    }

    /// An in-app updated core wins over the bundled one.
    static var coreExecutable: URL {
        let override = coreDirectory.appendingPathComponent("xray")
        return FileManager.default.isExecutableFile(atPath: override.path) ? override : bundledCore
    }

    /// Creates the data directories (0700) and links the bundled geo files into `assets/`.
    static func prepare() {
        let fm = FileManager.default
        for dir in [dataDirectory, assetsDirectory, runDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)

        guard let resources = Bundle.main.resourceURL else { return }
        for name in ["geoip.dat", "geosite.dat"] {
            let link = assetsDirectory.appendingPathComponent(name)
            let target = resources.appendingPathComponent(name)
            let type = (try? fm.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType
            switch type {
            case .typeSymbolicLink:
                try? fm.removeItem(at: link)
                try? fm.createSymbolicLink(at: link, withDestinationURL: target)
            case nil:
                try? fm.createSymbolicLink(at: link, withDestinationURL: target)
            default:
                break // a regular file is an updated copy installed by the core updater
            }
        }
    }
}

enum PackUpdateInterval: String, CaseIterable, Identifiable {
    case never, daily, weekly
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Seconds between automatic updates, nil for never.
    var seconds: TimeInterval? {
        switch self {
        case .never: nil
        case .daily: 24 * 3600
        case .weekly: 7 * 24 * 3600
        }
    }
}

enum Prefs {
    private static var defaults: UserDefaults { .standard }

    /// Spec 13 defaults. Registered so `@AppStorage` in Settings and these getters agree.
    static func registerDefaults() {
        defaults.register(defaults: [
            "proxyPort": 10808,
            "reconnectOnLaunch": true,
            "restartOnWakeOrNetwork": true,
            "checkAppUpdates": true,
            "allowLAN": false,
            "proxyUsername": "",
            "proxyPassword": "",
            "autoUpdateSubscriptions": true,
            "subscriptionUpdateViaProxy": false,
            "defaultIntervalHours": 12,
            "latencyURL": "https://www.gstatic.com/generate_204",
            "latencyTimeout": 8.0,
            "latencyConcurrency": 8,
            "speedTestURL": Prefs.defaultSpeedURL,
            "logLevel": XrayLogLevel.warning.rawValue,
            "logConnections": false,
        ])
    }

    static var lastAppUpdateCheck: Date? {
        get { defaults.object(forKey: "lastAppUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastAppUpdateCheck") }
    }

    /// Per-pack auto-update interval (spec 11.2); weekly unless changed.
    static func packUpdateInterval(_ id: String) -> PackUpdateInterval {
        let raw = (defaults.dictionary(forKey: "packUpdateIntervals") as? [String: String])?[id]
        return raw.flatMap(PackUpdateInterval.init(rawValue:)) ?? .weekly
    }

    static func setPackUpdateInterval(_ interval: PackUpdateInterval, for id: String) {
        var all = (defaults.dictionary(forKey: "packUpdateIntervals") as? [String: String]) ?? [:]
        all[id] = interval.rawValue
        defaults.set(all, forKey: "packUpdateIntervals")
    }

    static var reconnectOnLaunch: Bool { defaults.bool(forKey: "reconnectOnLaunch") }
    static var restartOnWakeOrNetwork: Bool { defaults.bool(forKey: "restartOnWakeOrNetwork") }
    static var autoUpdateSubscriptions: Bool { defaults.bool(forKey: "autoUpdateSubscriptions") }
    static var subscriptionUpdateViaProxy: Bool { defaults.bool(forKey: "subscriptionUpdateViaProxy") }
    static var defaultIntervalHours: Int { max(1, defaults.integer(forKey: "defaultIntervalHours")) }

    static var logLevel: XrayLogLevel {
        XrayLogLevel(rawValue: defaults.string(forKey: "logLevel") ?? "") ?? .warning
    }

    /// Port, LAN and credentials as the core should listen.
    static var inbound: InboundSettings {
        InboundSettings(
            port: port,
            allowLAN: defaults.bool(forKey: "allowLAN"),
            username: defaults.string(forKey: "proxyUsername"),
            password: defaults.string(forKey: "proxyPassword")
        )
    }

    static var port: Int {
        get { let p = defaults.integer(forKey: "proxyPort"); return p == 0 ? 10808 : p }
        set { defaults.set(newValue, forKey: "proxyPort") }
    }

    static var activeProfileID: UUID? {
        get { defaults.string(forKey: "activeProfileID").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "activeProfileID") }
    }

    static var wasRunning: Bool {
        get { defaults.bool(forKey: "wasRunning") }
        set { defaults.set(newValue, forKey: "wasRunning") }
    }

    static var logConnections: Bool {
        get { defaults.bool(forKey: "logConnections") }
        set { defaults.set(newValue, forKey: "logConnections") }
    }

    static var tunEnabled: Bool {
        get { defaults.bool(forKey: "tunEnabled") }
        set { defaults.set(newValue, forKey: "tunEnabled") }
    }

    static var routingMode: RoutingMode {
        get { RoutingMode(rawValue: defaults.string(forKey: "routingMode") ?? "") ?? .global }
        set { defaults.set(newValue.rawValue, forKey: "routingMode") }
    }

    static var enabledRegionPacks: Set<String> {
        get { Set(defaults.stringArray(forKey: "enabledRegionPacks") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "enabledRegionPacks") }
    }

    static let defaultSpeedURL = "https://speed.cloudflare.com/__down?bytes=100000000"

    static var speedURL: URL {
        defaults.string(forKey: "speedTestURL").flatMap(URL.init(string:)) ?? URL(string: defaultSpeedURL)!
    }

    static var latencyOptions: LatencyOptions {
        let url = defaults.string(forKey: "latencyURL").flatMap(URL.init(string:))
            ?? URL(string: "https://www.gstatic.com/generate_204")!
        let timeout = defaults.double(forKey: "latencyTimeout")
        let concurrency = defaults.integer(forKey: "latencyConcurrency")
        return LatencyOptions(url: url, timeout: timeout > 0 ? timeout : 8, concurrency: concurrency > 0 ? concurrency : 8)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var userAgent: String {
        get { defaults.string(forKey: "userAgent") ?? "v2mac/\(appVersion)" }
        set { defaults.set(newValue, forKey: "userAgent") }
    }
}

enum Format {
    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
}
