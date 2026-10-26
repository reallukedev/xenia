import Foundation

/// What Siri and Shortcuts say back. Siri reads it aloud, so lists stay short.
enum IntentCopy {
    static func unread(conversations: [String], mentionedIn mentions: [String]) -> String {
        guard !conversations.isEmpty else { return String(localized: "You’re all caught up.") }
        let unread = String(inflecting: "You have ^[\(conversations.count) unread conversation](inflect: true): \(shortList(conversations)).")
        guard !mentions.isEmpty else { return unread }
        return unread + " " + String(localized: "You were mentioned in \(shortList(mentions)).")
    }

    /// The first few names, then how many more. One more is just named.
    static func shortList(_ names: [String], limit: Int = 3) -> String {
        guard names.count > limit + 1 else { return names.formatted(.list(type: .and)) }
        let others = String(inflecting: "^[\(names.count - limit) other](inflect: true)")
        return (names.prefix(limit) + [others]).formatted(.list(type: .and))
    }
}
