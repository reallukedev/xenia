import Foundation
import Testing
@testable import Xenia

/// iCloud's key-value store, in memory.
final class MemoryStore: CloudKeyValueStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func synchronize() -> Bool { true }
    var keys: [String] { Array(values.keys) }
}

/// Settings in a defaults suite of their own, removed afterwards: tests never touch the app's.
@MainActor
struct CloudSyncTests {
    let suiteName = "xenia.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store = MemoryStore()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Another device's choices come down on launch, and this device's fill in what's missing")
    func startMerges() {
        defer { cleanUp() }
        store.values[CloudPreferences.cloudKey("showPreviews")] = false
        let preferences = Preferences(defaults: defaults, legacy: nil)
        let cloud = CloudPreferences(preferences: preferences, store: store)
        cloud.start(center: NotificationCenter())
        #expect(preferences.showPreviews == false)
        // Unseen in iCloud: this device's value goes up.
        #expect(store.values[CloudPreferences.cloudKey("sounds")] as? Bool == true)
        // And it's kept locally, for the notification extension.
        #expect(defaults.object(forKey: "xenia.pref.showPreviews") as? Bool == false)
    }

    @Test("A change here goes up; one from elsewhere applies without echoing back")
    func bothWays() {
        defer { cleanUp() }
        let preferences = Preferences(defaults: defaults, legacy: nil)
        let cloud = CloudPreferences(preferences: preferences, store: store)
        let center = NotificationCenter()
        cloud.start(center: center)

        preferences.unifiedList = true
        #expect(store.values[CloudPreferences.cloudKey("unifiedList")] as? Bool == true)

        // Another device turns read receipts off.
        store.values[CloudPreferences.cloudKey("sendReadReceipts")] = false
        var echoes = 0
        let original = preferences.onSave
        preferences.onSave = { key, value in
            echoes += 1
            original?(key, value)
        }
        center.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil,
            userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: [CloudPreferences.cloudKey("sendReadReceipts")]]
        )
        #expect(preferences.sendReadReceipts == false)
        #expect(echoes == 0)
        #expect(cloud.lastRemoteChange != nil)
    }

    @Test("Every synced setting can be read and applied from another device", arguments: Preferences.syncedKeys)
    func everyKeyRoundTrips(key: String) {
        defer { cleanUp() }
        let preferences = Preferences(defaults: defaults, legacy: nil)
        guard let current = preferences.value(forKey: key) else {
            Issue.record("\(key) has no value(forKey:) case")
            return
        }
        preferences.apply(remote: !current, forKey: key)
        #expect(preferences.value(forKey: key) == !current, "\(key) has no apply(remote:) case")
        #expect(defaults.object(forKey: "xenia.pref.\(key)") as? Bool == !current)
    }

    @Test("Keys that aren't settings are ignored")
    func unknownKeys() {
        #expect(CloudPreferences.preferenceKey("pref.showPreviews") == "showPreviews")
        #expect(CloudPreferences.preferenceKey("pref.somethingElse") == nil)
        #expect(CloudPreferences.preferenceKey("other") == nil)
    }
}
