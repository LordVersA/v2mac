import Foundation
import Testing
@testable import V2MacCore

@Suite struct UsageAlertTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func inHours(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    @Test func expiryLevels() {
        #expect(UsageAlert.expiry(expiresAt: nil, now: now) == .none)
        #expect(UsageAlert.expiry(expiresAt: inHours(24 * 10), now: now) == .none)
        #expect(UsageAlert.expiry(expiresAt: inHours(24 * 3), now: now) == .soon)
        #expect(UsageAlert.expiry(expiresAt: inHours(25), now: now) == .soon)
        #expect(UsageAlert.expiry(expiresAt: inHours(24), now: now) == .lastDay)
        #expect(UsageAlert.expiry(expiresAt: inHours(-1), now: now) == .expired)
        #expect(UsageAlert.daysLeft(expiresAt: inHours(49), now: now) == 3)
        #expect(UsageAlert.daysLeft(expiresAt: inHours(-5), now: now) == 0)
    }

    @Test func trafficLevels() {
        #expect(UsageAlert.traffic(used: 10, total: nil) == .none)
        #expect(UsageAlert.traffic(used: 10, total: 0) == .none)
        #expect(UsageAlert.traffic(used: 79, total: 100) == .none)
        #expect(UsageAlert.traffic(used: 80, total: 100) == .low)
        #expect(UsageAlert.traffic(used: 95, total: 100) == .nearlyOut)
        #expect(UsageAlert.traffic(used: 120, total: 100) == .out)
    }

    @Test func eachLevelIsAnnouncedOnce() {
        var marker: String?
        func step(_ level: Int, _ subject: String = "a") -> Bool {
            let result = UsageAlert.step(level: level, subject: subject, marker: marker)
            marker = result.marker
            return result.notify
        }
        #expect(!step(0))
        #expect(step(1))
        #expect(!step(1))
        #expect(step(2))
        #expect(!step(1))   // fell back: quiet, but remembered
        #expect(step(2))
        #expect(!step(0))
        #expect(step(1))
        #expect(step(1, "b"))   // renewed or changed plan
        #expect(!step(1, "b"))
    }
}
