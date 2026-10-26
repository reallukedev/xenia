import Foundation
import OSLog
import XeniaCore
import UserNotifications

/// Turns a push (a room and an event ID, nothing more) into a notification: opens the app's
/// session from the shared stores, fetches and decrypts the message with the core, and words it
/// as the app would. If that can't finish in time, the push shows as "New Message".
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    private static let log = Logger(subsystem: "dev.xenia.matrix", category: "push")

    // Whether the system gets as far as making the extension: on the Mac it has been launching
    // the process and then giving up on it before any push arrived here.
    override init() {
        super.init()
        Self.log.notice("Extension started")
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        Self.log.notice("Push received")
        let fallback = Self.fallbackContent(for: request)
        lock.withLock {
            self.contentHandler = contentHandler
            self.fallback = fallback
        }
        let info = request.content.userInfo
        guard let roomID = info["room_id"] as? String, let eventID = info["event_id"] as? String else {
            finish(with: fallback)
            return
        }
        let pushedBadge = request.content.badge
        let work = Task { [self] in
            let outcome = await Decoders.shared.describe(roomID: roomID, eventID: eventID)
            // The server counts conversations with unread notifications; ones flagged unread by
            // hand it can't see, and the app's own badge counts them.
            let flagged = await Decoders.shared.flaggedUnread(except: roomID)
            let badge = pushedBadge.map { NSNumber(value: $0.intValue + flagged) }
            // A new object rather than a change to the one the time limit may be handing over.
            lock.withLock {
                self.fallback = self.fallback.map { fallback in Self.copy(fallback) { $0.badge = badge } }
            }
            Self.log.notice("Push handled: \(outcome.name, privacy: .public)")
            switch outcome {
            case .show(let pushed, let media):
                let preferences = NotificationContent.Preferences.current
                let worded = NotificationContent.make(pushed.message, preferences: preferences)
                worded.badge = badge
                if pushed.isQuiet {
                    finish(quietly: worded)
                } else {
                    // If the photos run out the clock, the decrypted words still show.
                    lock.withLock { self.fallback = worded }
                    finish(with: await NotificationExtras.finish(worded, message: pushed.message, preferences: preferences, media: media))
                }
            case .hide:
                if let fallback = lock.withLock({ self.fallback }) { finish(quietly: Self.placeholder(fallback)) }
            case .signedOut:
                // A pusher the server still has from before signing out: nothing here is unread.
                if let fallback = lock.withLock({ self.fallback }) {
                    finish(quietly: Self.placeholder(fallback) { $0.badge = 0 })
                }
            case .fallback:
                if let fallback = lock.withLock({ self.fallback }) { finish(with: fallback) }
            }
        }
        lock.withLock { self.work = work }
    }

    /// Without Apple's filtering entitlement an extension can't drop a push: empty content shows
    /// the push's own placeholder. So until Xenia has it, a push that shouldn't alert lands in
    /// Notification Center without a banner, sound or lighting the screen.
    private func finish(quietly content: UNMutableNotificationContent) {
        if Self.canSilencePushes {
            // Nothing shows, but the badge still follows (cleared after signing out, say).
            let silent = UNMutableNotificationContent()
            silent.badge = content.badge
            finish(with: silent)
        } else {
            finish(with: Self.copy(content) {
                $0.interruptionLevel = .passive
                $0.sound = nil
            })
        }
    }

    /// A changed copy: the stored fallback can be handed over by the time limit at any moment,
    /// so it's never changed in place.
    private static func copy(
        _ content: UNMutableNotificationContent,
        _ change: (UNMutableNotificationContent) -> Void
    ) -> UNMutableNotificationContent {
        let copy = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        change(copy)
        return copy
    }

    /// A push with nothing to show (a reaction, an edit, a read elsewhere) still has to show
    /// something until Xenia can silence pushes. It's marked, so the next push and the app take
    /// it away again rather than leaving "New Message" piling up in Notification Center.
    private static func placeholder(
        _ content: UNMutableNotificationContent,
        _ change: (UNMutableNotificationContent) -> Void = { _ in }
    ) -> UNMutableNotificationContent {
        copy(content) {
            $0.userInfo[NotificationContent.placeholderKey] = true
            change($0)
        }
    }

    /// `XENIA_CAN_SILENCE_PUSHES`: on once Apple grants the extension
    /// `com.apple.developer.usernotifications.filtering`.
    private static let canSilencePushes = Bundle.main.object(forInfoDictionaryKey: "XeniaCanSilencePushes") as? String == "YES"

    override func serviceExtensionTimeWillExpire() {
        Self.log.error("Ran out of time; showing the fallback")
        let (work, fallback) = lock.withLock { (self.work, self.fallback) }
        work?.cancel()
        if let fallback { finish(with: fallback) }
    }

    /// Hands the content over once: the task and the time limit can both try.
    private func finish(with content: UNNotificationContent) {
        let handler: ((UNNotificationContent) -> Void)? = lock.withLock {
            let handler = contentHandler
            contentHandler = nil
            return handler
        }
        guard let handler else { return }
        handler(content)
        // Only once the notification is handed over: placeholders from earlier pushes go.
        NotificationContent.removePlaceholders()
    }

    private static func fallbackContent(for request: UNNotificationRequest) -> UNMutableNotificationContent {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.title = String(localized: "Xenia")
        content.subtitle = ""
        content.body = String(localized: "New Message")
        content.categoryIdentifier = NotificationContent.category
        if !NotificationContent.Preferences.current.sounds { content.sound = nil }
        if let roomID = request.content.userInfo["room_id"] as? String {
            content.threadIdentifier = roomID
            content.userInfo["roomID"] = roomID
        }
        return content
    }
}

/// What to do with a push.
private enum Outcome: @unchecked Sendable {
    case show(PushedMessage, NotificationMedia)
    /// My own message, deleted, or filtered by the push rules.
    case hide
    /// No one is signed in on this device.
    case signedOut
    /// Couldn't decode in time: "New Message".
    case fallback

    /// For the log: which way it went, never what the message said.
    var name: String {
        switch self {
        case .show: "shown"
        case .hide: "hidden"
        case .signedOut: "signed out"
        case .fallback: "failed"
        }
    }
}

/// One session per extension process, reused by the pushes it handles and reopened when the
/// app's session changes (signed out, or another account). Opening is shared: a push that
/// arrives while the first is still opening the stores waits for that, rather than opening them
/// a second time.
private actor Decoders {
    static let shared = Decoders()

    private var decoder: PushDecoder?
    /// The saved session the decoder was opened with.
    private var openedWith: String?
    private var opening: (session: String, task: Task<PushDecoder?, Error>)?

    func flaggedUnread(except roomID: String) -> Int {
        Int(decoder?.flaggedUnreadRooms(exceptRoomId: roomID) ?? 0)
    }

    private func decoder(for session: String, secrets: SecretStore) async throws -> PushDecoder? {
        if let decoder, openedWith == session { return decoder }
        if let opening, opening.session == session { return try await opening.task.value }
        decoder = nil
        openedWith = nil
        let task = Task {
            try await openPushDecoder(config: AppEnvironment.clientConfig(forExtension: true), secrets: secrets, extension: .service)
        }
        opening = (session, task)
        defer { if opening?.session == session { opening = nil } }
        let opened = try await task.value
        decoder = opened
        openedWith = opened == nil ? nil : session
        return opened
    }

    func describe(roomID: String, eventID: String) async -> Outcome {
        let secrets = AppEnvironment.secretStore()
        guard let session = secrets.load(key: AppEnvironment.sessionKey) else {
            decoder = nil
            openedWith = nil
            return .signedOut
        }
        do {
            guard let decoder = try await decoder(for: session, secrets: secrets) else { return .signedOut }
            let roomsNotifyForAll = NotificationContent.Preferences.current.roomsNotifyForAll
            guard let pushed = try await decoder.describe(roomId: roomID, eventId: eventID, roomsNotifyForAll: roomsNotifyForAll) else {
                return .hide
            }
            return .show(pushed, NotificationMedia(
                avatar: { mxc, size in try? await decoder.loadAvatar(mxcUrl: mxc, sizePx: size) },
                picture: { source in
                    let side = NotificationExtras.picturePixels
                    return try? await decoder.loadThumbnail(source: source, widthPx: side, heightPx: side)
                }
            ))
        } catch {
            // The kind of failure is safe to keep; its details may name rooms or people.
            let kind = String(describing: error).prefix { $0 != "(" }
            Logger(subsystem: "dev.xenia.matrix", category: "push")
                .error("Couldn't describe a push: \(kind, privacy: .public) \(String(describing: error), privacy: .private)")
            return .fallback
        }
    }
}
