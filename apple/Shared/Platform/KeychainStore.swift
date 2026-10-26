import Foundation
import XeniaCore
import Security

/// The session's secrets in the Keychain: this device only, available after first unlock (so
/// the notification extension can decrypt pushes while the phone is locked), never synced or
/// backed up. On iPhone they live in an access group the extension shares.
final class KeychainStore: SecretStore, @unchecked Sendable {
    private let service = "dev.xenia.session"
    private let group: String?

    nonisolated init(group: String? = nil) {
        self.group = group
    }

    private nonisolated func query(_ key: String, inGroup: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if inGroup, let group {
            query[kSecAttrAccessGroup as String] = group
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// Moves a secret saved before the shared group existed into it, so the extension can read
    /// it. Safe to run on every launch.
    nonisolated func moveIntoGroup(key: String) {
        guard group != nil, !exists(query(key)) else { return }
        var legacy = query(key, inGroup: false)
        legacy[kSecReturnData as String] = true
        legacy[kSecReturnAttributes as String] = true
        legacy[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(legacy as CFDictionary, &result) == errSecSuccess,
              let found = result as? [String: Any],
              let data = found[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else { return }
        // Add the shared copy first, then remove the old one by its own group, so being stopped
        // halfway leaves a copy either way.
        guard save(key: key, value: value) else { return }
        if let oldGroup = found[kSecAttrAccessGroup as String] as? String {
            var old = query(key, inGroup: false)
            old[kSecAttrAccessGroup as String] = oldGroup
            SecItemDelete(old as CFDictionary)
        }
    }

    private nonisolated func exists(_ query: [String: Any]) -> Bool {
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    nonisolated func load(key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated func save(key: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query(key).merging(attributes) { $1 }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    nonisolated func delete(key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
