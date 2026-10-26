import XeniaCore
import SwiftUI

extension FocusedValues {
    /// Sidebar sections folded closed, whose rows Next and Previous skip.
    @Entry var foldedSections: Set<Scope>?
}

/// The menu bar: every action has a home here, with the standard shortcuts. Conversation
/// commands act on the conversation the window shows (Navigation is shared by every window), so
/// they work wherever the keyboard focus is.
struct XeniaCommands: Commands {
    let model: AppModel
    @FocusedValue(\.foldedSections) private var foldedSections

    private var signedIn: Bool { model.phase == .signedIn }

    /// The conversation on screen, unless a sheet covers it.
    private var room: RoomSummary? {
        let navigation = model.navigation
        guard signedIn, navigation.sheet == nil, let roomID = navigation.selectedRoomID else { return nil }
        return model.room(roomID)
    }

    /// A joined conversation is in front: invitations have nothing to mark, mute or search.
    private var joined: RoomSummary? {
        guard let room, !room.isInvite else { return nil }
        return room
    }

    /// Its timeline is in view: not hidden by a thread opened over it.
    private var timeline: RoomSummary? {
        let navigation = model.navigation
        guard navigation.thread == nil || !navigation.threadCoversConversation else { return nil }
        return joined
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { open(.newMessage) }
                .keyboardShortcut("n")
                .disabled(!signedIn)
            Button("New Group") { open(.newGroup) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!signedIn)
            Button("Browse Rooms…") { open(.browseRooms) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!signedIn)
        }
        TextEditingCommands()
        // As in Mail: ⌘F searches what's open, ⌥⌘F the whole list. Placed ahead of the text
        // system's Find, these take the keys and its items go without them. (Declared before
        // TextEditingCommands, they'd be dropped.)
        CommandGroup(before: .textEditing) {
            Button("Search in Conversation…") {
                guard let joined else { return }
                model.showMainWindow()
                // A thread open here has the panel's place.
                if model.navigation.thread?.roomID == joined.id { model.navigation.thread = nil }
                if model.navigation.searchRoomID == joined.id {
                    model.navigation.menuRequest = .findInConversation
                } else {
                    model.navigation.searchRoomID = joined.id
                }
            }
            .keyboardShortcut("f")
            .disabled(joined == nil)
            Button("Search All Conversations") {
                guard signedIn else { return }
                model.showMainWindow()
                model.navigation.menuRequest = .findInSidebar
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!signedIn)
            // The window's palette takes it; pressed again, it closes.
            Button("Search Everything…") {
                model.showMainWindow()
                model.navigation.everythingQuery = ""
            }
            .keyboardShortcut("k")
            .disabled(!signedIn || model.navigation.sheet != nil)
            Divider()
        }
        CommandMenu("Conversation") {
            conversationItems
        }
        // Xenia keeps running with its windows closed, so notifications arrive. As in Messages,
        // Window > Xenia brings the main window back.
        CommandGroup(before: .windowList) {
            Button("Xenia") { model.showMainWindow() }
                .keyboardShortcut("0")
            Divider()
        }
        // Xenia has no help book; the menu shouldn't promise one.
        CommandGroup(replacing: .help) {}
        // One list has nothing to switch between.
        CommandGroup(after: .sidebar) {
            if !model.isUnified {
                Button("Chats") { model.navigation.scope = .chats }
                    .keyboardShortcut("1")
                    .disabled(!signedIn)
                Button("Rooms") { model.navigation.scope = .rooms }
                    .keyboardShortcut("2")
                    .disabled(!signedIn)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var conversationItems: some View {
        let actions = RoomActions(model: model)
        Button(joined?.isUnread == true ? "Mark as Read" : "Mark as Unread") {
            if let joined { actions.toggleRead(joined) }
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(joined == nil)
        Button(joined?.isFavourite == true ? "Unpin" : "Pin") {
            if let joined { actions.toggleFavourite(joined) }
        }
        .disabled(joined == nil)
        Button(joined?.isMuted == true ? "Unmute" : "Mute") {
            if let joined { actions.toggleMute(joined) }
        }
        .disabled(joined == nil)
        Divider()
        Button("Tapback…") { request(.tapback) }
            .keyboardShortcut("t")
            .disabled(timeline == nil)
        Button("Show All Threads") {
            guard let joined else { return }
            let navigation = model.navigation
            navigation.mentionsRoomID = nil
            navigation.threadsRoomID = navigation.threadsRoomID == nil ? joined.id : nil
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(joined == nil)
        Button("Show Mentions") {
            guard let joined else { return }
            let navigation = model.navigation
            navigation.threadsRoomID = nil
            navigation.mentionsRoomID = navigation.mentionsRoomID == nil ? joined.id : nil
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(joined == nil || joined?.isDm == true)
        Button("Jump to Latest") { request(.jumpToLatest) }
            // ⌘↓ belongs to the message field (end of the text).
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(timeline == nil)
        Button("Show Details") {
            guard let room else { return }
            let navigation = model.navigation
            navigation.detailsRoomID = navigation.detailsRoomID == nil ? room.id : nil
        }
        .keyboardShortcut("i")
        .disabled(room == nil)
        Divider()
        Button("Next Conversation") { step(by: 1) }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(!signedIn)
        Button("Previous Conversation") { step(by: -1) }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(!signedIn)
        Divider()
        let markScope = model.isUnified ? nil : Optional(model.navigation.scope)
        Button("Mark All as Read") { actions.markAllRead(markScope) }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            // Only when there's something it would mark: invitations aren't read, and muted
            // conversations don't count as unread.
            .disabled(!signedIn || !model.rooms.contains { room in
                room.isUnread && !room.isInvite && markScope.map { room.scope == $0 } ?? true
            })
        Divider()
        Button(joined?.isDm == true ? "Delete Chat…" : "Leave Room…") { request(.leave) }
            .disabled(joined == nil)
    }

    /// Moves through the sidebar as Messages' Control-Tab does, wrapping at the ends.
    private func step(by offset: Int) {
        let navigation = model.navigation
        guard let next = model.neighbor(of: navigation.selectedRoomID, by: offset, in: navigation.scope, folded: foldedSections ?? []) else { return }
        navigation.selectedRoomID = next
    }

    private func request(_ request: MenuRequest) {
        model.navigation.menuRequest = request
    }

    /// Sheets need a signed-in window to open over: one opens if they're all closed.
    private func open(_ sheet: Navigation.Sheet) {
        guard signedIn else { return }
        model.showMainWindow()
        model.navigation.sheet = sheet
    }
}
