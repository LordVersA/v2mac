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
            SubscriptionSettings().tabItem { Label("Servers", systemImage: "tray.and.arrow.down") }.tag(SettingsTab.servers)
            CoreSettings().tabItem { Label("Core", systemImage: "cpu") }.tag(SettingsTab.core)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 560, height: 440)
    }
}
