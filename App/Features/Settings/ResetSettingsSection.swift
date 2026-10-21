import SwiftUI

/// Spec 13: the last section of a Settings tab. `tab` nil resets every tab.
struct ResetSettingsSection: View {
    @Environment(AppModel.self) private var model
    let tab: SettingsTab?
    /// For a tab that keeps copies of its settings in `@State`.
    var onReset: () -> Void = {}
    @State private var asking = false

    var body: some View {
        Section {
            HStack {
                Spacer()
                Button(tab == nil ? "Reset All Settings…" : "Reset to Defaults…", role: .destructive) { asking = true }
            }
        }
        .confirmationDialog(tab == nil ? "Reset all settings?" : "Reset these settings?", isPresented: $asking) {
            Button(tab == nil ? "Reset All" : "Reset", role: .destructive) {
                model.resetSettings(tab)
                onReset()
            }
        } message: {
            Text(message)
        }
    }

    private var message: LocalizedStringKey {
        switch tab {
        case nil: "Every setting goes back to its default, the proxy username and password are removed and the system proxy and kill switch are turned off. Your servers, subscriptions, rules, WARP account and language are kept."
        case .proxy?: "The settings on this tab go back to their defaults, the proxy username and password are removed and the system proxy is turned off."
        case .connection?: "The settings on this tab go back to their defaults and the kill switch is turned off."
        default: "The settings on this tab go back to their defaults."
        }
    }
}
