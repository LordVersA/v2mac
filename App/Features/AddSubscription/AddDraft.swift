import Foundation

/// What the Add sheet starts with. Set before the sheet opens and cleared once it has read it.
struct AddDraft: Equatable {
    enum Kind: Hashable {
        case subscription
        case custom
    }

    var kind = Kind.subscription
    var configText = ""
    var error: String?

    /// A single http(s) link without credentials. With credentials it is an HTTP proxy share link.
    static func isSubscriptionURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return url.host != nil && url.user == nil
    }
}
