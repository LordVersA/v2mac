import SwiftData
import SwiftUI

struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @Query private var profiles: [Profile]

    @State private var sortOrder = [KeyPathComparator(\ServerRow.sortIndex)]
    @State private var columns = TableColumnCustomization<ServerRow>()

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
        VStack(spacing: 0) {
            if let group = selectedGroup { GroupHeader(group: group) }
            Table(rows, selection: $model.selectedProfileIDs, sortOrder: $sortOrder, columnCustomization: $columns) {
                TableColumn("") { row in
                    ActiveMarker(
                        isActive: model.connection.activeServer?.id == row.id,
                        isConnected: model.connection.phase == .connected
                    )
                }
                .width(14)
                .customizationID("active")

                TableColumn("") { row in
                    if let flag = row.flag {
                        Text(flag).font(.system(size: 15)).accessibilityLabel("Flag")
                    }
                }
                .width(24)
                .customizationID("flag")

                TableColumn("Name", value: \.displayName) { row in
                    HStack(spacing: 6) {
                        Text(row.displayName).lineLimit(1)
                        if row.hasWarnings {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .accessibilityLabel("Has warnings")
                        }
                        if row.isStale {
                            Text("Removed from subscription").font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                if let id = ids.first { model.activate(profileID: id) }
            }
            .overlay {
                if rows.isEmpty {
                    if !model.searchText.isEmpty {
                        ContentUnavailableView.search
                    } else if selectedGroupID != nil {
                        ContentUnavailableView("No Servers", systemImage: "server.rack")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { ConnectionBar() }
        .searchable(text: $model.searchText, prompt: "Search")
        .toolbar { toolbar(model: appModel, latency: latency, isTesting: isTesting) }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(profile: singleSelection)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .navigationTitle(selectedGroup?.name ?? "All Servers")
        .onChange(of: rows.map(\.id), initial: true) { _, ids in model.visibleProfileIDs = ids }
    }

    private var singleSelection: Profile? {
        guard model.selectedProfileIDs.count == 1, let id = model.selectedProfileIDs.first else { return nil }
        return profiles.first { $0.id == id }
    }

    @ToolbarContentBuilder
    private func toolbar(model: AppModel, latency: LatencyService, isTesting: Bool) -> some ToolbarContent {
        ToolbarItem {
            Button { model.showAddSheet = true } label: {
                Label("Add Subscription", systemImage: "plus")
            }
            .help("Add Subscription (⌘N)")
        }
        ToolbarItem {
            Menu {
                Button("Update without Proxy") { model.updateSelection(viaProxy: false) }
                Button("Update via Proxy") { model.updateSelection(viaProxy: true) }
                    .disabled(!model.connection.isRunning)
            } label: {
                Label("Update", systemImage: "arrow.clockwise")
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
    }
}

/// Takes plain values: table cells do not reliably receive environment objects.
private struct ActiveMarker: View {
    let isActive: Bool
    let isConnected: Bool

    var body: some View {
        if isActive {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(isConnected ? Color.green : Color.secondary)
                .accessibilityLabel(isConnected ? "Active server, connected" : "Active server")
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
                Text("\(ms) ms").monospacedDigit()
            } icon: {
                Image(systemName: "cellularbars", variableValue: Self.strength(ms))
            }
            .labelStyle(CompactLabelStyle())
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
                Text(Format.rate(bps)).monospacedDigit().help("Top stable download speed")
            } else {
                Text("failed").foregroundStyle(.orange)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
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
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 14) {
            if let used = group.usedBytes { traffic(used: used, compact: compact) }
            if let expires = group.expiresAt { expiry(expires, compact: compact) }
            Spacer(minLength: 8)
            if let url = group.supportURL.flatMap(URL.init(string:)) {
                Link(destination: url) { Image(systemName: "bubble.left") }
                    .help("Support")
                    .accessibilityLabel("Open support")
            }
            if let url = group.webPageURL.flatMap(URL.init(string:)) {
                Link(destination: url) { Image(systemName: "person.crop.circle") }
                    .help("Account page")
                    .accessibilityLabel("Open account page")
            }
            updateStatus(compact: compact)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Traffic

    private func traffic(used: Int64, compact: Bool) -> some View {
        let total = group.totalBytes ?? 0
        let fraction = total > 0 ? min(Double(used) / Double(total), 1) : 0
        let tint: Color = fraction >= 0.9 ? .red : (fraction >= 0.75 ? .orange : .accentColor)
        return HStack(spacing: 8) {
            if total > 0, !compact {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 64, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: max(4, 64 * fraction), height: 4)
                    }
            }
            Text(total > 0 ? "\(Format.bytes(used)) of \(Format.bytes(total))" : "\(Format.bytes(used)) used")
                .monospacedDigit()
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
