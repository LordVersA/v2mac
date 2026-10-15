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

@Suite struct SwitchConditionTests {
    let current = UUID(), slow = UUID(), fast = UUID()
    let now = Date(timeIntervalSince1970: 1000)

    @Test func twoSlowChecksInARowAskForAFasterServer() {
        var policy = AutoSelectionPolicy()
        let outcomes: [LatencyOutcome] = [.ok(ms: 1500), .ok(ms: 400), .ok(ms: 1500), .timeout, .ok(ms: 1200), .ok(ms: 1300), .ok(ms: 1300)]
        // Met once, the count starts again, so a group with nothing faster is not retested every check.
        #expect(outcomes.map { policy.recordDelay($0, limit: 1000) } == [false, false, false, false, true, false, true])
        policy.didSwitch(at: now)
        let afterSwitch = policy.recordDelay(.ok(ms: 1500), limit: 1000)
        #expect(!afterSwitch, "a new server starts counting again")
    }

    @Test func degradedTakesTheFastestOtherServerEvenOverAManualChoice() {
        var policy = AutoSelectionPolicy()
        policy.selectManually()
        let results = [LatencyResult(id: current, outcome: .ok(ms: 50)),
                       LatencyResult(id: slow, outcome: .ok(ms: 400)),
                       LatencyResult(id: fast, outcome: .ok(ms: 120))]
        #expect(policy.choose(results: results, currentID: current, reason: .degraded, now: now) == fast)
        #expect(!policy.manualOverride)
        policy.didSwitch(at: now)
        // Within the cooldown nothing switches, and the server left behind is not taken back.
        #expect(policy.choose(results: results, currentID: fast, reason: .degraded, now: now.addingTimeInterval(30)) == nil)
        #expect(policy.choose(results: results, currentID: fast, reason: .degraded, now: now.addingTimeInterval(61)) == slow)
    }

    @Test func slowSpeedNeedsAWholeWindowOfSlowTraffic() {
        var watch = SlowSpeedWatch(floor: 100 * 1024, minutes: 1)
        // Busy but slow for 59 seconds: not yet a whole window.
        #expect((0..<59).map { _ in watch.record(20 * 1024) }.allSatisfy { !$0 })
        let full = watch.record(20 * 1024)
        #expect(full)
        // One fast second in the window means the server can do it.
        watch.reset()
        _ = (0..<30).map { _ in watch.record(20 * 1024) }
        _ = watch.record(500 * 1024)
        #expect((0..<29).map { _ in watch.record(20 * 1024) }.allSatisfy { !$0 })
    }

    @Test func anIdleConnectionIsNeverSlow() {
        var watch = SlowSpeedWatch(floor: 100 * 1024, minutes: 1)
        #expect((0..<120).map { _ in watch.record(200) }.allSatisfy { !$0 })
        // A few slow bursts in an idle minute are not enough either.
        watch.reset()
        let rates = (0..<60).map { $0 % 6 == 0 ? 20.0 * 1024 : 0 }
        #expect(rates.map { watch.record($0) }.allSatisfy { !$0 })
    }
}
