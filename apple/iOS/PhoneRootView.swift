import XeniaCore
import SwiftUI

/// iPhone: Chats and Rooms as tabs, each with its own stack. Each list's search bar searches
/// everything: conversations, people, public rooms and messages.
struct PhoneRootView: View {
    @Environment(AppModel.self) private var model
    /// Here so ⌘K and Siri can hand Chats' search words before it has ever been shown.
    @State private var chatsSearch = SearchModel()
    @State private var roomsSearch = SearchModel()
    @State private var isSearchingChats = false
    @State private var isSearchingRooms = false

    var body: some View {
        @Bindable var navigation = model.navigation
        Group {
            // In one list there's nothing to switch between, so no tab bar: just the list, with
            // Chats and Rooms as its sections.
            if model.isUnified {
                ListStack(scope: .chats, path: $navigation.chatsPath, search: chatsSearch, isSearching: $isSearchingChats)
            } else {
                TabView(selection: $navigation.tab) {
                    Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: Navigation.Tab.chats) {
                        ListStack(scope: .chats, path: $navigation.chatsPath, search: chatsSearch, isSearching: $isSearchingChats)
                    }
                    .badge(model.unreadTotals[.chats] ?? 0)
                    Tab("Rooms", systemImage: "number", value: Navigation.Tab.rooms) {
                        ListStack(scope: .rooms, path: $navigation.roomsPath, search: roomsSearch, isSearching: $isSearchingRooms)
                    }
                    .badge(model.unreadTotals[.rooms] ?? 0)
                }
                .tabBarMinimizeBehavior(.onScrollDown)
            }
        }
        .sheet(item: $navigation.sheet) { sheet in
            SheetContent(sheet: sheet)
        }
        .errorAlert("Something Went Wrong", message: Bindable(model).errorMessage)
        .verificationSheet(isHost: model.navigation.sheet == nil)
        .onChange(of: model.navigation.openRoomID) {
            model.pushNotificationContext()
        }
        // Siri and Spotlight's "Search in Xenia", or ⌘K: Chats' search bar takes the words.
        .onChange(of: model.navigation.everythingQuery, initial: true) { _, query in
            guard let query else { return }
            navigation.everythingQuery = nil
            navigation.sheet = nil
            navigation.tab = .chats
            navigation.chatsPath = []
            // ⌘K brings no words: whatever was being searched stays.
            if !query.isEmpty { chatsSearch.query = query }
            isSearchingChats = true
        }
        .background {
            // ⌘K from a hardware keyboard, listed when ⌘ is held as on the Mac.
            Button("Search Everything") { model.navigation.everythingQuery = "" }
                .keyboardShortcut("k")
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// One tab's list and everything it can push. Typing in its search bar swaps the list for results
/// from everywhere.
private struct ListStack: View {
    let scope: Scope
    @Binding var path: [Route]
    let search: SearchModel
    @Binding var isSearching: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var search = search
        NavigationStack(path: $path) {
            Group {
                if search.trimmed.isEmpty {
                    ConversationList(scope: scope)
                } else {
                    SearchResultsList(search: search) { roomID, _, eventID in
                        path.append(eventID.map { .message(roomID: roomID, eventID: $0) } ?? .conversation(roomID: roomID))
                    }
                }
            }
            .navigationTitle(model.isUnified ? "Messages" : scope == .chats ? "Chats" : "Rooms")
            .navigationSubtitle(ConnectionCopy.subtitle(model.connectionNotice) ?? "")
            .searchable(text: $search.query, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
            .task(id: search.query) { await search.run(model: model) }
            .toolbar { ListToolbar(scope: scope) }
            .navigationDestination(for: Route.self) { route in
                RouteView(route: route, path: $path)
            }
        }
    }
}

private struct ListToolbar: ToolbarContent {
    let scope: Scope
    @Environment(AppModel.self) private var model

    /// This iPhone isn't verified or chat backup isn't set up: the photo carries an orange dot.
    private var needsAttention: Bool {
        model.encryption?.backup == .off || model.encryption?.backup == .needsKey || model.encryption?.isDeviceVerified == false
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                model.navigation.sheet = .settings
            } label: {
                if let account = model.account {
                    AvatarView(name: account.displayName ?? account.userId, seed: account.userId, url: account.avatarUrl, size: 30)
                        .overlay(alignment: .bottomTrailing) {
                            if needsAttention {
                                Circle().fill(.orange).frame(width: 9, height: 9)
                                    .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                            }
                        }
                } else {
                    Image(systemName: "person.crop.circle")
                }
            }
            .accessibilityLabel(Text("Settings"))
            .accessibilityValue(needsAttention ? Text("Needs Attention") : Text(verbatim: ""))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            FilterMenu(scope: scope)
            if model.isUnified {
                Menu {
                    Button("New Message", systemImage: "square.and.pencil") { model.navigation.sheet = .newMessage }
                    Button("New Group", systemImage: "person.3") { model.navigation.sheet = .newGroup }
                    Button("Browse Rooms", systemImage: "globe") { model.navigation.sheet = .browseRooms }
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                } primaryAction: {
                    model.navigation.sheet = .newMessage
                }
            } else if scope == .chats {
                Button("New Message", systemImage: "square.and.pencil") { model.navigation.sheet = .newMessage }
            } else {
                Menu {
                    Button("New Group", systemImage: "person.3") { model.navigation.sheet = .newGroup }
                    Button("Browse Rooms", systemImage: "globe") { model.navigation.sheet = .browseRooms }
                } label: {
                    Label("New", systemImage: "plus")
                }
            }
        }
    }
}

/// What each route shows on iPhone.
private struct RouteView: View {
    let route: Route
    @Binding var path: [Route]

    @Environment(AppModel.self) private var model

    var body: some View {
        switch route {
        case .conversation(let roomID):
            PhoneConversationScreen(roomID: roomID, focus: .live, path: $path)
        case .message(let roomID, let eventID):
            PhoneConversationScreen(roomID: roomID, focus: .event(eventId: eventID), path: $path)
        case .info(let roomID):
            ConversationInfoView(
                roomID: roomID,
                openThreads: {
                    // Back to the conversation, with its threads listed over it.
                    if path.last == .info(roomID: roomID) { path.removeLast() }
                    model.navigation.threadsRoomID = roomID
                },
                openSearch: { path.append(.search(roomID: roomID)) }
            )
            .hidesTabBarWhenPushed()
        case .search(let roomID):
            ConversationSearchView(roomID: roomID) { eventID in
                path.append(.message(roomID: roomID, eventID: eventID))
            }
            .hidesTabBarWhenPushed()
        }
    }
}

/// A conversation on iPhone: the person or room at the top (tap for details), threads beside.
private struct PhoneConversationScreen: View {
    let roomID: String
    let focus: TimelineFocus
    @Binding var path: [Route]

    @Environment(AppModel.self) private var model
    @State private var showingMentions = false
    @State private var chosenMention: MentionDestination?

    var body: some View {
        let room = model.room(roomID)
        ConversationView(roomID: roomID, focus: focus) { root in
            model.navigation.openThread(roomID: roomID, root: root)
        }
        .threadPresentation(roomID: roomID)
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBarWhenPushed()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    path.append(.info(roomID: roomID))
                } label: {
                    // As in Messages: the photo, and under it the name on a little glass pill, so
                    // it reads over bubbles scrolling beneath.
                    VStack(spacing: -4) {
                        if let room {
                            AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: Theme.Metrics.headerAvatar + 8, isRoom: room.isRoom)
                                .zIndex(1)
                        }
                        HStack(spacing: 2) {
                            Text(room?.name ?? "")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .frame(maxWidth: 220)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(room?.name ?? ""), Details"))
            }
            if room?.isInvite != true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Threads", systemImage: "bubble.left.and.text.bubble.right") {
                        model.navigation.threadsRoomID = roomID
                    }
                    .accessibilityLabel(Text("Show All Threads"))
                }
                // In a chat with one person, every message is to you: nothing to list.
                if room?.isDm != true {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingMentions = true } label: {
                            MentionsButtonLabel(unread: room?.mentionCount ?? 0)
                        }
                    }
                }
            }
        }
        .background {
            // ⌘F from a hardware keyboard searches this conversation, as on the Mac.
            if room?.isInvite != true {
                Button("Search in Conversation") { path.append(.search(roomID: roomID)) }
                    .keyboardShortcut("f")
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $showingMentions, onDismiss: openChosenMention) {
            NavigationStack {
                MentionListView(roomID: roomID) { destination in
                    // Goes there once the sheet is gone: one presentation at a time.
                    chosenMention = destination
                    showingMentions = false
                }
                .navigationTitle("Mentions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .close) { showingMentions = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .continuesOnOtherDevices(room)
        .onAppear { model.pushNotificationContext() }
    }

    private func openChosenMention() {
        guard let destination = chosenMention else { return }
        chosenMention = nil
        switch destination {
        case .message(let eventID):
            path.append(.message(roomID: roomID, eventID: eventID))
        case .thread(let root):
            model.navigation.openThread(roomID: roomID, root: root)
        }
    }
}
