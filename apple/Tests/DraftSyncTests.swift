import CryptoKit
import Foundation
import Testing
@testable import Xenia

/// The same key on every device, as iCloud Keychain gives them; `reloaded` stands in for one
/// that arrives late.
final class FixedKey: DraftKeyProviding {
    var current: SymmetricKey?
    var reloaded: SymmetricKey?
    init(_ key: SymmetricKey?, reloaded: SymmetricKey? = nil) {
        current = key
        self.reloaded = reloaded
    }
    func key() -> SymmetricKey? { current }
    func reloadedKey() -> SymmetricKey? {
        if let reloaded { current = reloaded }
        return reloaded
    }
}

@MainActor
struct DraftSyncTests {
    let store = MemoryStore()
    let key = SymmetricKey(size: .bits256)
    let center = NotificationCenter()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A second device, collecting what it's handed.
    private func device(key: DraftKeyProviding? = nil) -> (DraftSync, () -> [DraftSync.Entry]) {
        let sync = DraftSync(store: store, keys: key ?? FixedKey(self.key))
        var received: [DraftSync.Entry] = []
        sync.onReceive = { received.append($0) }
        return (sync, { received })
    }

    private func changed(_ keys: [String]) {
        center.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil,
                    userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: keys])
    }

    @Test("A draft typed on one device reaches the other, and iCloud sees neither the words nor the room")
    func roundTrip() throws {
        let (mac, _) = device()
        mac.start(account: "@luke:example.org", center: center, now: now)
        mac.publish(room: "!design:example.org", thread: "$root", text: "See you at the review", now: now)

        let stored = try #require(store.values.first)
        #expect(stored.key.hasPrefix(DraftSync.prefix))
        #expect(!stored.key.contains("design"))
        let sealed = try #require(stored.value as? Data)
        #expect(sealed.range(of: Data("See you".utf8)) == nil)
        #expect(sealed.range(of: Data("design".utf8)) == nil)

        let (phone, received) = device()
        phone.start(account: "@luke:example.org", center: center, now: now)
        #expect(received() == [DraftSync.Entry(
            account: "@luke:example.org", room: "!design:example.org", thread: "$root", text: "See you at the review", updated: now
        )])
    }

    @Test("Live changes apply once, older copies never win, and other accounts' drafts are left alone")
    func ordering() throws {
        let (phone, received) = device()
        phone.start(account: "@luke:example.org", center: center, now: now)
        let (mac, _) = device()
        mac.start(account: "@luke:example.org", center: NotificationCenter(), now: now)
        mac.publish(room: "!a:example.org", thread: nil, text: "Newer", now: now)
        let cloudKey = DraftSync.cloudKey(account: "@luke:example.org", room: "!a:example.org", thread: nil)
        changed([cloudKey])
        changed([cloudKey])
        #expect(received().map(\.text) == ["Newer"])

        // A stale copy (an offline device catching up) doesn't undo the newer one.
        store.values[cloudKey] = DraftSync.seal(DraftSync.Entry(
            account: "@luke:example.org", room: "!a:example.org", thread: nil, text: "Older", updated: now.addingTimeInterval(-60)
        ), with: key)
        changed([cloudKey])
        #expect(received().map(\.text) == ["Newer"])

        // Sent on the Mac: the draft clears here too.
        mac.publish(room: "!a:example.org", thread: nil, text: "  ", now: now.addingTimeInterval(5))
        changed([cloudKey])
        #expect(received().last?.text == "")

        let other = DraftSync.cloudKey(account: "@maya:example.org", room: "!a:example.org", thread: nil)
        store.values[other] = DraftSync.seal(DraftSync.Entry(
            account: "@maya:example.org", room: "!a:example.org", thread: nil, text: "Hers", updated: now
        ), with: key)
        changed([other])
        #expect(!received().map(\.text).contains("Hers"))
    }

    @Test("Cleared drafts are tidied away after a week; turning sync off removes only this account's")
    func tidying() {
        let (mac, _) = device()
        mac.start(account: "@luke:example.org", center: center, now: now)
        mac.publish(room: "!old:example.org", thread: nil, text: "", now: now.addingTimeInterval(-8 * 24 * 3600))
        mac.publish(room: "!kept:example.org", thread: nil, text: "Still writing", now: now)
        let other = DraftSync.cloudKey(account: "@maya:example.org", room: "!a:example.org", thread: nil)
        store.values[other] = DraftSync.seal(DraftSync.Entry(
            account: "@maya:example.org", room: "!a:example.org", thread: nil, text: "Hers", updated: now
        ), with: key)

        let (phone, received) = device()
        phone.start(account: "@luke:example.org", center: NotificationCenter(), now: now)
        #expect(received().map(\.text) == ["Still writing"])
        #expect(store.values[DraftSync.cloudKey(account: "@luke:example.org", room: "!old:example.org", thread: nil)] == nil)

        phone.removeAll()
        #expect(Array(store.values.keys) == [other])
    }

    @Test("A key that reaches this device late is picked up rather than the drafts being lost")
    func lateKey() {
        let (mac, _) = device()
        mac.start(account: "@luke:example.org", center: center, now: now)
        mac.publish(room: "!a:example.org", thread: nil, text: "Hello", now: now)

        let (phone, received) = device(key: FixedKey(SymmetricKey(size: .bits256), reloaded: key))
        phone.start(account: "@luke:example.org", center: NotificationCenter(), now: now)
        #expect(received().map(\.text) == ["Hello"])
    }
}
