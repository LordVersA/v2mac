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
