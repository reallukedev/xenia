import Foundation
import XeniaCore

/// Every sentence the core's structured values become. The core never builds user-facing text;
/// it hands over enums, and this file puts them into words, localizably.
enum Copy {
    // MARK: Message bodies

    /// One line for a list, a quote or a notification. `sender` prefixes emotes ("Maya waves").
    static func preview(of body: Body, sender: String? = nil) -> String {
        switch body {
        case .text(let text), .notice(let text):
            return text
        case .emote(let text):
            return sender.map { String(localized: "preview.emote", defaultValue: "\($0) \(text)", comment: "An emote: who, then what they did (Maya waves)") } ?? text
        case .image(let caption):
            return caption ?? String(localized: "Photo")
        case .video(let caption):
            return caption ?? String(localized: "Video")
        case .audio(let caption):
            return caption ?? String(localized: "Audio")
        case .voice:
            return String(localized: "Voice Message")
        case .file(let name, let caption):
            return caption ?? name
        case .sticker(let description):
            return description.isEmpty ? String(localized: "Sticker") : description
        case .poll(let question):
            return String(localized: "Poll: \(question)")
        case .location:
            return String(localized: "Location")
        case .gallery(let count):
            return String(inflecting: "^[\(count) Photo](inflect: true)")
        case .deleted:
            return String(localized: "Message deleted")
        case .encrypted:
            return String(localized: "Encrypted message")
        case .unsupported:
            return String(localized: "Message")
        case .invite:
            return String(localized: "Invited you")
        }
    }

    /// An SF Symbol that stands in for media in previews, if the body is media.
    static func symbol(for body: Body) -> String? {
        switch body {
        case .image, .gallery: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .voice: "mic"
        case .file: "doc"
        case .location: "location"
        case .poll: "chart.bar"
        case .encrypted: "lock"
        default: nil
        }
    }

    // MARK: Notes

    static func note(_ note: Note) -> String {
        switch note {
        case .membership(let name, let isYou, let change):
            return membership(name: name, isYou: isYou, change: change)
        case .renamed(let old, let new):
            return String(localized: "\(old) is now \(new)")
        case .roomNamed(let by, let byYou, let name):
            return byYou ? String(localized: "You named the conversation “\(name)”") : String(localized: "\(by) named the conversation “\(name)”")
        case .topicChanged(let by, let byYou):
            return byYou ? String(localized: "You changed the topic") : String(localized: "\(by) changed the topic")
        case .photoChanged(let by, let byYou):
            return byYou ? String(localized: "You changed the conversation photo") : String(localized: "\(by) changed the conversation photo")
        case .encryptionEnabled:
            return String(localized: "Messages in this conversation are end-to-end encrypted")
        case .created(let by, let byYou):
            return byYou ? String(localized: "You started the conversation") : String(localized: "\(by) started the conversation")
        case .callStarted(let by, let byYou):
            return byYou ? String(localized: "You started a call") : String(localized: "\(by) started a call")
        }
    }

    private static func membership(name: String, isYou: Bool, change: MembershipNote) -> String {
        switch (change, isYou) {
        case (.joined, true): String(localized: "You joined")
        case (.joined, false): String(localized: "\(name) joined")
        case (.left, true): String(localized: "You left")
        case (.left, false): String(localized: "\(name) left")
        case (.invited, true): String(localized: "You were invited")
        case (.invited, false): String(localized: "\(name) was invited")
        case (.declinedInvite, true): String(localized: "You declined the invitation")
        case (.declinedInvite, false): String(localized: "\(name) declined the invitation")
        case (.inviteWithdrawn, true): String(localized: "Your invitation was withdrawn")
        case (.inviteWithdrawn, false): String(localized: "\(name)’s invitation was withdrawn")
        case (.removed, true): String(localized: "You were removed")
        case (.removed, false): String(localized: "\(name) was removed")
        case (.banned, true): String(localized: "You were banned")
        case (.banned, false): String(localized: "\(name) was banned")
        case (.removedAndBanned, true): String(localized: "You were removed and banned")
        case (.removedAndBanned, false): String(localized: "\(name) was removed and banned")
        case (.unbanned, true): String(localized: "You were unbanned")
        case (.unbanned, false): String(localized: "\(name) was unbanned")
        case (.askedToJoin, true): String(localized: "You asked to join")
        case (.askedToJoin, false): String(localized: "\(name) asked to join")
        }
    }

    /// "Maya joined and 4 other changes".
    static func noteGroup(_ notes: [NoteLine]) -> String {
        guard let first = notes.first else { return "" }
        let others = notes.count - 1
        let lead: String = note(first.note)
        let value: String.LocalizationValue = "\(lead) and ^[\(others) other change](inflect: true)"
        return String(inflecting: value)
    }

    // MARK: Conversation rows

    /// The second line of a conversation row.
    static func preview(_ room: RoomSummary) -> String {
        switch room.preview {
        case .invite(let inviter):
            return inviter.map { String(localized: "\($0) invited you") } ?? String(localized: "You were invited")
        case .empty(let isEncrypted):
            return isEncrypted ? String(localized: "Encrypted conversation") : String(localized: "No messages yet")
        case .note(let note):
            return Copy.note(note)
        case .message(let sender, let body, _, _):
            let prefix = senderPrefix(sender, body: body)
            let text = messageText(sender, body: body, roomName: room.name)
            return prefix.map { String(localized: "preview.withSender", defaultValue: "\($0) \(text)", comment: "A group's last message after who sent it (Maya: See you there)") } ?? text
        }
    }

    /// "You:" or "Maya:" before a message in a group's row; nothing in one-to-one chats or for
    /// emotes (which read "Maya waves").
    static func senderPrefix(_ sender: PreviewSender?, body: Body) -> String? {
        if case .emote = body { return nil }
        switch sender {
        case .you: return String(localized: "You:")
        case .other(let firstName): return String(localized: "\(firstName):")
        case nil: return nil
        }
    }

    static func messageText(_ sender: PreviewSender?, body: Body, roomName: String) -> String {
        switch sender {
        case .you: preview(of: body, sender: String(localized: "You"))
        case .other(let firstName): preview(of: body, sender: firstName)
        case nil: preview(of: body, sender: roomName)
        }
    }

    // MARK: Errors

    static func error(_ error: Error) -> String {
        guard let xenia = error as? XeniaError else {
            return String(localized: "Something went wrong. Try again in a moment.")
        }
        switch xenia {
        case .InvalidCredentials:
            return String(localized: "The username or password is incorrect. Check them and try again.")
        case .UserDeactivated:
            return String(localized: "This account has been deactivated. Contact your server’s administrator for help.")
        case .RateLimited:
            return String(localized: "Too many attempts. Wait a moment and try again.")
        case .ServerUnreachable:
            return String(localized: "Xenia can’t reach the server. Check the address and your internet connection, then try again.")
        case .NotAMatrixServer:
            return String(localized: "That address doesn’t lead to a Matrix server. Check it and try again.")
        case .InsecureServer:
            return String(localized: "This server doesn’t use a secure connection, so Xenia won’t send your password to it. Use its https address.")
        case .SlidingSyncUnsupported:
            return String(localized: "This server doesn’t support the sync Xenia needs. Ask its administrator to update it, or use another server.")
        case .PasswordLoginUnsupported:
            return String(localized: "This server only signs in through its website, which Xenia doesn’t support yet. Use another server for now.")
        case .NotSignedIn:
            return String(localized: "You’re signed out. Sign in again to continue.")
        case .NotFound:
            return String(localized: "Xenia couldn’t find that. It may have been deleted, or you may no longer have access.")
        case .Forbidden:
            return String(localized: "You don’t have permission to do that here. Ask an admin of the conversation.")
        case .PasswordRequired:
            return String(localized: "Enter your account password to continue.")
        case .InvalidRecoveryKey:
            return String(localized: "That recovery key didn’t work. Check each character and try again.")
        case .Generic:
            return String(localized: "Something went wrong. Try again in a moment.")
        }
    }
}

extension Copy {
    // MARK: Invitations

    /// Where the composer would be: "Maya invited you to chat." or "Maya invited you to join."
    static func invitation(from inviter: String?, isDirect: Bool) -> String {
        guard let inviter else { return String(localized: "You’re invited.") }
        return isDirect
            ? String(localized: "\(inviter) invited you to chat.")
            : String(localized: "\(inviter) invited you to join.")
    }
}
