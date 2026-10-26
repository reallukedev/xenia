import Foundation
import XeniaCore
import Testing
@testable import Xenia

@Suite("Search Everything")
struct EverythingResultsTests {
    @Test("The Top Hit is the name itself, then names that start with the words, then a word in the name")
    func rankByName() {
        let rooms = [
            Self.room("Osamu", at: 400),
            Self.room("Design with Sam", at: 300),
            Self.room("Samantha Lee", at: 200),
            Self.room("Sam", at: 100),
        ]
        let ranked = EverythingResults.rank(rooms, query: "sam")
        #expect(ranked.map(\.name) == ["Sam", "Samantha Lee", "Design with Sam", "Osamu"])
    }

    @Test("Equally good matches go to the most recent")
    func tiesByRecency() {
        let rooms = [Self.room("Book Club", at: 100), Self.room("Book Swap", at: 500)]
        #expect(EverythingResults.rank(rooms, query: "book").first?.name == "Book Swap")
    }

    @Test("Case and accents don't keep a name from matching itself")
    func foldsCaseAndAccents() {
        let rooms = [Self.room("Zoë Martin", at: 900), Self.room("Zoe", at: 100)]
        #expect(EverythingResults.rank(rooms, query: "ZOË").first?.name == "Zoe")
    }

    @Test("An empty field lists pinned conversations, then recent ones, then every action")
    func emptyFieldIsASwitcher() {
        let rooms = [
            Self.room("Invite", at: 900, invite: true),
            Self.room("Maya", at: 800),
            Self.room("Launch", at: 700, favourite: true),
            Self.room("Sam", at: 600),
        ]
        let sections = EverythingResults.sections(query: "  ", found: .init(), rooms: rooms, actions: PaletteAction.allCases)
        #expect(sections.map(\.kind) == [.pinned, .recent, .actions])
        #expect(sections[0].items == [.conversation(rooms[2])])
        #expect(sections[1].items == [.conversation(rooms[1]), .conversation(rooms[3])])
        #expect(sections[2].items.count == PaletteAction.allCases.count)
    }

    @Test("With words, the Top Hit leads and isn't repeated under Conversations")
    func topHitLeads() {
        let maya = Self.room("Maya", at: 100)
        let mayaTeam = Self.room("Maya's Team", at: 900)
        let found = EverythingResults.Found(conversations: [mayaTeam, maya])
        let sections = EverythingResults.sections(query: "maya", found: found, rooms: [], actions: PaletteAction.allCases)
        #expect(sections.map(\.kind) == [.topHit, .conversations])
        #expect(sections[0].items == [.conversation(maya)])
        #expect(sections[1].items == [.conversation(mayaTeam)])
    }

    @Test("Searches still running show their heading with nothing under it; a failed message search keeps its heading")
    func loadingAndFailedSections() {
        let found = EverythingResults.Found(isSearchingDirectory: true, messagesFailed: true)
        let sections = EverythingResults.sections(query: "zz", found: found, rooms: [], actions: PaletteAction.allCases)
        #expect(sections.map(\.kind) == [.people, .publicRooms, .messages])
        #expect(sections.map(\.items.count) == [0, 0, 0])
        #expect(sections.map(\.isLoading) == [true, true, false])
        #expect(sections.map(\.failed) == [false, false, true])
    }

    @Test("Matching actions come ahead of messages, whose list grows as it scrolls")
    func actionsBeforeMessages() {
        let found = EverythingResults.Found(messages: [Self.hit("$1", "a new idea")])
        let sections = EverythingResults.sections(query: "new", found: found, rooms: [], actions: PaletteAction.allCases)
        #expect(sections.map(\.kind) == [.actions, .messages])
        #expect(sections[0].items == [.action(.newMessage), .action(.newGroup)])
    }

    @Test("Actions match their titles and the other words people use for them", arguments: [
        ("new", [PaletteAction.newMessage, .newGroup]),
        ("join", [.browseRooms]),
        ("read mark", [.markAllRead]),
        ("pref", [.settings]),
        ("new room", [.newGroup]),
        ("xylophone", []),
    ])
    func actionMatching(query: String, expected: [PaletteAction]) {
        #expect(PaletteAction.allCases.filter { $0.matches(query) } == expected)
    }

    @Test("The arrow keys walk every row across sections and stop at the ends")
    func keyboardWalk() {
        let sections = [
            EverythingSection(kind: .topHit, items: [.action(.newMessage)]),
            EverythingSection(kind: .people, items: [], isLoading: true),
            EverythingSection(kind: .actions, items: [.action(.newGroup), .action(.settings)]),
        ]
        let order = EverythingResults.keyboardOrder(sections)
        #expect(order == ["action:newMessage", "action:newGroup", "action:settings"])
        #expect(EverythingSelection.moved("action:newMessage", by: 1, in: order) == "action:newGroup")
        #expect(EverythingSelection.moved("action:settings", by: 1, in: order) == "action:settings")
        #expect(EverythingSelection.moved("action:newMessage", by: -1, in: order) == "action:newMessage")
        #expect(EverythingSelection.moved(nil, by: 1, in: order) == "action:newMessage")
        #expect(EverythingSelection.moved("action:newGroup", by: 1, in: []) == nil)
    }

    @Test("The highlighted row stays put while results arrive, and falls back to the first when it goes")
    func selectionSurvivesNewResults() {
        let order = ["room:a", "person:b", "message:c"]
        #expect(EverythingSelection.kept("person:b", in: order) == "person:b")
        #expect(EverythingSelection.kept("person:gone", in: order) == "room:a")
        #expect(EverythingSelection.kept(nil, in: order) == "room:a")
    }

    // MARK: Fixtures

    private static func room(_ name: String, at timestamp: Int64, favourite: Bool = false, invite: Bool = false) -> RoomSummary {
        RoomSummary(
            id: "!\(name):localhost", name: name, avatarUrl: nil, avatarSeed: name, dmUserId: nil, scope: .rooms,
            isDirect: false, isDm: false, isEncrypted: false, isFavourite: favourite, favouriteOrder: nil, isLowPriority: false,
            isInvite: invite, isPublic: false, inviterName: nil, topic: nil, alias: nil,
            memberCount: 3, unreadCount: 0, mentionCount: 0, isMarkedUnread: false, isMuted: false,
            notificationMode: .allMessages, hasOwnNotificationMode: false, isUnread: false, unreadKind: .none,
            pinnedEventIds: [], preview: .message(sender: nil, body: .text(text: ""), mentionsMe: false, isOwn: false),
            timestampMs: timestamp, draft: nil, lastSendState: nil
        )
    }

    private static func hit(_ eventID: String, _ text: String) -> MessageHit {
        MessageHit(
            roomId: "!room:localhost", eventId: eventID, senderId: "@maya:localhost", senderName: "Maya",
            senderAvatarUrl: nil, isOwn: false, body: .text(text: text), text: text, timestampMs: 0
        )
    }
}
