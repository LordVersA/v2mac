import Foundation

/// Decides when a download has reached its top stable speed, so a test can stop early
/// instead of pulling the whole file.
///
/// Feed it cumulative byte counts; speed is measured over a sliding one-second window and
/// the highest window is the result. The test is finished once that peak has not been
/// beaten by a meaningful margin for a while (the link is at its ceiling), or at a hard cap.
public struct SpeedMeter: Sendable {
    public var window: Double = 1.0
    /// Never stop before this much time has passed, so slow-start is not mistaken for a ceiling.
    public var minimumDuration: Double = 3.0
    /// How long the peak must stand unbeaten.
    public var plateau: Double = 2.0
    /// A new window must beat the peak by this factor to count as still ramping up.
    public var improvement: Double = 1.05
    public var maximumDuration: Double = 15.0

    private var samples: [(time: Double, bytes: Int64)] = [(0, 0)]
    /// Highest window speed seen, in bytes per second.
    public private(set) var peak: Double = 0
    private var peakTime: Double = 0
    private var bar: Double = 0

    public init() {}

    /// Returns true when the test should stop.
    public mutating func add(elapsed: Double, bytes: Int64) -> Bool {
        samples.append((elapsed, bytes))
        guard elapsed >= window else { return false }
        let start = samples.last { $0.time <= elapsed - window } ?? samples[0]
        samples.removeAll { $0.time < start.time }
        let speed = Double(bytes - start.bytes) / (elapsed - start.time)
        peak = max(peak, speed)
        if speed > bar * improvement {
            bar = speed
            peakTime = elapsed
        }
        if elapsed >= maximumDuration { return true }
        return elapsed >= minimumDuration && elapsed - peakTime >= plateau
    }

    /// Whole-transfer average, for downloads that finish before a window fills.
    public static func average(bytes: Int64, elapsed: Double) -> Double {
        elapsed > 0 ? Double(bytes) / elapsed : 0
    }
}
