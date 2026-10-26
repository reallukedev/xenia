import Foundation
import NaturalLanguage
import XeniaCore

/// The reactions offered for a message: the six most likely, read from the message itself.
/// Emoji others already chose come first (joining in is the commonest reaction), then what its
/// words and kind suggest, then its tone, then your own habits. All on this device, and only
/// when a menu opens.
enum ReactionSuggestions {
    static let count = 6

    static func suggest(for message: TimelineMessage, recents: [String] = RecentReactions.all) -> [String] {
        var picks: [String] = []
        func add(_ emoji: [String]) {
            for item in emoji where !picks.contains(item) && picks.count < count { picks.append(item) }
        }
        // Theirs, most popular first; mine stay in, so the menu can take them back.
        add(message.reactions.sorted { $0.count > $1.count }.map(\.key))
        let text = message.plainText ?? ""
        add(fromWords(text))
        add(fromKind(message.content, text: text))
        add(fromTone(text))
        add(recents)
        add(fallback)
        return picks
    }

    /// When nothing else speaks.
    static let fallback = ["❤️", "👍", "😂", "😮", "😢", "🙏"]

    /// Words and phrases, matched whole, in the order they're checked. The first matches fill
    /// the menu, so stronger signals come first.
    private static let lexicon: [(words: [String], emoji: [String])] = [
        (["congrats", "congratulations", "we did it", "shipped", "launched", "promoted", "got the job", "engaged", "passed", "won", "nailed it"], ["🎉", "🥳", "👏"]),
        (["happy birthday", "birthday", "bday"], ["🥳", "🎂", "🎉"]),
        (["thank", "thanks", "thank you", "thx", "ty", "appreciate", "grateful"], ["🙏", "❤️", "🥰"]),
        (["love you", "love it", "love this", "miss you", "<3"], ["❤️", "🥰", "😍"]),
        (["lol", "lmao", "haha", "hahaha", "rofl", "funny", "hilarious"], ["😂", "🤣", "💀"]),
        (["sorry", "condolences", "passed away", "sad", "rough day", "sick", "not feeling", "bad news"], ["🫂", "😢", "❤️"]),
        (["wow", "amazing", "incredible", "insane", "unbelievable", "no way", "omg", "whoa"], ["🤯", "😮", "🔥"]),
        (["beautiful", "gorgeous", "cute", "adorable", "pretty", "stunning", "lovely"], ["😍", "🥰", "❤️"]),
        (["great", "awesome", "perfect", "nice", "cool", "fire", "killer", "works really well"], ["🔥", "👏", "🙌"]),
        (["done", "finished", "merged", "fixed", "deployed", "booked", "paid", "submitted", "up in", "uploaded"], ["✅", "🙌", "👍"]),
        (["see you", "sounds good", "works for me", "ok", "okay", "sure", "deal", "agreed", "on my way", "omw", "will do"], ["👍", "👌", "🙌"]),
        (["moved to", "reschedule", "postponed", "running late", "late", "delayed", "cancelled", "canceled"], ["👍", "👌", "😬"]),
        (["coffee", "latte", "espresso"], ["☕️", "😋", "👍"]),
        (["dinner", "lunch", "breakfast", "pizza", "food", "eat", "tacos", "burger", "hungry", "brunch"], ["😋", "🍕", "🤤"]),
        (["drinks", "beer", "wine", "cocktail", "cocktails"], ["🍻", "🥂", "🎉"]),
        (["weekend", "trip", "vacation", "holiday", "beach", "flight", "hike", "camping", "cabin"], ["🙌", "😎", "🏖️"]),
        (["good morning", "morning"], ["☀️", "👋", "❤️"]),
        (["good night", "goodnight", "night night"], ["🌙", "😴", "❤️"]),
        (["hello", "hi", "hey", "yo"], ["👋", "😊", "❤️"]),
        (["tired", "exhausted", "ugh"], ["😩", "🫠", "🫂"]),
        (["scary", "terrifying", "creepy", "yikes"], ["😱", "😬", "👀"]),
        (["did you see", "guess what", "drama", "gossip"], ["👀", "😮", "😂"]),
        (["review", "feedback", "thoughts", "take a look", "check out", "notes", "prompt"], ["👀", "👍", "🙌"]),
        (["dog", "puppy", "cat", "kitten"], ["🥰", "🐶", "😍"]),
    ]

    /// Emoji the words call for. Words are matched whole, so "hi" doesn't fire on "this".
    static func fromWords(_ text: String) -> [String] {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "<3")).inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let padded = " " + words.joined(separator: " ") + " "
        var out: [String] = []
        for entry in lexicon where entry.words.contains(where: { padded.contains(" \($0) ") }) {
            out += entry.emoji
        }
        return out
    }

    static func fromKind(_ content: MessageContent, text: String) -> [String] {
        switch content {
        case .image, .video, .sticker: ["😍", "🔥", "❤️"]
        case .audio, .file: ["👍", "👀", "🙏"]
        case .poll: ["👍", "👀"]
        case .location: ["👍"]
        default: text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ? ["🤔", "👍", "👎"] : []
        }
    }

    /// Positive, negative or neither, from Apple's on-device language model.
    static func fromTone(_ text: String) -> [String] {
        // A greeting or two words is too little to read a tone from.
        guard text.split(whereSeparator: \.isWhitespace).count >= 4 else { return [] }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let score = Double(tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore).0?.rawValue ?? "0") ?? 0
        if score > 0.5 { return ["❤️", "😍", "🙌"] }
        if score < -0.5 { return ["😢", "🫂", "😮"] }
        return []
    }
}

/// The emoji you've reacted with lately: they fill out the suggestions and the Mac's second row.
/// Kept on this device only.
enum RecentReactions {
    private static let key = "xenia.recentReactions"
    private static let defaults = ["❤️", "👍", "😂", "🙏", "🎉"]

    static var all: [String] {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Array((saved + defaults).uniqued().prefix(5))
    }

    static func use(_ key: String) {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        UserDefaults.standard.set(Array(([key] + saved).uniqued().prefix(8)), forKey: Self.key)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
