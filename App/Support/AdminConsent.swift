import AppKit

/// Spec 9.5: says what administrator access is for before macOS asks for the password, and
/// points to the source. "Don't show this again" is kept as `adminConsentShown`.
enum AdminConsent {
    static let key = "adminConsentShown"

    @MainActor static func confirm() -> Bool {
        if UserDefaults.standard.bool(forKey: key) { return true }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        alert.messageText = String(localized: "Allow administrator access?")
        alert.informativeText = String(localized: """
        TUN mode, the system proxy and the kill switch change settings for the whole Mac, so V2Mac starts \
        a small helper with administrator rights. It only changes this Mac's proxy, routes and firewall while \
        you use them, and puts them back when you turn them off or quit.

        V2Mac saves none of your data and sends nothing anywhere. It is open source, so you can check \
        exactly what it does. macOS asks for your password next.
        """)
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        let source = NSButton(title: String(localized: "View the source on GitHub"), target: SourceLink.shared,
                              action: #selector(SourceLink.open))
        source.bezelStyle = .inline
        source.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        source.imagePosition = .imageTrailing
        source.sizeToFit()
        alert.accessoryView = source
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't show this again")
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: key) }
        return confirmed
    }

    /// Opens the repository without closing the alert.
    @MainActor private final class SourceLink: NSObject {
        static let shared = SourceLink()
        @objc func open() { NSWorkspace.shared.open(AboutLinks.repository) }
    }
}
