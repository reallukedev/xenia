import XeniaCore
import SwiftUI

extension View {
    /// Search Everything (⌘K) floating over the window, as Spotlight and Open Quickly do.
    func searchEverythingPalette() -> some View {
        modifier(SearchEverythingHost())
    }
}

private struct SearchEverythingHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false
    /// Outlives the panel, so reopening doesn't start a new search from nothing.
    @State private var search = SearchModel()

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let top = max(proxy.size.height * 0.14, Theme.Spacing.xxl)
                    ZStack(alignment: .top) {
                        if isShown {
                            // A click anywhere outside the panel puts it away.
                            Color.clear
                                .contentShape(.rect)
                                .onTapGesture { isShown = false }
                                .accessibilityHidden(true)
                            SearchEverythingPalette(
                                search: search,
                                maxResultsHeight: min(440, max(160, proxy.size.height - top - 96)),
                                close: { isShown = false }
                            )
                            .frame(width: min(640, proxy.size.width - 2 * Theme.Spacing.xxl))
                            .padding(.top, top)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .animation(Theme.Motion.palette, value: isShown)
            // ⌘K (no words), or Siri and Spotlight's "Search in Xenia".
            .onChange(of: model.navigation.everythingQuery, initial: true) { _, query in
                guard let query else { return }
                model.navigation.everythingQuery = nil
                // ⌘K again puts it away, as Spotlight's shortcut does.
                if isShown, query.isEmpty {
                    isShown = false
                    return
                }
                model.navigation.sheet = nil
                show(query)
            }
    }

    private func show(_ query: String) {
        search.query = query
        isShown = true
    }
}

/// The panel: a large field, and below it everything that matches, one row highlighted.
private struct SearchEverythingPalette: View {
    let search: SearchModel
    let maxResultsHeight: CGFloat
    let close: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isFieldFocused: Bool
    @State private var selection: String?
    /// The row the keyboard moved to, for the list to scroll into view.
    @State private var scrollTarget: String?
    @State private var resultsHeight: CGFloat = 0
    /// When the rows last moved without the pointer moving (the panel appearing, typing, the
    /// arrow keys scrolling): rows sliding under a still pointer mustn't take the highlight.
    @State private var rowsMovedAt = Date.now
    @State private var starter = ConversationStarter()

    var body: some View {
        @Bindable var search = search
        let sections = self.sections
        let order = EverythingResults.keyboardOrder(sections)
        VStack(spacing: 0) {
            field($search.query, order: order)
            if !sections.isEmpty || isNoResults {
                Divider()
            }
            if isNoResults {
                ContentUnavailableView.search(text: search.trimmed)
                    .frame(height: 200)
            } else if !sections.isEmpty {
                results(sections)
            }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Search Everything"))
        .accessibilityAddTraits(.isModal)
        .task(id: search.query) { await search.run(model: model) }
        .onChange(of: order, initial: true) { _, order in
            selection = EverythingSelection.kept(selection, in: order)
            rowsMovedAt = .now
        }
        .onAppear { isFieldFocused = true }
        .onExitCommand(perform: close)
        .errorAlert(starter.errorTitle, message: $starter.error)
    }

    // MARK: Field

    private func field(_ query: Binding<String>, order: [String]) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Everything", text: query)
                .textFieldStyle(.plain)
                .font(.title)
                .focused($isFieldFocused)
                .onKeyPress(.downArrow) { move(by: 1, in: order) }
                .onKeyPress(.upArrow) { move(by: -1, in: order) }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .onSubmit {
                    if let item = item(selection) { activate(item) }
                }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m + Theme.Spacing.xxs)
    }

    private func move(by offset: Int, in order: [String]) -> KeyPress.Result {
        guard let next = EverythingSelection.moved(selection, by: offset, in: order) else { return .ignored }
        selection = next
        rowsMovedAt = .now
        // A section's first row brings its heading along.
        let section = sections.first { $0.items.first?.id == next }
        scrollTarget = section.map { headerID($0.kind) } ?? next
        return .handled
    }

    // MARK: Results

    private func results(_ sections: [EverythingSection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        header(section, isFirst: section.kind == sections.first?.kind)
                        ForEach(section.items) { item in
                            row(item, isTopHit: section.kind == .topHit)
                        }
                        if section.failed {
                            Text("Message search isn’t available right now.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Theme.Spacing.s)
                                .padding(.vertical, Theme.Spacing.xs)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsHeight = $0 }
            }
            // Margins rather than padding, so a row scrolled into view keeps clear of the edge.
            .contentMargins(Theme.Spacing.s, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(resultsHeight + 2 * Theme.Spacing.s, maxResultsHeight))
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target)
                scrollTarget = nil
            }
        }
    }

    private func header(_ section: EverythingSection, isFirst: Bool) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(title(section.kind))
            if section.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.top, isFirst ? Theme.Spacing.xs : Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.xs)
        .id(headerID(section.kind))
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: EverythingItem, isTopHit: Bool) -> some View {
        let isSelected = selection == item.id
        return Button { activate(item) } label: {
            label(item, isTopHit: isTopHit)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, Theme.Spacing.xs + Theme.Spacing.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled(item))
        // The Top Hit draws differently from the same conversation listed under Pinned a
        // keystroke ago: its own identity, or the stack reuses the old row.
        .id(isTopHit ? "top:" + item.id : item.id)
        .onContinuousHover { phase in
            guard case .active = phase, Date.now.timeIntervalSince(rowsMovedAt) > 0.3 else { return }
            selection = item.id
        }
        .onAppear {
            if case .message(let hit) = item, hit.eventId == search.messages.last?.eventId {
                Task { await search.loadMoreMessages() }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func label(_ item: EverythingItem, isTopHit: Bool) -> some View {
        switch item {
        case .conversation(let room) where isTopHit:
            TopHitRow(room: room)
        case .conversation(let room):
            SearchRoomRow(room: room)
        case .person(let person):
            PersonRow(person: person, isWorking: starter.pending == person.userId)
        case .publicRoom(let room):
            DirectoryRow(room: room, isJoining: starter.pending == room.id, avatarSize: 36)
        case .message(let hit):
            MessageHitRow(hit: hit, query: search.trimmed, roomName: model.room(hit.roomId)?.name)
        case .action(let action):
            ActionRow(action: action)
        }
    }

    // MARK: What's shown

    private var sections: [EverythingSection] {
        EverythingResults.sections(
            query: search.query,
            found: EverythingResults.Found(
                conversations: search.conversations,
                people: search.people,
                publicRooms: search.publicRooms,
                messages: search.messages,
                isSearchingDirectory: search.isSearchingPeople,
                isSearchingMessages: search.isSearchingMessages,
                messagesFailed: search.messagesFailed
            ),
            rooms: model.rooms,
            actions: availableActions
        )
    }

    private var isNoResults: Bool {
        search.isEmptyResult && !availableActions.contains { $0.matches(search.trimmed) }
    }

    /// As in the menu bar: Mark All as Read only when there's something it would mark.
    private var availableActions: [PaletteAction] {
        PaletteAction.allCases.filter { action in
            guard action == .markAllRead else { return true }
            let scope = markScope
            return model.rooms.contains { room in
                room.isUnread && !room.isInvite && scope.map { room.scope == $0 } ?? true
            }
        }
    }

    private var markScope: Scope? {
        model.isUnified ? nil : model.navigation.scope
    }

    private func item(_ id: String?) -> EverythingItem? {
        guard let id else { return nil }
        return sections.lazy.flatMap(\.items).first { $0.id == id }
    }

    private func isDisabled(_ item: EverythingItem) -> Bool {
        if case .publicRoom(let room) = item { return !room.canJoin && !room.isJoined }
        return false
    }

    // MARK: Choosing

    private func activate(_ item: EverythingItem) {
        guard !isDisabled(item) else { return }
        switch item {
        case .conversation(let room):
            open(room.id, scope: room.scope)
        case .message(let hit):
            open(hit.roomId, scope: model.roomsByID[hit.roomId]?.scope ?? .rooms, eventID: hit.eventId)
        case .person(let person):
            starter.chat(with: person.userId, client: model.client) { open($0, scope: .chats) }
        case .publicRoom(let room):
            starter.join(room.id, client: model.client) { [model] roomID in
                open(roomID, scope: model.roomsByID[roomID]?.scope ?? .rooms)
            }
        case .action(let action):
            close()
            perform(action)
        }
    }

    private func open(_ roomID: String, scope: Scope, eventID: String? = nil) {
        close()
        model.navigation.open(roomID: roomID, scope: scope, eventID: eventID)
    }

    private func perform(_ action: PaletteAction) {
        switch action {
        case .newMessage: model.navigation.sheet = .newMessage
        case .newGroup: model.navigation.sheet = .newGroup
        case .browseRooms: model.navigation.sheet = .browseRooms
        case .settings: openSettings()
        case .markAllRead: RoomActions(model: model).markAllRead(markScope)
        }
    }

    private func title(_ kind: EverythingSection.Kind) -> LocalizedStringKey {
        switch kind {
        case .topHit: "Top Hit"
        case .pinned: "Pinned"
        case .recent: "Recent"
        case .conversations: "Conversations"
        case .people: "People"
        case .publicRooms: "Public Rooms"
        case .actions: "Actions"
        case .messages: "Messages"
        }
    }

    private func headerID(_ kind: EverythingSection.Kind) -> String {
        "section:\(kind)"
    }
}

/// The best named match, a little larger, as Spotlight's Top Hit is.
private struct TopHitRow: View {
    let room: RoomSummary

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: 44, isRoom: room.isRoom)
            VStack(alignment: .leading, spacing: 1) {
                Text(room.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: Text {
        if room.isDm, let user = room.dmUserId { return Text(verbatim: user) }
        if let alias = room.alias { return Text(verbatim: alias) }
        if room.scope == .chats { return Text("Chat") }
        return Text("^[\(room.memberCount) member](inflect: true)")
    }
}

/// A command, with its shortcut on the right as a menu shows it.
private struct ActionRow: View {
    let action: PaletteAction

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: action.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(.fill.tertiary, in: .rect(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(action.title)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.s)
            Text(verbatim: action.shortcut)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
