import Foundation
import V2MacCore

enum AppPaths {
    /// Debug builds (the "V2MacDev" app) keep their own folder, away from an installed V2Mac.
    #if DEBUG
    static let dataFolderName = "v2mac-dev"
    #else
    static let dataFolderName = "v2mac"
    #endif

    static let dataDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(dataFolderName, isDirectory: true)

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
    var title: String {
        switch self {
        case .never: String(localized: "Never")
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        }
    }
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
        defaults.register(defaults: defaultValues)
        migrateCustomRules()
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: NotificationKind.allCases.map { ($0.key, $0.defaultOn) }))
        if defaults.string(forKey: "speedTestURL") == retiredSpeedURL { defaults.removeObject(forKey: "speedTestURL") }
        // The proxy password used to be kept in the preferences file; it moves to the keychain once.
        if let old = defaults.string(forKey: "proxyPassword"), old.isEmpty || Keychain.set(old, for: .proxyPassword) {
            defaults.removeObject(forKey: "proxyPassword")
        }
        // macOS puts a new menu bar icon at the far left, where a notch hides it first. This is
        // AppKit's own (undocumented) key for a dragged icon, in points from the right edge of
        // the screen; seeding it starts the icon beside the system ones. A position the user
        // chose by ⌘-dragging is already stored here and is left alone.
        let iconPosition = "NSStatusItem Preferred Position Item-0"
        if defaults.object(forKey: iconPosition) == nil { defaults.set(350, forKey: iconPosition) }
    }

    /// Settings a backup carries (spec 12.9): every one with a default, and those the app keeps
    /// without one. Region packs are restored through their service, since they need downloading.
    static var backupKeys: [String] {
        Array(defaultValues.keys) + NotificationKind.allCases.map(\.key)
            + ["routingMode", "tunEnabled", "packUpdateIntervals", "userAgent"] + legacyRuleKeys
    }

    private static var defaultValues: [String: Any] {
        [
            "proxyPort": defaultPort,
            "customRuleList": "[]",
            "ruleProfiles": "[]",
            "activeRuleProfile": "",
            "blockQUIC": false,
            "reconnectOnLaunch": true,
            "warpExit": false,
            "restartOnWakeOrNetwork": true,
            "checkAppUpdates": true,
            "allowLAN": false,
            "proxyUsername": "",
            "systemProxy": false,
            "killSwitch": false,
            "autoUpdateSubscriptions": true,
            "subscriptionUpdateViaProxy": false,
            "defaultIntervalHours": 12,
            "latencyURL": "https://www.gstatic.com/generate_204",
            "latencyTimeout": 8.0,
            "latencyConcurrency": 8,
            "speedTestURL": Prefs.defaultSpeedURL,
            "liveSwitch": true,
            "autoSelectServer": false,
            "switchOnDelay": false,
            "switchDelayMs": 1000,
            "switchOnSlowSpeed": false,
            "switchSpeedKBps": 100,
            "switchSpeedMinutes": 2,
            "tunFailurePolicy": TunFailurePolicy.continueProxy.rawValue,
            "allowInsecure": false,
            "checkExit": true,
            "menuBarCountry": true,
            "menuBarSpeed": false,
            "fragmentEnabled": false,
            "fragmentPackets": FragmentSettings.Packets.tlsHello.rawValue,
            "fragmentLength": FragmentSettings.defaultLength,
            "fragmentInterval": FragmentSettings.defaultInterval,
            "noiseEnabled": false,
            "noisePacket": NoiseSettings.defaultPacket,
            "noiseDelay": NoiseSettings.defaultDelay,
            "dnsEnabled": false,
            "dnsServers": DNSSettings.defaultServers.joined(separator: ", "),
            "dnsQueryStrategy": DNSQueryStrategy.useIP.rawValue,
            "logLevel": XrayLogLevel.warning.rawValue,
            "logConnections": false,
            "countTraffic": true,
        ]
    }

    static var lastCoreUpdateCheck: Date? {
        get { defaults.object(forKey: "lastCoreUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastCoreUpdateCheck") }
    }

    /// Spec 12.8: count traffic for the session and the total.
    static var countTraffic: Bool { defaults.bool(forKey: "countTraffic") }

    static var trafficUsage: TrafficUsage {
        get { defaults.data(forKey: "trafficUsage").flatMap { try? JSONDecoder().decode(TrafficUsage.self, from: $0) } ?? TrafficUsage() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "trafficUsage") }
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
            password: proxyPassword
        )
    }

    /// The registered WARP device, kept in the keychain as JSON (spec 9.10).
    static var warpAccount: WarpAccount? {
        get { Keychain.string(.warpAccount).flatMap { try? JSONDecoder().decode(WarpAccount.self, from: Data($0.utf8)) } }
        set { Keychain.set(newValue.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }, for: .warpAccount) }
    }

    /// The WARP outbound traffic leaves through after the server, when that is on.
    static var warpExit: JSONValue? {
        defaults.bool(forKey: "warpExit") ? warpAccount?.outbound : nil
    }

    /// Kept in the keychain (spec 13).
    static var proxyPassword: String {
        get { Keychain.string(.proxyPassword) ?? "" }
        set { Keychain.set(newValue, for: .proxyPassword) }
    }

    /// An administrator account the user chose to save, so the root helper starts without the
    /// system's prompt (spec 9.5). The password is in the keychain.
    static var adminAccount: (user: String, password: String)? {
        guard let user = defaults.string(forKey: "adminUser"), !user.isEmpty,
              let password = Keychain.string(.adminPassword) else { return nil }
        return (user, password)
    }

    static func setAdminAccount(_ account: (user: String, password: String)?) {
        defaults.set(account?.user, forKey: "adminUser")
        Keychain.set(account?.password, for: .adminPassword)
    }

    /// Spec 9.9: point the system proxy at the local port while connected.
    static var systemProxy: Bool {
        get { defaults.bool(forKey: "systemProxy") }
        set { defaults.set(newValue, forKey: "systemProxy") }
    }

    /// Spec 9.8: block traffic outside the connection while one is wanted.
    static var killSwitch: Bool {
        get { defaults.bool(forKey: "killSwitch") }
        set { defaults.set(newValue, forKey: "killSwitch") }
    }

    /// Changing servers swaps the outbound in the running core instead of restarting it.
    static var liveSwitch: Bool { defaults.bool(forKey: "liveSwitch") }

    static var autoSelectServer: Bool { defaults.bool(forKey: "autoSelectServer") }

    /// Spec 9.7, conditions: switch when two checks in a row answer slower than this (ms).
    static var switchDelayLimit: Int? {
        defaults.bool(forKey: "switchOnDelay") ? max(100, defaults.integer(forKey: "switchDelayMs")) : nil
    }

    /// Spec 9.7, conditions: switch when the download rate stays under `bytesPerSecond` for `minutes`.
    static var switchSpeedFloor: (bytesPerSecond: Double, minutes: Int)? {
        guard defaults.bool(forKey: "switchOnSlowSpeed") else { return nil }
        return (Double(max(1, defaults.integer(forKey: "switchSpeedKBps"))) * 1024, max(1, defaults.integer(forKey: "switchSpeedMinutes")))
    }
    static var tunFailurePolicy: TunFailurePolicy {
        TunFailurePolicy(rawValue: defaults.string(forKey: "tunFailurePolicy") ?? "") ?? .continueProxy
    }

    /// Look up the exit address and place after connecting (spec 9.6).
    static var checkExit: Bool { defaults.bool(forKey: "checkExit") }

    static func notify(_ kind: NotificationKind) -> Bool { defaults.bool(forKey: kind.key) }

    /// What the last expiry or traffic warning was about, per subscription (`UsageAlert.step`).
    static func usageMarker(_ name: String, group: UUID) -> String? {
        (defaults.dictionary(forKey: name) as? [String: String])?[group.uuidString]
    }

    static func setUsageMarker(_ marker: String, _ name: String, group: UUID) {
        var all = (defaults.dictionary(forKey: name) as? [String: String]) ?? [:]
        all[group.uuidString] = marker
        defaults.set(all, forKey: name)
    }

    /// The release tag the last "update available" notification was about.
    static func announcedTag(_ name: String) -> String? { defaults.string(forKey: name) }
    static func setAnnouncedTag(_ tag: String, _ name: String) { defaults.set(tag, forKey: name) }

    /// Servers whose link says `allowInsecure` get the certificate they present pinned (spec 8.5).
    static var allowInsecure: Bool { defaults.bool(forKey: "allowInsecure") }

    /// TLS fragment and noise packets, each only while its switch is on.
    static var dialer: DialerSettings {
        var settings = DialerSettings()
        if defaults.bool(forKey: "fragmentEnabled") {
            settings.fragment = FragmentSettings(
                packets: FragmentSettings.Packets(rawValue: defaults.string(forKey: "fragmentPackets") ?? "") ?? .tlsHello,
                length: defaults.string(forKey: "fragmentLength") ?? "",
                interval: defaults.string(forKey: "fragmentInterval") ?? ""
            )
        }
        if defaults.bool(forKey: "noiseEnabled") {
            settings.noise = NoiseSettings(
                packet: defaults.string(forKey: "noisePacket") ?? "",
                delay: defaults.string(forKey: "noiseDelay") ?? ""
            )
        }
        return settings
    }

    static var dns: DNSSettings? {
        guard defaults.bool(forKey: "dnsEnabled") else { return nil }
        return DNSSettings(
            servers: DNSSettings.servers(from: defaults.string(forKey: "dnsServers") ?? ""),
            queryStrategy: DNSQueryStrategy(rawValue: defaults.string(forKey: "dnsQueryStrategy") ?? "") ?? .useIP
        )
    }

    /// Debug builds listen elsewhere, so they never fight an installed V2Mac for its port.
    #if DEBUG
    static let defaultPort = 10818
    #else
    static let defaultPort = 10808
    #endif

    static var port: Int {
        get { let p = defaults.integer(forKey: "proxyPort"); return p == 0 ? defaultPort : p }
        set { defaults.set(newValue, forKey: "proxyPort") }
    }

    static var activeProfileID: UUID? {
        get { defaults.string(forKey: "activeProfileID").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "activeProfileID") }
    }

    /// Servers a connection came up on, newest first (the menu bar panel's "Recent" list).
    static var recentServerIDs: [UUID] {
        get { (defaults.stringArray(forKey: "recentServerIDs") ?? []).compactMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue.map(\.uuidString), forKey: "recentServerIDs") }
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

    /// Spec 8.6. Keys match `RoutingSettings`.
    static var customRules: CustomRules {
        CustomRules(rules: customRuleList, blockQUIC: defaults.bool(forKey: "blockQUIC"))
    }

    static var customRuleList: [CustomRule] {
        get { CustomRule.decode(defaults.string(forKey: "customRuleList") ?? "[]") }
        set { defaults.set(CustomRule.encode(newValue), forKey: "customRuleList") }
    }

    /// Spec 8.6: named rule sets. The active one's rules live in `customRuleList`; its copy here is
    /// brought up to date when another is chosen. With none saved, the current list is "Default".
    static var ruleProfiles: [RuleProfile] {
        get {
            let saved = RuleProfile.decode(defaults.string(forKey: "ruleProfiles") ?? "[]")
            guard saved.isEmpty else { return saved }
            // Saved at once, so the profile keeps one id.
            let first = [RuleProfile(name: String(localized: "Default"), rules: customRuleList)]
            defaults.set(RuleProfile.encode(first), forKey: "ruleProfiles")
            return first
        }
        set { defaults.set(RuleProfile.encode(newValue), forKey: "ruleProfiles") }
    }

    static var activeRuleProfile: UUID? {
        get { UUID(uuidString: defaults.string(forKey: "activeRuleProfile") ?? "") ?? ruleProfiles.first?.id }
        set { defaults.set(newValue?.uuidString ?? "", forKey: "activeRuleProfile") }
    }

    /// Saves the current rules into the active profile and loads `id`'s.
    static func switchRuleProfile(to id: UUID) {
        var profiles = ruleProfiles
        if let active = profiles.firstIndex(where: { $0.id == activeRuleProfile }) { profiles[active].rules = customRuleList }
        guard let target = profiles.first(where: { $0.id == id }) else { return }
        ruleProfiles = profiles
        activeRuleProfile = id
        customRuleList = target.rules
    }

    /// The Block, Proxy and Direct lists of earlier versions; still read from old backups.
    private static let legacyRuleKeys = ["customRulesProxy", "customRulesDirect", "customRulesBlock"]

    /// The three lists become the ordered list once, in the order they were applied, so nothing changes.
    static func migrateCustomRules() {
        guard legacyRuleKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        let text = legacyRuleKeys.map { defaults.string(forKey: $0) ?? "" }
        customRuleList = CustomRule.migrating(proxy: text[0], direct: text[1], block: text[2])
        legacyRuleKeys.forEach(defaults.removeObject)
    }

    static var enabledRegionPacks: Set<String> {
        get { Set(defaults.stringArray(forKey: "enabledRegionPacks") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "enabledRegionPacks") }
    }

    /// Cloudflare answers 403 to requests of 100 MB or more, so stay well under that.
    static let defaultSpeedURL = "https://speed.cloudflare.com/__down?bytes=50000000"
    /// The old default, which Cloudflare now refuses; a saved copy is dropped on launch.
    static let retiredSpeedURL = "https://speed.cloudflare.com/__down?bytes=100000000"

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
    /// How long a subscription still runs: "Expired", "Expires today", "12 days left" or, with
    /// `long` and two months or more to go, the date. A warning is due within a week, or past.
    static func expiry(_ date: Date, long: Bool) -> (text: String, isExpired: Bool, isWarning: Bool) {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        let expired = date <= Date()
        let text: String
        if expired { text = String(localized: "Expired") }
        else if days <= 0 { text = String(localized: "Expires today") }
        else if !long || days < 60 { text = days == 1 ? String(localized: "1 day left") : String(localized: "\(days) days left") }
        else { text = String(localized: "Until \(date.formatted(.dateTime.month(.abbreviated).day().year()))") }
        return (text, expired, expired || days < 7)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        // Below one kilobyte the formatter says "Zero KB" or switches to bytes, which reads as noise.
        guard bytesPerSecond >= 1024 else { return "0 KB/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }

    /// A rate that keeps its shape while it changes: whole kilobytes below one megabyte, then
    /// always one decimal (`6.0 MB/s`), so a decimal point never comes and goes.
    static func steadyRate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1000 { return String(format: "%.0f KB/s", kb) }
        return String(format: "%.1f MB/s", kb / 1024)
    }

    /// `12.3 MB`, always in megabytes so "received of total" reads consistently.
    static func megabytes(_ value: Int64) -> String {
        String(format: "%.1f MB", Double(value) / 1_048_576)
    }

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .binary, spellsOutZero: false))
    }
}
