import SwiftUI
import V2MacCore

/// This session's and the total traffic, shown when the usage in the bar or the menu bar
/// panel is clicked (spec 12.8).
struct UsageDetails: View {
    let connection: ConnectionController

    var body: some View {
        let usage = connection.usage
        VStack(alignment: .leading, spacing: 12) {
            section("This Session", up: usage.sessionUp, down: usage.sessionDown,
                    note: usage.sessionStart.map { String(localized: "Since \($0.formatted(date: .abbreviated, time: .shortened))") })
            Divider()
            section("Total", up: usage.totalUp, down: usage.totalDown,
                    note: usage.totalSince.map { String(localized: "Since \($0.formatted(date: .abbreviated, time: .omitted))") })
            Button("Reset Total") { connection.resetTotalUsage() }
                .controlSize(.small)
                .disabled(usage.total == 0)
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
    }

    private func section(_ title: LocalizedStringKey, up: Int64, down: Int64, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(Format.bytes(up + down)).font(.headline.monospacedDigit())
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Label("Downloaded", systemImage: "arrow.down")
                    Text(Format.bytes(down)).monospacedDigit().gridColumnAlignment(.trailing)
                }
                GridRow {
                    Label("Uploaded", systemImage: "arrow.up")
                    Text(Format.bytes(up)).monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

/// "1.2 GB" for this session, which opens `UsageDetails` when clicked.
struct SessionUsageButton: View {
    let connection: ConnectionController
    var showsTitle = false
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 4) {
                if showsTitle { Text("This session") }
                Label(Format.bytes(connection.usage.session), systemImage: "chart.bar")
                    .contentTransition(.numericText())
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Traffic this session. Click for details and the total.")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { UsageDetails(connection: connection) }
    }
}
