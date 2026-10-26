import XeniaCore
import Testing
@testable import Xenia

@Suite("Poll votes")
struct PollVoteTests {
    private static func answers(mine: Set<String>) -> [PollAnswer] {
        ["a", "b", "c"].map { id in
            PollAnswer(id: id, text: id, votes: mine.contains(id) ? 1 : 0, isMine: mine.contains(id), voters: [], isWinner: false)
        }
    }

    @Test("One-answer polls replace the vote, and a second tap takes it back", arguments: [
        (Set<String>(), "b", ["b"]),
        (["a"], "b", ["b"]),
        (["b"], "b", []),
    ] as [(Set<String>, String, [String])])
    func singleChoice(mine: Set<String>, tapped: String, expected: [String]) {
        #expect(PollVote.selection(tapping: tapped, answers: Self.answers(mine: mine), maxSelections: 1) == expected)
    }

    @Test("Several-answer polls add and remove in the poll's order, up to the limit", arguments: [
        (["c"], "a", UInt32(3), ["a", "c"] as [String]?),
        (["a", "c"], "a", 3, ["c"]),
        (["a", "b"], "c", 2, nil),
        (["a", "b"], "b", 2, ["a"]),
    ] as [(Set<String>, String, UInt32, [String]?)])
    func multipleChoice(mine: Set<String>, tapped: String, limit: UInt32, expected: [String]?) {
        #expect(PollVote.selection(tapping: tapped, answers: Self.answers(mine: mine), maxSelections: limit) == expected)
    }
}
