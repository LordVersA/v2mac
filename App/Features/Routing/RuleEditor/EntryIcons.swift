import AppKit
import SwiftUI
import V2MacCore

/// Icons for the simple rule editor's rows, from what is on this Mac only: an app entry's own
/// icon, a site's icon from an installed app of the same name or vendor, and symbols otherwise.
/// Nothing is fetched, so the list of sites never leaves the Mac.
@MainActor @Observable
final class EntryIcons {
    /// One set for every window: the app list is read once.
    static let shared = EntryIcons()

    enum Icon {
        case image(NSImage)
        case symbol(String, Color)
    }

    private var apps: [InstalledApp] = []
    @ObservationIgnored private var cache: [String: Icon] = [:]

    private static let appleBrands: Set<String> = ["apple", "icloud", "mzstatic", "aaplimg", "itunes", "appstore", "cdn-apple", "me", "mac"]

    func load() async {
        guard apps.isEmpty else { return }
        apps = await InstalledApps.all()
        cache = [:]
    }

    func icon(for entry: RuleEntry) -> Icon {
        if let cached = cache[entry.id] { return cached }
        let icon = entry.kind == .app ? appIcon(entry.text) : siteIcon(entry)
        // Unresolved before the app list loads; looked up again once it has.
        if !apps.isEmpty { cache[entry.id] = icon }
        return icon
    }

    private func image(_ path: String) -> Icon { .image(NSWorkspace.shared.icon(forFile: path)) }

    private func appIcon(_ text: String) -> Icon {
        if text.hasPrefix("/") { return image((text as NSString).expandingTildeInPath) }
        var word = text.trimmingCharacters(in: CharacterSet(charactersIn: "*\"' ")).lowercased()
        let isPattern = text.hasPrefix("*")
        if word.hasSuffix(".app") { word.removeLast(4) }
        guard !word.isEmpty else { return .symbol("asterisk", .secondary) }
        let match = apps.first { $0.name == word + ".app" || $0.bundleID.lowercased() == word }
            ?? (isPattern ? apps.first { $0.name.contains(word) || $0.bundleID.lowercased().contains(word) } : nil)
        if let match { return image(match.path) }
        if text.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: word) { return image(url.path) }
        // Daemons and command-line tools have no icon of their own.
        return .symbol("gearshape.fill", .gray)
    }

    private func siteIcon(_ entry: RuleEntry) -> Icon {
        let host = SeenGroup.displayName(entry).lowercased()
        guard let brand = SeenGroup.brand(of: entry) ?? EntryGroups.brand(ofHost: host), brand.count >= 2 else {
            return .symbol("network", .teal)
        }
        if Self.appleBrands.contains(brand) { return .symbol("apple.logo", .primary) }
        if brand.count >= 4, let app = apps.first(where: {
            $0.name.replacingOccurrences(of: " ", with: "").hasPrefix(brand) || EntryGroups.brand(ofBundleID: $0.bundleID) == brand
        }) { return image(app.path) }
        return .symbol("globe", .blue)
    }
}
