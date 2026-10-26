#if DEBUG
import XeniaCore
import SwiftUI

/// Sample conversations for previews: every state a row can be in.
enum PreviewData {
    static func room(
        _ name: String,
        id: String = UUID().uuidString,
        direct: Bool = true,
        unread: UnreadKind = .none,
        invite: Bool = false,
        muted: Bool = false,
        draft: String? = nil,
        preview: RoomPreview = .message(sender: nil, body: .text(text: "See you at 7, bring chalk"), mentionsMe: false, isOwn: false)
    ) -> RoomSummary {
        RoomSummary(
            id: id, name: name, avatarUrl: nil, avatarSeed: "@\(name.lowercased()):localhost",
            dmUserId: direct ? "@\(name.lowercased()):localhost" : nil, scope: direct ? .chats : .rooms,
            isDirect: direct, isDm: direct, isEncrypted: true, isFavourite: false, favouriteOrder: nil, isLowPriority: false,
            isInvite: invite, isPublic: false, inviterName: invite ? "Maya Okafor" : nil, topic: nil, alias: nil,
            memberCount: direct ? 2 : 6, unreadCount: unread == .none ? 0 : 2, mentionCount: unread == .mention ? 1 : 0,
            isMarkedUnread: false, isMuted: muted, notificationMode: muted ? .mute : .allMessages, hasOwnNotificationMode: muted,
            isUnread: unread != .none || invite, unreadKind: invite ? .unread : unread, pinnedEventIds: [],
            preview: invite ? .invite(inviter: "Maya Okafor") : preview,
            timestampMs: Int64(Date.now.timeIntervalSince1970 * 1000) - 3_600_000, draft: draft, lastSendState: nil
        )
    }

    static let rooms: [RoomSummary] = [
        room("Maya Okafor", unread: .unread),
        room("Launch Planning", direct: false, unread: .mention,
             preview: .message(sender: .other(firstName: "Priya"), body: .text(text: "Luke, can you review the notes?"), mentionsMe: true, isOwn: false)),
        room("Book Club", direct: false, invite: true),
        room("Design Crit", direct: false, muted: true,
             preview: .message(sender: .other(firstName: "Alex"), body: .image(caption: nil), mentionsMe: false, isOwn: false)),
        room("Sam Reyes", draft: "Running ten minutes late"),
        room("Christopher Montgomery-Wellington III",
             preview: .message(sender: nil, body: .text(text: "Thank you, that's really kind! Happy to send over the slides whenever you're ready."), mentionsMe: false, isOwn: false)),
    ]
}

#Preview("Conversation Rows") {
    List(PreviewData.rooms) { room in
        ConversationRow(room: room)
    }
    .listStyle(.plain)
    .environment(AppModel())
}

#Preview("Typing") {
    VStack(alignment: .leading, spacing: 16) {
        TypingIndicator(people: [Reader(userId: "@maya:localhost", name: "Maya Okafor", avatarUrl: nil)], isGroup: false)
        TypingIndicator(people: [
            Reader(userId: "@maya:localhost", name: "Maya Okafor", avatarUrl: nil),
            Reader(userId: "@sam:localhost", name: "Sam Reyes", avatarUrl: nil),
        ], isGroup: true)
    }
    .padding(.vertical)
    .environment(AppModel())
}
#endif
