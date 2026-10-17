import SwiftUI
import V2MacCore

struct CleanIPRequest: Identifiable {
    let id: UUID
}

/// Scans Cloudflare addresses for a server behind its CDN and adds the server at the chosen
/// one to Custom Configs (spec 10.4). The original server is left as it is.
struct CleanIPSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID
    @State private var phase: CleanIPScanner.Phase?
    @State private var results: [CleanIPScanner.Candidate]?
    @State private var selection: String?
    @State private var addError: String?

    private static let sampleSize = 200
    private static let keep = 16

    var body: some View {
        let profile = model.profile(id: profileID)
        VStack(alignment: .leading, spacing: 16) {
            Text("Find Clean IP").font(.title2.weight(.semibold))
            Text("Pings \(Self.sampleSize) random Cloudflare addresses on port \(String(profile?.port ?? 0)), then tries the fastest \(Self.keep) as \(profile?.name ?? ""). The server's name stays as SNI and Host.")
                .font(.callout).foregroundStyle(.secondary)
            if let results {
                if results.isEmpty {
                    Label("No address answered. Your network may block Cloudflare, or the server is not behind it.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                } else {
                    Table(results, selection: $selection) {
                        TableColumn("Address") { Text($0.ip).monospacedDigit() }
                        TableColumn("Ping") { Text("\($0.tcpMs) ms").monospacedDigit() }.width(70)
                        TableColumn("Delay") { candidate in
                            if let ms = candidate.realMs { Text("\(ms) ms").monospacedDigit() } else { Text("No answer").foregroundStyle(.red) }
                        }
                        .width(90)
                    }
                    if results.allSatisfy({ $0.realMs == nil }) {
                        Label("None got through the server. It may be down, or its name may be blocked: Find Settings under TLS fragment can help with that.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            } else {
                Spacer()
                switch phase {
                case .pinging(let done, let total)?:
                    ProgressView("Pinging addresses… \(done) of \(total)", value: Double(done), total: Double(max(total, 1)))
                case .testing(let done, let total)?:
                    ProgressView("Trying the fastest through the server… \(done) of \(total)", value: Double(done), total: Double(max(total, 1)))
                case nil:
                    ProgressView()
                }
                Spacer()
            }
            if let addError {
                Text(addError).font(.callout).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Spacer()
                Button(results == nil ? "Cancel" : "Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add as New Server") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen?.realMs == nil)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
        .task { await scan() }
    }

    private var chosen: CleanIPScanner.Candidate? { results?.first { $0.ip == selection } }

    private func scan() async {
        guard let profile = model.profile(id: profileID), let config = profile.config else { results = []; return }
        let addresses = CleanIPScanner.sample(Self.sampleSize)
        await model.latency.beforeTesting(addresses)
        let found = await CleanIPScanner.scan(
            config, port: profile.port, addresses: addresses, keep: Self.keep,
            interface: model.latency.physicalInterface(), tester: model.latency.tester(options: Prefs.latencyOptions)
        ) { phase in
            await MainActor.run { self.phase = phase }
        }
        guard !Task.isCancelled else { return }
        results = found
        selection = found.first { $0.realMs != nil }?.ip
        #if DEBUG
        print("[v2mac-debug] clean ip:", found.prefix(5).map { "\($0.ip) \($0.tcpMs)/\($0.realMs.map(String.init) ?? "-")" }.joined(separator: ", "))
        #endif
    }

    private func add() {
        guard let profile = model.profile(id: profileID), let config = profile.config, let chosen,
              let name = CleanIPScanner.hostName(of: config) else { return }
        let parsed = ParsedProfile(
            name: "\(profile.name) · \(chosen.ip)", kind: .outbound, protocolName: profile.protocolName,
            address: chosen.ip, port: profile.port, transport: profile.transport, security: profile.security,
            config: CleanIPScanner.pointing(config, to: chosen.ip, name: name)
        )
        Task {
            do {
                model.sidebarSelection = .group(try await model.subscriptions.addCustom([parsed]))
                dismiss()
            } catch {
                addError = error.localizedDescription
            }
        }
    }
}
