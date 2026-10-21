import Foundation
import Testing

@Suite @MainActor
struct SettingsResetTests {
    /// A new setting must be added to a tab's reset list, or to the kept list on purpose.
    @Test func everySettingIsResetOrKept() {
        let reset = Set(SettingsTab.allCases.flatMap(Prefs.resetKeys))
        let forgotten = Set(Prefs.backupKeys).subtracting(reset).subtracting(Prefs.keptOnReset)
        #expect(forgotten.isEmpty, "\(forgotten.sorted())")
        #expect(reset.isDisjoint(with: Prefs.keptOnReset))
    }

    @Test func resetFallsBackToTheDefault() {
        Prefs.registerDefaults()
        UserDefaults.standard.set(9999, forKey: "proxyPort")
        for key in Prefs.resetKeys(.proxy) { UserDefaults.standard.removeObject(forKey: key) }
        #expect(Prefs.port == Prefs.defaultPort)
    }
}
