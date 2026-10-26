import Foundation
import XeniaCore
import Testing
@testable import Xenia

@Suite("Navigation")
struct NavigationTests {
    @Test("Opening from a notification or a link closes whatever covered the conversation")
    func openClearsCovers() {
        let navigation = Navigation()
        navigation.sheet = .settings
        navigation.thread = ThreadRef(roomID: "!a:localhost", root: "$root")
        navigation.threadsRoomID = "!a:localhost"
        navigation.detailsRoomID = "!a:localhost"

        navigation.open(roomID: "!b:localhost", scope: .rooms)

        #expect(navigation.sheet == nil)
        #expect(navigation.thread == nil)
        #expect(navigation.threadsRoomID == nil)
        #expect(navigation.detailsRoomID == nil)
        #expect(navigation.openRoomID == "!b:localhost")
    }

    @Test("Files dropped on a conversation's row go to that conversation, once")
    func droppedFilesHandOverOnce() {
        let navigation = Navigation()
        let file = URL(filePath: "/tmp/photo.jpeg")
        navigation.droppedFiles = DroppedFiles(roomID: "!a:localhost", urls: [file])

        #expect(navigation.takeDroppedFiles(for: "!b:localhost").isEmpty)
        #expect(navigation.takeDroppedFiles(for: "!a:localhost") == [file])
        #expect(navigation.takeDroppedFiles(for: "!a:localhost").isEmpty)
    }

    @Test("With chats and rooms in one list, everything opens there")
    func unifiedOpensInChats() {
        let navigation = Navigation()
        navigation.isUnified = true
        navigation.open(roomID: "!room:localhost", scope: .rooms)
        #if os(macOS)
        #expect(navigation.scope == .chats)
        #else
        #expect(navigation.tab == .chats)
        #expect(navigation.roomsPath.isEmpty)
        #endif
        #expect(navigation.openRoomID == "!room:localhost")
    }

    @Test("Opening at a message keeps which message")
    func openAtMessage() {
        let navigation = Navigation()
        navigation.open(roomID: "!a:localhost", scope: .chats, eventID: "$found")
        #if os(macOS)
        #expect(navigation.focusedEventID == "$found")
        #else
        #expect(navigation.chatsPath == [.message(roomID: "!a:localhost", eventID: "$found")])
        #endif
    }

    #if os(macOS)
    @Test("Each list keeps its own selection, and a room that's gone leaves them all")
    func selections() {
        let navigation = Navigation()
        navigation.selectedRoomID = "!chat:localhost"
        navigation.scope = .rooms
        navigation.selectedRoomID = "!room:localhost"

        navigation.scope = .chats
        #expect(navigation.selectedRoomID == "!chat:localhost")

        navigation.forget(roomID: "!room:localhost")
        navigation.scope = .rooms
        #expect(navigation.selectedRoomID == nil)
    }

    @Test("Joining the lists keeps the open conversation open")
    func unifyingKeepsSelection() {
        let navigation = Navigation()
        navigation.scope = .rooms
        navigation.selectedRoomID = "!room:localhost"
        navigation.isUnified = true
        #expect(navigation.scope == .chats)
        #expect(navigation.selectedRoomID == "!room:localhost")
    }
    #endif
}

struct ListAnimationTests {
    @Test("Only one conversation moving animates; a first sync or a reshuffle settles in place")
    func smallChangesAnimate() {
        let a = Self.room("a"), b = Self.room("b"), c = Self.room("c"), d = Self.room("d")
        #expect(AppModel.isSmallChange(from: [a, b, c, d], to: [a, b, c, d]))
        // A new message brings one conversation to the top.
        #expect(AppModel.isSmallChange(from: [a, b, c, d], to: [c, a, b, d]))
        #expect(AppModel.isSmallChange(from: [a, b, c], to: [d, a, b, c]))
        // Catching up after a while reorders several.
        #expect(!AppModel.isSmallChange(from: [a, b, c, d], to: [d, c, b, a]))
        // The first sync fills in previews, which changes row heights.
        let emptyB = Self.room("b", preview: .empty(isEncrypted: false))
        #expect(!AppModel.isSmallChange(from: [a, emptyB, c], to: [a, b, c]))
        #expect(AppModel.isSmallChange(from: [a, emptyB, c], to: [a, emptyB, c]))
    }

    private static func room(_ name: String, preview: RoomPreview = .message(sender: nil, body: .text(text: "Hi"), mentionsMe: false, isOwn: false)) -> RoomSummary {
        RoomSummary(
            id: "!\(name):localhost", name: name, avatarUrl: nil, avatarSeed: name, dmUserId: nil, scope: .rooms,
            isDirect: false, isDm: false, isEncrypted: false, isFavourite: false, favouriteOrder: nil, isLowPriority: false,
            isInvite: false, isPublic: false, inviterName: nil, topic: nil, alias: nil,
            memberCount: 3, unreadCount: 0, mentionCount: 0, isMarkedUnread: false, isMuted: false,
            notificationMode: .allMessages, hasOwnNotificationMode: false, isUnread: false, unreadKind: .none,
            pinnedEventIds: [], preview: preview, timestampMs: 0, draft: nil, lastSendState: nil
        )
    }
}
