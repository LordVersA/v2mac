import Charts
import SwiftUI

/// The last minute of traffic: download as a soft filled curve, upload as a faint line over it.
/// New samples come in from the right, and the oldest fade out on the left.
struct TrafficSparkline: View {
    let samples: [ConnectionController.RateSample]

    /// How many samples fit across; `ConnectionController` keeps as many.
    private static let window = 60

    var body: some View {
        let points = Self.smoothed(samples)
        let last = points.last?.id ?? 0
        let peak = max(points.map { max($0.down, $0.up) }.max() ?? 0, 1024)
        Chart(points) { point in
            AreaMark(x: .value("Time", point.id), y: .value("Download", point.down))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", point.id), y: .value("Download", point.down), series: .value("Direction", "Download"))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.accentColor)
            LineMark(x: .value("Time", point.id), y: .value("Upload", point.up), series: .value("Direction", "Upload"))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: (last - Self.window + 1)...max(last, 1))
        // Headroom, so the highest point does not touch the top edge.
        .chartYScale(domain: 0...(peak * 1.2))
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25)], startPoint: .leading, endPoint: .trailing))
        // No animation on new samples: a 0.9 s spring every second kept Charts re-laying out all
        // three marks on every frame, ~65% CPU, even with every window closed.
        .accessibilityHidden(true)
    }

    /// Each point averaged with its neighbours: one-second samples of bursty traffic are spikes,
    /// and the graph is there to show the trend.
    private static func smoothed(_ samples: [ConnectionController.RateSample]) -> [ConnectionController.RateSample] {
        guard samples.count > 2 else { return samples }
        return samples.indices.map { index in
            let near = samples[max(index - 1, 0)...min(index + 1, samples.count - 1)]
            let count = Double(near.count)
            return .init(id: samples[index].id, down: near.reduce(0) { $0 + $1.down } / count, up: near.reduce(0) { $0 + $1.up } / count)
        }
    }
}
