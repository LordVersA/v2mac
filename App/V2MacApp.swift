import SwiftData
import SwiftUI

@main
struct V2MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
                .modelContainer(model.container)
        } label: {
            MenuBarIcon(phase: model.connection.phase)
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

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Subscription…") { model.showAddSheet = true }
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
