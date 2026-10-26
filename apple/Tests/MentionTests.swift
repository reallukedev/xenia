import XeniaCore
import Testing
@testable import Xenia

@Suite("Mention suggestions")
struct MentionTests {
    private static func member(_ name: String, _ userID: String, isYou: Bool = false) -> Member {
        Member(userId: userID, name: name, avatarUrl: nil, isInvited: false, isAdmin: false, isYou: isYou)
    }

    private static let room = [
        member("Luke", "@luke:example.org", isYou: true),
        member("Maya Lin", "@maya:example.org"),
        member("Émile Zola", "@ez:example.org"),
        member("Sam", "@samuel:example.org"),
    ]

    @Test("Matches the start of any word or the user ID, never you", arguments: [
        ("lin", ["@maya:example.org"]),
        ("emile", ["@ez:example.org"]),
        ("samu", ["@samuel:example.org"]),
        ("luke", []),
        ("x", []),
    ])
    func matching(query: String, expected: [String]) {
        #expect(MentionSuggestions.matches(Self.room, query).map(\.userId) == expected)
    }

    @Test("A new member list is matched, not the one matched before")
    func memberListChanges() {
        #expect(MentionSuggestions.matches(Self.room, "ma").map(\.userId) == ["@maya:example.org"])
        let joined = Self.room + [Self.member("Mark", "@mark:example.org")]
        #expect(MentionSuggestions.matches(joined, "ma").map(\.userId) == ["@maya:example.org", "@mark:example.org"])
    }
}
