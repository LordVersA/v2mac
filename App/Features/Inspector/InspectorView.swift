import CoreImage.CIFilterBuiltins
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let profile: Profile?
    @State private var showQR = false
    /// Worked out when the server changes: it means parsing the server's whole config.
    @State private var sni: (id: UUID, value: String?)?

    var body: some View {
        Group {
            if let profile {
                let name = ServerName(profile.name)
                let isActive = model.connection.activeServer?.id == profile.id
                Form {
                    Section {
                        HStack(spacing: 10) {
                            if let flag = name.flag { Text(flag).font(.largeTitle) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name.title).font(.title3.bold()).textSelection(.enabled)
                                Text(profile.typeSummary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(isActive ? "Active Server" : "Connect", systemImage: isActive ? "checkmark.circle.fill" : "power") {
                            model.activate(profile)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(isActive)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.snappy, value: isActive)
                        .frame(maxWidth: .infinity)
                        Button(profile.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: profile.isFavorite ? "star.fill" : "star") {
                            model.setFavorite([profile.id], !profile.isFavorite)
                        }
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: .infinity)
                    }

                    Section("Connection") {
                        LabeledContent("Protocol", value: profile.protocolName)
                        if !profile.transport.isEmpty { LabeledContent("Transport", value: profile.transport) }
                        LabeledContent("Security", value: profile.security.isEmpty ? "—" : profile.security)
                        if !profile.address.isEmpty { field("Address", "\(profile.address):\(profile.port)") }
                        if let sni, sni.id == profile.id, let value = sni.value { field("SNI / Host", value) }
                    }

                    Section("Performance") {
                        LabeledContent("Delay", value: delayText(profile))
                        if let speed = profile.speedBps, speed > 0 {
                            LabeledContent("Speed", value: Format.rate(speed))
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

                    Section {
                        CopyButton("Copy Share Link", systemImage: "link") { profile.originalLink ?? "" }
                            .disabled(profile.originalLink == nil)
                        Button("QR Code", systemImage: "qrcode") { showQR = true }
                            .disabled(profile.originalLink == nil)
                            .popover(isPresented: $showQR, arrowEdge: .bottom) {
                                QRPopover(name: profile.name, link: profile.originalLink ?? "")
                            }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a server to see its details."))
            }
        }
        .animation(.smooth(duration: 0.2), value: profile == nil)
        .task(id: profile?.id) { sni = profile.map { ($0.id, sni(of: $0)) } }
    }

    private func field(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).textSelection(.enabled) }
    }

    private func sni(of profile: Profile) -> String? {
        guard let stream = profile.config?["streamSettings"] else { return nil }
        return stream["tlsSettings"]?["serverName"]?.stringValue
            ?? stream["realitySettings"]?["serverName"]?.stringValue
            ?? stream["wsSettings"]?["host"]?.stringValue
    }

    private func delayText(_ p: Profile) -> String {
        switch p.delayState {
        case .untested: "Not tested"
        case .na: "Not applicable"
        case .timeout: "Timeout"
        case .invalid: "Invalid"
        case .ok:
            "\(p.delayMs ?? 0) ms" + (p.delayTestedAt.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? "")
        }
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
