import XeniaCore
import SwiftUI

/// One list: Chats or Rooms, or both (headed Chats and Rooms when Settings says so). On iPhone each row pushes the conversation; on the Mac the list is
/// the sidebar and selection shows the conversation beside it.
struct ConversationList: View {
    let scope: Scope

    @Environment(AppModel.self) private var model
    @State private var leaving: RoomSummary?
    /// Counts swipe actions, so each one taps once (never synced changes).
    @State private var swipeFeedback = 0
    @SceneStorage("xenia.chatsExpanded") private var chatsExpanded = true
    @SceneStorage("xenia.roomsExpanded") private var roomsExpanded = true

    var body: some View {
        let all = model.lists[scope] ?? []
        let pinned = model.pinnedRooms(in: all, scope: scope)
        let pinnedIDs = Set(pinned.map(\.id))
        // Pinned conversations live in the grid, not twice.
        let rooms = pinned.isEmpty ? all : all.filter { !pinnedIDs.contains($0.id) }
        // Rows keep a column for the dot only while one below the pins has something new;
        // pins show theirs beside the name.
        let anyUnread = rooms.contains { $0.unreadKind != .none }

        List(selection: selection(pinnedIDs)) {
            if VerifyDeviceBanner.isNeeded(model) {
                VerifyDeviceBanner()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Theme.Spacing.s, leading: Theme.Spacing.m, bottom: Theme.Spacing.s, trailing: Theme.Spacing.m))
                    .selectionDisabled()
                    .transition(.opacity)
            }
            if !pinned.isEmpty {
                PinnedConversations(rooms: pinned) { leaving = $0 }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Theme.Spacing.s, leading: Theme.Spacing.s, bottom: Theme.Spacing.m, trailing: Theme.Spacing.s))
                    .selectionDisabled()
            }
            if !model.roomsLoaded && rooms.isEmpty {
                // The list's own rows, blanked: the shape of what's coming, exactly.
                ForEach(LoadingRows.rooms) { room in
                    ConversationRow(room: room)
                        .redacted(reason: .placeholder)
                        .listRowSeparator(room.id == LoadingRows.rooms.first?.id ? .hidden : .automatic, edges: .top)
                        .conversationRowInsets(reservesUnreadSpace: false)
                        .selectionDisabled()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            } else if model.isSectioned {
                let chats = rooms.filter { $0.scope == .chats }
                let others = rooms.filter { $0.scope == .rooms }
                if !chats.isEmpty {
                    section("Chats", isExpanded: $chatsExpanded) { rows(chats, anyUnread: anyUnread) }
                }
                if !others.isEmpty {
                    section("Rooms", isExpanded: $roomsExpanded) { rows(others, anyUnread: anyUnread) }
                }
            } else {
                rows(rooms, anyUnread: anyUnread)
            }
        }
        .environment(\.reservesUnreadSpace, anyUnread)
        // Faces for the rows below the fold, read from disk before they scroll in.
        .task(id: all.map(\.avatarUrl)) {
            let keys = all.compactMap { room in room.avatarUrl.map { MediaLoader.avatarKey($0, points: Theme.Metrics.rowAvatar) } }
            await model.media.warmAvatars(keys)
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.plain)
        // Only small changes: as the list first arrives, or catches up, rows would fly in from
        // nowhere or slide over each other.
        .animation(model.animatesListChanges ? Theme.Motion.row : nil, value: rooms.map(\.id))
        .sensoryFeedback(.selection, trigger: swipeFeedback)
        #endif
        .overlay {
            ListPlaceholder(scope: scope, isEmpty: all.isEmpty)
        }
        .leaveConfirmation($leaving)
        #if os(macOS)
        // The menu bar's Next and Previous skip rows folded out of sight.
        .focusedSceneValue(\.foldedSections, foldedSections)
        #endif
    }

    private var foldedSections: Set<Scope> {
        guard model.isSectioned else { return [] }
        var folded: Set<Scope> = []
        if !chatsExpanded { folded.insert(.chats) }
        if !roomsExpanded { folded.insert(.rooms) }
        return folded
    }

    @ViewBuilder
    private func rows(_ rooms: [RoomSummary], anyUnread: Bool) -> some View {
        let selected = model.navigation.selectedRoomID
        ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
            let next = rooms.indices.contains(index + 1) ? rooms[index + 1].id : nil
            row(room, separator: next != nil && room.id != selected && next != selected)
                .contextMenu { RoomContextMenu(room: room, confirmLeave: { leaving = $0 }) }
                .tag(room.id)
                .listRowSeparator(room.id == rooms.first?.id ? .hidden : .automatic, edges: .top)
                .conversationRowInsets(reservesUnreadSpace: anyUnread)
                #if os(macOS)
                .springLoaded(isInvite: room.isInvite) { files in
                    let navigation = model.navigation
                    if !files.isEmpty { navigation.droppedFiles = DroppedFiles(roomID: room.id, urls: files) }
                    navigation.selectedRoomID = room.id
                }
                #else
                // The list keeps each row's separator where it first measured it; a new identity
                // when the dot space comes or goes moves the separator with the text.
                .id(anyUnread ? room.id : "\(room.id).flush")
                #endif
                // A two-finger swipe on the Mac, as in Messages and Mail there; the context menu
                // and the menu bar hold the same actions.
                .swipeActions(edge: .leading) {
                    if !room.isInvite { leadingSwipes(room) }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !room.isInvite { trailingSwipes(room) }
                }
        }
    }

    /// As in Messages: a full swipe marks it read or unread; the shorter pull also offers a pin.
    @ViewBuilder
    private func leadingSwipes(_ room: RoomSummary) -> some View {
        let actions = RoomActions(model: model)
        Button(room.isUnread ? "Read" : "Unread",
               systemImage: room.isUnread ? "checkmark.message.fill" : "message.badge.fill") {
            swipeFeedback += 1
            actions.toggleRead(room)
        }
        .tint(.blue)
        Button(room.isFavourite ? "Unpin" : "Pin", systemImage: room.isFavourite ? "pin.slash.fill" : "pin.fill") {
            swipeFeedback += 1
            actions.toggleFavourite(room)
        }
        .tint(.yellow)
    }

    @ViewBuilder
    private func trailingSwipes(_ room: RoomSummary) -> some View {
        Button(room.isDm ? "Delete" : "Leave", systemImage: "trash.fill", role: .destructive) {
            leaving = room
        }
        Button(room.isMuted ? "Unmute" : "Mute", systemImage: room.isMuted ? "bell.fill" : "bell.slash.fill") {
            swipeFeedback += 1
            RoomActions(model: model).toggleMute(room)
        }
        .tint(.indigo)
    }

    /// A heading over chats or rooms: on the Mac a sidebar section that folds away, as in Mail.
    @ViewBuilder
    private func section<Content: View>(_ title: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        Section(title, isExpanded: isExpanded, content: content)
        #else
        // A heading that scrolls with the rows: a pinned one would sit over them under the bar.
        Text(title)
            .font(.title3.weight(.bold))
            .accessibilityAddTraits(.isHeader)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.l, leading: Theme.Spacing.l, bottom: Theme.Spacing.xs, trailing: Theme.Spacing.l))
        content()
        #endif
    }

    private func selection(_ pinnedIDs: Set<String>) -> Binding<String?>? {
        #if os(macOS)
        // A pin marks itself with a ring; the list leaves the pins' row unhighlighted.
        let navigation = model.navigation
        return Binding(
            get: { navigation.selectedRoomID.flatMap { pinnedIDs.contains($0) ? nil : $0 } },
            set: { id in
                if id == nil, let selected = navigation.selectedRoomID, pinnedIDs.contains(selected) { return }
                navigation.selectedRoomID = id
            }
        )
        #else
        nil
        #endif
    }

    @ViewBuilder
    private func row(_ room: RoomSummary, separator: Bool = false) -> some View {
        #if os(macOS)
        ConversationRow(room: room, showsSeparator: separator)
        #else
        NavigationLink(value: Route.conversation(roomID: room.id)) {
            ConversationRow(room: room)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        #endif
    }
}

extension RoomSummary: @retroactive Identifiable {}

extension AppModel {
    /// Favorites pinned above the list, as Messages pins: only in the plain list (not while
    /// filtering or finding, where every match belongs in the list), never invitations. In the
    /// order they were dragged into, never by recency: pins that swapped places with every new
    /// message would be hard to find by position, which is the point of pinning.
    func pinnedRooms(in rooms: [RoomSummary], scope: Scope) -> [RoomSummary] {
        guard (filters[scope] ?? .all) == .all,
              (queries[scope] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        else { return [] }
        return PinnedConversations.pins(from: rooms)
    }

    /// The list as it's drawn, top to bottom: pins, then the rest (chats before rooms when
    /// they're headed separately).
    func visibleOrder(_ scope: Scope) -> [RoomSummary] {
        let all = lists[scope] ?? []
        let pinned = pinnedRooms(in: all, scope: scope)
        let pinnedIDs = Set(pinned.map(\.id))
        let rest = all.filter { !pinnedIDs.contains($0.id) }
        let ordered = isSectioned ? rest.filter { $0.scope == .chats } + rest.filter { $0.scope == .rooms } : rest
        return pinned + ordered
    }

    /// The conversation `offset` rows away from `current`, as the menu bar's Next and Previous
    /// move: wrapping at the ends, never onto invitations or rows in a folded section (pins
    /// always show). From a row that's folded away, it moves to the nearest shown row that way.
    func neighbor(of current: String?, by offset: Int, in scope: Scope, folded: Set<Scope>) -> String? {
        let order = visibleOrder(scope).filter { !$0.isInvite }
        let pinnedIDs = Set(pinnedRooms(in: lists[scope] ?? [], scope: scope).map(\.id))
        let shown = order.indices.filter { index in
            let room = order[index]
            return pinnedIDs.contains(room.id) || !folded.contains(room.scope)
        }
        guard !shown.isEmpty else { return nil }
        guard let at = order.firstIndex(where: { $0.id == current }) else {
            return order[offset > 0 ? shown[0] : shown[shown.count - 1]].id
        }
        if let position = shown.firstIndex(of: at) {
            return order[shown[(position + offset % shown.count + shown.count) % shown.count]].id
        }
        // Folded away: the first shown row past it, wrapping.
        let next = offset > 0 ? shown.first { $0 > at } ?? shown[0] : shown.last { $0 < at } ?? shown[shown.count - 1]
        return order[next].id
    }
}

private extension View {
    func conversationRowInsets(reservesUnreadSpace: Bool) -> some View {
        #if os(iOS)
        // Messages' measurements: the dot in the margin, 11 points above and below. Caught up,
        // there's no dot, and rows start at the page margin like the title above them.
        listRowInsets(EdgeInsets(top: 11, leading: reservesUnreadSpace ? 6 : Theme.Spacing.l, bottom: 11, trailing: Theme.Spacing.l))
        #else
        self
        #endif
    }
}

#if os(macOS)
private extension View {
    /// Files dragged over a row open its conversation after a moment, as Finder springs folders
    /// open. Dropped on the row, they're sent there, as dropping them on the conversation would.
    func springLoaded(isInvite: Bool, open: @escaping (_ dropped: [URL]) -> Void) -> some View {
        modifier(SpringLoading(isInvite: isInvite, open: open))
    }
}

private struct SpringLoading: ViewModifier {
    /// An invitation opens, but has nowhere to send files until it's accepted.
    let isInvite: Bool
    let open: ([URL]) -> Void
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                pending?.cancel()
                // A bubble dragged out of a conversation isn't a new file.
                let files = isInvite ? [] : urls.filter { $0.isFileURL && !AttachmentActions.isOwnDrag($0) }
                open(files)
                return !files.isEmpty
            } isTargeted: { targeted in
                pending?.cancel()
                guard targeted else { return }
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    open([])
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
    }
}
#endif

/// Stand-ins drawn blank while the list loads, with names and previews of varied lengths.
private enum LoadingRows {
    static let rooms: [RoomSummary] = [
        ("Maya Okafor", "Sounds good, see you then"), ("Alex Chen", "Final check with the window closed"),
        ("Saturday Walks", "Of course! The more the merrier"), ("Sam Reyes", "Running a few minutes late"),
        ("Priya Natarajan", "Could it wait until they try"), ("Jordan Blake", "I have one! Big blue one"),
        ("Book Club", "Next month we’re reading the one"), ("Design Crit", "Crit moved to three"),
        ("Coffee Chat", "Group meets on Friday"), ("Community Garden", "Tomatoes are finally in"),
    ].enumerated().map { index, item in
        RoomSummary(
            id: "loading-\(index)", name: item.0, avatarUrl: nil, avatarSeed: "", dmUserId: nil, scope: .chats,
            isDirect: true, isDm: true, isEncrypted: false, isFavourite: false, favouriteOrder: nil, isLowPriority: false,
            isInvite: false, isPublic: false, inviterName: nil, topic: nil, alias: nil,
            memberCount: 2, unreadCount: 0, mentionCount: 0, isMarkedUnread: false, isMuted: false,
            notificationMode: .allMessages, hasOwnNotificationMode: false, isUnread: false, unreadKind: .none,
            pinnedEventIds: [], preview: .message(sender: nil, body: .text(text: item.1), mentionsMe: false, isOwn: false),
            timestampMs: 0, draft: nil, lastSendState: nil
        )
    }
}
