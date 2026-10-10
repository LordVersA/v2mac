import SwiftData
import SwiftUI

@main
struct V2MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel())
    }

    private var exitCountry: String? {
        if case .known(let exit) = model.connection.exit { return exit.countryCode }
        return nil
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
                .modelContainer(model.container)
        } label: {
            MenuBarIcon(phase: model.connection.phase, countryCode: exitCountry)
                .background(WindowRequestHandler(model: model))
        }
        .menuBarExtraStyle(.window)

        Window("V2Mac", id: "main") {
            MainView()
                .environment(model)
                .modelContainer(model.container)
        }
        .defaultSize(width: 980, height: 620)
        .defaultLaunchBehavior(.presented)
        .commands { AppCommands(model: model) }

        Window("Logs", id: "logs") {
            LogView()
                .environment(model)
        }
        .defaultSize(width: 760, height: 460)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(model)
                .modelContainer(model.container)
        }
    }
}

/// Opens the window a notification click asked for. It lives in the menu bar label, the one
/// view that exists whichever windows are open.
struct WindowRequestHandler: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .onChange(of: model.windowRequest) { _, request in
                guard let request else { return }
                model.windowRequest = nil
                switch request {
                case .main: model.openMainWindow(openWindow)
                case .settings(let tab): model.openSettings(openSettings, tab: tab)
                }
            }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Subscription or Config…") { model.showAddSheet = true }
                .keyboardShortcut("n")
        }
        CommandMenu("Subscriptions") {
            Button("Update without Proxy") { model.updateSelection(viaProxy: false) }
                .keyboardShortcut("r")
            Button("Update via Proxy") { model.updateSelection(viaProxy: true) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!model.connection.isRunning)
        }
        CommandMenu("Servers") {
            Button("Test Real Delay") { model.testReal() }
                .keyboardShortcut("t")
            Button("Speed Test") { model.testSpeed() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("TCP Ping") { model.testTCP() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Stop Testing") { model.latency.cancel() }
                .disabled(!model.latency.isRunning)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show Logs") { model.openLogs(openWindow) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") {
                model.showInspector.toggle()
            }
            .keyboardShortcut("i")
        }
    }
}
