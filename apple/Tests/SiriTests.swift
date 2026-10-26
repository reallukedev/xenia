import Foundation
import Testing
@testable import Xenia

@Suite("Siri recipients")
struct MessageRecipientTests {
    private static func target(
        _ name: String, id: String, user: String? = nil, alias: String? = nil, active: Int64 = 0
    ) -> MessageTarget {
        MessageTarget(id: id, name: name, userID: user, alias: alias, isDM: user != nil, lastActivity: active)
    }

    private static let maya = target("Maya Okafor", id: "!maya:x", user: "@maya:example.org", active: 50)
    private static let mayaOld = target("Maya Okafor", id: "!mayaold:x", user: "@maya:example.org", active: 10)
    private static let mayan = target("Maya Lin", id: "!lin:x", user: "@mlin:example.org", active: 90)
    private static let sam = target("Sam", id: "!sam:x", user: "@samuel.okafor:example.org", active: 70)
    private static let design = target("☕️ Design Crit", id: "!design:x", alias: "#design:example.org", active: 30)
    private static let everyone = [maya, mayaOld, mayan, sam, design]

    private static func said(_ names: String..., ids: [String] = []) -> SpokenPerson {
        SpokenPerson(names: names, identifiers: ids)
    }

    @Test("A whole name beats a first name, whatever the case and accents")
    func wholeName() {
        #expect(MessageRecipients.matches(for: Self.said("maya okafor"), in: Self.everyone) == [Self.maya])
        #expect(MessageRecipients.matches(for: Self.said("Máya Okafor"), in: Self.everyone) == [Self.maya])
    }

    @Test("A first name shared by two people asks which, the latest first")
    func firstName() {
        #expect(MessageRecipients.matches(for: Self.said("Maya"), in: Self.everyone).map(\.id) == ["!lin:x", "!maya:x"])
    }

    @Test("An old DM with the same person isn't offered as a second choice")
    func sameUser() {
        #expect(MessageRecipients.matches(for: Self.said("Maya Okafor"), in: [Self.mayaOld, Self.maya]) == [Self.maya])
    }

    @Test("Usernames, last names and room names without their emoji all find the conversation")
    func otherNames() {
        #expect(MessageRecipients.matches(for: Self.said("samuel okafor"), in: Self.everyone) == [Self.sam])
        #expect(MessageRecipients.matches(for: Self.said("Okafor"), in: Self.everyone).map(\.id) == ["!sam:x", "!maya:x"])
        #expect(MessageRecipients.matches(for: Self.said("design crit"), in: Self.everyone) == [Self.design])
    }

    @Test("An ID from a donation or an earlier answer is exact")
    func byIdentifier() {
        #expect(MessageRecipients.matches(for: Self.said("Maya", ids: ["@MAYA:example.org"]), in: Self.everyone) == [Self.maya])
        #expect(MessageRecipients.matches(for: Self.said("Whoever", ids: ["!design:x"]), in: Self.everyone) == [Self.design])
        #expect(MessageRecipients.matches(for: Self.said("Crit", ids: ["#design:example.org"]), in: Self.everyone) == [Self.design])
    }

    @Test("Nobody by that name finds nothing")
    func noMatch() {
        #expect(MessageRecipients.matches(for: Self.said("Priya"), in: Self.everyone).isEmpty)
        #expect(MessageRecipients.matches(for: Self.said("☕️"), in: Self.everyone).isEmpty)
    }

    @Test("A group name prefers rooms to a person with that name")
    func groups() {
        let person = Self.target("Design", id: "!dm:x", user: "@design:example.org")
        #expect(MessageRecipients.groups(named: "Design", id: nil, in: [person, Self.design]) == [Self.design])
        #expect(MessageRecipients.groups(named: "Maya Okafor", id: nil, in: Self.everyone) == [Self.maya])
    }

    @Test("A request goes to its one conversation, or waits while it's unclear")
    func destination() {
        let suggested = MessageRequest(conversationID: "!sam:x", people: [Self.said("Maya")])
        #expect(MessageRecipients.destination(of: suggested, in: Self.everyone) == Self.sam)
        let group = MessageRequest(groupName: "Design Crit", groupID: nil, people: [])
        #expect(MessageRecipients.destination(of: group, in: Self.everyone) == Self.design)
        #expect(MessageRecipients.destination(of: MessageRequest(people: [Self.said("Maya")]), in: Self.everyone) == nil)
        #expect(MessageRecipients.destination(of: MessageRequest(people: [Self.said("Maya Lin")]), in: Self.everyone) == Self.mayan)
        let two = MessageRequest(people: [Self.said("Sam"), Self.said("Maya Lin")])
        #expect(MessageRecipients.destination(of: two, in: Self.everyone) == nil)
    }
}

@Suite("Siri copy")
struct IntentCopyTests {
    @Test("Unread conversations are counted, named and cut short for Siri to read")
    func unread() {
        #expect(IntentCopy.unread(conversations: [], mentionedIn: []) == "You’re all caught up.")
        #expect(IntentCopy.unread(conversations: ["Maya"], mentionedIn: []) == "You have 1 unread conversation: Maya.")
        #expect(
            IntentCopy.unread(conversations: ["Maya", "Sam", "Design Crit", "Ops", "Lunch"], mentionedIn: ["Design Crit"])
                == "You have 5 unread conversations: Maya, Sam, Design Crit, and 2 others. You were mentioned in Design Crit."
        )
    }

    @Test("One name more than fits is named rather than counted")
    func shortList() {
        #expect(IntentCopy.shortList(["A", "B", "C", "D"]) == "A, B, C, and D")
        #expect(IntentCopy.shortList(["A", "B", "C", "D", "E"]) == "A, B, C, and 2 others")
    }
}

#if os(iOS)
import Intents
import UIKit

@Suite("Siri messaging")
struct SiriHandlerTests {
    /// SwiftUI owns the app's delegate and forwards to Xenia's: Siri must reach the handler through it.
    @Test("Siri finds the message handler through the app's delegate")
    @MainActor
    func handlerIsReachable() throws {
        let delegate = try #require(UIApplication.shared.delegate)
        let handler = delegate.application?(UIApplication.shared, handlerFor: INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText, content: "Hi", speakableGroupName: nil,
            conversationIdentifier: nil, serviceName: nil, sender: nil, attachments: nil
        ))
        #expect(handler is MessageIntentHandler)
    }
}
#endif
