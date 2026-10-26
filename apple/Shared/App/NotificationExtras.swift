import Foundation
import Intents
import OSLog
import XeniaCore
import UniformTypeIdentifiers
import UserNotifications

/// Where a notification's pictures come from: the running app's client, or the notification
/// extension's own session.
nonisolated struct NotificationMedia: Sendable {
    var avatar: @Sendable (_ mxcURL: String, _ sizePx: UInt32) async -> Data?
    var picture: @Sendable (_ source: String) async -> Data?
}

/// What turns a worded notification into one that looks like Messages: the sender as a person
/// with their photo (and the group's photo), and a photo in the message attached to it.
nonisolated enum NotificationExtras {
    private static let log = Logger(subsystem: "dev.xenia.matrix", category: "notifications")
    private static let avatarPixels: UInt32 = 256
    /// Big enough for the expanded notification, small enough for the extension's memory.
    static let picturePixels: UInt32 = 1200

    /// A copy of `content` with the extras added. With previews off it stays as it is: a photo or
    /// a face would give away who wrote and what.
    static func finish(
        _ content: UNMutableNotificationContent,
        message: IncomingMessage,
        preferences: NotificationContent.Preferences,
        media: NotificationMedia
    ) async -> UNNotificationContent {
        guard preferences.showPreviews else { return content }
        // Its own copy: the caller may hand `content` over as it is if time runs out.
        let content = (content.mutableCopy() as? UNMutableNotificationContent) ?? content
        async let senderPhoto = load(message.senderAvatarUrl ?? (message.isDirect ? message.avatarUrl : nil), media)
        // Only iPhone notifications show a group's photo.
        #if os(iOS)
        async let groupPhoto = load(message.isDirect ? nil : message.avatarUrl, media)
        #else
        let groupPhoto: Data? = nil
        #endif
        async let picture = loadPicture(message.picture, media)
        if let data = await picture, let attachment = attachment(data) {
            content.attachments = [attachment]
        }
        return await asCommunication(content, message: message, senderPhoto: senderPhoto, groupPhoto: groupPhoto)
    }

    private static func load(_ mxc: String?, _ media: NotificationMedia) async -> Data? {
        guard let mxc else { return nil }
        return await media.avatar(mxc, avatarPixels)
    }

    private static func loadPicture(_ source: String?, _ media: NotificationMedia) async -> Data? {
        guard let source else { return nil }
        return await media.picture(source)
    }

    /// The sender as a person, so the notification shows their photo (or initials) and Focus can
    /// let chosen people through. Needs the Communication Notifications capability; without it
    /// the notification stays as worded.
    private static func asCommunication(
        _ content: UNMutableNotificationContent,
        message: IncomingMessage,
        senderPhoto: Data?,
        groupPhoto: Data?
    ) async -> UNNotificationContent {
        let senderID = message.senderId ?? message.roomId
        let senderName = message.senderFullName ?? message.senderName ?? message.roomName
        let sender = INPerson(
            personHandle: INPersonHandle(value: senderID, type: .unknown),
            nameComponents: nil,
            displayName: senderName,
            image: senderPhoto.map { INImage(imageData: $0) },
            contactIdentifier: nil,
            customIdentifier: senderID
        )
        let me = INPerson(
            personHandle: INPersonHandle(value: nil, type: .unknown),
            nameComponents: nil, displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: nil,
            isMe: true, suggestionType: .none
        )
        let intent = INSendMessageIntent(
            // A group needs more than one recipient to be drawn as a group.
            recipients: message.isDirect ? [me] : [me, sender],
            outgoingMessageType: .outgoingMessageText,
            // The banner's words come from the notification itself; the donation that the
            // system keeps (for suggestions) needn't hold the message.
            content: nil,
            speakableGroupName: message.isDirect ? nil : INSpeakableString(spokenPhrase: message.roomName),
            conversationIdentifier: message.roomId,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        #if os(iOS)
        if !message.isDirect, let groupPhoto {
            intent.setImage(INImage(imageData: groupPhoto), forParameterNamed: \.speakableGroupName)
        }
        #endif
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        // So leaving the conversation takes it out of suggestions (`MessageDonation.forget`).
        interaction.groupIdentifier = message.roomId
        do {
            try await interaction.donate()
            return try content.updating(from: intent)
        } catch {
            log.error("Couldn't make a communication notification: \(String(describing: error), privacy: .private)")
            return content
        }
    }

    /// The picture as an attachment, in a file the system takes over.
    private static func attachment(_ data: Data) -> UNNotificationAttachment? {
        guard let type = imageType(data), let ext = type.preferredFilenameExtension else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "xenia-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "picture", url: url, options: [
                UNNotificationAttachmentOptionsTypeHintKey: type.identifier,
            ])
        } catch {
            log.error("Couldn't attach a picture: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// The image format from the file's first bytes (media handles don't say).
    static func imageType(_ data: Data) -> UTType? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 12 else { return nil }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return .webP }
        if Array(bytes[4..<8]) == Array("ftyp".utf8) { return .heic }
        return nil
    }
}
