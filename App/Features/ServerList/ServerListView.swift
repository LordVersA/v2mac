import SwiftData
import SwiftUI
import V2MacCore

struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @Query private var profiles: [Profile]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sortOrder = [KeyPathComparator(\ServerRow.sortIndex)]


    private var selectedGroupID: UUID? {
        if case .group(let id) = model.sidebarSelection { return id }
        return nil
    }

    private var rows: [ServerRow] {
        var items = profiles.filter { p in
            switch model.sidebarSelection {
            case .all: true
            case .favorites: p.isFavorite
            case .group(let id): p.group?.id == id
            }
        }.map(ServerRow.init)

        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            items = items.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.address.localizedCaseInsensitiveContains(query)
                    || $0.typeSummary.localizedCaseInsensitiveContains(query)
            }
        }
        // Stale rows always sort last; otherwise follow the chosen column order.
        var sorted = items.sorted(using: sortOrder)
        // Untested and failed rows stay last whichever way the Delay column is sorted.
        if sortOrder.first?.keyPath == \ServerRow.delaySortKey {
            sorted = sorted.filter { $0.delayState == .ok } + sorted.filter { $0.delayState != .ok }
        }
        return sorted.filter { !$0.isStale } + sorted.filter(\.isStale)
    }

    private var selectedGroup: ServerGroup? {
        selectedGroupID.flatMap { model.group(id: $0) }
    }

    var body: some View {
        @Bindable var model = model
        let rows = rows
        // Resolved here, in the view body: the toolbar builder runs outside the environment.
        let latency = model.latency
        let isTesting = latency.isRunning
        let appModel = model
        let isUpdating = !model.subscriptions.updatingGroupIDs.isEmpty
        // Looked up once: it is a database fetch.
        let selectedGroup = selectedGroup
        let showsHeader = selectedGroup.map { !$0.isManual } ?? false
        let showsFavorites = model.sidebarSelection == .favorites
        let showsEmptyState = rows.isEmpty && (!model.searchText.isEmpty || model.sidebarSelection != .all)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let group = selectedGroup, showsHeader {
                    GroupHeader(group: group)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                else {
                    // Keeps the table from reaching up behind the toolbar, as a subscription's header
                    // does. There it draws a lighter band only as wide as itself, whose end shows as
                    // an edge through the search field when the inspector is open beside it.
                    Color.clear.frame(height: 1)
                }
                ServerTable(rows: rows, profiles: profiles, showsGroup: selectedGroupID == nil, sortOrder: $sortOrder)
                .overlay {
                    ZStack {
                        if showsEmptyState {
                            // On a glass card, so the empty table's row stripes don't run through the text.
                            Group {
                                if !model.searchText.isEmpty {
                                    ContentUnavailableView.search
                                } else if showsFavorites {
                                    ContentUnavailableView(
                                        "No Favorites", systemImage: "star",
                                        description: Text("Right-click a server and choose Add to Favorites.")
                                    )
                                } else if selectedGroup?.isManual == true {
                                    ContentUnavailableView(
                                        "No Custom Configs", systemImage: "doc.on.clipboard",
                                        description: Text("Paste share links or Xray configs with ⌘V.")
                                    )
                                } else {
                                    ContentUnavailableView("No Servers", systemImage: "server.rack")
                                }
                            }
                            .fixedSize()
                            .padding(.horizontal, 36)
                            .padding(.vertical, 28)
                            .glassEffect(.regular, in: .rect(cornerRadius: 28))
                            .transition(.blurReplace)
                        }
                    }
                    .animation(.smooth(duration: 0.25), value: showsEmptyState)
                }
                .overlay(alignment: .bottom) { MissingFavoritesToast(profiles: profiles) }
            }
            // Only when the header comes or goes, so switching between subscriptions stays instant.
            .animation(.snappy(duration: 0.25), value: showsHeader)
            .safeAreaInset(edge: .bottom) { ConnectionBar() }

            // A plain panel, not `.inspector`: with that modifier attached (even hidden) the table
            // re-fits every visible cell several times on each step of a window resize.
            if model.showInspector {
                // No background of its own and the dividing line as an overlay: both would otherwise
                // run up behind the toolbar and show as an edge through the search field.
                InspectorPane(profiles: profiles)
                    .scrollContentBackground(.hidden)
                    .frame(width: 260)
                    .overlay(alignment: .leading) { Divider() }
            }
        }
        .searchable(text: $model.searchText, prompt: "Search")
        .toolbar { toolbar(model: appModel, latency: latency, isTesting: isTesting, isUpdating: isUpdating) }
        .navigationTitle(showsFavorites ? String(localized: "Favorites") : (selectedGroup?.displayName ?? String(localized: "All Servers")))
        #if DEBUG
        .navigationSubtitle("Dev build")
        #endif
        .onChange(of: rows.map(\.id), initial: true) { _, ids in model.visibleProfileIDs = ids }
    }

    @ToolbarContentBuilder
    private func toolbar(model: AppModel, latency: LatencyService, isTesting: Bool, isUpdating: Bool) -> some ToolbarContent {
        if model.updates.availableAppUpdate != nil {
            ToolbarItem {
                UpdateButton()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            Button { model.showAddSheet = true } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a subscription or custom configs (⌘N)")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            ToolbarSplitButton(
                title: "Update", systemImage: "arrow.clockwise", isSpinning: isUpdating,
                help: "Update subscriptions without the proxy (⌘R)", menuHelp: "Choose how to update"
            ) {
                model.updateSelection(viaProxy: false)
            } menu: {
                Button("Update without Proxy") { model.updateSelection(viaProxy: false) }
                Button("Update via Proxy") { model.updateSelection(viaProxy: true) }
                    .disabled(!model.connection.isRunning)
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            // Test stays available while a run goes on: what it asks for is queued after it.
            HStack(spacing: 0) {
                ToolbarSplitButton(
                    title: "Test", systemImage: "speedometer", isSpinning: false,
                    help: isTesting ? "Test delay after the running test (⌘T)" : "Test delay (⌘T)",
                    menuHelp: "Choose a test"
                ) {
                    model.testReal()
                } menu: {
                    Button("Real Delay") { model.testReal() }
                    Button("Speed Test") { model.testSpeed() }
                    Button("TCP Ping") { model.testTCP() }
                }
                if isTesting {
                    Divider().frame(height: 16)
                    StopTestingButton(latency: latency)
                }
            }
        }
        if model.sandbox.pin != nil {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { model.sandbox.open() } label: {
                    Label("Sandbox", systemImage: "shield.lefthalf.filled")
                }
                .help("Open the Secure Sandbox")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button { model.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Toggle Inspector (⌘I)")
        }
    }
}

/// A toolbar button with a menu beside it, laid out by hand so every one of them is identical:
/// the system's own menu indicator sits off-centre and changes size between a plain menu and a
/// split button.
private struct ToolbarSplitButton<MenuContent: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSpinning: Bool
    let help: LocalizedStringKey
    let menuHelp: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .symbolEffect(.rotate, isActive: isSpinning)
                    .frame(width: 33, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(title)
            .help(help)
            Divider().frame(height: 16)
            Menu(content: menu) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .focusable(false)
            // A menu keeps a minimum width of its own; this trims it to the width of the icon half.
            .padding(.horizontal, -1.5)
            .accessibilityLabel(Text("\(Text(title)) options"))
            .help(menuHelp)
        }
        .buttonStyle(.plain)
    }
}

/// Reads the selection itself, so that picking a row does not rebuild (and re-sort) the list.
private struct InspectorPane: View {
    let profiles: [Profile]
    @Environment(AppModel.self) private var model

    var body: some View {
        InspectorView(profile: selection)
    }

    private var selection: Profile? {
        guard model.selectedProfileIDs.count == 1, let id = model.selectedProfileIDs.first else { return nil }
        return profiles.first { $0.id == id }
    }
}

/// Asks what to do with favorites a manual update no longer found in their subscription
/// (spec 6.6). Reads the list of them itself, so that it does not rebuild the server list.
private struct MissingFavoritesToast: View {
    let profiles: [Profile]
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ids = model.missingFavoriteIDs
        // Counted from what is still there: a favorite can be removed by hand while this shows.
        let count = ids.isEmpty ? 0 : profiles.count { ids.contains($0.id) && $0.isFavorite && $0.isStale }
        ZStack {
            if count > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "star.slash.fill").foregroundStyle(.yellow)
                    Text(count == 1
                        ? "1 favorite server is no longer in its subscription."
                        : "\(count) favorite servers are no longer in their subscriptions.")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Keep") { withAnimation { model.resolveMissingFavorites(remove: false) } }
                        .help("Keep them in Favorites")
                    Button("Remove", role: .destructive) { withAnimation { model.resolveMissingFavorites(remove: true) } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help("Remove them from Favorites and from the list")
                }
                .font(.callout)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: count > 0)
    }
}

/// Reads the progress itself: read in the list's toolbar it rebuilt the whole list on every result.
private struct StopTestingButton: View {
    let latency: LatencyService

    var body: some View {
        Button { latency.cancel() } label: {
            Image(systemName: "stop.circle")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 33, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop Testing")
        .help("Stop testing (\(latency.completed)/\(latency.total))")
    }
}

/// The table on its own, so that what only it needs (column widths change on every step of a
/// window resize) does not rebuild the whole list view with its toolbar and inspector.
private struct ServerTable: View {
    let rows: [ServerRow]
    let profiles: [Profile]
    /// In "All" and "Favorites", where rows come from several subscriptions.
    let showsGroup: Bool
    @Binding var sortOrder: [KeyPathComparator<ServerRow>]

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Widths, order and hidden columns, kept across launches.
    @State private var columns = ServerTable.savedColumns()
    @State private var saveTask: Task<Void, Never>?
    private static let columnsKey = "serverTableColumns"

    private static func savedColumns() -> TableColumnCustomization<ServerRow> {
        guard let data = UserDefaults.standard.data(forKey: columnsKey),
              let saved = try? JSONDecoder().decode(TableColumnCustomization<ServerRow>.self, from: data) else { return .init() }
        return saved
    }

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            Table(rows, selection: $model.selectedProfileIDs, sortOrder: $sortOrder, columnCustomization: $columns) {
                TableColumn("Name", value: \.displayName) { row in
                    let isActive = model.connection.activeServer?.id == row.id
                    let tint: Color = model.connection.phase == .connected ? .green : .secondary
                    // A server that did not answer its last test steps back, so the working ones stand out.
                    let isDead = row.delayState == .timeout || row.delayState == .invalid
                    HStack(spacing: 6) {
                        // In the name cell, as an icon in a Finder list: a fixed slot keeps the names aligned.
                        Text(row.flag ?? "").font(.title3).frame(width: 22).accessibilityHidden(true)
                        if isActive {
                            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(tint)
                                .accessibilityLabel(model.connection.phase == .connected ? "Active server, connected" : "Active server")
                                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                        }
                        Text(row.displayName).lineLimit(1)
                            .fontWeight(isActive ? .semibold : .regular)
                            .foregroundStyle(isActive ? AnyShapeStyle(tint) : (isDead ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
                        if row.hasWarnings {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .accessibilityLabel("Has warnings")
                        }
                        if row.isFavorite {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                                .accessibilityLabel("Favorite")
                        }
                        if row.isStale {
                            Text("Removed from subscription").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .animation(.snappy, value: isActive)
                    .animation(.smooth, value: model.connection.phase == .connected)
                }
                .customizationID("name")

                // Always declared and shown or hidden below: a column inside an `if` makes the
                // table give every column its minimum width.
                TableColumn("Subscription", value: \.groupName) { row in
                    GroupTag(name: row.groupName, color: row.groupColor)
                }
                .width(min: 80, ideal: 160)
                .customizationID("group")

                TableColumn("Type", value: \.typeSummary) { row in
                    TypeTags(summary: row.typeSummary)
                }
                .customizationID("type")

                TableColumn("Address", value: \.address) { row in
                    Text(row.address).foregroundStyle(.secondary).lineLimit(1)
                }
                .defaultVisibility(.hidden)
                .customizationID("address")

                TableColumn("Delay", value: \.delaySortKey) { row in
                    DelayText(row: row, isTesting: model.latency.testingIDs.contains(row.id))
                }
                .width(min: 84, ideal: 96)
                .alignment(.trailing)
                .customizationID("delay")

                TableColumn("Speed", value: \.speedSortKey) { row in
                    let live = model.latency.liveSpeed
                    SpeedText(row: row, isTesting: model.latency.speedTestingIDs.contains(row.id),
                              live: live?.id == row.id ? live : nil)
                }
                .width(min: 84, ideal: 96)
                .alignment(.trailing)
                .customizationID("speed")
            }
            .onChange(of: showsGroup, initial: true) {
                columns[visibility: "group"] = showsGroup ? .visible : .hidden
            }
            // A resize changes this on every step, so it is written once the dragging has stopped.
            .onChange(of: columns) {
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled, let data = try? JSONEncoder().encode(columns) else { return }
                    UserDefaults.standard.set(data, forKey: Self.columnsKey)
                }
            }
            // Sideways swipes move the table only when its columns are wider than the list.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                if let id = ids.first { model.activate(profileID: id) }
            }
            .onChange(of: model.revealProfileID) { _, id in
                guard let id else { return }
                model.revealProfileID = nil
                Task {
                    // On the next turn: the table has yet to take the rows of the list just opened.
                    await Task.yield()
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    // Once more when a subscription's header has slid in above the table, which
                    // makes the table shorter and would leave a row near the end behind the bar.
                    try? await Task.sleep(for: .milliseconds(350))
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        if !ids.isEmpty {
            Button(ids.count == 1 ? "Test Delay" : "Test Delay (\(ids.count))") { model.testReal(Array(ids)) }
            Button("Speed Test") { model.testSpeed(Array(ids)) }
            Button("TCP Ping") { model.testTCP(Array(ids)) }
            Divider()
        }
        if let id = ids.first, ids.count == 1 {
            Button("Connect") { model.activate(profileID: id) }
            if let link = profiles.first(where: { $0.id == id })?.originalLink {
                Button("Copy Share Link") {
                    Task {
                        guard await OwnerCheck.confirm(OwnerCheck.shareLinkReason) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                }
            }
        }
        let selected = profiles.filter { ids.contains($0.id) }
        if let only = selected.first, selected.count == 1 {
            Button(only.group?.isManual == true ? "Edit…" : "Edit a Copy…") { model.editServer(only.id) }
            if only.kind == .outbound, let config = only.config, CleanIPScanner.hostName(of: config) != nil {
                Button("Find Clean IP…") { model.cleanIPScan = CleanIPRequest(id: only.id) }
            }
        }
        if !selected.isEmpty {
            // With a mixed selection the rest are added first.
            if selected.allSatisfy(\.isFavorite) {
                Button(ids.count == 1 ? "Remove from Favorites" : "Remove from Favorites (\(ids.count))") { model.setFavorite(ids, false) }
            } else {
                Button(ids.count == 1 ? "Add to Favorites" : "Add to Favorites (\(ids.count))") { model.setFavorite(ids, true) }
            }
        }
        // Subscription servers come and go with their subscription; pasted ones are the user's to remove.
        if !selected.isEmpty, selected.allSatisfy({ $0.group?.isManual == true }) {
            Divider()
            Button(ids.count == 1 ? "Delete" : "Delete (\(ids.count))", role: .destructive) { model.deleteProfiles(ids) }
        }
    }
}

struct DelayText: View {
    let row: ServerRow
    var isTesting = false

    var body: some View {
        if isTesting {
            ProgressView().controlSize(.small)
        } else {
            result
        }
    }

    @ViewBuilder
    private var result: some View {
        switch row.delayState {
        case .untested:
            Text("—").foregroundStyle(.tertiary)
        case .na:
            Text("n/a").foregroundStyle(.tertiary)
        case .timeout:
            Text("timeout").foregroundStyle(.orange)
        case .invalid:
            Text("invalid").foregroundStyle(.red)
        case .ok:
            let ms = row.delayMs ?? 0
            // Bars as well as colour, so the quality reads without relying on colour alone.
            Label {
                Text("\(ms) ms").monospacedDigit().contentTransition(.numericText())
            } icon: {
                Image(systemName: "cellularbars", variableValue: Self.strength(ms))
            }
            .labelStyle(CompactLabelStyle())
            .animation(.snappy, value: ms)
            .help(row.delayKind == "tcp" ? "TCP ping" : "Real delay")
            .foregroundStyle(ms < 300 ? Color.green : (ms < 800 ? Color.orange : Color.red))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ms) milliseconds")
        }
    }

    /// How many of the bars are filled: all under 300 ms, down to one for a very slow server.
    private static func strength(_ ms: Int) -> Double {
        switch ms {
        case ..<150: 1
        case ..<300: 0.75
        case ..<800: 0.5
        default: 0.25
        }
    }
}

struct SpeedText: View {
    let row: ServerRow
    var isTesting = false
    /// Set while this row's download runs, so the speed shows as it is measured.
    var live: LatencyService.LiveSpeed?

    var body: some View {
        if isTesting, let live {
            if let bps = live.bps {
                // Several readings a second: a fixed format in a fixed width, and no animation,
                // so the text changes in place instead of shifting.
                Label {
                    // The widest reading, hidden, holds the width.
                    ZStack(alignment: .trailing) {
                        Text("000.0 MB/s").hidden()
                        Text(Format.steadyRate(bps))
                    }
                    .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.down")
                }
                .labelStyle(CompactLabelStyle())
                .foregroundStyle(.tint)
                .transaction { $0.animation = nil }
                .help("Downloading: current speed")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Testing, \(Format.rate(bps))")
            } else {
                Text("Connecting…").foregroundStyle(.secondary)
            }
        } else if isTesting {
            ProgressView().controlSize(.small)
        } else if let bps = row.speedBps {
            if bps > 0 {
                Text(Format.rate(bps)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: bps)
                    .help("Top stable download speed")
            } else {
                Text("failed").foregroundStyle(.orange)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// "vless · ws · tls" as the protocol in plain text, then transport and security as small tags.
struct TypeTags: View {
    let summary: String

    var body: some View {
        let parts = summary.components(separatedBy: " · ")
        HStack(spacing: 4) {
            Text(parts.first ?? "").foregroundStyle(.secondary)
            ForEach(parts.dropFirst(), id: \.self) { part in
                Text(part)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 4))
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }
}

private struct BadgeLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if !iconOnly { configuration.title }
        }
    }
}

private struct GroupHeader: View {
    let group: ServerGroup

    var body: some View {
        // Falls back to a shorter row instead of wrapping when the column is narrow.
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 14) {
            if let used = group.usedBytes { traffic(used: used, compact: compact) }
            if let expires = group.expiresAt { expiry(expires, compact: compact) }
            Spacer(minLength: 8)
            if let url = group.supportURL.flatMap(URL.init(string:)) {
                linkBadge("Support", systemImage: "bubble.left", url: url, compact: compact, help: "Open support")
            }
            if let url = group.webPageURL.flatMap(URL.init(string:)) {
                linkBadge("Account", systemImage: "person.crop.circle", url: url, compact: compact, help: "Open account page")
            }
            updateStatus(compact: compact)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Small capsule link; the narrow row keeps only the icon.
    private func linkBadge(_ title: LocalizedStringKey, systemImage: String, url: URL, compact: Bool, help: LocalizedStringKey) -> some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
                .labelStyle(BadgeLabelStyle(iconOnly: compact))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
                .contentShape(.capsule)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Traffic

    private func traffic(used: Int64, compact: Bool) -> some View {
        let total = group.totalBytes ?? 0
        let fraction = total > 0 ? min(Double(used) / Double(total), 1) : 0
        let tint: Color = fraction >= 0.9 ? .red : (fraction >= 0.75 ? .orange : .accentColor)
        return HStack(spacing: 8) {
            if total > 0, !compact {
                Gauge(value: fraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(tint)
                    .frame(width: 96)
                    .animation(.smooth, value: fraction)
            }
            Text(total > 0 ? "\(Format.bytes(used)) of \(Format.bytes(total))" : "\(Format.bytes(used)) used")
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: used)
                .foregroundStyle(fraction >= 0.9 ? Color.red : Color.secondary)
        }
        .help(trafficHelp(used: used, total: total))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trafficHelp(used: used, total: total))
    }

    private func trafficHelp(used: Int64, total: Int64) -> String {
        var parts: [String] = []
        if total > 0 { parts.append(String(localized: "\(Format.bytes(max(total - used, 0))) left")) } else { parts.append(String(localized: "No limit")) }
        if let up = group.uploadBytes, let down = group.downloadBytes {
            parts.append(String(localized: "Uploaded \(Format.bytes(up)), downloaded \(Format.bytes(down))"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Expiry

    private func expiry(_ date: Date, compact: Bool) -> some View {
        let state = Format.expiry(date, long: !compact)
        return Label(state.text, systemImage: state.isWarning ? "exclamationmark.circle" : "calendar")
            .labelStyle(CompactLabelStyle())
            .foregroundStyle(state.isExpired ? Color.red : (state.isWarning ? Color.orange : Color.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
            .help("Expires \(date.formatted(date: .long, time: .omitted))")
    }

    // MARK: Update status

    @ViewBuilder
    private func updateStatus(compact: Bool) -> some View {
        if let error = group.lastUpdateError {
            Label(compact ? String(localized: "Update failed") : error, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(CompactLabelStyle())
                .foregroundStyle(.orange)
                .help(error)
        } else if let updated = group.lastUpdatedAt {
            Text(updated.formatted(.relative(presentation: .named)))
                .foregroundStyle(.tertiary)
                .help(updateHelp(updated))
        }
    }

    private func updateHelp(_ updated: Date) -> String {
        let relative = updated.formatted(.relative(presentation: .named))
        var text = group.lastUpdateViaProxy == true ? String(localized: "Updated \(relative) via proxy") : String(localized: "Updated \(relative) without proxy")
        if let interval = group.serverIntervalHours { text += " · " + String(localized: "refreshes every \(interval) h") }
        if group.lastSkippedCount > 0 { text += " · " + String(localized: "\(group.lastSkippedCount) skipped") }
        return text
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}
