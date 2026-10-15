import AppIntents
import SwiftUI
import WidgetKit

@main
struct V2MacControls: WidgetBundle {
    var body: some Widget {
        ConnectionControl()
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
