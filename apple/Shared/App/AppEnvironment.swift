import Foundation
import XeniaCore
#if os(iOS)
import UIKit
#endif

/// Where the app keeps its files, how it introduces itself, and its launch arguments.
enum AppEnvironment {
    /// Where the core keeps the session in the secret store (see xenia-core's `session.rs`).
    nonisolated static let sessionKey = "xenia.session.v1"

    /// Where the stores live, and this device's names. The notification extension passes
    /// `forExtension`: it never creates or moves folders, since an empty folder it made would look
    /// like moved stores to the app.
    static func clientConfig(forExtension: Bool = false) -> ClientConfig {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var data = support.appending(path: "Xenia", directoryHint: .isDirectory)
        var cache = caches.appending(path: "Xenia", directoryHint: .isDirectory)
        // On iPhone the stores live in the App Group, where the notification extension can open
        // them to decrypt pushes. Stores from before the group existed move there once; if the
        // move fails, the app keeps using them where they are (and pushes show generic text).
        if let group = AppGroup.containerURL {
            let sharedData = group.appending(path: "Library/Application Support/Xenia", directoryHint: .isDirectory)
            let sharedCache = group.appending(path: "Library/Caches/Xenia", directoryHint: .isDirectory)
            if forExtension || moveIfNeeded(from: data, to: sharedData) {
                data = sharedData
                if forExtension || moveIfNeeded(from: cache, to: sharedCache) { cache = sharedCache }
            }
        }
        if !forExtension {
            try? files.createDirectory(at: data, withIntermediateDirectories: true)
            try? files.createDirectory(at: cache, withIntermediateDirectories: true)
        }
        // The stores hold encryption keys: keep them out of iCloud and device backups.
        var excluded = data
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        return ClientConfig(
            dataDir: data.path(percentEncoded: false),
            cacheDir: cache.path(percentEncoded: false),
            deviceName: deviceName,
            userAgent: "Xenia/\(version) (\(platform) \(os.majorVersion).\(os.minorVersion))",
            defaultServer: defaultServer
        )
    }

    /// This device's name in the account's session list and for its pushes.
    static var deviceName: String {
        #if os(iOS)
        String(localized: "Xenia on iPhone", comment: "This device's name in the account's session list")
        #else
        String(localized: "Xenia on Mac", comment: "This device's name in the account's session list")
        #endif
    }

    /// The server sign-in starts with: matrix.org, or a local test server in development.
    static var defaultServer: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "XeniaDefaultServer") as? String
        return configured.flatMap { $0.isEmpty ? nil : $0 } ?? "matrix.org"
    }

    /// The process's one secret store.
    nonisolated static func secretStore() -> SecretStore { sharedSecretStore }

    /// Made on first use, so moving an old session into the shared group (a few Keychain
    /// queries) runs once per process rather than on every read.
    private nonisolated static let sharedSecretStore: SecretStore = {
        #if os(macOS) && DEBUG
        // Local Mac debug builds are ad-hoc signed, so every build is a new Keychain identity and
        // macOS would ask for the password each launch. They keep the session in a file inside
        // the app's container instead. Release builds are team-signed and use the Keychain.
        return FileSecretStore()
        #else
        let store = KeychainStore(group: AppGroup.keychainGroup)
        store.moveIntoGroup(key: sessionKey)
        return store
        #endif
    }()

    /// Moves a folder of stores to its new home. Returns whether the new home is the one to use:
    /// nothing to move, or the move worked. A new home holding no sessions (made by an older
    /// build, or empty) doesn't count as moved.
    private static func moveIfNeeded(from old: URL, to new: URL) -> Bool {
        let files = FileManager.default
        let oldSessions = old.appending(path: "sessions").path(percentEncoded: false)
        let newSessions = new.appending(path: "sessions").path(percentEncoded: false)
        guard files.fileExists(atPath: oldSessions) else { return true }
        if files.fileExists(atPath: newSessions) { return true }
        do {
            if files.fileExists(atPath: new.path(percentEncoded: false)) { try files.removeItem(at: new) }
            try files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }

    /// Where this device's pushes go, from the build settings; nil turns push off.
    static var pushGateway: String? {
        let configured = Bundle.main.object(forInfoDictionaryKey: "XeniaPushGateway") as? String
        return configured.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// True while the app only hosts the unit tests: it mustn't restore the real session, sync or
    /// ask for notifications behind them.
    static var isHostingTests: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        return false
        #endif
    }

    /// A debug-only launch argument like `-XeniaResetSession YES`.
    static func launchFlag(_ name: String) -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: name)
        #else
        return false
        #endif
    }

    /// Debug-only `-XeniaDevSignIn user:password`, for automated runs against the test server.
    static func devSignIn() -> (user: String, password: String)? {
        #if DEBUG
        guard let value = UserDefaults.standard.string(forKey: "XeniaDevSignIn"),
              let colon = value.firstIndex(of: ":") else { return nil }
        return (String(value[..<colon]), String(value[value.index(after: colon)...]))
        #else
        return nil
        #endif
    }
}
