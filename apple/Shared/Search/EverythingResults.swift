import Foundation
import XeniaCore

/// A command Search Everything can run, found by its name or a word for it.
enum PaletteAction: String, CaseIterable, Identifiable {
    case newMessage, newGroup, browseRooms, settings, markAllRead

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newMessage: String(localized: "New Message")
        case .newGroup: String(localized: "New Group")
        case .browseRooms: String(localized: "Browse Rooms")
        case .settings: String(localized: "Settings")
        case .markAllRead: String(localized: "Mark All as Read")
        }
    }

    var symbol: String {
        switch self {
        case .newMessage: "square.and.pencil"
        case .newGroup: "person.3"
        case .browseRooms: "globe"
        case .settings: "gearshape"
        case .markAllRead: "checkmark.message"
        }
    }

    /// As the menu bar shows it.
    var shortcut: String {
        switch self {
        case .newMessage: "⌘N"
        case .newGroup: "⇧⌘N"
        case .browseRooms: "⇧⌘B"
        case .settings: "⌘,"
        case .markAllRead: "⇧⌘K"
        }
    }

    /// Other words people reach for, besides the title's.
    private var keywords: [String] {
        switch self {
        case .newMessage: ["chat", "dm", "direct", "compose", "write", "start"]
        case .newGroup: ["room", "create", "start"]
        case .browseRooms: ["join", "directory", "public", "explore", "find"]
        case .settings: ["preferences", "account", "options"]
        case .markAllRead: ["unread", "clear"]
        }
    }

    /// Every word typed starts a word of the title or a keyword, in any order.
    func matches(_ query: String) -> Bool {
        let typed = EverythingResults.words(query)
        guard !typed.isEmpty else { return true }
        let own = EverythingResults.words(([title] + keywords).joined(separator: " "))
        return typed.allSatisfy { word in own.contains { $0.hasPrefix(word) } }
    }
}

/// One result: what choosing it opens or does.
enum EverythingItem: Hashable, Identifiable {
    case conversation(RoomSummary)
    case person(Person)
    case publicRoom(DirectoryRoom)
    case message(MessageHit)
    case action(PaletteAction)

    var id: String {
        switch self {
        case .conversation(let room): "room:" + room.id
        case .person(let person): "person:" + person.userId
        case .publicRoom(let room): "directory:" + room.id
        case .message(let hit): "message:" + hit.eventId
        case .action(let action): "action:" + action.rawValue
        }
    }
}

struct EverythingSection: Identifiable, Equatable {
    enum Kind: Hashable {
        case topHit, pinned, recent, conversations, people, publicRooms, actions, messages
    }

    let kind: Kind
    var items: [EverythingItem]
    /// Still looking: the header carries a spinner.
    var isLoading = false
    /// The search behind it couldn't run (messages, when the server can't be reached).
    var failed = false

    var id: Kind { kind }
}

/// What Search Everything shows, in order, from what the search found so far.
enum EverythingResults {
    static let pinnedLimit = 5
    static let recentLimit = 6
    static let conversationLimit = 7
    static let peopleLimit = 6
    static let publicRoomLimit = 5

    struct Found {
        var conversations: [RoomSummary] = []
        var people: [Person] = []
        var publicRooms: [DirectoryRoom] = []
        var messages: [MessageHit] = []
        var isSearchingDirectory = false
        var isSearchingMessages = false
        var messagesFailed = false
    }

    /// An empty field is a switcher: pinned and recent conversations, then every action. Words
    /// lead with the best named match. Actions come ahead of messages, whose list grows as it
    /// scrolls.
    static func sections(query: String, found: Found, rooms: [RoomSummary], actions: [PaletteAction]) -> [EverythingSection] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [EverythingSection] = []
        func add(_ kind: EverythingSection.Kind, _ items: [EverythingItem], isLoading: Bool = false, failed: Bool = false) {
            guard !items.isEmpty || isLoading || failed else { return }
            sections.append(EverythingSection(kind: kind, items: items, isLoading: isLoading, failed: failed))
        }
        guard !term.isEmpty else {
            let joined = rooms.filter { !$0.isInvite }
            add(.pinned, PinOrder.sorted(joined.filter(\.isFavourite)).prefix(pinnedLimit).map(EverythingItem.conversation))
            add(.recent, joined.filter { !$0.isFavourite }.prefix(recentLimit).map(EverythingItem.conversation))
            add(.actions, actions.map(EverythingItem.action))
            return sections
        }
        let ranked = rank(found.conversations, query: term)
        add(.topHit, ranked.prefix(1).map(EverythingItem.conversation))
        add(.conversations, ranked.dropFirst().prefix(conversationLimit).map(EverythingItem.conversation))
        add(.people, found.people.prefix(peopleLimit).map(EverythingItem.person),
            isLoading: found.isSearchingDirectory && found.people.isEmpty)
        add(.publicRooms, found.publicRooms.prefix(publicRoomLimit).map(EverythingItem.publicRoom),
            isLoading: found.isSearchingDirectory && found.publicRooms.isEmpty)
        add(.actions, actions.filter { $0.matches(term) }.map(EverythingItem.action))
        add(.messages, found.messages.map(EverythingItem.message),
            isLoading: found.isSearchingMessages, failed: found.messagesFailed)
        return sections
    }

    /// Conversations by how well their name answers the words: the name itself, then names that
    /// start with them, then a word in the name that does, then the rest (an address, a user ID,
    /// letters inside a word). Ties go to the most recent.
    static func rank(_ rooms: [RoomSummary], query: String) -> [RoomSummary] {
        let typed = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let typedWords = words(typed)
        func score(_ room: RoomSummary) -> Int {
            let name = fold(room.name)
            if name == typed { return 0 }
            if name.hasPrefix(typed) { return 1 }
            let nameWords = words(name)
            if typedWords.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) { return 2 }
            return 3
        }
        return rooms
            .map { (room: $0, score: score($0)) }
            .sorted { $0.score != $1.score ? $0.score < $1.score : $0.room.timestampMs > $1.room.timestampMs }
            .map(\.room)
    }

    /// Every row in the order the arrow keys walk them, across sections.
    static func keyboardOrder(_ sections: [EverythingSection]) -> [String] {
        sections.flatMap { $0.items.map(\.id) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    static func words(_ text: String) -> [String] {
        fold(text).split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
    }
}

/// The one highlighted row, moved by the arrow keys and kept while results arrive.
enum EverythingSelection {
    /// Up or down a row, stopping at the ends as Open Quickly does.
    static func moved(_ current: String?, by offset: Int, in order: [String]) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return order.first }
        return order[min(max(index + offset, 0), order.count - 1)]
    }

    /// The same row when it's still there, so results streaming in don't take it away;
    /// otherwise the first.
    static func kept(_ current: String?, in order: [String]) -> String? {
        if let current, order.contains(current) { return current }
        return order.first
    }
}
