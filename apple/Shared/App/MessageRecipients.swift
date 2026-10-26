import Foundation
import XeniaCore

/// A conversation Siri can send to, as plain values so matching runs anywhere.
nonisolated struct MessageTarget: Sendable, Equatable, Identifiable {
    /// The room's ID.
    let id: String
    let name: String
    /// For a DM, the other person's Matrix ID.
    let userID: String?
    let alias: String?
    let isDM: Bool
    /// Milliseconds since 1970, for putting the conversation you use most first.
    let lastActivity: Int64
    /// The face Spotlight has, for Siri's lists.
    var face: Data?
}

extension MessageTarget {
    init(_ room: RoomSummary, face: Data? = nil) {
        self.init(
            id: room.id, name: room.name, userID: room.dmUserId, alias: room.alias,
            isDM: room.isDm, lastActivity: room.timestampMs, face: face
        )
    }
}

/// Someone Siri heard: the names it has for them and any identifiers (a Matrix ID from a
/// donation, a room ID from a list Xenia gave it).
nonisolated struct SpokenPerson: Sendable, Equatable {
    var names: [String]
    var identifiers: [String]
}

/// What a "send a message" request names, without the Intents types.
nonisolated struct MessageRequest: Sendable, Equatable {
    /// The room, when Siri suggests a conversation Xenia donated.
    var conversationID: String?
    var groupName: String?
    /// The room behind a group name Xenia resolved.
    var groupID: String?
    var people: [SpokenPerson] = []
}

/// Finds the conversations a spoken name means. The closest kind of match wins (an ID, then the
/// whole name, then its first words, then any of its words), and within it the conversation
/// with the latest activity comes first, so "Maya" means the Maya you talk to.
nonisolated enum MessageRecipients {
    static func matches(for person: SpokenPerson, in targets: [MessageTarget]) -> [MessageTarget] {
        best(in: targets) { target in
            if person.identifiers.contains(where: target.isIdentified) { return 0 }
            return person.names.compactMap { closeness(of: $0, to: target) }.min()
        }
    }

    /// A group by name: rooms and group chats first, a DM only when nothing else is called that.
    static func groups(named name: String, id: String?, in targets: [MessageTarget]) -> [MessageTarget] {
        if let id, let room = targets.first(where: { $0.id == id }) { return [room] }
        let groups = matches(for: SpokenPerson(names: [name], identifiers: []), in: targets.filter { !$0.isDM })
        return groups.isEmpty ? matches(for: SpokenPerson(names: [name], identifiers: []), in: targets) : groups
    }

    /// The one conversation a request is for, or nil while that's still ambiguous.
    static func destination(of request: MessageRequest, in targets: [MessageTarget]) -> MessageTarget? {
        if let id = request.conversationID, let room = targets.first(where: { $0.id == id }) { return room }
        if let name = request.groupName {
            let groups = groups(named: name, id: request.groupID, in: targets)
            if groups.count == 1 { return groups[0] }
        }
        guard request.people.count == 1 else { return nil }
        let people = matches(for: request.people[0], in: targets)
        return people.count == 1 ? people[0] : nil
    }

    // MARK: Matching

    /// Lower is closer: the whole name, its first words, any run of its words.
    private static func closeness(of spoken: String, to target: MessageTarget) -> Int? {
        let said = words(spoken)
        guard !said.isEmpty else { return nil }
        let name = words(target.name)
        // "maya" for @maya:example.org, as people often know each other by their usernames.
        let username = target.userID.map { words(localpart(of: $0)) } ?? []
        if said == name { return 1 }
        if name.starts(with: said) || said == username { return 2 }
        if name.containsRun(said) || username.containsRun(said) { return 3 }
        return nil
    }

    /// The targets at the closest level anything reached, newest first, one per person.
    private static func best(in targets: [MessageTarget], closeness: (MessageTarget) -> Int?) -> [MessageTarget] {
        let scored = targets.compactMap { target in closeness(target).map { (target, $0) } }
        guard let closest = scored.map(\.1).min() else { return [] }
        let found = scored.filter { $0.1 == closest }.map(\.0).sorted { $0.lastActivity > $1.lastActivity }
        // Two DMs with the same person (an old one, a new one): the latest is them.
        var people: Set<String> = []
        return found.filter { target in
            guard let user = target.userID?.lowercased() else { return true }
            return people.insert(user).inserted
        }
    }

    /// Case, accents and punctuation don't matter, and emoji in a room's name aren't said.
    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func localpart(of userID: String) -> String {
        String(userID.dropFirst(userID.hasPrefix("@") ? 1 : 0).prefix { $0 != ":" })
    }
}

nonisolated private extension MessageTarget {
    func isIdentified(by identifier: String) -> Bool {
        identifier == id
            || userID?.caseInsensitiveCompare(identifier) == .orderedSame
            || alias?.caseInsensitiveCompare(identifier) == .orderedSame
    }
}

nonisolated private extension Array where Element == String {
    func containsRun(_ run: [String]) -> Bool {
        guard !run.isEmpty, run.count <= count else { return false }
        return (0...(count - run.count)).contains { Array(self[$0..<($0 + run.count)]) == run }
    }
}
