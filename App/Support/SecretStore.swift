import CryptoKit
import Foundation
import Observation

/// Passwordless local encryption by default; optional login Keychain storage (spec 13).
@MainActor @Observable
final class SecretStore {
    static let shared = SecretStore(directory: AppPaths.dataDirectory.appendingPathComponent("secrets", isDirectory: true))
    static let preferenceKey = "useKeychain"

    private(set) var usesKeychain: Bool
    private(set) var errorMessage: String?
    @ObservationIgnored private var cached: Result<[String: String], Error>?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readKeychain: (Keychain.Item) throws -> String?
    @ObservationIgnored private let writeKeychain: (String?, Keychain.Item) throws -> Void

    init(directory: URL, defaults: UserDefaults = .standard,
         readKeychain: @escaping (Keychain.Item) throws -> String? = Keychain.string,
         writeKeychain: @escaping (String?, Keychain.Item) throws -> Void = { try Keychain.set($0, for: $1) }) {
        self.directory = directory
        self.defaults = defaults
        self.readKeychain = readKeychain
        self.writeKeychain = writeKeychain
        usesKeychain = defaults.bool(forKey: Self.preferenceKey)
    }

    func string(_ item: Keychain.Item) throws -> String? {
        let value = try values()[item.rawValue]
        return value?.isEmpty == false ? value : nil
    }

    func set(_ value: String?, for item: Keychain.Item) throws {
        do {
            var next = try values()
            // Empty entries prevent an old Keychain value from returning after it was forgotten locally.
            next[item.rawValue] = value ?? ""
            if usesKeychain { try writeKeychain(value, item) }
            else { try writeLocal(next) }
            cached = .success(next)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// The caller explains the macOS prompt before opting in. The source survives a failed copy.
    func setUsesKeychain(_ enabled: Bool) throws {
        guard enabled != usesKeychain else { return }
        do {
            var next = try values()
            if enabled {
                for item in Keychain.Item.allCases where next[item.rawValue] == nil {
                    next[item.rawValue] = try readKeychain(item) ?? ""
                }
                for item in Keychain.Item.allCases { try writeKeychain(next[item.rawValue], item) }
            } else {
                try writeLocal(next)
            }
            defaults.set(enabled, forKey: Self.preferenceKey)
            usesKeychain = enabled
            cached = .success(next)
            errorMessage = nil
            if enabled {
                // Commit the choice first: failed cleanup must not lose the only readable copy.
                for file in [dataURL, keyURL] where FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Also checked before connecting, so unreadable secrets cannot silently remove proxy authentication.
    @discardableResult
    func values() throws -> [String: String] {
        if let cached { return try cached.get() }
        do {
            let loaded: [String: String]
            if usesKeychain {
                var entries: [String: String] = [:]
                for item in Keychain.Item.allCases { entries[item.rawValue] = try readKeychain(item) ?? "" }
                loaded = entries
            } else if FileManager.default.fileExists(atPath: dataURL.path) {
                let key = try localKey()
                let box = try AES.GCM.SealedBox(combined: Data(contentsOf: dataURL))
                loaded = try JSONDecoder().decode([String: String].self, from: AES.GCM.open(box, using: key))
            } else {
                loaded = [:]
            }
            cached = .success(loaded)
            errorMessage = nil
            return loaded
        } catch {
            cached = .failure(error)
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func retryRead() throws {
        cached = nil
        try values()
    }

    private var dataURL: URL { directory.appendingPathComponent("secrets.enc") }
    private var keyURL: URL { directory.appendingPathComponent("secrets.key") }

    private func localKey() throws -> SymmetricKey {
        let bytes = try Data(contentsOf: keyURL)
        guard bytes.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        return SymmetricKey(data: bytes)
    }

    private func writeLocal(_ entries: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let key: SymmetricKey
        if fm.fileExists(atPath: keyURL.path) {
            key = try localKey()
        } else {
            // Never replace a missing key for existing ciphertext: that would destroy saved secrets.
            guard !fm.fileExists(atPath: dataURL.path) else { throw CocoaError(.fileReadNoSuchFile) }
            key = SymmetricKey(size: .bits256)
            try key.withUnsafeBytes { try Data($0).write(to: keyURL, options: .atomic) }
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(entries), using: key)
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        try combined.write(to: dataURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dataURL.path)
    }
}
