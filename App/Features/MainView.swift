import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ServerGroup.sortIndex) private var groups: [ServerGroup]

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
        .sheet(isPresented: Bindable(model.sandbox).showEntrySheet) { SandboxEntrySheet() }
    }
}

/// A glowing icon that shows its text while the pointer is over it; opens Settings to install.
struct UpdateButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var glowStart = Date()
    @State private var closing: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .trailing) {
            // The item is always as wide as the open pill: the toolbar only passes hover and clicks
            // inside an item's frame, and resizing the item made the toolbar jump.
            pillLabel.hidden()
            if hovering {
                pillLabel
                    .glassEffect(.regular, in: .capsule)
                    .background { glow }
                    .contentShape(.capsule)
                    .onTapGesture(perform: open)
                    .onHover(perform: hover)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
            }
            Button(action: open) { icon }
                .buttonStyle(.plain)
                .padding(6)
                .onHover(perform: hover)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Software Update Available")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    /// Room is left on the right for the button's own icon, which stays on top.
    private var pillLabel: some View {
        HStack(spacing: 6) {
            Text("Software Update Available").font(.callout.weight(.medium))
            icon.hidden()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .fixedSize()
    }

    private func open() { model.openSettings(openSettings, tab: .general) }

    /// Closes half a second after the pointer leaves, so moving between the icon and the pill keeps it open.
    private func hover(_ inside: Bool) {
        closing?.cancel()
        if inside {
            guard !hovering else { return }
            glowStart = .now
            withAnimation(.smooth(duration: 0.3)) { hovering = true }
        } else {
            closing = Task {
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.3)) { hovering = false }
            }
        }
    }

    private var icon: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.title3)
            .background {
                // While hovered, the glow moves out to the pill around the whole button.
                Circle()
                    .fill(Self.rainbow)
                    .blur(radius: 5)
                    .opacity(hovering ? 0 : 1)
            }
    }

    /// Blobs of colour drift, swell and flare behind the pill on their own beats, like a sun's surface.
    private var glow: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            // Measured from the hover, not the reference date: huge values wreck the sines' precision.
            let t = context.date.timeIntervalSince(glowStart)
            // Shapes, not a Canvas: the toolbar clips a Canvas to the item's own frame.
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    ForEach(Self.flares.indices, id: \.self) { i in
                        let n = Double(i)
                        let x = size.width * (0.5 + 0.48 * sin(t * (0.35 + 0.07 * n) + n * 1.9))
                        let y = size.height * (0.5 + 0.3 * sin(t * (0.6 + 0.11 * n) + n * 2.7))
                        let r = size.height * (0.4 + 0.15 * sin(t * (0.8 + 0.13 * n) + n))
                        let flare = 0.2 + 0.7 * pow(0.5 + 0.5 * sin(t * (1.1 + 0.23 * n) + n * 3.3), 2)
                        Ellipse()
                            .fill(Self.flares[i].opacity(flare))
                            .frame(width: r * 3.2, height: r * 2)
                            .position(x: x, y: y)
                    }
                }
                .blendMode(.plusLighter)
            }
            .padding(-6)
            .clipShape(.capsule)
            .blur(radius: 8)
        }
    }

    private static let flares: [Color] = [.red, .orange, .yellow, .pink, .orange, .purple, .cyan, .red]

    private static let rainbow = AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
}
