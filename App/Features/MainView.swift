import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \ServerGroup.sortIndex) private var groups: [ServerGroup]

    /// Opens Settings on the tab where the update can be installed.
    private func updateButton(_ title: LocalizedStringKey, tab: SettingsTab) -> some View {
        Button(title, systemImage: "arrow.down.circle.fill") {
            model.openSettings(openSettings, tab: tab)
        }
        // Toolbars show only the icon by default.
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
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
                    Text("Add a subscription URL, or paste configs with ⌘V.")
                } actions: {
                    Button("Add Subscription") { model.showAddSheet = true }
                        .buttonStyle(.glassProminent)
                }
            } else {
                ServerListView()
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        // Text fields handle their own paste; this is reached when a list has the focus.
        .onPasteCommand(of: [.plainText]) { _ in model.pasteFromClipboard() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.updates.availableAppUpdate != nil {
                    updateButton("Software Update Available", tab: .general)
                }
                if model.updates.availableCoreUpdate != nil {
                    updateButton("Xray Update Available", tab: .core)
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
