import SwiftData
import SwiftUI

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
            guard let id = selectedGroupID else { return true }
            return p.group?.id == id
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
        let showsHeader = selectedGroup.map { !$0.isManual } ?? false
        let showsEmptyState = rows.isEmpty && (!model.searchText.isEmpty || selectedGroupID != nil)
        VStack(spacing: 0) {
            if let group = selectedGroup, showsHeader {
                GroupHeader(group: group)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            ServerTable(rows: rows, profiles: profiles, sortOrder: $sortOrder)
            .overlay {
                ZStack {
                    if showsEmptyState {
                        // On a glass card, so the empty table's row stripes don't run through the text.
                        Group {
                            if !model.searchText.isEmpty {
                                ContentUnavailableView.search
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
        }
        // Only when the header comes or goes, so switching between subscriptions stays instant.
        .animation(.snappy(duration: 0.25), value: showsHeader)
        .safeAreaInset(edge: .bottom) { ConnectionBar() }
        .searchable(text: $model.searchText, prompt: "Search")
        .toolbar { toolbar(model: appModel, latency: latency, isTesting: isTesting, isUpdating: isUpdating) }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(profile: singleSelection)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .navigationTitle(selectedGroup?.name ?? "All Servers")
        #if DEBUG
        .navigationSubtitle("Dev build")
        #endif
        .onChange(of: rows.map(\.id), initial: true) { _, ids in model.visibleProfileIDs = ids }
    }

    private var singleSelection: Profile? {
        guard model.selectedProfileIDs.count == 1, let id = model.selectedProfileIDs.first else { return nil }
        return profiles.first { $0.id == id }
    }

    @ToolbarContentBuilder
    private func toolbar(model: AppModel, latency: LatencyService, isTesting: Bool, isUpdating: Bool) -> some ToolbarContent {
        ToolbarItem {
            Button { model.showAddSheet = true } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a subscription or custom configs (⌘N)")
        }
        ToolbarItem {
            Menu {
                Button("Update without Proxy") { model.updateSelection(viaProxy: false) }
                Button("Update via Proxy") { model.updateSelection(viaProxy: true) }
                    .disabled(!model.connection.isRunning)
            } label: {
                Label("Update", systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: isUpdating)
            }
            .help("Update subscriptions")
        }
        ToolbarItem {
            if isTesting {
                Button { latency.cancel() } label: {
                    Label("Stop Testing", systemImage: "stop.circle")
                }
                .help("Stop testing (\(latency.completed)/\(latency.total))")
            } else {
                Menu {
                    Button("Real Delay") { model.testReal() }
                    Button("Speed Test") { model.testSpeed() }
                    Button("TCP Ping") { model.testTCP() }
                } label: {
                    Label("Test", systemImage: "speedometer")
                } primaryAction: {
                    model.testReal()
                }
                .help("Test delay (⌘T)")
            }
        }
        ToolbarItem {
            Button { model.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Toggle Inspector (⌘I)")
        }
    }
}

/// The table on its own, so that what only it needs (column widths change on every step of a
/// window resize) does not rebuild the whole list view with its toolbar and inspector.
private struct ServerTable: View {
    let rows: [ServerRow]
    let profiles: [Profile]
    @Binding var sortOrder: [KeyPathComparator<ServerRow>]

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns = TableColumnCustomization<ServerRow>()

    var body: some View {
        @Bindable var model = model
        Table(rows, selection: $model.selectedProfileIDs, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("") { row in
                if let flag = row.flag {
                    Text(flag).font(.title3).accessibilityLabel("Flag")
                }
            }
            .width(24)
            .customizationID("flag")

            TableColumn("Name", value: \.displayName) { row in
                let isActive = model.connection.activeServer?.id == row.id
                let tint: Color = model.connection.phase == .connected ? .green : .secondary
                HStack(spacing: 6) {
                    if isActive {
                        Image(systemName: "circle.fill").font(.caption2).foregroundStyle(tint)
                            .accessibilityLabel(model.connection.phase == .connected ? "Active server, connected" : "Active server")
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                    Text(row.displayName).lineLimit(1)
                        .fontWeight(isActive ? .semibold : .regular)
                        .foregroundStyle(isActive ? tint : .primary)
                    if row.hasWarnings {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .accessibilityLabel("Has warnings")
                    }
                    if row.isStale {
                        Text("Removed from subscription").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .animation(.snappy, value: isActive)
                .animation(.smooth, value: model.connection.phase == .connected)
            }
            .customizationID("name")

            TableColumn("Type", value: \.typeSummary) { row in
                Text(row.typeSummary).foregroundStyle(.secondary).lineLimit(1)
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
            .width(min: 70, ideal: 80)
            .customizationID("delay")

            TableColumn("Speed", value: \.speedSortKey) { row in
                SpeedText(row: row, isTesting: model.latency.speedTestingIDs.contains(row.id))
            }
            .width(min: 70, ideal: 80)
            .customizationID("speed")
        }
        // Sideways swipes move the table only when its columns are wider than the list.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { model.activate(profileID: id) }
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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
        }
        // Subscription servers come and go with their subscription; pasted ones are the user's to remove.
        let selected = profiles.filter { ids.contains($0.id) }
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

    var body: some View {
        if isTesting {
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
                linkBadge("Support", systemImage: "bubble.left", url: url, compact: compact)
                    .help("Open support")
            }
            if let url = group.webPageURL.flatMap(URL.init(string:)) {
                linkBadge("Account", systemImage: "person.crop.circle", url: url, compact: compact)
                    .help("Open account page")
            }
            updateStatus(compact: compact)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Small capsule link; the narrow row keeps only the icon.
    private func linkBadge(_ title: String, systemImage: String, url: URL, compact: Bool) -> some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
                .labelStyle(BadgeLabelStyle(iconOnly: compact))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
                .contentShape(.capsule)
        }
        .accessibilityLabel("Open \(title.lowercased()) page")
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
        if total > 0 { parts.append("\(Format.bytes(max(total - used, 0))) left") } else { parts.append("No limit") }
        if let up = group.uploadBytes, let down = group.downloadBytes {
            parts.append("Uploaded \(Format.bytes(up)), downloaded \(Format.bytes(down))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Expiry

    private func expiry(_ date: Date, compact: Bool) -> some View {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        let expired = date <= Date()
        let soon = !expired && days < 7
        let text: String
        if expired { text = "Expired" }
        else if days <= 0 { text = "Expires today" }
        else if compact || days < 60 { text = "\(days) day\(days == 1 ? "" : "s") left" }
        else { text = "Until \(date.formatted(.dateTime.month(.abbreviated).day().year()))" }
        return Label(text, systemImage: expired || soon ? "exclamationmark.circle" : "calendar")
            .labelStyle(CompactLabelStyle())
            .foregroundStyle(expired ? Color.red : (soon ? Color.orange : Color.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
            .help("Expires \(date.formatted(date: .long, time: .omitted))")
    }

    // MARK: Update status

    @ViewBuilder
    private func updateStatus(compact: Bool) -> some View {
        if let error = group.lastUpdateError {
            Label(compact ? "Update failed" : error, systemImage: "exclamationmark.triangle.fill")
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
        var text = "Updated \(updated.formatted(.relative(presentation: .named))) \(group.lastUpdateViaProxy == true ? "via proxy" : "without proxy")"
        if let interval = group.serverIntervalHours { text += " · refreshes every \(interval) h" }
        if group.lastSkippedCount > 0 { text += " · \(group.lastSkippedCount) skipped" }
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
