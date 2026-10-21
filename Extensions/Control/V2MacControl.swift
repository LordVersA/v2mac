import AppIntents
import SwiftUI
import WidgetKit

@main
struct V2MacControls: WidgetBundle {
    var body: some Widget {
        ConnectionControl()
        StatusWidget()
    }
}

/// Spec 12.4: a switch for Control Center and the menu bar, with the V2Mac glyph.
struct ConnectionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlBridge.kind, provider: Provider()) { isOn in
            ControlWidgetToggle("V2Mac", isOn: isOn, action: SetConnectionIntent()) { on in
                Label(on ? "Connected" : "Off", image: "v2mac.glyph")
            }
        }
        .displayName("V2Mac")
        .description("Connect or disconnect V2Mac.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool { ControlBridge.isConnected }
    }
}

/// Spec 12.4: a desktop and Notification Center widget with the state, the server, the exit and a
/// switch. The app reloads it on every change, so it never asks for a refresh itself.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ControlBridge.widgetKind, provider: Provider()) { entry in
            StatusView(status: entry.status)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("V2Mac")
        .description("Shows the connection and turns it on or off.")
        .supportedFamilies([.systemSmall])
    }

    struct Entry: TimelineEntry {
        var date = Date()
        var status: ControlBridge.Status
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry(status: .init(phase: .connected, server: "🇩🇪 Frankfurt 1", exit: "🇩🇪 Frankfurt"))
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(context.isPreview ? placeholder(in: context) : Entry(status: ControlBridge.status))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(status: ControlBridge.status)], policy: .never))
        }
    }
}

struct StatusView: View {
    let status: ControlBridge.Status

    private var isOn: Bool { status.phase == .connecting || status.phase == .connected }

    private var title: LocalizedStringKey {
        switch status.phase {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Failed"
        }
    }

    private var tint: Color {
        switch status.phase {
        case .off: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image("v2mac.glyph").font(.title2).foregroundStyle(tint)
                Spacer()
                Button(intent: SetConnectionIntent(value: !isOn)) {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(isOn ? .green : .gray)
                .accessibilityLabel(isOn ? "Disconnect" : "Connect")
            }
            Spacer(minLength: 0)
            Text(title).font(.headline).foregroundStyle(tint)
            if !status.server.isEmpty {
                Text(status.server).font(.subheadline).lineLimit(2)
            }
            if !status.exit.isEmpty {
                Text(status.exit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
