import CryptoKit
import Foundation
import Security

/// Unsent drafts follow you between your devices through iCloud's key-value store. Each draft is
/// sealed with a key kept in iCloud Keychain (end-to-end encrypted), so iCloud holds ciphertext
/// only: neither the words nor which conversation they belong to.
@MainActor
final class DraftSync {
    /// A synced draft, once opened. Empty text is a cleared draft (sent, or deleted).
    nonisolated struct Entry: Codable, Equatable, Sendable {
        var account: String
        var room: String
        var thread: String?
        var text: String
        var updated: Date
    }

    nonisolated static let prefix = "draft.v1."
    /// Cleared drafts are kept this long so every device hears of it, then tidied away.
    nonisolated static let clearedLifetime: TimeInterval = 7 * 24 * 3600

    private let store: CloudKeyValueStore
    private let keys: DraftKeyProviding
    private var account: String?
    private var observer: NSObjectProtocol?
    /// When each draft last changed as far as this device knows, so an older copy never wins.
    private var known: [String: Date] = [:]
    /// Called with a draft from another device; empty text clears it here.
    var onReceive: ((Entry) -> Void)?

    init(store: CloudKeyValueStore, keys: DraftKeyProviding = DraftKeyStore()) {
        self.store = store
        self.keys = keys
    }

    var isRunning: Bool { account != nil }

    /// Starts for a signed-in account: brings down what other devices left, then follows changes.
    func start(account: String, center: NotificationCenter = .default, now: Date = .now) {
        guard self.account != account else { return }
        stop(center: center)
        self.account = account
        observer = center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated {
                guard let self else { return }
                self.receive(keys: changed ?? self.store.keys)
            }
        }
        store.synchronize()
        receive(keys: store.keys, now: now)
    }

    func stop(center: NotificationCenter = .default) {
        if let observer { center.removeObserver(observer) }
        observer = nil
        account = nil
        known = [:]
    }

    /// This device's draft changed: the other devices get it.
    func publish(room: String, thread: String?, text: String, now: Date = .now) {
        guard let account, let key = keys.key() else { return }
        let cloudKey = Self.cloudKey(account: account, room: room, thread: thread)
        let entry = Entry(account: account, room: room, thread: thread, text: Self.isEmpty(text) ? "" : text, updated: now)
        guard let sealed = Self.seal(entry, with: key) else { return }
        known[cloudKey] = now
        store.set(sealed, forKey: cloudKey)
    }

    /// Drafts stop syncing: this account's leave iCloud, on every device.
    func removeAll() {
        guard let account else { return }
        for cloudKey in store.keys where cloudKey.hasPrefix(Self.prefix) {
            if open(cloudKey)?.account == account { store.set(nil, forKey: cloudKey) }
        }
        known = [:]
    }

    private func receive(keys changed: [String], now: Date = .now) {
        guard let account else { return }
        for cloudKey in changed where cloudKey.hasPrefix(Self.prefix) {
            // Removed (tidied away): nothing to apply.
            guard let entry = open(cloudKey), entry.account == account else { continue }
            if Self.isEmpty(entry.text), now.timeIntervalSince(entry.updated) > Self.clearedLifetime {
                store.set(nil, forKey: cloudKey)
                continue
            }
            if let seen = known[cloudKey], seen >= entry.updated { continue }
            known[cloudKey] = entry.updated
            onReceive?(entry)
        }
    }

    private func open(_ cloudKey: String) -> Entry? {
        guard let sealed = store.object(forKey: cloudKey) as? Data else { return nil }
        // The key may have just arrived from another device's first sync: look again once.
        if let key = keys.key(), let entry = Self.open(sealed, with: key) { return entry }
        guard let fresh = keys.reloadedKey() else { return nil }
        return Self.open(sealed, with: fresh)
    }

    // MARK: Format

    /// Hashed, so the key names in iCloud don't say who you talk to either.
    nonisolated static func cloudKey(account: String, room: String, thread: String?) -> String {
        let digest = SHA256.hash(data: Data("\(account)\n\(room)\n\(thread ?? "")".utf8))
        return prefix + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func seal(_ entry: Entry, with key: SymmetricKey) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let plain = try? encoder.encode(entry) else { return nil }
        return try? AES.GCM.seal(plain, using: key).combined
    }

    nonisolated static func open(_ sealed: Data, with key: SymmetricKey) -> Entry? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Entry.self, from: plain)
    }

    nonisolated static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Where the drafts' key comes from: iCloud Keychain in the app, a fixed key in tests.
protocol DraftKeyProviding {
    func key() -> SymmetricKey?
    /// The key as the Keychain has it now, after another device may have replaced it.
    func reloadedKey() -> SymmetricKey?
}

/// The drafts' key in iCloud Keychain, made by whichever device syncs a draft first.
final class DraftKeyStore: DraftKeyProviding {
    private var cached: SymmetricKey?

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.xenia.drafts",
            kSecAttrAccount as String: "key",
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

    func key() -> SymmetricKey? {
        if let cached { return cached }
        cached = load() ?? create()
        return cached
    }

    func reloadedKey() -> SymmetricKey? {
        let fresh = load()
        if let fresh { cached = fresh }
        return fresh
    }

    private func load() -> SymmetricKey? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    private func create() -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        var attributes = query
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        // Synced items can't be "this device only"; after first unlock is the strictest that syncs.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = "Xenia Drafts"
        switch SecItemAdd(attributes as CFDictionary, nil) {
        case errSecSuccess: return key
        // Another device's arrived meanwhile: use that one.
        case errSecDuplicateItem: return load()
        default: return nil
        }
    }
}
