import ServiceManagement
import SwiftUI
import V2MacCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ProxySettings().tabItem { Label("Proxy", systemImage: "network") }
            RoutingSettings().tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
            SubscriptionSettings().tabItem { Label("Servers", systemImage: "tray.and.arrow.down") }
            CoreSettings().tabItem { Label("Core", systemImage: "cpu") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
    }
}
