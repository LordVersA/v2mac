import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \ServerGroup.sortIndex) private var groups: [ServerGroup]

    /// Opens Settings on the tab where the update can be installed.
    private func updateButton(_ title: LocalizedStringKey, tab: SettingsTab) -> some View {
        Button {
            model.openSettings(openSettings, tab: tab)
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .background {
                    Circle()
                        .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .blur(radius: 5)
                }
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private func profile(for request: ServerEditorRequest) -> Profile? {
        switch request.target {
        case .new: nil
        case .edit(let id), .copy(let id): model.profile(id: id)
        }
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
        .onPasteCommand(of: [.plainText, .image]) { _ in model.pasteFromClipboard() }
        // Config files, pictures of QR codes, and links dragged from a browser.
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { url.isFileURL ? model.importFile(url) : model.importText(url.absoluteString) }
            return !urls.isEmpty
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.updates.availableAppUpdate != nil {
                    updateButton("Software Update Available", tab: .general)
                }
            }
        }
        .sheet(isPresented: $model.showAddSheet) {
            if model.opensEditorAfterAddSheet {
                model.opensEditorAfterAddSheet = false
                model.serverEditor = ServerEditorRequest(target: .new)
            }
        } content: {
            AddSubscriptionSheet()
        }
        .alert("Could not save changes", isPresented: Binding { model.saveError != nil } set: { if !$0 { model.saveError = nil } }) {
            Button("OK") {}
        } message: {
            Text("They will be lost when V2Mac quits. \(model.saveError ?? "")")
        }
        .sheet(item: $model.cleanIPScan) { CleanIPSheet(profileID: $0.id) }
        .sheet(item: $model.serverEditor) { request in
            ServerEditorSheet(request: request, profile: profile(for: request))
        }
        .sheet(isPresented: $model.showRegionsSheet) {
            RegionPacksView()
        }
    }
}
