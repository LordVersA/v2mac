import SwiftUI
import V2MacCore

struct DiagnosticsSection: View {
    static func title(_ level: XrayLogLevel) -> LocalizedStringKey {
        switch level {
        case .none: "None"
        case .error: "Error"
        case .warning: "Warning"
        case .info: "Info"
        case .debug: "Debug"
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("logLevel") private var level = XrayLogLevel.warning.rawValue
    @AppStorage("logConnections") private var logConnections = false

    var body: some View {
        Section("Diagnostics") {
            Picker("Log level", selection: $level) {
                ForEach([XrayLogLevel.error, .warning, .info, .debug], id: \.rawValue) { Text(Self.title($0)).tag($0.rawValue) }
            }
            .onChange(of: level) { model.connection.reconnectIfRunning() }
            Toggle("Log connections", isOn: $logConnections)
                .onChange(of: logConnections) { model.connection.reconnectIfRunning() }
            Button("Show Logs") { model.openLogs(openWindow) }
            // macOS writes app and core crashes here as .ips files; users attach them to an issue.
            Button("Show Crash Reports") {
                NSWorkspace.shared.open(URL.libraryDirectory.appending(path: "Logs/DiagnosticReports", directoryHint: .isDirectory))
            }
        }
    }
}
