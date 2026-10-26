import Foundation
import XeniaCore
import Testing
@testable import Xenia

@Suite("Attachments")
struct AttachmentTests {
    @Test("Every file gets a name Quick Look can open", arguments: [
        ("beach.jpg", "image/jpeg", MessageAttachment.Kind.photo, "beach.jpg"),
        ("Image", "image/png", .photo, "Image.png"),
        ("Image", nil, .photo, "Image.jpeg"),
        ("Sunset at the cabin. Wow", "image/jpeg", .photo, "Sunset at the cabin. Wow.jpeg"),
        ("notes", "application/pdf", .file, "notes.pdf"),
        ("  spaced.pdf  ", nil, .file, "spaced.pdf"),
        ("archive.tar.gz", nil, .file, "archive.tar.gz"),
        ("", nil, .file, "File"),
        ("", nil, .video, "Video.mp4"),
        ("clip", "video/quicktime", .video, "clip.mov"),
        ("Voice Message", nil, .audio, "Voice Message.m4a"),
    ] as [(String, String?, MessageAttachment.Kind, String)])
    func fileNames(name: String, mimetype: String?, kind: MessageAttachment.Kind, expected: String) {
        #expect(MessageAttachment.fileName(name, mimetype: mimetype, kind: kind) == expected)
    }

    @Test("A conversation's attachments come in order, photos titled by who sent them")
    func attachmentsInRows() throws {
        let photo = MediaInfo(source: "mxc://a", thumbnail: "mxc://a-thumb", width: 800, height: 600, blurhash: nil,
                              mimetype: "image/png", size: 1200, filename: "Image")
        let rows: [TimelineRow] = [
            .message(message: Self.message("1", from: "Maya Okafor", .image(media: photo, caption: nil))),
            .header(id: "h", timestampMs: 0),
            .message(message: Self.message("2", from: "Maya Okafor", .text(blocks: [], plain: "Hi", kind: .normal, isJumbo: false))),
            .message(message: Self.message("3", from: "Luke", isOwn: true, .image(media: photo, caption: "The view"))),
            .message(message: Self.message("4", from: "Sam Reyes", .audio(source: "mxc://v", filename: "audio.ogg", durationMs: 4000,
                                                                          size: 300, mimetype: "audio/mp4", isVoice: true, caption: nil))),
            .message(message: Self.message("5", from: "Sam Reyes", .file(source: "mxc://f", filename: "plan", size: 10,
                                                                         mimetype: "application/pdf", caption: nil))),
        ]

        let attachments = MessageAttachment.all(in: rows)

        #expect(attachments.map(\.id) == ["1", "3", "4", "5"])
        #expect(attachments.map(\.kind) == [.photo, .photo, .audio, .file])
        #expect(attachments.map(\.title) == ["Maya Okafor", "You", "Voice Message", "plan.pdf"])
        let first = try #require(attachments.first)
        #expect(first.fileName == "Image.png")
        #expect(first.thumbnailSource == "mxc://a-thumb")
    }

    @Test("Pins are favorites in a steady order, nine at most, never invitations")
    func pins() {
        let names = ["Zoe", "alex", "Maya", "Book Club", "Coffee", "Dana", "Eli", "Fran", "Gus", "Hal", "Ivy"]
        var rooms = names.map { Self.room($0, favourite: true) }
        rooms.append(Self.room("Aaron", favourite: false))
        rooms.append(Self.room("Abby", favourite: true, invite: true))

        let pins = PinnedConversations.pins(from: rooms)

        #expect(pins.map(\.name) == ["alex", "Book Club", "Coffee", "Dana", "Eli", "Fran", "Gus", "Hal", "Ivy"])
    }

    @Test("Arranged pins keep their places; ones never arranged follow, by name")
    func arrangedPins() {
        let rooms = [
            Self.room("Zoe", favourite: true, order: 0.2),
            Self.room("Maya", favourite: true),
            Self.room("Book Club", favourite: true, order: 0.8),
            Self.room("alex", favourite: true),
            Self.room("Coffee", favourite: true, order: 0.5),
        ]

        #expect(PinnedConversations.pins(from: rooms).map(\.name) == ["Zoe", "Coffee", "Book Club", "alex", "Maya"])
    }

    @Test("Moving a pin saves only its new place, between its neighbors")
    func movingOnePin() {
        let current = ["a": 0.2, "b": 0.4, "c": 0.6, "d": 0.8]

        #expect(PinOrder.changes(for: ["d", "a", "b", "c"], current: current) == ["d": 0.1])
        #expect(PinOrder.changes(for: ["a", "c", "b", "d"], current: current).count == 1)
        #expect(PinOrder.changes(for: ["b", "c", "d", "a"], current: current) == ["a": 0.9])
        #expect(PinOrder.changes(for: ["a", "b", "c", "d"], current: current).isEmpty)
    }

    @Test("Pins never arranged, or packed too tight to fit between, all get even places", arguments: [
        [String: Double](),
        ["a": 0.5, "b": 0.5 + 1e-9, "c": 0.5 + 2e-9, "d": 0.5 + 3e-9],
    ])
    func spreadingPins(current: [String: Double]) {
        // c moves between a and b, which leave it no room.
        let ids = ["a", "c", "b", "d"]
        let changes = PinOrder.changes(for: ids, current: current)
        let places = ids.map { changes[$0] ?? current[$0]! }

        #expect(places == [0.2, 0.4, 0.6, 0.8])
    }

    @Test("Reactions are suggested from what the message says", arguments: [
        ("We shipped it!", "🎉"),
        ("Thanks so much for the help", "🙏"),
        ("haha that's hilarious", "😂"),
        ("So sorry to hear about your dad", "🫂"),
        ("Want to grab coffee later?", "☕️"),
        ("Crit moved to 3pm today", "👍"),
        ("Are you free tonight?", "🤔"),
    ])
    func suggestionsFollowTheWords(text: String, expected: String) {
        let message = Self.message("1", from: "Maya Okafor", .text(blocks: [], plain: text, kind: .normal, isJumbo: false))
        let picks = ReactionSuggestions.suggest(for: message, recents: [])
        #expect(picks.count == ReactionSuggestions.count)
        #expect(picks.first == expected)
        #expect(Set(picks).count == picks.count)
    }

    @Test("Others' reactions come first, then the message's own, then habits, never repeated")
    func suggestionsJoinIn() {
        let message = Self.message("1", from: "Maya Okafor", .text(blocks: [], plain: "hi there", kind: .normal, isJumbo: false), reactions: [
            Reaction(key: "🔥", count: 1, isMine: false, senderNames: ["Sam"]),
            Reaction(key: "🫡", count: 3, isMine: false, senderNames: ["Priya", "Alex", "Jo"]),
        ])
        let picks = ReactionSuggestions.suggest(for: message, recents: ["🦄", "🔥"])
        #expect(Array(picks.prefix(3)) == ["🫡", "🔥", "👋"])
        #expect(picks.contains("🦄"))
        // "this" mustn't count as "hi".
        let plain = Self.message("2", from: "Maya Okafor", .text(blocks: [], plain: "this one", kind: .normal, isJumbo: false))
        #expect(ReactionSuggestions.fromWords("this one").isEmpty)
        #expect(ReactionSuggestions.suggest(for: plain, recents: []).count == ReactionSuggestions.count)
    }

    #if os(macOS)
    @Test("Saving next to a file of the same name numbers it as Finder does")
    func freeNames() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(AttachmentActions.freeName(for: "Photo.jpg", in: folder).lastPathComponent == "Photo.jpg")
        try Data().write(to: folder.appending(path: "Photo.jpg"))
        try Data().write(to: folder.appending(path: "Photo 2.jpg"))
        #expect(AttachmentActions.freeName(for: "Photo.jpg", in: folder).lastPathComponent == "Photo 3.jpg")
        try Data().write(to: folder.appending(path: "README"))
        #expect(AttachmentActions.freeName(for: "README", in: folder).lastPathComponent == "README 2")
    }
    #endif

    private static func message(_ id: String, from sender: String, isOwn: Bool = false, _ content: MessageContent, reactions: [Reaction] = []) -> TimelineMessage {
        TimelineMessage(
            id: id, eventId: "$\(id)", senderId: "@\(sender.lowercased()):localhost", senderName: sender, senderAvatarUrl: nil,
            isOwn: isOwn, timestampMs: 0, content: content, isEdited: false, mentionsMe: false, sendState: .sent,
            reactions: reactions, reply: nil, thread: nil, readBy: [], canEdit: false, canReply: true, canForward: true, canRedact: false,
            isPinned: false, run: RunPosition(isFirst: true, isLast: true), showSender: false, delivery: nil, seen: nil, isHighlighted: false
        )
    }

    private static func room(_ name: String, favourite: Bool, invite: Bool = false, order: Double? = nil) -> RoomSummary {
        RoomSummary(
            id: "!\(name):localhost", name: name, avatarUrl: nil, avatarSeed: name, dmUserId: nil, scope: .chats,
            isDirect: true, isDm: true, isEncrypted: false, isFavourite: favourite, favouriteOrder: order, isLowPriority: false,
            isInvite: invite, isPublic: false, inviterName: nil, topic: nil, alias: nil,
            memberCount: 2, unreadCount: 0, mentionCount: 0, isMarkedUnread: false, isMuted: false,
            notificationMode: .allMessages, hasOwnNotificationMode: false, isUnread: false, unreadKind: .none,
            pinnedEventIds: [], preview: .message(sender: nil, body: .text(text: ""), mentionsMe: false, isOwn: false),
            timestampMs: 0, draft: nil, lastSendState: nil
        )
    }
}
