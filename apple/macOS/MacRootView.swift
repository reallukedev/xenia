import XeniaCore
import SwiftUI

/// The Mac window: conversations in the sidebar, the selected one beside it, a thread over it.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all
    /// Where the window was, so relaunching returns to the same list and conversation.
    @SceneStorage("xenia.scope") private var savedScope = "chats"
    @SceneStorage("xenia.room") private var savedRoom = ""

    var body: some View {
        @Bindable var navigation = model.navigation
        NavigationSplitView(columnVisibility: $columns) {
            MacSidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            if let roomID = navigation.selectedRoomID, model.room(roomID) != nil {
                MacConversationDetail(roomID: roomID)
                    .id(roomID)
            } else if !model.roomsLoaded && model.rooms.isEmpty {
                // Launching, or returning to a conversation while the list loads: wait quietly
                // rather than flash "No Chat Selected".
                Color.clear
            } else {
                NoConversationSelected()
            }
        }
        .sheet(item: $navigation.sheet) { sheet in
            SheetContent(sheet: sheet)
        }
        .errorAlert("Something Went Wrong", message: Bindable(model).errorMessage)
        .verificationSheet(isHost: model.navigation.sheet == nil && model.verification?.fromSettings != true)
        .onChange(of: model.navigation.selectedRoomID) { _, roomID in
            model.navigation.thread = nil
            model.navigation.threadsRoomID = nil
            model.navigation.detailsRoomID = nil
            if model.navigation.searchRoomID != roomID { model.navigation.searchRoomID = nil }
            model.pushNotificationContext()
            savedRoom = roomID ?? ""
        }
        // Search All Conversations brings back a hidden sidebar; the sidebar takes the request.
        .onChange(of: model.navigation.menuRequest) { _, request in
            if request == .findInSidebar { columns = .all }
        }
        .onChange(of: model.navigation.scope) { _, scope in
            savedScope = scope == .rooms ? "rooms" : "chats"
        }
        .onAppear {
            guard model.navigation.selectedRoomID == nil else { return }
            // In one list (maybe turned on from another device meanwhile) there's only Chats.
            model.navigation.scope = savedScope == "rooms" && !model.isUnified ? .rooms : .chats
            if !savedRoom.isEmpty { model.navigation.selectedRoomID = savedRoom }
        }
        // Messages' toolbar carries no window title: the person in the middle says where you are.
        .toolbar(removing: .title)
        .searchEverythingPalette()
        .frame(minWidth: 760, minHeight: 480)
    }
}

private struct NoConversationSelected: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scope = model.navigation.scope
        content(scope)
            .toolbar { ComposeToolbarItem() }
    }

    private func content(_ scope: Scope) -> some View {
        ContentUnavailableView {
            Label(scope == .chats ? "No Chat Selected" : "No Room Selected", systemImage: scope == .chats ? "bubble.left.and.bubble.right" : "number")
        } description: {
            Text(scope == .chats ? "Choose a chat in the sidebar, or start a new one." : "Choose a room in the sidebar, or browse your server’s rooms.")
        } actions: {
            if scope == .chats {
                Button("New Message") { model.navigation.sheet = .newMessage }
            } else {
                Button("Browse Rooms") { model.navigation.sheet = .browseRooms }
            }
        }
    }
}

/// The sidebar: Chats or Rooms, a find field that also searches people and messages, and the list.
private struct MacSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = SearchModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var navigation = model.navigation
        let scope = navigation.scope
        // The picker sits above the list, not over it: rows never scroll under it.
        VStack(spacing: 0) {
            if !model.isUnified {
                ScopePicker(scope: $navigation.scope)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.bottom, Theme.Spacing.s)
            }
            if let notice = ConnectionCopy.subtitle(model.connectionNotice) {
                ConnectionNotice(text: notice, isConnecting: model.connectionNotice == .connecting)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            Group {
                if search.trimmed.isEmpty {
                    ConversationList(scope: scope)
                } else {
                    SearchResultsList(search: search, openRoom: open)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .searchable(text: $search.query, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        // Return opens the top conversation, as Mail's search opens the first match.
        .onSubmit(of: .search) {
            if let first = search.conversations.first { open(first.id, first.scope, nil) }
        }
        .task(id: search.query) { await search.run(model: model) }
        .onChange(of: model.navigation.menuRequest, initial: true) { _, request in
            guard request == .findInSidebar else { return }
            model.navigation.menuRequest = nil
            // After the sidebar comes back, if it was hidden.
            Task { searchFocused = true }
        }
        .animation(Theme.Motion.panel, value: model.connectionNotice)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            // As in Messages, the sidebar keeps only the filter; compose heads the conversation.
            ToolbarSpacer(.flexible)
            ToolbarItem {
                FilterMenu(scope: scope)
                    .menuIndicator(.hidden)
                    .help("Show All, Unread or Pinned")
            }
        }
    }

    private func open(_ roomID: String, _ scope: Scope, _ eventID: String?) {
        model.navigation.open(roomID: roomID, scope: scope, eventID: eventID)
        search.query = ""
        searchFocused = false
    }
}

/// Under the search field while the connection isn't normal: what's happening, quietly. (The
/// window's title is the conversation's, so this can't be its subtitle.)
private struct ConnectionNotice: View {
    let text: String
    let isConnecting: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isConnecting {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.caption)
            }
            Text(text)
                .font(.caption)
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

/// Chats and Rooms, full width under the search field, each with a dot when something in it is
/// new. The stock segmented control keeps its own narrow width in a sidebar, so this draws the
/// same track and thumb itself.
private struct ScopePicker: View {
    @Binding var scope: Scope
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var thumb

    /// White on the light track; a lighter gray on the dark one, as a selected segment is drawn.
    private var thumbFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.2) : .white
    }

    var body: some View {
        HStack(spacing: 0) {
            segment("Chats", value: .chats)
            segment("Rooms", value: .rooms)
        }
        .padding(2)
        .background(.fill.tertiary, in: .capsule)
        .animation(Theme.Motion.flip, value: scope)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Show"))
    }

    private func segment(_ title: LocalizedStringKey, value: Scope) -> some View {
        let selected = scope == value
        let unread = (model.unreadTotals[value] ?? 0) > 0
        return Button {
            scope = value
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                if unread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(.capsule)
            .background {
                if selected {
                    Capsule()
                        .fill(thumbFill)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityValue(unread ? Text("Unread") : Text(""))
        .help(value == .chats ? "Chats (⌘1)" : "Rooms (⌘2)")
    }
}

/// A conversation in the detail column: a thread opens over it, Threads and Details in popovers.
/// As in Messages, the person or room sits in the middle of the toolbar; clicking it shows
/// Details.
private struct MacConversationDetail: View {
    let roomID: String

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var leaving: RoomSummary?
    @State private var viewer = MediaViewerState()
    @State private var searchBeside = true
    @State private var searchState = ConversationSearchState()

    private nonisolated static let searchWidth: CGFloat = 340

    var body: some View {
        @Bindable var navigation = model.navigation
        let room = model.room(roomID)
        let focus: TimelineFocus = navigation.focusedEventID.map { .event(eventId: $0) } ?? .live
        ConversationView(roomID: roomID, focus: focus) { root in
            navigation.openThread(roomID: roomID, root: root)
        }
        .id(focus)
        .threadPresentation(roomID: roomID)
        // Beside the conversation, as threads open: a result scrolls the timeline to it and
        // the results stay for the next. Over it in a narrow window; a thread opened here takes
        // the place.
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if searchBeside { searchPanel }
        }
        .overlay(alignment: .trailing) {
            if !searchBeside { searchPanel }
        }
        .animation(Theme.Motion.panel, value: navigation.searchRoomID)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.searchWidth + 560 } action: { searchBeside = $0 }
        .overlay { MediaViewer(state: viewer) }
        .environment(\.mediaViewer, viewer)
        .onChange(of: roomID) { viewer.closeNow() }
        // The window keeps the name (the Window menu lists it); the toolbar shows the person.
        .navigationTitle(room?.name ?? "")
        .toolbar {
            if viewer.isOpen {
                MediaViewerToolbar(state: viewer)
            } else {
                conversationToolbar(room: room)
            }
        }
        .onChange(of: navigation.menuRequest) { _, request in
            guard request == .leave else { return }
            navigation.menuRequest = nil
            leaving = model.room(roomID)
        }
        .leaveConfirmation($leaving)
        .continuesOnOtherDevices(room)
        .onDisappear {
            if navigation.focusedEventID != nil { navigation.focusedEventID = nil }
        }
    }

    @ViewBuilder
    private var searchPanel: some View {
        let navigation = model.navigation
        if navigation.searchRoomID == roomID, navigation.thread?.roomID != roomID {
            ConversationSearchView(roomID: roomID, state: searchState) { eventID in
                // The same result again scrolls back to it.
                if navigation.focusedEventID == eventID {
                    navigation.focusedEventID = nil
                    Task { navigation.focusedEventID = eventID }
                } else {
                    navigation.focusedEventID = eventID
                }
            } close: {
                navigation.searchRoomID = nil
            }
            .frame(width: Self.searchWidth)
            .background(.background)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
            .padding([.vertical, .trailing], Theme.Spacing.s)
            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private func conversationToolbar(room: RoomSummary?) -> some ToolbarContent {
        @Bindable var navigation = model.navigation
        ComposeToolbarItem()
        ToolbarItem(placement: .principal) {
            ConversationTitle(room: room) { toggleDetails() }
                .popover(isPresented: showingDetails, arrowEdge: .bottom) {
                    ConversationInfoView(roomID: roomID) {
                        navigation.detailsRoomID = nil
                        navigation.threadsRoomID = roomID
                    } openSearch: {
                        navigation.detailsRoomID = nil
                        navigation.searchRoomID = roomID
                    }
                    .frame(width: 340, height: 480)
                }
        }
        // The photo and pill are the title; no glass capsule around them.
        .sharedBackgroundVisibility(.hidden)
        if room?.isInvite != true {
            ToolbarItem(placement: .primaryAction) {
                Button("Threads", systemImage: "bubble.left.and.text.bubble.right") {
                    navigation.mentionsRoomID = nil
                    navigation.threadsRoomID = navigation.threadsRoomID == nil ? roomID : nil
                }
                .help("Show All Threads (⇧⌘T)")
                .popover(isPresented: Binding(
                    get: { navigation.threadsRoomID == roomID },
                    set: { if !$0 { navigation.threadsRoomID = nil } }
                ), arrowEdge: .bottom) {
                    ThreadListView(roomID: roomID) { root in
                        navigation.threadsRoomID = nil
                        navigation.openThread(roomID: roomID, root: root)
                    }
                    .frame(width: 380, height: 460)
                }
            }
            // In a chat with one person, every message is to you: nothing to list.
            if room?.isDm != true {
                // Each its own circle, with room between, as Messages spaces its buttons.
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigation.threadsRoomID = nil
                        navigation.mentionsRoomID = navigation.mentionsRoomID == nil ? roomID : nil
                    } label: {
                        MentionsButtonLabel(unread: room?.mentionCount ?? 0)
                    }
                    .help("Show Mentions (⇧⌘M)")
                    .popover(isPresented: Binding(
                        get: { navigation.mentionsRoomID == roomID },
                        set: { if !$0 { navigation.mentionsRoomID = nil } }
                    ), arrowEdge: .bottom) {
                        MentionListView(roomID: roomID) { destination in
                            navigation.mentionsRoomID = nil
                            switch destination {
                            case .message(let eventID):
                                navigation.open(roomID: roomID, scope: room?.scope ?? .rooms, eventID: eventID)
                            case .thread(let root):
                                navigation.openThread(roomID: roomID, root: root)
                            }
                        }
                        .frame(width: 380, height: 460)
                    }
                }
            }
        }
    }

    private var showingDetails: Binding<Bool> {
        let navigation = model.navigation
        return Binding(
            get: { navigation.detailsRoomID == roomID },
            set: { if !$0 { navigation.detailsRoomID = nil } }
        )
    }

    private func toggleDetails() {
        let navigation = model.navigation
        navigation.detailsRoomID = navigation.detailsRoomID == roomID ? nil : roomID
    }
}

/// The person or room in the middle of the toolbar, as in Messages: their photo, and their name
/// on a small glass pill tucked under it, which reads over messages scrolling beneath.
private struct ConversationTitle: View {
    let room: RoomSummary?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // The photo fills the bar; the pill hangs below it, over the conversation. Both are in
            // the button's frame, so the whole pill is clickable too.
            ZStack(alignment: .bottom) {
                avatar
                    .padding(.top, 2)
                    .padding(.bottom, 15)
                namePill
                    .fixedSize()
            }
            .contentShape(.rect)
        }
        // The toolbar centers the taller frame; this keeps the photo in line with the window buttons.
        .offset(y: 7)
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Theme.Motion.hover) { hovering = over } }
        .help("Show Details (⌘I)")
        .accessibilityLabel(Text("\(room?.name ?? ""), Details"))
    }

    @ViewBuilder
    private var avatar: some View {
        if let room {
            AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: 34, isRoom: room.isRoom)
        } else {
            Color.clear.frame(width: 34, height: 34)
        }
    }

    /// The chevron points down: the details open below, in a popover.
    private var namePill: some View {
        HStack(spacing: 3) {
            Text(room?.name ?? "")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .frame(maxWidth: 280)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Compose, at the head of the conversation column as in Messages.
private struct ComposeToolbarItem: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("New Message", systemImage: "square.and.pencil") {
                model.navigation.sheet = model.navigation.scope == .chats ? .newMessage : .newGroup
            }
            .help(model.navigation.scope == .chats ? "New Message (⌘N)" : "New Group (⇧⌘N)")
        }
    }
}


