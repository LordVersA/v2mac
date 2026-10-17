import Foundation
import Security

/// Only used after the user opts in through Settings (spec 13).
enum Keychain {
    enum Item: String, CaseIterable {
        case proxyPassword, warpAccount
    }

    private static let service = Bundle.main.bundleIdentifier ?? "io.github.lordversa.v2mac"
    static func string(_ item: Item) throws -> String? {
        var query = base(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value.isEmpty ? nil : value
    }

    /// Saves `value`, or deletes the item when it is nil or empty.
    static func set(_ value: String?, for item: Item) throws {
        let value = value ?? ""
        guard !value.isEmpty else {
            let status = SecItemDelete(base(item) as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { try check(status); return }
        var add = base(item)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "V2Mac \(item.label)"
        try check(SecItemAdd(add as CFDictionary, nil))
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Explicit cleanup only: never read or reuse the retired administrator credential.
    static func removeLegacyAdministratorPassword() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "adminPassword"]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func base(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: item.rawValue]
    }
}

private extension Keychain.Item {
    var label: String {
        switch self {
        case .proxyPassword: "proxy password"
        case .warpAccount: "WARP device"
        }
    }
}
