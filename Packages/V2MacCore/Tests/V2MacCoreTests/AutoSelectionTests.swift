import Foundation
import Testing
@testable import V2MacCore

@Suite struct AutoSelectionTests {
    let current = UUID(), first = UUID(), fastest = UUID()
    let now = Date(timeIntervalSince1970: 1000)

    @Test func initialChoiceUsesOnlySuccessfulFreshResponses() {
        var policy = AutoSelectionPolicy()
        let results = [LatencyResult(id: current, outcome: .timeout),
                       LatencyResult(id: first, outcome: .ok(ms: 500)),
                       LatencyResult(id: fastest, outcome: .ok(ms: 100))]
        #expect(policy.choose(results: results, currentID: current, reason: .initial, now: now) == fastest)
        #expect(policy.choose(results: [.init(id: first, outcome: .invalid("bad config"))],
                              currentID: current, reason: .initial, now: now) == nil)
    }

    @Test func fallbackUsesGroupOrderRatherThanFastestPing() {
        var policy = AutoSelectionPolicy()
        let results = [LatencyResult(id: current, outcome: .ok(ms: 1)),
                       LatencyResult(id: first, outcome: .ok(ms: 500)),
                       LatencyResult(id: fastest, outcome: .ok(ms: 50))]
        #expect(policy.choose(results: results, currentID: current, reason: .fallback, now: now) == first)
    }

    @Test func manualOverrideLastsUntilTheConnectionFails() {
        var policy = AutoSelectionPolicy()
        policy.selectManually()
        let results = [LatencyResult(id: current, outcome: .ok(ms: 1000)),
                       LatencyResult(id: first, outcome: .ok(ms: 100))]
        #expect(policy.choose(results: results, currentID: current, reason: .initial, now: now) == nil)
        #expect(policy.choose(results: results, currentID: current, reason: .faster, now: now) == nil)
        let outcomes: [LatencyOutcome] = [.timeout, .ok(ms: 900), .timeout, .timeout]
        let healthDecisions = outcomes.map { policy.recordHealth($0) }
        #expect(healthDecisions == [false, false, false, true])
        #expect(policy.choose(results: results, currentID: current, reason: .fallback, now: now) == first)
        #expect(!policy.manualOverride)
    }

    @Test func hysteresisAndCooldownPreventFlapping() {
        var policy = AutoSelectionPolicy()
        let slight = [LatencyResult(id: current, outcome: .ok(ms: 500)),
                      LatencyResult(id: first, outcome: .ok(ms: 400))]
        #expect(policy.choose(results: slight, currentID: current, reason: .faster, now: now) == nil)
        let better = [LatencyResult(id: current, outcome: .ok(ms: 500)),
                      LatencyResult(id: first, outcome: .ok(ms: 300))]
        #expect(policy.choose(results: better, currentID: current, reason: .faster, now: now) == first)
        policy.didSwitch(at: now)
        #expect(policy.choose(results: better, currentID: current, reason: .faster, now: now.addingTimeInterval(59)) == nil)
        #expect(policy.choose(results: better, currentID: current, reason: .faster, now: now.addingTimeInterval(60)) == first)
    }

    @Test func aFailedPeerIsExcludedUntilItsCooldownEnds() {
        var policy = AutoSelectionPolicy()
        let results = [LatencyResult(id: current, outcome: .ok(ms: 10)),
                       LatencyResult(id: first, outcome: .ok(ms: 100))]
        #expect(policy.choose(results: results, currentID: current, reason: .fallback, now: now) == first)
        policy.didSwitch(at: now)
        #expect(policy.choose(results: results, currentID: first, reason: .faster, now: now.addingTimeInterval(119)) == nil)
        let slow = [LatencyResult(id: current, outcome: .ok(ms: 10)),
                    LatencyResult(id: first, outcome: .ok(ms: 500))]
        #expect(policy.choose(results: slow, currentID: first, reason: .faster, now: now.addingTimeInterval(120)) == current)
    }

    @Test func noRespondingPeersProducesNoSelection() {
        var policy = AutoSelectionPolicy()
        #expect(policy.choose(results: [.init(id: first, outcome: .timeout)], currentID: current,
                              reason: .fallback, now: now) == nil)
    }
}

@Suite struct ProxyHealthProbeTests {
    @Test(arguments: ["http://localhost/", "http://127.0.0.1/", "http://10.0.0.1/", "http://172.16.1.1/",
                      "http://192.168.1.1/", "http://[::1]/", "http://router.local/", "file:///tmp/probe",
                      "https://user:password@example.com/"])
    func localAndNonHTTPURLsCannotMasqueradeAsAProxyResponse(_ text: String) throws {
        #expect(!ProxyHealthProbe.isSuitable(try #require(URL(string: text))))
    }

    @Test func directRoutesAreNeverUsedForHealthChecks() async throws {
        let result = await ProxyHealthProbe.measure(route: .direct, url: try #require(URL(string: "https://example.com")), timeout: 1)
        guard case .invalid = result else { Issue.record("health probe must reject direct routes"); return }
    }
}
