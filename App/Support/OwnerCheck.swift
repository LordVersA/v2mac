import Foundation
import LocalAuthentication

/// Spec 12.9: with the setting on, copying or showing a share link and exporting a backup need
/// Touch ID or the login password first. One check covers the next minute.
@MainActor
enum OwnerCheck {
    /// Off when missing, so it needs no registered default and stays out of backups.
    static let key = "requireOwnerForSecrets"
    private static var confirmedAt: Date?

    /// `reason` completes macOS's "V2Mac is trying to …".
    static func confirm(_ reason: String) async -> Bool {
        guard UserDefaults.standard.bool(forKey: key) else { return true }
        if let confirmedAt, Date().timeIntervalSince(confirmedAt) < 60 { return true }
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return false }
        confirmedAt = Date()
        return true
    }

    static var shareLinkReason: String { String(localized: "show a server's share link") }
}
