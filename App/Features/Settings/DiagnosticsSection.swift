import SwiftUI
import V2MacCore

struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("logLevel") private var level = XrayLogLevel.warning.rawValue
    @AppStorage("logConnections") private var logConnections = false

    var body: some View {
        Section("Diagnostics") {
            Picker("Log level", selection: $level) {
                ForEach([XrayLogLevel.error, .warning, .info, .debug], id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            .onChange(of: level) { model.connection.reconnectIfRunning() }
            Toggle("Log connections", isOn: $logConnections)
                .onChange(of: logConnections) { model.connection.reconnectIfRunning() }
            Button("Show Logs") { model.openLogs(openWindow) }
        }
    }
}
