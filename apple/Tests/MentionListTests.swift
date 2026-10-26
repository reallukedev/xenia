import XeniaCore
import SwiftUI
import Testing
@testable import Xenia

@Suite("Mentions list")
struct MentionListTests {
    private static func hit(body: Body = .text(text: "hey Luke"), preview: [TextMark], thread: String? = nil) -> MentionHit {
        MentionHit(
            roomId: "!room:example.org", eventId: "$event", senderId: "@maya:example.org", senderName: "Maya",
            senderAvatarUrl: nil, body: body, preview: preview, timestampMs: 0, threadRootId: thread
        )
    }

    @Test("A mention in the conversation opens at the message")
    func messageDestination() {
        let hit = Self.hit(preview: [TextMark(text: "hey Luke", isMatch: false)])
        #expect(MentionDestination(hit) == .message(eventID: "$event"))
    }

    @Test("A mention in a thread opens the thread")
    func threadDestination() {
        let hit = Self.hit(preview: [TextMark(text: "hey Luke", isMatch: false)], thread: "$root")
        #expect(MentionDestination(hit) == .thread(root: "$root"))
    }

    @Test("The preview keeps every word and sets the mention apart")
    func previewMarksTheMention() {
        let hit = Self.hit(preview: [TextMark(text: "hey ", isMatch: false), TextMark(text: "Luke", isMatch: true)])
        let preview = MentionPreview.attributed(hit)
        #expect(String(preview.characters) == "hey Luke")
        let marked = preview.runs.filter { $0.foregroundColor == .accentColor }.map { String(preview[$0.range].characters) }
        #expect(marked == ["Luke"])
    }

    @Test("A message without words of its own reads as it does in the list")
    func previewWithoutWords() {
        let hit = Self.hit(body: .voice, preview: [])
        #expect(String(MentionPreview.attributed(hit).characters) == Copy.preview(of: .voice, sender: "Maya"))
    }
}
