import Foundation
import Security

/// What the app shares with its notification extensions, which decrypt pushed messages in their
/// own processes: the stores, the preferences and the session's secrets. Local Mac debug builds
/// are signed to run locally, without the group, so they keep everything in the app's container.
nonisolated enum AppGroup {
    /// "group.<bundle ID>", from the Info.plist so a build under another bundle ID uses its own.
    static let identifier: String = {
        let group = Bundle.main.object(forInfoDictionaryKey: "XeniaAppGroup") as? String
        return group.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "group.dev.xenia.matrix"
    }()

    /// This build carries the group: every iPhone build, and team-signed Mac builds.
    static let isAvailable: Bool = {
        #if os(iOS)
        true
        #else
        hasEntitlement("com.apple.security.application-groups")
        #endif
    }()

    /// The shared container, or nil without the group.
    static var containerURL: URL? {
        guard isAvailable else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    #if os(macOS)
    /// Whether the running build was signed with an entitlement.
    static func hasEntitlement(_ name: String) -> Bool {
        entitlement(name) != nil
    }

    /// An entitlement's value in the running build's signature.
    static func entitlement(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }
    #endif

    /// Preferences both processes read (previews, sounds, Time Sensitive mentions).
    static var defaults: UserDefaults {
        guard isAvailable, sharesPreferences else { return .standard }
        return UserDefaults(suiteName: identifier) ?? .standard
    }

    /// Whether macOS lets the group's preferences be written. A Developer ID profile may leave a
    /// "group." group out; macOS then refuses every write, and each refusal blocks the main
    /// thread on cfprefsd, so flipping switches quickly hangs the app. Such a build keeps its
    /// preferences in its own defaults instead.
    private static let sharesPreferences: Bool = {
        #if os(macOS)
        guard identifier.hasPrefix("group.") else { return true }
        let groups = profileEntitlement("com.apple.security.application-groups") as? [String]
        return groups?.contains(identifier) == true
        #else
        true
        #endif
    }()

    #if os(macOS)
    /// An entitlement the build's provisioning profile grants, as opposed to one it claims.
    private static func profileEntitlement(_ name: String) -> Any? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        guard let signed = try? Data(contentsOf: url) else { return nil }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let fed = signed.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        var content: CFData?
        guard fed == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content,
              let profile = try? PropertyListSerialization.propertyList(from: content as Data, format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any] else { return nil }
        return entitlements[name]
    }
    #endif

    /// Xenia's own lock (Face ID) is on, as the extensions see it: notifications then offer no
    /// history and no way to reply or mark as read without opening, and unlocking, Xenia.
    static var isAppLockOn: Bool {
        get { defaults.bool(forKey: "xenia.lock.requiresUnlock") }
        set { defaults.set(newValue, forKey: "xenia.lock.requiresUnlock") }
    }

    /// The Keychain access group for the session, like "TEAMID.dev.xenia.shared", from the
    /// Info.plist so the team prefix follows the signing team. Nil without the group.
    static var keychainGroup: String? {
        isAvailable ? sharedKeychainGroup : nil
    }

    /// The same group on both platforms, for what iCloud Keychain carries between them: an item
    /// saved on the iPhone is readable on the Mac only when both put it in one group.
    static var sharedKeychainGroup: String? {
        let group = Bundle.main.object(forInfoDictionaryKey: "XeniaKeychainGroup") as? String
        return group.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }
}
