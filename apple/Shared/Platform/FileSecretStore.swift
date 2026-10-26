import Foundation
import XeniaCore

/// Development builds on the Mac only: secrets in a file inside the app's own container, readable
/// only by this user. See `AppEnvironment.secretStore()` for why.
final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    nonisolated init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = support.appending(path: "Xenia/dev-secrets.plist")
    }

    /// Every secret, or nil when the file is there but can't be read (as behind a locked screen):
    /// writing then would replace them all with one.
    private nonisolated func read() -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private nonisolated func write(_ values: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListEncoder().encode(values)
            // Readable while the Mac is locked after its first unlock, as the Keychain's copy is:
            // "complete" protection made sign-in fail behind a locked screen.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
            return true
        } catch {
            return false
        }
    }

    nonisolated func load(key: String) -> String? {
        lock.withLock { read()?[key] }
    }

    nonisolated func save(key: String, value: String) -> Bool {
        lock.withLock {
            guard var values = read() else { return false }
            values[key] = value
            return write(values)
        }
    }

    nonisolated func delete(key: String) {
        lock.withLock {
            guard var values = read() else { return }
            values[key] = nil
            _ = write(values)
        }
    }
}
