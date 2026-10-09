import SwiftUI

/// Core output and app events, in memory only (spec 9.4 "Show Logs").
struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var problemsOnly = false
    @State private var follow = true

    private var lines: [(id: Int, text: String)] {
        let all = model.logs.lines.enumerated().map { (id: $0.offset, text: $0.element) }
        return all.filter { line in
            (!problemsOnly || Self.severity(line.text) != nil)
                && (filter.isEmpty || line.text.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(lines, id: \.id) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Self.color(for: line.text))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: model.logs.lines.count) {
                    if follow, let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 280)
        .searchable(text: $filter, prompt: "Filter")
        .toolbar {
            ToolbarItemGroup {
                Toggle("Warnings and Errors Only", systemImage: "exclamationmark.triangle", isOn: $problemsOnly)
                    .help("Show only warnings and errors")
                Toggle("Follow", systemImage: "arrow.down.to.line", isOn: $follow)
                    .help("Keep the newest line in view")
            }
            ToolbarItemGroup {
                Button("Copy", systemImage: "doc.on.doc") { copy() }
                Button("Clear", systemImage: "trash") { model.logs.clear() }
            }
        }
        .overlay {
            if model.logs.lines.isEmpty {
                ContentUnavailableView("No Log Output", systemImage: "text.alignleft",
                                       description: Text("Core output appears here while it runs."))
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
    }

    private static func severity(_ line: String) -> Severity? {
        let lower = line.lowercased()
        if lower.contains("[error]") || lower.contains("failed") { return .error }
        if lower.contains("[warning]") { return .warning }
        return nil
    }

    private enum Severity { case warning, error }

    private static func color(for line: String) -> Color {
        switch severity(line) {
        case .error: .red
        case .warning: .orange
        case nil: line.hasPrefix("[v2mac]") ? .secondary : .primary
        }
    }
}

/// Failure follow-ups shared by the connection bar and the menu bar panel.
struct FailureActions: View {
    let connection: ConnectionController
    let showLogs: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let conflict = connection.portConflict {
                Button("Use \(conflict.suggested)") { connection.useSuggestedPort() }
                    .controlSize(.small)
            }
            Button("Show Logs", action: showLogs)
                .controlSize(.small)
        }
    }
}
