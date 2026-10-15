import Foundation
import os
import Security

/// Secrets, as generic passwords in the login keychain: the local proxy's password and, when
/// the user saves it, the administrator password for the root helper. Each is read from the
/// keychain once and then kept in memory, so a refused keychain prompt is not asked again.
enum Keychain {
    enum Item: String {
        case proxyPassword, adminPassword
    }

    private static let service = Bundle.main.bundleIdentifier ?? "io.github.lordversa.v2mac"
    private static let cache = OSAllocatedUnfairLock<[Item: String]>(initialState: [:])

    static func string(_ item: Item) -> String? {
        if let cached = cache.withLock({ $0[item] }) { return cached.isEmpty ? nil : cached }
        var query = base(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        let value = found ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
        cache.withLock { $0[item] = value }
        return value.isEmpty ? nil : value
    }

    /// Saves `value`, or deletes the item when it is nil or empty.
    @discardableResult
    static func set(_ value: String?, for item: Item) -> Bool {
        let value = value ?? ""
        cache.withLock { $0[item] = value }
        guard !value.isEmpty else {
            let status = SecItemDelete(base(item) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = base(item)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "V2Mac \(item == .proxyPassword ? "proxy password" : "administrator password")"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func base(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: item.rawValue]
    }
}
