import Foundation
import OSLog
import XeniaCore
@preconcurrency import UserNotifications

/// Local notifications for new messages while Xenia runs: banners that reply and mark as read,
/// the app badge, and Time Sensitive pings for mentions.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    private let center = UNUserNotificationCenter.current()
    private static let log = Logger(subsystem: "dev.xenia.matrix", category: "notifications")
    private static let category = NotificationContent.category
    private static let replyAction = "xenia.reply"
    private static let markReadAction = "xenia.markRead"

    /// Automated runs (`-XeniaQuietNotifications YES`) never prompt or banner.
    private let isQuiet = AppEnvironment.launchFlag("XeniaQuietNotifications")
    private var placeholderSweep: Task<Void, Never>?

    override init() {
        super.init()
        center.delegate = self
        Self.registerCategories()
        // Placeholders from pushes that had nothing to show, left while Xenia wasn't running.
        if !isQuiet { NotificationContent.removePlaceholders() }
    }

    /// Reply and Mark as Read need the iPhone unlocked. With Xenia's own lock on there are none:
    /// the notification only opens Xenia, which asks for Face ID first.
    static func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: String(localized: "Reply"),
            options: [.authenticationRequired],
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Message")
        )
        let markRead = UNNotificationAction(
            identifier: markReadAction, title: String(localized: "Mark as Read"), options: [.authenticationRequired]
        )
        let actions = AppGroup.isAppLockOn ? [] : [reply, markRead]
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [], options: [])
        ])
    }

    /// Placeholders from pushes with nothing to show (a reaction, an edit, my own message) go a
    /// moment after a sync brings their events, once the extension has left them. Launching used
    /// to be the only time, and the Mac app rarely relaunches.
    func removePlaceholdersSoon() {
        // One sweep at a time, not restarted by every sync, which can come faster than it waits.
        guard !isQuiet, placeholderSweep == nil else { return }
        placeholderSweep = Task {
            try? await Task.sleep(for: .seconds(5))
            NotificationContent.removePlaceholders()
            placeholderSweep = nil
        }
    }

    /// Asks once, after the first sign-in's conversations have loaded, when the reason is clear.
    func requestAuthorizationIfNeeded() async {
        guard !isQuiet else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Announces a message. With `unlessPushed`, it waits a moment and stays quiet if a push has
    /// already shown the same message, so it's never announced twice; if the push never comes,
    /// this one still does.
    func post(_ message: IncomingMessage, preferences: Preferences, unlessPushed: Bool = false) {
        guard !isQuiet else {
            Self.log.info("Quiet run: skipped a notification for \(message.roomId, privacy: .public)")
            return
        }
        let wording = NotificationContent.Preferences(
            showPreviews: preferences.showPreviews,
            sounds: preferences.sounds,
            mentionsTimeSensitive: preferences.mentionsTimeSensitive
        )
        let worded = NotificationContent.make(message, preferences: wording)
        guard let client = model?.client else { return }
        let media = NotificationMedia(
            avatar: { mxc, size in try? await client.loadAvatar(mxcUrl: mxc, sizePx: size) },
            picture: { source in
                let side = NotificationExtras.picturePixels
                return try? await client.loadThumbnail(source: source, widthPx: side, heightPx: side)
            }
        )
        Task { [center] in
            if unlessPushed {
                try? await Task.sleep(for: Self.pushGrace)
                if await Self.wasPushed(message, center: center) { return }
            }
            let content = await NotificationExtras.finish(worded, message: message, preferences: wording, media: media)
            // Two messages in the same millisecond keep their own notifications.
            let id = message.eventId ?? String(message.timestampMs)
            let request = UNNotificationRequest(identifier: "\(message.roomId)-\(id)", content: content, trigger: nil)
            try? await center.add(request)
            if let eventID = message.eventId { await Self.replaceGenericPush(eventID: eventID, center: center) }
        }
    }

    /// How long a push gets to arrive before the running app announces a message itself.
    private static let pushGrace = Duration.seconds(6)

    /// The push for a message this app has just announced in full, if the extension couldn't word
    /// it: its "New Message" goes, so the message shows once.
    private static func replaceGenericPush(eventID: String, center: UNUserNotificationCenter) async {
        let generic = await center.deliveredNotifications().filter { notification in
            let info = notification.request.content.userInfo
            return notification.request.trigger is UNPushNotificationTrigger
                && info["timestampMs"] == nil
                && info["event_id"] as? String == eventID
        }.map(\.request.identifier)
        if !generic.isEmpty { center.removeDeliveredNotifications(withIdentifiers: generic) }
    }

    private static func wasPushed(_ message: IncomingMessage, center: UNUserNotificationCenter) async -> Bool {
        await center.deliveredNotifications().contains { notification in
            let info = notification.request.content.userInfo
            return notification.request.trigger is UNPushNotificationTrigger
                && info["roomID"] as? String == message.roomId
                && (info["timestampMs"] as? NSNumber)?.int64Value == message.timestampMs
        }
    }

    func updateBadge(chats: Int, rooms: Int) {
        guard !isQuiet else { return }
        center.setBadgeCount(chats + rooms)
    }

    /// Removes a conversation's notifications once it's been read.
    func clear(roomID: String) {
        clear(roomIDs: [roomID])
    }

    /// Removes the notifications of every conversation in `roomIDs`, in one pass.
    func clear(roomIDs: Set<String>) {
        guard !isQuiet else { return }
        Task { [center] in
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { roomIDs.contains($0.request.content.threadIdentifier) }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Removes the notifications of conversations read since they arrived, here or on another
    /// device: the conversation is read and nothing newer than the notification came since.
    func clearRead(in rooms: [RoomSummary]) {
        guard !isQuiet else { return }
        let read = Dictionary(rooms.filter { !$0.isUnread }.map { ($0.id, $0.timestampMs) }, uniquingKeysWith: max)
        guard !read.isEmpty else { return }
        Task { [center] in
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { notification in
                guard let latest = read[notification.request.content.threadIdentifier] else { return false }
                // A notification the extension couldn't word carries no message time, only when
                // it arrived, a little after the message was sent.
                if let sent = (notification.request.content.userInfo["timestampMs"] as? NSNumber)?.int64Value {
                    return sent <= latest
                }
                return Int64(notification.date.timeIntervalSince1970 * 1000) - 30_000 <= latest
            }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func clearAll() {
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A push while Xenia is in front: the running app already announced it (or chose not
        // to, because that conversation is on screen). Only the app's own banners show.
        if notification.request.trigger is UNPushNotificationTrigger { return [] }
        // The core already decided this deserves a banner (another conversation is on screen).
        return [.banner, .sound, .list]
    }

    // The completion handler, not the async form: UIKit must hear "done" on the main thread, and
    // the async form finished on a background one, which crashed every tap on a notification.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let roomID = info["roomID"] as? String else { return completionHandler() }
        let isDirect = info["isDirect"] as? Bool ?? true
        let action = response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            await handle(action: action, roomID: roomID, isDirect: isDirect, reply: reply)
            completionHandler()
        }
    }

    private func handle(action: String, roomID: String, isDirect: Bool, reply: String?) async {
        guard let model else { return }
        // A reply to a pushed notification can launch Xenia in the background: bring the session
        // up first (it's a no-op when already running).
        await model.start()
        switch action {
        case Self.replyAction:
            guard let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            // From a notification shown before Xenia's lock went on: nothing goes out without
            // unlocking, but the words aren't lost.
            if AppGroup.isAppLockOn {
                await saveAsDraft(text, roomID: roomID, model: model)
                return
            }
            // Replying isn't reading: no receipt, and the conversation stays unread (my own
            // message would otherwise count as reading it).
            do {
                try await model.client.sendMessage(roomId: roomID, message: composeMessage(text: text, mentions: []))
                try? await model.client.setMarkedUnread(roomId: roomID, unread: true)
            } catch {
                Self.log.error("Couldn't send a reply from a notification: \(String(describing: error), privacy: .private)")
                await keepUnsentReply(text, roomID: roomID, model: model)
            }
        case Self.markReadAction:
            guard !AppGroup.isAppLockOn else { return }
            // The banner stays until the read receipt is really sent, so nothing looks read
            // that isn't.
            do {
                try await model.client.markRead(roomId: roomID)
                clear(roomID: roomID)
            } catch {
                Self.log.error("Couldn't mark as read from a notification: \(String(describing: error), privacy: .private)")
            }
        default:
            #if os(macOS)
            model.showMainWindow()
            #endif
            // A push that couldn't be decoded doesn't say which list it's in; the list does.
            let scope = model.roomsByID[roomID]?.scope ?? (isDirect ? .chats : .rooms)
            model.navigation.open(roomID: roomID, scope: scope)
        }
    }

    /// A reply that couldn't go: it becomes the conversation's draft (after any draft already
    /// there), and a notification says so, since the banner it was typed into is gone.
    private func saveAsDraft(_ text: String, roomID: String, model: AppModel) async {
        let existing = await model.client.loadDraft(roomId: roomID, threadRoot: nil) ?? ""
        let draft = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : existing + "\n" + text
        await model.saveDraft(roomID: roomID, threadRoot: nil, text: draft)
    }

    private func keepUnsentReply(_ text: String, roomID: String, model: AppModel) async {
        await saveAsDraft(text, roomID: roomID, model: model)
        guard !isQuiet else { return }
        let content = UNMutableNotificationContent()
        // With previews off, the conversation's name stays private too.
        let roomName = model.roomsByID[roomID]?.name
        content.title = model.preferences.showPreviews ? roomName ?? String(localized: "Xenia") : String(localized: "Xenia")
        content.body = String(localized: "Your reply couldn’t be sent. It’s saved in the conversation.")
        content.threadIdentifier = roomID
        content.userInfo = ["roomID": roomID, "isDirect": model.roomsByID[roomID]?.isDirect ?? true]
        content.sound = model.preferences.sounds ? .default : nil
        try? await center.add(UNNotificationRequest(identifier: "\(roomID)-unsent-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
