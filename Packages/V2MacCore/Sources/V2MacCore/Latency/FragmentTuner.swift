import Foundation

/// Finds TLS fragment settings that get through this network to one server (spec 8.4): each
/// candidate dials the server through its own throwaway core, a couple at a time, twice, and the fastest one that
/// answered both times wins. No fragment at all is a candidate too, and wins when it is close.
public enum FragmentTuner {
    public struct Trial: Sendable, Equatable, Identifiable {
        public var fragment: FragmentSettings?
        /// Average delay of the rounds, or nil when a round failed.
        public var ms: Int?
        public var id: String { fragment.map { "\($0.packets.rawValue) \($0.length) \($0.interval)" } ?? "none" }

        public init(fragment: FragmentSettings?, ms: Int?) {
            self.fragment = fragment
            self.ms = ms
        }
    }

    /// From gentle to aggressive; the ones filters in Iran and China are known to miss.
    public static let candidates: [FragmentSettings?] = [
        nil,
        FragmentSettings(packets: .tlsHello, length: "100-200", interval: "10-20"),
        FragmentSettings(packets: .tlsHello, length: "10-20", interval: "10-20"),
        FragmentSettings(packets: .tlsHello, length: "1-5", interval: "1-5"),
        FragmentSettings(packets: .tlsHello, length: "20-50", interval: "30-50"),
        FragmentSettings(packets: .firstPackets, length: "1-5", interval: "1-2"),
        FragmentSettings(packets: .firstPackets, length: "10-20", interval: "10-20"),
        FragmentSettings(packets: .firstPackets, length: "100-200", interval: "10-20"),
    ]

    /// The fastest working candidate; no fragment when it works and is within a fifth of that.
    public static func pick(_ trials: [Trial]) -> Trial? {
        let working = trials.filter { $0.ms != nil }
        guard let fastest = working.min(by: { $0.ms! < $1.ms! }) else { return nil }
        if let plain = working.first(where: { $0.fragment == nil }), Double(plain.ms!) <= Double(fastest.ms!) * 1.2 { return plain }
        return fastest
    }

    /// Runs the candidates `concurrency` at a time, `rounds` times; a candidate that fails a round
    /// is not tried again. `tester` makes a tester that dials with the given fragment.
    public static func run(
        _ target: LatencyTarget,
        rounds: Int = 2,
        concurrency: Int = 2,
        tester: @escaping @Sendable (FragmentSettings?) -> RealDelayTester,
        onTrial: @escaping @Sendable (Trial) async -> Void
    ) async -> [Trial] {
        var totals = Array(repeating: 0, count: candidates.count)
        var alive = Set(candidates.indices)
        for _ in 0..<max(1, rounds) {
            let results = await withTaskGroup(of: (Int, Int?).self) { group in
                var waiting = alive.sorted()
                func launch() {
                    guard !waiting.isEmpty else { return }
                    let i = waiting.removeFirst()
                    group.addTask {
                        let box = OutcomeBox()
                        await tester(candidates[i]).run([target]) { await box.set($0.outcome) }
                        if case .ok(let ms) = await box.value { return (i, ms) }
                        return (i, nil)
                    }
                }
                for _ in 0..<max(1, concurrency) { launch() }
                var out: [(Int, Int?)] = []
                while let result = await group.next() {
                    out.append(result)
                    if !Task.isCancelled { launch() }
                }
                return out
            }
            if Task.isCancelled { return [] }
            for (i, ms) in results {
                if let ms { totals[i] += ms } else { alive.remove(i); await onTrial(Trial(fragment: candidates[i], ms: nil)) }
            }
        }
        var trials: [Trial] = []
        for i in candidates.indices {
            let trial = Trial(fragment: candidates[i], ms: alive.contains(i) ? totals[i] / max(1, rounds) : nil)
            if trial.ms != nil { await onTrial(trial) }
            trials.append(trial)
        }
        return trials
    }

    private actor OutcomeBox {
        var value: LatencyOutcome?
        func set(_ outcome: LatencyOutcome) { value = outcome }
    }
}
