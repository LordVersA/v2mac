import AppIntents
import SwiftData
import V2MacCore

// Actions for Shortcuts, Spotlight and Siri (spec 12.4). The Shortcuts app can give any of
// them a keyboard shortcut that works everywhere.

struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect"
    static let description = IntentDescription("Connects to the server selected in V2Mac.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppDelegate.model, let server = model.connection.activeServer else {
            return .result(dialog: "Choose a server in V2Mac first.")
        }
        model.connection.connectActive()
        return .result(dialog: "Connecting to \(server.name).")
    }
}

struct DisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect"
    static let description = IntentDescription("Stops the V2Mac connection.")

    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.model?.connection.disconnect()
        return .result()
    }
}

struct ToggleConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Connection On or Off"
    static let description = IntentDescription("Connects when V2Mac is off, and disconnects when it is on.")

    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.model?.connection.toggle()
        return .result()
    }
}

struct SetTunModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set TUN Mode"
    static let description = IntentDescription("Routes all traffic on this Mac through the proxy, or only apps that use the local proxy.")

    @Parameter(title: "On") var on: Bool

    static var parameterSummary: some ParameterSummary { Summary("Turn TUN mode \(\.$on)") }

    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.model?.connection.setTunEnabled(on)
        return .result()
    }
}

struct SetSystemProxyIntent: AppIntent {
    static let title: LocalizedStringResource = "Set System Proxy"
    static let description = IntentDescription("Points the system proxy at V2Mac while it is connected, or turns that off.")

    @Parameter(title: "On") var on: Bool

    static var parameterSummary: some ParameterSummary { Summary("Turn the system proxy \(\.$on)") }

    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.model?.connection.setSystemProxyEnabled(on)
        return .result()
    }
}

struct SetKillSwitchIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Kill Switch"
    static let description = IntentDescription("Blocks all traffic outside the V2Mac connection while it is wanted, or turns that off.")

    @Parameter(title: "On") var on: Bool

    static var parameterSummary: some ParameterSummary { Summary("Turn the kill switch \(\.$on)") }

    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.model?.connection.setKillSwitchEnabled(on)
        return .result()
    }
}

enum RoutingModeOption: String, AppEnum {
    case global, bypassRegions, direct, rulesOnly

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Routing Mode"
    static let caseDisplayRepresentations: [RoutingModeOption: DisplayRepresentation] = [
        .global: "Global", .bypassRegions: "Bypass Regions", .direct: "Direct", .rulesOnly: "Rules Only",
    ]
}

struct SetRoutingModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Routing Mode"
    static let description = IntentDescription("Chooses which traffic goes through the proxy.")

    @Parameter(title: "Mode") var mode: RoutingModeOption

    static var parameterSummary: some ParameterSummary { Summary("Set routing mode to \(\.$mode)") }

    @MainActor func perform() async throws -> some IntentResult {
        RoutingMode(rawValue: mode.rawValue).map { AppDelegate.model?.connection.setRoutingMode($0) }
        return .result()
    }
}

struct ConnectionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Connection Status"
    static let description = IntentDescription("Tells whether V2Mac is connected, to which server, and where traffic comes out.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let connection = AppDelegate.model?.connection else { return .result(value: "Off", dialog: "V2Mac is off.") }
        var text: String
        switch connection.phase {
        case .off: text = "Off"
        case .connecting, .switching: text = "Connecting"
        case .connected: text = "Connected to \(connection.activeServer?.name ?? "a server")"
        case .failed(let message): text = "Failed: \(message)"
        }
        if case .known(let exit) = connection.exit { text += ", exit at \(([exit.city, exit.countryCode].compactMap { $0 } + [exit.ip]).joined(separator: ", "))" }
        return .result(value: text, dialog: "\(text).")
    }
}

struct V2MacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleConnectionIntent(), phrases: ["Turn \(.applicationName) on or off", "Toggle \(.applicationName)"],
                    shortTitle: "Connect or Disconnect", systemImageName: "power")
        AppShortcut(intent: ConnectIntent(), phrases: ["Connect \(.applicationName)"], shortTitle: "Connect", systemImageName: "bolt.horizontal.circle")
        AppShortcut(intent: DisconnectIntent(), phrases: ["Disconnect \(.applicationName)"], shortTitle: "Disconnect", systemImageName: "bolt.horizontal.circle.fill")
        AppShortcut(intent: ConnectionStatusIntent(), phrases: ["Is \(.applicationName) connected", "\(.applicationName) status"],
                    shortTitle: "Connection Status", systemImageName: "info.circle")
        AppShortcut(intent: ConnectToServerIntent(), phrases: ["Connect \(.applicationName) to \(\.$server)", "Use \(\.$server) in \(.applicationName)"],
                    shortTitle: "Connect to Server", systemImageName: "server.rack")
        AppShortcut(intent: ConnectToFastestIntent(), phrases: ["Connect \(.applicationName) to the fastest server", "Find the fastest \(.applicationName) server"],
                    shortTitle: "Connect to Fastest", systemImageName: "hare")
        AppShortcut(intent: AddToRuleIntent(), phrases: ["Add to a \(.applicationName) rule"], shortTitle: "Add to Rule", systemImageName: "arrow.triangle.branch")
        AppShortcut(intent: UpdateSubscriptionsIntent(), phrases: ["Update \(.applicationName) subscriptions"],
                    shortTitle: "Update Subscriptions", systemImageName: "arrow.clockwise")
    }
}

// MARK: Servers and groups (spec 12.4)

/// A server in the list, for "Connect to Server" in Shortcuts and Siri, and for Spotlight.
struct ServerEntity: IndexedEntity, Equatable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Server"
    static let defaultQuery = ServerQuery()

    let id: UUID
    let name: String
    let group: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(group)") }

    /// Favorites first, then in list order. Servers a subscription dropped are left out unless they are favorites.
    @MainActor static func all() -> [ServerEntity] {
        let profiles = (try? AppDelegate.model?.context.fetch(FetchDescriptor<Profile>())) ?? []
        return profiles.filter { !$0.isStale || $0.isFavorite }
            .sorted { ($0.isFavorite ? 0 : 1, $0.group?.sortIndex ?? 0, $0.sortIndex) < ($1.isFavorite ? 0 : 1, $1.group?.sortIndex ?? 0, $1.sortIndex) }
            .map { ServerEntity(id: $0.id, name: $0.name, group: $0.group?.displayName ?? "") }
    }
}

struct ServerQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        await MainActor.run { ServerEntity.all().filter { identifiers.contains($0.id) } }
    }

    func entities(matching string: String) async throws -> [ServerEntity] {
        await MainActor.run { ServerEntity.all().filter { $0.name.localizedStandardContains(string) || $0.group.localizedStandardContains(string) } }
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        await MainActor.run { ServerEntity.all() }
    }
}

struct GroupEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Group"
    static let defaultQuery = GroupQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct GroupQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [GroupEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [GroupEntity] {
        await MainActor.run {
            let groups = (try? AppDelegate.model?.context.fetch(FetchDescriptor<ServerGroup>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
            return groups.map { GroupEntity(id: $0.id, name: $0.displayName) }
        }
    }
}

struct ConnectToServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Server"
    static let description = IntentDescription("Makes a server the active one and connects to it.")

    @Parameter(title: "Server") var server: ServerEntity

    static var parameterSummary: some ParameterSummary { Summary("Connect to \(\.$server)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppDelegate.model, model.profile(id: server.id) != nil else {
            return .result(dialog: "That server is no longer in V2Mac.")
        }
        model.activate(profileID: server.id)
        return .result(dialog: "Connecting to \(server.name).")
    }
}

/// What Spotlight runs when a server is picked there: the main window with that server selected.
struct ShowServerIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show Server"
    static let description = IntentDescription("Opens V2Mac with a server selected.")

    @Parameter(title: "Server") var target: ServerEntity

    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.model?.reveal(target.id)
        AppDelegate.model?.windowRequest = .main
        return .result()
    }
}

struct TestDelayIntent: AppIntent {
    static let title: LocalizedStringResource = "Test Server Delay"
    static let description = IntentDescription("Measures the real delay of the servers in a group, or of every server, and returns those that answered, fastest first.")

    @Parameter(title: "Group", description: "Every server when empty.") var group: GroupEntity?

    static var parameterSummary: some ParameterSummary { Summary("Test the servers in \(\.$group)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[ServerEntity]> & ProvidesDialog {
        guard let model = AppDelegate.model else { return .result(value: [], dialog: "V2Mac is not ready.") }
        let results = await model.measureDelays(groupID: group?.id)
        let servers = ServerEntity.all()
        let found = results.compactMap { result in servers.first { $0.id == result.id } }
        guard let best = found.first, let ms = results.first?.ms else {
            return .result(value: [], dialog: "No server answered.")
        }
        return .result(value: found, dialog: "\(found.count) servers answered. The fastest is \(best.name), at \(ms) ms.")
    }
}

struct ConnectToFastestIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Fastest Server"
    static let description = IntentDescription("Measures the servers in a group, or every server, and connects to the one with the lowest real delay.")

    @Parameter(title: "Group", description: "Every server when empty.") var group: GroupEntity?

    static var parameterSummary: some ParameterSummary { Summary("Connect to the fastest server in \(\.$group)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppDelegate.model else { return .result(dialog: "V2Mac is not ready.") }
        guard let best = await model.measureDelays(groupID: group?.id).first, let profile = model.profile(id: best.id) else {
            return .result(dialog: "No server answered.")
        }
        model.activate(profile)
        return .result(dialog: "Connecting to \(profile.name), at \(best.ms) ms.")
    }
}

struct UpdateSubscriptionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Update Subscriptions"
    static let description = IntentDescription("Downloads the server lists of one subscription, or of all of them.")

    @Parameter(title: "Group", description: "Every subscription when empty.") var group: GroupEntity?
    @Parameter(title: "Through the Proxy", default: false) var viaProxy: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Update \(\.$group)") { \.$viaProxy }
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppDelegate.model else { return .result(dialog: "V2Mac is not ready.") }
        if let group { await model.subscriptions.update(groupID: group.id, viaProxy: viaProxy) }
        else { await model.subscriptions.updateAll(viaProxy: viaProxy) }
        let groups = (try? model.context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        let failed = groups.filter { !$0.isManual && (group == nil || $0.id == group?.id) && $0.lastUpdateError != nil }
        if failed.isEmpty { return .result(dialog: "Subscriptions updated.") }
        return .result(dialog: "Could not update \(failed.map(\.displayName).formatted()).")
    }
}

struct GetExitIPIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Exit IP Address"
    static let description = IntentDescription("Returns the public IP address traffic comes out at, as V2Mac last checked it after connecting.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard case .known(let exit) = AppDelegate.model?.connection.exit else {
            return .result(value: "", dialog: "V2Mac does not know the exit address. Connect first.")
        }
        let place = [exit.city, exit.countryCode].compactMap { $0 }.joined(separator: ", ")
        return .result(value: exit.ip, dialog: place.isEmpty ? "\(exit.ip)" : "\(exit.ip), \(place)")
    }
}

struct RuleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Rule"
    static let defaultQuery = RuleQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct RuleQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [RuleEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor func suggestedEntities() async throws -> [RuleEntity] {
        Prefs.rules.map { RuleEntity(id: $0.id, name: $0.name) }
    }
}

/// Adds sites, addresses or apps to a saved rule and applies it at once (spec 8.6).
struct AddToRuleIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Rule"
    static let description = IntentDescription("Adds sites, addresses or apps to one of your rules and applies it.")

    @Parameter(title: "Items", description: "Domains, addresses, geosite: lists or app bundle ids, one per line.") var text: String
    @Parameter(title: "Rule") var rule: RuleEntity

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to \(\.$rule)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let items = Rule.Item.parse(text).items
        guard !items.isEmpty else { return .result(dialog: "Nothing in that text can go in a rule.") }
        guard AppDelegate.model?.rules.addSaved(items, to: rule.id) == true else { return .result(dialog: "That rule is no longer in V2Mac.") }
        return .result(dialog: "Added to \(rule.name).")
    }
}
