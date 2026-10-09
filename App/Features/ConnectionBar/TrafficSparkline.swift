import Charts
import SwiftUI

/// The last minute of download and upload rates as two small lines.
struct TrafficSparkline: View {
    let samples: [ConnectionController.RateSample]

    var body: some View {
        Chart(samples) { sample in
            LineMark(x: .value("Time", sample.id), y: .value("Download", sample.down), series: .value("Direction", "Download"))
                .foregroundStyle(.green)
            LineMark(x: .value("Time", sample.id), y: .value("Upload", sample.up), series: .value("Direction", "Upload"))
                .foregroundStyle(.blue)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(samples.map { max($0.down, $0.up) }.max() ?? 0, 1024))
        .accessibilityHidden(true)
    }
}
