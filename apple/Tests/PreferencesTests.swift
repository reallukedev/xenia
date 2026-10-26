import Foundation
import Testing
@testable import Xenia

/// Settings in defaults suites of their own, removed afterwards: tests never touch the app's.
struct PreferencesTests {
    let suites = [UUID().uuidString, UUID().uuidString].map { "xenia.tests.\($0)" }
    let defaults: UserDefaults
    let legacy: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suites[0]))
        legacy = try #require(UserDefaults(suiteName: suites[1]))
    }

    private func cleanUp() {
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
    }

    @Test("The list layout reads and writes the two settings older versions know", arguments: [
        (ListLayout.separate, false, false),
        (.together, true, false),
        (.sections, true, true),
    ])
    func listLayout(layout: ListLayout, unified: Bool, sectioned: Bool) {
        defer { cleanUp() }
        let preferences = Preferences(defaults: defaults, legacy: nil)
        preferences.listLayout = layout
        #expect(preferences.unifiedList == unified)
        #expect(preferences.sectionedList == sectioned)
        #expect(Preferences(defaults: defaults, legacy: nil).listLayout == layout)
    }

    @Test("Going back to separate lists remembers whether the one list had sections")
    func separateKeepsSections() {
        defer { cleanUp() }
        let preferences = Preferences(defaults: defaults, legacy: nil)
        preferences.listLayout = .sections
        preferences.listLayout = .separate
        preferences.unifiedList = true
        #expect(preferences.listLayout == .sections)
    }

    @Test("Settings from before the shared defaults carry over once, without overwriting newer ones")
    func migration() {
        defer { cleanUp() }
        legacy.set(false, forKey: "xenia.pref.sounds")
        legacy.set(false, forKey: "xenia.pref.showPreviews")
        defaults.set(true, forKey: "xenia.pref.showPreviews")

        let preferences = Preferences(defaults: defaults, legacy: legacy)
        #expect(preferences.sounds == false)
        #expect(preferences.showPreviews == true)

        // Once moved, the old store is no longer read.
        legacy.set(false, forKey: "xenia.pref.sendReadReceipts")
        #expect(Preferences(defaults: defaults, legacy: legacy).sendReadReceipts == true)
    }
}
