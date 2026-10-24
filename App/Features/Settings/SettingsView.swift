import ServiceManagement
import SwiftUI
import V2MacCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ProxySettings().tabItem { Label("Proxy", systemImage: "network") }.tag(SettingsTab.proxy)
            RoutingSettings().tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }.tag(SettingsTab.routing)
            ConnectionSettings().tabItem { Label("Connection", systemImage: "bolt.horizontal") }.tag(SettingsTab.connection)
            WarpSettings().tabItem { Label("WARP", systemImage: "cloud") }.tag(SettingsTab.warp)
            SubscriptionSettings().tabItem { Label("Servers", systemImage: "tray.and.arrow.down") }.tag(SettingsTab.servers)
            if model.sandbox.pin != nil {
                SandboxSettings().tabItem { Label("Sandbox (beta)", systemImage: "shield.lefthalf.filled") }.tag(SettingsTab.sandbox)
            }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }.tag(SettingsTab.notifications)
            CoreSettings().tabItem { Label("Core", systemImage: "cpu") }.tag(SettingsTab.core)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        // Narrower, some tabs go to an overflow menu; Russian tab names need more room than the others.
        .frame(width: (Bundle.main.preferredLocalizations.first == "ru" ? 780 : 630) + (model.sandbox.pin != nil ? 90 : 0), height: 440)
    }
}
