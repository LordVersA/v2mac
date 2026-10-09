import CoreImage.CIFilterBuiltins
import SwiftUI

struct InspectorView: View {
    let profile: Profile?
    @State private var showQR = false

    var body: some View {
        Group {
            if let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(profile.name).font(.title3.bold()).textSelection(.enabled)

                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                            field("Protocol", profile.protocolName)
                            if !profile.transport.isEmpty { field("Transport", profile.transport) }
                            field("Security", profile.security.isEmpty ? "—" : profile.security)
                            if !profile.address.isEmpty { field("Address", "\(profile.address):\(profile.port)") }
                            if let sni = sni(of: profile) { field("SNI / Host", sni) }
                            field("Delay", delayText(profile))
                        }

                        if !profile.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(profile.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }

                        HStack {
                            Button("Copy Share Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(profile.originalLink ?? "", forType: .string)
                            }
                            .disabled(profile.originalLink == nil)
                            Button("QR Code", systemImage: "qrcode") { showQR = true }
                                .disabled(profile.originalLink == nil)
                                .popover(isPresented: $showQR, arrowEdge: .bottom) {
                                    QRPopover(name: profile.name, link: profile.originalLink ?? "")
                                }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a server to see its details."))
            }
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
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
