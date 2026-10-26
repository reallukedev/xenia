import CryptoKit
import Foundation
import XeniaCore
import Synchronization

/// The conversation list as it last looked, kept so the next launch draws it on the first frame
/// as Messages does, instead of a loading shape. It holds what the list shows (names, the last
/// message's preview), so it lives in the app's own container, protected like its other files,
/// and goes away on sign-out.
nonisolated enum ListSnapshotStore {
    private static let prefix = "List Snapshot "
    private static var folder: URL { URL.applicationSupportDirectory }

    /// One file per saved session, so a list is only ever drawn for the session that saved it
    /// (a development build and the installed app can share a container).
    private static func url(for session: String) -> URL {
        let digest = SHA256.hash(data: Data(session.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: prefix + digest, directoryHint: .notDirectory)
    }

    static func load(session: String) -> ListSnapshot? {
        guard let data = try? Data(contentsOf: url(for: session)) else { return nil }
        return decodeListSnapshot(bytes: data)
    }

    /// Writes off the main thread. Other sessions' lists stay: a development build and the
    /// installed app can share a container, each with its own.
    static func save(_ snapshot: ListSnapshot, session: String) {
        let url = url(for: session)
        let folder = folder
        Task.detached(priority: .utility) {
            let data = encodeListSnapshot(snapshot: snapshot)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #if os(iOS)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? data.write(to: url, options: .atomic)
            #endif
        }
    }

    /// Signed out: every saved list goes, whoever it belonged to.
    static func remove() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Opens once the session is live. Photos and conversations asked for while the saved list is
/// showing wait here instead of failing. A cancelled wait (a conversation closed meanwhile) ends
/// at once, so check `Task.isCancelled` after waiting.
@MainActor
final class SessionGate {
    private(set) var isOpen = false
    /// Locked rather than on the main actor: cancellation removes a waiter from any thread.
    private nonisolated let waiters = Mutex<[UUID: CheckedContinuation<Void, Never>]>([:])

    /// Signed out (not just still opening): nothing is coming, so nobody waits.
    private var hasEnded = false

    func wait() async {
        if isOpen || hasEnded || Task.isCancelled { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Checked under the lock: cancelled before this, the handler found nothing to end.
                let cancelled = waiters.withLock { waiters in
                    if Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if cancelled { continuation.resume() }
            }
        } onCancel: {
            waiters.withLock { $0.removeValue(forKey: id) }?.resume()
        }
    }

    func open() {
        isOpen = true
        hasEnded = false
        release()
    }

    /// Signed out: nothing is coming, so whoever waits goes on (and finds no session).
    func close() {
        isOpen = false
        hasEnded = true
        release()
    }

    private func release() {
        let waiting = waiters.withLock { waiters in
            defer { waiters = [:] }
            return waiters.values
        }
        waiting.forEach { $0.resume() }
    }
}
