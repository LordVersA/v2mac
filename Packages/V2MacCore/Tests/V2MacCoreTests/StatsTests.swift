import Foundation
import Testing
@testable import V2MacCore

@Suite struct StatsTests {
    @Test func parsesInboundCounters() throws {
        let json = #"{"stats":{"inbound":{"mixed-in":{"downlink":12080,"uplink":3965}},"outbound":{},"user":{}}}"#
        let s = try StatsClient.parse(Data(json.utf8), inboundTag: "mixed-in")
        #expect(s.downlink == 12080)
        #expect(s.uplink == 3965)
    }

    @Test func missingCountersAreZero() throws {
        let s = try StatsClient.parse(Data(#"{"cmdline":[]}"#.utf8), inboundTag: "mixed-in")
        #expect(s.downlink == 0 && s.uplink == 0)
    }

    @Test func rejectsNonObject() {
        #expect(throws: StatsError.badResponse) {
            try StatsClient.parse(Data("[]".utf8), inboundTag: "mixed-in")
        }
    }

    @Test func rateBetweenSnapshots() {
        let t0 = Date(timeIntervalSince1970: 100)
        let a = TrafficSnapshot(uplink: 1000, downlink: 2000, date: t0)
        let b = TrafficSnapshot(uplink: 3000, downlink: 8000, date: t0.addingTimeInterval(2))
        let r = b.rate(since: a)
        #expect(r.upBytesPerSecond == 1000)
        #expect(r.downBytesPerSecond == 3000)
    }

    @Test func counterResetGivesZero() {
        let t0 = Date(timeIntervalSince1970: 100)
        let a = TrafficSnapshot(uplink: 5000, downlink: 5000, date: t0)
        let b = TrafficSnapshot(uplink: 10, downlink: 10, date: t0.addingTimeInterval(1))
        #expect(b.rate(since: a) == .zero)
    }
}

@Suite struct TrafficUsageTests {
    @Test func countsAcrossCoreRestartsAndSessions() {
        var usage = TrafficUsage()
        let start = Date(timeIntervalSince1970: 0)
        usage.startSession(at: start)
        let first = TrafficSnapshot(uplink: 100, downlink: 1000)
        var d = first.bytes(since: nil)
        usage.add(up: d.up, down: d.down, now: start)
        d = TrafficSnapshot(uplink: 150, downlink: 1600).bytes(since: first)
        usage.add(up: d.up, down: d.down)
        // A restarted core counts from zero again.
        d = TrafficSnapshot(uplink: 10, downlink: 20).bytes(since: TrafficSnapshot(uplink: 150, downlink: 1600))
        usage.add(up: d.up, down: d.down)
        #expect(usage.sessionUp == 160 && usage.sessionDown == 1620)
        #expect(usage.totalSince == start)

        usage.startSession()
        usage.add(up: 1, down: 2)
        #expect(usage.session == 3)
        #expect(usage.total == 1783)
        usage.resetTotal()
        #expect(usage.total == 0 && usage.session == 3)
    }
}
