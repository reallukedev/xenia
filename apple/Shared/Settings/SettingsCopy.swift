import XeniaCore
import UserNotifications

/// The words Settings uses to report where things stand, kept pure so they're tested.
enum SettingsCopy {
    enum Tone: Equatable { case secondary, warning, good }

    /// The line under your name at the top of Settings. What needs you comes first: the
    /// connection, then this device's verification, then chat backup.
    static func hero(connection: ConnectionState, backup: BackupStatus?, deviceVerified: Bool? = nil) -> (text: String, tone: Tone) {
        switch connection {
        case .offline: return (String(localized: "Offline"), .warning)
        case .error: return (String(localized: "Can’t reach your server"), .warning)
        case .connecting: return (String(localized: "Connecting…"), .secondary)
        case .connected: break
        }
        if deviceVerified == false, backup != .off {
            return (String(localized: "Verify this \(deviceKind) to read older messages"), .warning)
        }
        switch backup {
        case .off: return (String(localized: "Chat backup is off"), .warning)
        case .needsKey: return (String(localized: "Enter your recovery key to read older messages"), .warning)
        case .on: return (String(localized: "Connected"), .secondary)
        case .checking, nil: return (String(localized: "Connected"), .secondary)
        }
    }

    /// The Chat Backup row's value.
    static func backupValue(_ backup: BackupStatus?) -> String {
        switch backup {
        case .on: String(localized: "On")
        case .needsKey: String(localized: "Needs Key")
        case .off: String(localized: "Off")
        case .checking, nil: String(localized: "Checking…")
        }
    }

    /// Chat Backup's status line: the state and what it means, in one sentence.
    static func backupHero(_ backup: BackupStatus?) -> String {
        switch backup {
        case .on: String(localized: "Your messages are backed up and encrypted.")
        case .needsKey: String(localized: "Enter your recovery key to read older messages.")
        case .off: String(localized: "Without it, new devices can’t read your old messages.")
        case .checking, nil: String(localized: "Checking…")
        }
    }

    // MARK: Devices

    /// "iPhone" or "Mac": this device, in sentences.
    static var deviceKind: String {
        #if os(macOS)
        String(localized: "Mac")
        #else
        String(localized: "iPhone")
        #endif
    }

    /// The Devices page's status line.
    static func devicesHero(thisVerified: Bool?, others: Int) -> (text: String, tone: Tone) {
        switch thisVerified {
        case false?:
            return (String(localized: "Verify this \(deviceKind) to read your encrypted messages."), .warning)
        case true? where others == 0:
            return (String(localized: "This \(deviceKind) is verified."), .secondary)
        case true?:
            return (String(inflecting: "Verified · ^[\(others) other device](inflect: true) signed in"), .secondary)
        case nil:
            return (String(localized: "Checking your devices…"), .secondary)
        }
    }

    static func verifiedValue(_ verified: Bool?) -> String {
        switch verified {
        case true?: String(localized: "Verified")
        case false?: String(localized: "Not Verified")
        case nil: String(localized: "Checking…")
        }
    }

    /// A symbol for a device, from the name it gave itself.
    static func deviceSymbol(name: String?) -> String {
        let lower = (name ?? "").lowercased()
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("android") || lower.contains("phone") { return "smartphone" }
        if lower.contains("mac") { return "laptopcomputer" }
        if lower.contains("web") || lower.contains("firefox") || lower.contains("chrome") || lower.contains("safari")
            || lower.contains("browser") { return "globe" }
        if lower.contains("windows") || lower.contains("linux") || lower.contains("desktop") { return "desktopcomputer" }
        return "questionmark.app.dashed"
    }

    /// A device's name, or its ID when it never named itself.
    static func deviceName(_ session: Session) -> String {
        session.name ?? session.deviceId
    }

    /// "Active now", "Today at 9:41 AM", "Sep 12".
    static func lastActive(_ ms: Int64?, now: Date = .now) -> String? {
        guard let ms else { return nil }
        let then = TimeFormat.date(ms)
        if now.timeIntervalSince(then) < 5 * 60 { return String(localized: "Active now") }
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(then, inSameDayAs: now) {
            return String(localized: "Today at \(then.formatted(date: .omitted, time: .shortened))")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(then, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let sameYear = calendar.isDate(then, equalTo: now, toGranularity: .year)
        let day = sameYear ? then.formatted(.dateTime.month(.abbreviated).day()) : then.formatted(.dateTime.month(.abbreviated).day().year())
        return String(localized: "\(day)")
    }

    // MARK: Verification

    /// Who a verification is with, for its words.
    enum VerificationTarget: Equatable {
        /// My other devices, any of them (verifying this one).
        case anyDevice
        /// One of my devices, by name.
        case device(String)
        /// Someone else, by name.
        case person(String)
    }

    /// The title and one line of explanation for each step of a verification.
    static func verification(_ state: VerificationState?, target: VerificationTarget, isIncoming: Bool) -> (title: String, message: String) {
        let other: String = switch target {
        case .anyDevice: String(localized: "your other device")
        case .device(let name), .person(let name): name
        }
        switch state {
        case nil, .requested?:
            switch target {
            case .anyDevice:
                return (String(localized: "Verify This \(deviceKind)"),
                        String(localized: "Accept the request on another device you’re signed in on."))
            case .device(let name):
                return (String(localized: "Waiting for \(name)"),
                        String(localized: "Accept the request on \(name)."))
            case .person(let name):
                return (String(localized: "Waiting for \(name)"),
                        String(localized: "Ask them to accept your request."))
            }
        case .incoming?:
            if case .person(let name) = target {
                return (String(localized: "\(name) Wants to Verify"),
                        String(localized: "Compare emoji to make sure it’s really them."))
            }
            return (String(localized: "Verify \(other)?"),
                    String(localized: "Only accept if you started this."))
        case .starting?:
            return (String(localized: "Getting Ready…"), String(localized: "Just a moment."))
        case .compare?:
            return (String(localized: "Compare Emoji"),
                    String(localized: "Check that the other screen shows the same emoji, in the same order."))
        case .confirmed?:
            return (String(localized: "Waiting for the Other Side"),
                    String(localized: "Confirm the emoji on \(other)."))
        case .done?:
            if case .person(let name) = target {
                return (String(localized: "\(name) Is Verified"),
                        String(localized: "You’ll be told if their keys ever change."))
            }
            return (String(localized: "Verified"),
                    String(localized: "Older messages will unlock shortly."))
        case .ended(let reason)?:
            return (String(localized: "Verification Stopped"), ended(reason))
        }
    }

    static func ended(_ reason: VerificationEnd) -> String {
        switch reason {
        case .declined: String(localized: "It was declined on the other device.")
        case .cancelledHere: String(localized: "You cancelled verification.")
        case .mismatch: String(localized: "The emoji didn’t match. If you didn’t start this, someone may be trying to intercept your messages.")
        case .timedOut: String(localized: "No response. Try again with both devices open.")
        case .answeredElsewhere: String(localized: "Answered on another device.")
        case .crossed: String(localized: "Both sides started at once. Start from one side only.")
        case .other: String(localized: "Something went wrong. Try again.")
        }
    }

    // MARK: Storage and blocking

    static func bytes(_ count: UInt64) -> String {
        count == 0 ? String(localized: "None") : Int64(count).formatted(.byteCount(style: .file))
    }

    static func blockedValue(_ count: Int?) -> String? {
        guard let count else { return nil }
        return count == 0 ? String(localized: "None") : count.formatted()
    }

    enum Permission { case allowed, denied, notAsked }

    static func permission(_ status: UNAuthorizationStatus) -> Permission {
        switch status {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        default: .notAsked
        }
    }

    static func timeSensitiveFooter(_ on: Bool) -> String {
        #if os(macOS)
        let onText = String(localized: "They can break through Focus.")
        #else
        let onText = String(localized: "They can break through Focus.")
        #endif
        return on ? onText
           : String(localized: "They follow your Focus like other messages.")
    }

    static func roomsFooter(allMessages: Bool) -> String {
        allMessages ? String(localized: "Public rooms notify only for mentions.")
                    : String(localized: "Chats always notify.")
    }

    /// Why pushes can't reach this iPhone while Xenia is closed.
    static func pushProblem(_ problem: PushRegistrar.Problem) -> String {
        switch problem {
        case .noToken:
            String(localized: "Check your connection and try again.")
        case .serverRefused:
            String(localized: "Your server didn’t respond. Try again in a moment.")
        }
    }

    static func previewsFooter(_ on: Bool) -> String {
        on ? String(localized: "Show the sender and message.")
           : String(localized: "Show “New Message” only.")
    }

    static func soundsFooter(_ on: Bool) -> String {
        on ? String(localized: "Play a sound for new messages.")
           : String(localized: "New messages arrive silently.")
    }

    static func typingFooter(_ on: Bool) -> String {
        on ? String(localized: "Let people see when you’re typing.")
           : String(localized: "People can’t see when you’re typing.")
    }

    static func linkPreviewsFooter(_ on: Bool) -> String {
        on ? String(localized: "Previews come through your server, so websites don’t see you.")
           : String(localized: "Links show as plain text.")
    }

    static func encryptedLinkPreviewsFooter(_ on: Bool) -> String {
        on ? String(localized: "Your server can see links in encrypted conversations.")
           : String(localized: "Your server never sees links in encrypted conversations.")
    }

    static func syncDraftsFooter(_ on: Bool) -> String {
        on ? String(localized: "Continue unsent messages on your other devices. End-to-end encrypted.")
           : String(localized: "Drafts stay on this device.")
    }

    static func readReceiptsFooter(_ on: Bool) -> String {
        on ? String(localized: "People see when you’ve read their messages.")
           : String(localized: "People don’t see when you’ve read their messages.")
    }

    // MARK: Page status lines

    static func notificationsHero(_ permission: Permission, roomsNotifyForAll: Bool) -> (text: String, tone: Tone) {
        switch permission {
        case .denied: (String(localized: "Off · Turn on in \(systemSettingsName)"), .warning)
        case .notAsked: (String(localized: "Off"), .secondary)
        case .allowed:
            roomsNotifyForAll
                ? (String(localized: "On · All messages"), .secondary)
                : (String(localized: "On · Chats and mentions"), .secondary)
        }
    }

    static func notificationsValue(_ permission: Permission, roomsNotifyForAll: Bool) -> String {
        switch permission {
        case .allowed: roomsNotifyForAll ? String(localized: "On") : String(localized: "Mentions")
        case .denied: String(localized: "Off")
        case .notAsked: String(localized: "Not Asked")
        }
    }

    /// Privacy's status line: what others learn about you, in two words each.
    static func privacyHero(receipts: Bool, typing: Bool, blocked: Int?) -> String {
        let read = receipts ? String(localized: "Read receipts on") : String(localized: "Read receipts off")
        let typed = typing ? String(localized: "typing shared") : String(localized: "typing hidden")
        var parts = [read, typed]
        if let blocked, blocked > 0 { parts.append(String(inflecting: "^[\(blocked) person](inflect: true) blocked")) }
        return parts.joined(separator: " · ")
    }

    static func storageHero(_ bytes: UInt64?) -> String {
        guard let bytes else { return String(localized: "Measuring…") }
        return bytes == 0
            ? String(localized: "Nothing stored")
            : String(localized: "\(Self.bytes(bytes)) of photos and files")
    }

    static var systemSettingsName: String {
        #if os(macOS)
        String(localized: "System Settings")
        #else
        String(localized: "Settings")
        #endif
    }

    static func colorCodeFooter(_ on: Bool) -> String {
        on ? String(localized: "Each person’s name gets its own color.")
           : String(localized: "Names are gray, like in Messages.")
    }

    static func conversationsHero(layout: ListLayout, membership: Bool) -> String {
        let lists = switch layout {
        case .separate: String(localized: "Chats and rooms apart")
        case .together: String(localized: "Chats and rooms together")
        case .sections: String(localized: "Chats and rooms in sections")
        }
        let notes = membership ? String(localized: "joins and leaves shown") : String(localized: "joins and leaves hidden")
        return "\(lists) · \(notes)"
    }

    static func cloudSignInFooter(_ on: Bool) -> String {
        on ? String(localized: "Your devices sign in with your password from iCloud Keychain.")
           : String(localized: "Your devices sign in with your password from iCloud Keychain.")
    }

    static func cloudSettingsFooter(isAvailable: Bool) -> String {
        isAvailable ? String(localized: "Settings sync across your devices.")
                    : String(localized: "Sign in to iCloud to sync settings.")
    }

    /// The Conversations row's value: how the lists are laid out.
    static func listLayoutValue(_ layout: ListLayout) -> String {
        switch layout {
        case .separate: String(localized: "Separate")
        case .together: String(localized: "Together")
        case .sections: String(localized: "In Sections")
        }
    }

    static func listLayoutFooter(_ layout: ListLayout) -> String {
        switch layout {
        case .separate:
            #if os(macOS)
            String(localized: "Switch between them above the list.")
            #else
            String(localized: "Each in its own tab.")
            #endif
        case .together:
            String(localized: "One list, newest first.")
        case .sections:
            String(localized: "One list, chats first, then rooms.")
        }
    }

    static func membershipFooter(_ on: Bool) -> String {
        on ? String(localized: "Show when people join, leave or change names.")
           : String(localized: "Show only messages.")
    }

    /// What signing out costs, said before it happens.
    static func signOutWarning(_ backup: BackupStatus?) -> String {
        switch backup {
        case .on:
            String(localized: "You’ll need your recovery key to read encrypted messages again.")
        case .needsKey:
            String(localized: "You’ll need your recovery key to read encrypted messages again.")
        default:
            String(localized: "Chat backup is off. You’ll lose access to your encrypted messages.")
        }
    }
}
