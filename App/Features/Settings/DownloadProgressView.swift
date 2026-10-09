import SwiftUI
import V2MacCore

/// Percent, size and speed of a running download.
struct DownloadProgressView: View {
    let title: String
    let progress: DownloadProgress?
    let rate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(title)
                Spacer()
                Text(detail).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        guard let progress else { return "Starting…" }
        var parts: [String] = []
        if let fraction = progress.fraction { parts.append("\(Int(fraction * 100))%") }
        if let total = progress.total {
            parts.append("\(Format.megabytes(progress.received)) of \(Format.megabytes(total))")
        } else {
            parts.append(Format.megabytes(progress.received))
        }
        if let rate { parts.append(Format.rate(rate)) }
        return parts.joined(separator: " · ")
    }
}
