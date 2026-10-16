import Foundation
import Testing

@Suite @MainActor
struct SecretStoreTests {
    private func withDirectory(_ body: (URL, UserDefaults) throws -> Void) throws {
        let id = "v2mac-secret-test-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: id))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: id)
        }
        try body(directory, defaults)
    }

    @Test func localStorageEncryptsAllSecretsWithoutTouchingKeychain() throws {
        try withDirectory { directory, defaults in
            let unexpectedRead: (Keychain.Item) throws -> String? = { _ in
                Issue.record("Local storage accessed Keychain")
                throw CocoaError(.userCancelled)
            }
            let store = SecretStore(directory: directory, defaults: defaults, readKeychain: unexpectedRead,
                                    writeKeychain: { _, _ in Issue.record("Local storage wrote Keychain") })
            #expect(!store.usesKeychain)
            #expect(try store.string(.proxyPassword) == nil)
            for item in Keychain.Item.allCases { try store.set("demo-secret-\(item.rawValue)", for: item) }
            let reloaded = SecretStore(directory: directory, defaults: defaults, readKeychain: unexpectedRead)
            for item in Keychain.Item.allCases {
                #expect(try reloaded.string(item) == "demo-secret-\(item.rawValue)")
            }
            let data = try Data(contentsOf: directory.appendingPathComponent("secrets.enc"))
            #expect(data.range(of: Data("demo-secret".utf8)) == nil)
            let fm = FileManager.default
            #expect(try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
            for name in ["secrets.key", "secrets.enc"] {
                #expect(try fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.posixPermissions] as? Int == 0o600)
            }
            try reloaded.set(nil, for: .adminPassword)
            let cleared = SecretStore(directory: directory, defaults: defaults, readKeychain: unexpectedRead)
            #expect(try cleared.string(.adminPassword) == nil)
            #expect(try cleared.string(.proxyPassword) == "demo-secret-proxyPassword")
        }
    }

    @Test func switchingStoragePreservesCurrentValuesAndRecoversLegacySecrets() throws {
        try withDirectory { directory, defaults in
            var keychain = ["proxyPassword": "old-proxy", "adminPassword": "demo-admin", "warpAccount": "demo-warp"]
            var reads = 0
            let read: (Keychain.Item) throws -> String? = { reads += 1; return keychain[$0.rawValue] }
            let write: (String?, Keychain.Item) throws -> Void = { keychain[$1.rawValue] = $0 }
            let store = SecretStore(directory: directory, defaults: defaults, readKeychain: read, writeKeychain: write)
            try store.set("new-proxy", for: .proxyPassword)
            #expect(reads == 0)
            try store.setUsesKeychain(true)
            #expect(store.usesKeychain)
            #expect(defaults.bool(forKey: SecretStore.preferenceKey))
            #expect(try store.string(.proxyPassword) == "new-proxy")
            #expect(try store.string(.adminPassword) == "demo-admin")
            #expect(try store.string(.warpAccount) == "demo-warp")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("secrets.enc").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("secrets.key").path))

            let restarted = SecretStore(directory: directory, defaults: defaults, readKeychain: read, writeKeychain: write)
            #expect(try restarted.string(.proxyPassword) == "new-proxy")
            try restarted.setUsesKeychain(false)
            let readsBefore = reads
            let local = SecretStore(directory: directory, defaults: defaults, readKeychain: read, writeKeychain: write)
            #expect(!local.usesKeychain)
            #expect(try local.string(.warpAccount) == "demo-warp")
            try local.set(nil, for: .adminPassword)
            #expect(reads == readsBefore)
            try local.setUsesKeychain(true)
            #expect(try local.string(.adminPassword) == nil)
            #expect(keychain["adminPassword"]?.isEmpty == true)
        }
    }

    @Test func refusedKeychainMigrationLeavesTheLocalCopyAndChoiceIntact() throws {
        try withDirectory { directory, defaults in
            var writes = 0
            let store = SecretStore(directory: directory, defaults: defaults, readKeychain: { _ in nil }, writeKeychain: { _, _ in
                writes += 1
                if writes == 2 { throw CocoaError(.userCancelled) }
            })
            try store.set("demo-proxy", for: .proxyPassword)
            #expect(throws: (any Error).self) { try store.setUsesKeychain(true) }
            #expect(!store.usesKeychain)
            #expect(!defaults.bool(forKey: SecretStore.preferenceKey))
            #expect(store.errorMessage != nil)
            let reloaded = SecretStore(directory: directory, defaults: defaults)
            #expect(try reloaded.string(.proxyPassword) == "demo-proxy")
        }
    }

    @Test func failedKeychainSaveDoesNotChangeTheCachedPassword() throws {
        try withDirectory { directory, defaults in
            defaults.set(true, forKey: SecretStore.preferenceKey)
            let store = SecretStore(directory: directory, defaults: defaults, readKeychain: { _ in "demo-old" },
                                    writeKeychain: { _, _ in throw CocoaError(.userCancelled) })
            let original = try store.string(.proxyPassword)
            #expect(original == "demo-old")
            #expect(throws: (any Error).self) { try store.set("demo-new", for: .proxyPassword) }
            let afterFailure = try store.string(.proxyPassword)
            #expect(afterFailure == "demo-old")
        }
    }

    @Test func refusedReadsAreNotRepeatedUntilExplicitRetry() throws {
        try withDirectory { directory, defaults in
            defaults.set(true, forKey: SecretStore.preferenceKey)
            var reads = 0
            let store = SecretStore(directory: directory, defaults: defaults, readKeychain: { _ in
                reads += 1
                throw CocoaError(.userCancelled)
            })
            for item in Keychain.Item.allCases {
                #expect(throws: (any Error).self) { try store.string(item) }
            }
            #expect(reads == 1)
            #expect(throws: (any Error).self) { try store.retryRead() }
            #expect(reads == 2)
        }
    }

    @Test func keychainChoiceIsNotExportedInBackups() {
        #expect(!Prefs.backupKeys.contains(SecretStore.preferenceKey))
    }

    @Test func corruptCiphertextAndMissingKeysAreNeverOverwritten() throws {
        try withDirectory { directory, defaults in
            let store = SecretStore(directory: directory, defaults: defaults)
            try store.set("demo-proxy", for: .proxyPassword)
            let dataURL = directory.appendingPathComponent("secrets.enc")
            var data = try Data(contentsOf: dataURL)
            data[data.count - 1] ^= 1
            try data.write(to: dataURL)
            let corrupt = SecretStore(directory: directory, defaults: defaults)
            #expect(throws: (any Error).self) { try corrupt.string(.proxyPassword) }
            #expect(throws: (any Error).self) { try corrupt.set("replacement", for: .proxyPassword) }
            #expect(try Data(contentsOf: dataURL) == data)

            let keyURL = directory.appendingPathComponent("secrets.key")
            try FileManager.default.removeItem(at: keyURL)
            let missingKey = SecretStore(directory: directory, defaults: defaults)
            #expect(throws: (any Error).self) { try missingKey.set("replacement", for: .proxyPassword) }
            #expect(!FileManager.default.fileExists(atPath: keyURL.path))
            #expect(try Data(contentsOf: dataURL) == data)
        }
    }
}
