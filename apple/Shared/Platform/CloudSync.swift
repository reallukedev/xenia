import Foundation
import Security

// MARK: - Settings

/// A key-value store in iCloud. `NSUbiquitousKeyValueStore` in the app; an in-memory one in tests.
protocol CloudKeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
    /// Every key the store holds.
    var keys: [String] { get }
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStore {
    var keys: [String] { Array(dictionaryRepresentation.keys) }
}

/// Keeps Settings the same on every device signed in to the same iCloud account: a change here
/// goes up at once, a change from another device comes down and applies. Nothing secret goes
/// through it, only the switches in Settings.
@Observable
final class CloudPreferences {
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let store: CloudKeyValueStore
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// When a change last came from another device, for Settings' status line.
    private(set) var lastRemoteChange: Date?

    init(preferences: Preferences, store: CloudKeyValueStore) {
        self.preferences = preferences
        self.store = store
    }

    /// The iCloud store, or nil when this build can't use iCloud (a Mac debug build has no
    /// iCloud entitlement, and asking for the store without one crashes).
    static var systemStore: CloudKeyValueStore? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        #if os(macOS) && DEBUG
        return nil
        #else
        return NSUbiquitousKeyValueStore.default
        #endif
    }

    /// Takes what iCloud has (another device's choices win over this device's defaults), then
    /// follows changes both ways.
    func start(center: NotificationCenter = .default) {
        store.synchronize()
        pull(keys: Preferences.syncedKeys)
        preferences.onSave = { [weak self] key, value in
            self?.store.set(value, forKey: Self.cloudKey(key))
        }
        observer = center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated {
                guard let self else { return }
                let keys = changed.map { $0.compactMap(Self.preferenceKey) } ?? Preferences.syncedKeys
                self.pull(keys: keys)
                self.lastRemoteChange = .now
            }
        }
    }

    func stop(center: NotificationCenter = .default) {
        if let observer { center.removeObserver(observer) }
        observer = nil
        preferences.onSave = nil
    }

    /// Applies iCloud's values for `keys`; keys iCloud hasn't seen go up from this device.
    func pull(keys: [String]) {
        for key in keys {
            if let value = store.object(forKey: Self.cloudKey(key)) as? Bool {
                preferences.apply(remote: value, forKey: key)
            } else if let local = preferences.value(forKey: key) {
                store.set(local, forKey: Self.cloudKey(key))
            }
        }
    }

    static func cloudKey(_ key: String) -> String { "pref.\(key)" }

    static func preferenceKey(_ cloudKey: String) -> String? {
        guard cloudKey.hasPrefix("pref.") else { return nil }
        let key = String(cloudKey.dropFirst("pref.".count))
        return Preferences.syncedKeys.contains(key) ? key : nil
    }
}

// MARK: - Account

/// The account, kept in iCloud Keychain so Xenia signs in by itself on your other Apple devices:
/// the server, your Matrix ID, your password and, once you have one, your recovery key.
///
/// iCloud Keychain is end-to-end encrypted: Apple can't read it. Each device still signs in as its
/// own session with its own encryption keys (sharing one session between devices would break
/// Matrix's encryption), and the recovery key lets it read older messages and trust itself.
nonisolated struct CloudAccount: Codable, Equatable, Sendable {
    var homeserver: String
    var userID: String
    var password: String
    var recoveryKey: String?
}

/// Reads and writes the `CloudAccount`. Every call is safe without iCloud: it just finds nothing.
nonisolated struct CloudAccountStore {
    private let service = "dev.xenia.account"
    private let account = "matrix"

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        if let group = AppGroup.sharedKeychainGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    func load() -> CloudAccount? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(CloudAccount.self, from: data)
    }

    @discardableResult
    func save(_ value: CloudAccount) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        // Synced items can't be "this device only"; after first unlock is the strictest that syncs.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: "Xenia (\(value.userID))",
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Updates the saved account in place (a new recovery key, a new password).
    func update(_ change: (inout CloudAccount) -> Void) {
        guard var current = load() else { return }
        change(&current)
        save(current)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
