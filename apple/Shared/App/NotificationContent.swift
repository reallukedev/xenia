import Foundation
import XeniaCore
import UserNotifications

/// How a new message reads as a notification, the same whether the app posts it while running or
/// the notification extension builds it from a push.
enum NotificationContent {
    static let category = "xenia.message"

    /// The preferences that shape a notification, read from the defaults both processes share.
    struct Preferences {
        var showPreviews = true
        var sounds = true
        var mentionsTimeSensitive = true
        var roomsNotifyForAll = true

        static var current: Preferences {
            let defaults = AppGroup.defaults
            func read(_ key: String) -> Bool { defaults.object(forKey: "xenia.pref.\(key)") as? Bool ?? true }
            return Preferences(
                showPreviews: read("showPreviews"),
                sounds: read("sounds"),
                mentionsTimeSensitive: read("mentionsTimeSensitive"),
                roomsNotifyForAll: read("roomsNotifyForAll")
            )
        }
    }

    static func make(_ message: IncomingMessage, preferences: Preferences) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if preferences.showPreviews {
            content.title = message.roomName
            if !message.isDirect, let sender = message.senderName {
                content.subtitle = sender
            }
            content.body = Copy.preview(of: message.body, sender: message.senderName)
        } else {
            content.title = String(localized: "Xenia")
            content.body = String(localized: "New Message")
        }
        content.threadIdentifier = message.roomId
        content.categoryIdentifier = category
        var info: [String: Any] = ["roomID": message.roomId, "isDirect": message.isDirect, "timestampMs": message.timestampMs]
        if let eventID = message.eventId { info["eventID"] = eventID }
        // With previews off, nothing in the notification says who wrote.
        if preferences.showPreviews {
            if let senderID = message.senderId { info["senderID"] = senderID }
            if let name = message.senderFullName { info["senderName"] = name }
        }
        content.userInfo = info
        content.sound = preferences.sounds ? .default : nil
        if message.isPing && preferences.mentionsTimeSensitive {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1
        }
        return content
    }
}

extension NotificationContent {
    /// Marks a push that had nothing to show (see the notification extension).
    nonisolated static let placeholderKey = "xeniaPlaceholder"

    /// Takes away the placeholders pushes left behind. Off the caller's thread: on the Mac, reaching
    /// the notification center from the extension while the system waits for it to start stalls
    /// it until the system gives up on it.
    nonisolated static func removePlaceholders() {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let ids = delivered
                .filter { $0.request.content.userInfo[placeholderKey] as? Bool == true }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}

