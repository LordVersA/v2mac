import CoreImage.CIFilterBuiltins
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let profile: Profile?
    @State private var showQR = false
    @State private var showsMore = false
    /// Worked out when the server changes: it means parsing the server's whole config.
    @State private var details: (id: UUID, rows: [Detail])?

    private struct Detail: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    var body: some View {
        Group {
            if let profile {
                let isActive = model.connection.activeServer?.id == profile.id
                Form {
                    Section {
                        header(profile, isActive: isActive)
                    }

                    if isActive, model.connection.phase == .connected {
                        Section("Live") { InspectorLive(connection: model.connection) }
                    }

                    Section("Performance") {
                        InspectorPerformance(profile: profile)
                    }

                    Section("Connection") {
                        LabeledContent("Type") { TypeTags(summary: profile.typeSummary) }
                        if !profile.address.isEmpty { InspectorAddress(address: "\(profile.address):\(profile.port)") }
                        if let details, details.id == profile.id, !details.rows.isEmpty {
                            DisclosureGroup("More", isExpanded: $showsMore) {
                                ForEach(details.rows) { row in
                                    LabeledContent(row.title) { Text(row.value).textSelection(.enabled) }
                                }
                            }
                        }
                    }

                    if !profile.warnings.isEmpty {
                        Section("Warnings") {
                            ForEach(profile.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a server to see its details."))
            }
        }
        .animation(.smooth(duration: 0.2), value: profile == nil)
        .task(id: profile?.id) { details = profile.map { ($0.id, Self.details(of: $0)) } }
    }

    /// Who the server is, the one main action, then the smaller ones as a row of round buttons.
    private func header(_ profile: Profile, isActive: Bool) -> some View {
        let name = ServerName(profile.name)
        let isManual = profile.group?.isManual == true
        return VStack(spacing: 10) {
            Text(name.flag ?? "🌐").font(.system(size: 44)).accessibilityHidden(true)
            Text(name.title).font(.title3.bold()).multilineTextAlignment(.center).textSelection(.enabled)
            if let group = profile.group { GroupTag(name: group.displayName, color: group.tint) }

            Button(isActive ? "Active Server" : "Connect", systemImage: isActive ? "checkmark.circle.fill" : "power") {
                model.activate(profile)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isActive)
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy, value: isActive)
            .padding(.top, 4)

            HStack(spacing: 12) {
                Button(profile.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: profile.isFavorite ? "star.fill" : "star") {
                    model.setFavorite([profile.id], !profile.isFavorite)
                }
                .contentTransition(.symbolEffect(.replace))
                .help(profile.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                CopyButton("Copy Share Link", systemImage: "link") { profile.originalLink ?? "" }
                    .disabled(profile.originalLink == nil)
                    .help("Copy share link")
                Button("QR Code", systemImage: "qrcode") { showQR = true }
                    .disabled(profile.originalLink == nil)
                    .help("Show QR code")
                    .popover(isPresented: $showQR, arrowEdge: .bottom) {
                        QRPopover(name: profile.name, link: profile.originalLink ?? "")
                    }
                Button(isManual ? "Edit…" : "Edit a Copy…", systemImage: "pencil") {
                    model.editServer(profile.id)
                }
                .help(isManual ? "Change this server's details" : "Change the details in a copy saved in Custom Configs")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// What the table's Type column leaves out.
    private static func details(of profile: Profile) -> [Detail] {
        var rows = [Detail(title: String(localized: "Protocol"), value: profile.protocolName)]
        if !profile.transport.isEmpty { rows.append(Detail(title: String(localized: "Transport"), value: profile.transport)) }
        if !profile.security.isEmpty { rows.append(Detail(title: String(localized: "Security"), value: profile.security)) }
        let config = profile.config
        let stream = config?["streamSettings"]
        let sni = stream?["tlsSettings"]?["serverName"]?.stringValue
            ?? stream?["realitySettings"]?["serverName"]?.stringValue
            ?? stream?["wsSettings"]?["host"]?.stringValue
        if let sni, !sni.isEmpty { rows.append(Detail(title: String(localized: "SNI / Host"), value: sni)) }
        let fingerprint = stream?["tlsSettings"]?["fingerprint"]?.stringValue
            ?? stream?["realitySettings"]?["fingerprint"]?.stringValue
        if let fingerprint, !fingerprint.isEmpty { rows.append(Detail(title: String(localized: "Fingerprint"), value: fingerprint)) }
        let settings = config?["settings"]
        let flow = settings?["vnext"]?[0]?["users"]?[0]?["flow"]?.stringValue ?? settings?["flow"]?.stringValue
        if let flow, !flow.isEmpty { rows.append(Detail(title: String(localized: "Flow"), value: flow)) }
        return rows
    }
}

/// Where the active server's traffic comes out, and how much is passing. On its own so that the
/// once-a-second rates do not re-evaluate the whole inspector.
private struct InspectorLive: View {
    let connection: ConnectionController

    var body: some View {
        switch connection.exit {
        case .known(let exit):
            LabeledContent {
                Text(exit.ip).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Text(verbatim: (exit.flag.map { $0 + " " } ?? "") + (exit.place() ?? String(localized: "Unknown place")))
            }
        case .failed:
            Label("No answer through this server", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .checking:
            Text("Checking where traffic comes out…").foregroundStyle(.secondary)
        case .unknown:
            EmptyView()
        }
        VStack(alignment: .leading, spacing: 6) {
            TrafficSparkline(samples: connection.rateHistory).frame(height: 36)
            HStack(spacing: 14) {
                Label(Format.rate(connection.downRate), systemImage: "arrow.down")
                Label(Format.rate(connection.upRate), systemImage: "arrow.up")
            }
            .font(.caption.monospacedDigit())
            // No rolling digits: they change every second, and the transition blurs text on the CPU.
            .foregroundStyle(.secondary)
        }
    }
}

/// The last test's results in the table's own colours, and a way to test this server again.
private struct InspectorPerformance: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        let row = ServerRow(profile)
        let isTesting = model.latency.testingIDs.contains(profile.id)
        LabeledContent("Delay") {
            VStack(alignment: .trailing, spacing: 1) {
                DelayText(row: row, isTesting: isTesting)
                if profile.delayState == .ok, let tested = profile.delayTestedAt {
                    Text(tested.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        let isSpeedTesting = model.latency.speedTestingIDs.contains(profile.id)
        if isSpeedTesting || (profile.speedBps ?? 0) > 0 {
            let live = model.latency.liveSpeed
            LabeledContent("Speed") {
                SpeedText(row: row, isTesting: isSpeedTesting, live: live?.id == profile.id ? live : nil)
            }
        }
        // Another test may be running: this one is queued after it.
        Button(isTesting ? "Testing…" : "Test Now", systemImage: "speedometer") { model.testReal([profile.id]) }
            .disabled(isTesting)
            .frame(maxWidth: .infinity)
    }
}

/// The address in a fixed-width face, with a copy button that shows while the pointer is over the row.
private struct InspectorAddress: View {
    let address: String
    @State private var hovering = false

    var body: some View {
        LabeledContent("Address") {
            HStack(spacing: 6) {
                CopyButton("Copy address") { address }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .opacity(hovering ? 1 : 0)
                    .help("Copy address")
                Text(address).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Share link as a QR code, for scanning with another device.
private struct QRPopover: View {
    let name: String
    let link: String

    var body: some View {
        VStack(spacing: 10) {
            if let image = Self.image(for: link) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("QR code for \(name)")
            } else {
                ContentUnavailableView("Link Too Long", systemImage: "qrcode",
                                       description: Text("This link does not fit in a QR code."))
            }
            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(width: 280)
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
