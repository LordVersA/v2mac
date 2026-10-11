import V2MacCore

/// Collects concurrent probe callbacks without moving app state off the main actor.
actor AutomaticLatencyResults {
    private(set) var results: [LatencyResult] = []
    func append(_ result: LatencyResult) { results.append(result) }
}
