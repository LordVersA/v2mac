import AppIntents
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
    case global, bypassRegions, direct

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Routing Mode"
    static let caseDisplayRepresentations: [RoutingModeOption: DisplayRepresentation] = [
        .global: "Global", .bypassRegions: "Bypass Regions", .direct: "Direct",
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
    }
}
