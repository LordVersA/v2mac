import Testing
@testable import V2MacCore

@Suite struct SpeedMeterTests {
    private func run(rate: (Double) -> Double) -> (done: Double, peak: Double) {
        var meter = SpeedMeter()
        var bytes: Double = 0
        var t = 0.0
        while t < 30 {
            t += 0.1
            bytes += rate(t) * 0.1
            if meter.add(elapsed: t, bytes: Int64(bytes)) { return (t, meter.peak) }
        }
        return (t, meter.peak)
    }

    @Test func stopsOnceSpeedIsFlat() {
        let r = run { _ in 5_000_000 }
        #expect(r.done <= 5.5)
        #expect(abs(r.peak - 5_000_000) < 300_000)
    }

    @Test func keepsGoingWhileRamping() {
        let r = run { min($0 * 2_000_000, 10_000_000) }
        #expect(r.done >= 6)
        #expect(r.peak > 9_000_000)
    }

    @Test func reportsCurrentSpeedFromTheStart() {
        var meter = SpeedMeter()
        // A burst in the first milliseconds is not a speed yet.
        _ = meter.add(elapsed: 0.001, bytes: 64_000)
        #expect(meter.current == 0)
        _ = meter.add(elapsed: 0.5, bytes: 1_000_000)
        #expect(meter.current == 2_000_000)
        #expect(meter.peak == 0)
        _ = meter.add(elapsed: 1.0, bytes: 3_000_000)
        _ = meter.add(elapsed: 2.0, bytes: 4_000_000)
        // The last second, not the peak.
        #expect(meter.current == 1_000_000)
        #expect(meter.peak == 3_000_000)
    }

    @Test func capsAtMaximum() {
        let r = run { $0 * 1_000_000 }
        #expect(r.done <= 15.1)
    }
}
