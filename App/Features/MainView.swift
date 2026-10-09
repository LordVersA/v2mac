import SwiftData
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \ServerGroup.sortIndex) private var groups: [ServerGroup]

    /// Opens Settings on the tab where the update can be installed.
    private func updateButton(_ title: LocalizedStringKey, tab: SettingsTab) -> some View {
        Button(title, systemImage: "arrow.down.circle.fill") {
            model.openSettings(openSettings, tab: tab)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.blue)
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            if groups.isEmpty {
                ContentUnavailableView {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("No Subscriptions").font(.title2.bold())
                } description: {
                    Text("Add a subscription URL to see its servers.")
                } actions: {
                    Button("Add Subscription") { model.showAddSheet = true }
                        .buttonStyle(.glassProminent)
                }
            } else {
                ServerListView()
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if model.updates.availableAppUpdate != nil {
                    updateButton("Update Available", tab: .general)
                }
                if model.updates.availableCoreUpdate != nil {
                    updateButton("Core Update Available", tab: .core)
                }
            }
        }
        .sheet(isPresented: $model.showAddSheet) {
            AddSubscriptionSheet()
        }
        .sheet(isPresented: $model.showRegionsSheet) {
            RegionPacksView()
        }
    }
}
