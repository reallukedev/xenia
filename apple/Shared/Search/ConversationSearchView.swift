import XeniaCore
import SwiftUI

/// Words and filters in one conversation, back through its whole history: this device's
/// encrypted index, the server's search, and a walk through older messages, newest first.
/// On the Mac it sits beside the conversation and each result scrolls the timeline to it; on
/// iPhone choosing one opens the conversation there.
struct ConversationSearchView: View {
    let roomID: String
    /// Kept by the conversation on the Mac, so the words and results outlive the panel moving
    /// between beside and over the conversation, or a thread opening in its place.
    var state: ConversationSearchState?
    let openMessage: (String) -> Void
    /// Closes the search (Mac, beside the conversation).
    var close: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var ownState = ConversationSearchState()
    @State private var members: [Member] = []
    @State private var selection: String?
    @FocusState private var fieldFocused: Bool
    @State private var isSearchPresented = false

    private var current: ConversationSearchState { state ?? ownState }
    private var search: SearchModel { current.search }
    private var refinements: SearchRefinements { current.refinements }

    var body: some View {
        let room = model.room(roomID)
        content(room)
            .task(id: SearchKey(query: search.query, refinements: refinements)) {
                search.filters = refinements.filters()
                await search.run(model: model, scope: .room(roomId: roomID))
            }
            .task(id: roomID) {
                members = (try? await model.client.members(roomId: roomID)) ?? []
            }
            .onChange(of: search.query) { _, query in absorbTypedFilters(query, isDirect: room?.isDm == true) }
            // A new search's results replace the old: a selection among them goes too.
            .onChange(of: search.messages.map(\.eventId)) { _, ids in
                if let selection, !ids.contains(selection) { self.selection = nil }
            }
    }

    @ViewBuilder
    private func content(_ room: RoomSummary?) -> some View {
        #if os(macOS)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                field(isDirect: room?.isDm == true)
                // Scrolls sideways when a long name or date doesn't fit the panel.
                ScrollView(.horizontal) {
                    SearchFilterBar(refinements: Bindable(current).refinements, members: members, isDirect: room?.isDm == true)
                }
                .scrollIndicators(.never)
            }
            .padding(Theme.Spacing.m)
            Divider()
            results(room)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: model.navigation.menuRequest) { _, request in
            // ⌘F again while it's open: back to the field, as Safari's Find does.
            guard request == .findInConversation else { return }
            model.navigation.menuRequest = nil
            fieldFocused = true
        }
        .onExitCommand { close?() }
        #else
        results(room)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: Bindable(search).query, isPresented: $isSearchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Messages")
            // Opening search is asking to type: the field is ready, as Messages' is.
            .onAppear { if search.query.isEmpty && refinements.isEmpty { isSearchPresented = true } }
            .onSubmit(of: .search) { absorbTypedFilters(search.query, isDirect: room?.isDm == true, finishing: true) }
            .safeAreaInset(edge: .top, spacing: 0) {
                ScrollView(.horizontal) {
                    SearchFilterBar(refinements: Bindable(current).refinements, members: members, isDirect: room?.isDm == true)
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, Theme.Spacing.s)
                }
                .scrollIndicators(.hidden)
                .background(.bar)
            }
        #endif
    }

    #if os(macOS)
    private func field(isDirect: Bool) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Messages", text: Bindable(search).query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    // A filter finished by Return starts a new search: nothing to open yet.
                    guard !absorbTypedFilters(search.query, isDirect: isDirect, finishing: true) else { return }
                    if let selection { openMessage(selection) } else { move(by: 1) }
                }
                .onKeyPress(.downArrow) { move(by: 1); return .handled }
                .onKeyPress(.upArrow) { move(by: -1); return .handled }
            if !search.query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { search.query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .frame(height: 28)
        .background(.fill.tertiary, in: .rect(cornerRadius: 7, style: .continuous))
    }

    /// The next or previous result, opened beside the search as Mail's arrows do.
    private func move(by step: Int) {
        let ids = search.messages.map(\.eventId)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { $0 + step } ?? (step > 0 ? 0 : ids.count - 1)
        selection = ids[min(max(index, 0), ids.count - 1)]
    }
    #endif

    private func results(_ room: RoomSummary?) -> some View {
        List(selection: $selection) {
            ForEach(search.messages, id: \.eventId) { hit in
                row(hit)
                    .onAppear {
                        if hit.eventId == search.messages.last?.eventId {
                            Task { await search.loadMoreMessages() }
                        }
                    }
            }
            if search.hasCriteria, !search.messages.isEmpty || search.isSearchingMessages || search.isPaused {
                SearchStatusRow(search: search, isEncrypted: room?.isEncrypted == true)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            }
        }
        #if os(macOS)
        .onChange(of: selection) { _, eventID in
            if let eventID { openMessage(eventID) }
        }
        #endif
        .overlay {
            if !search.hasCriteria {
                SearchSuggestions(room: room, refinements: Bindable(current).refinements)
            } else if search.messages.isEmpty, !search.isSearchingMessages, !search.isPaused {
                if search.messagesFailed || search.coverage.historyFailed {
                    ContentUnavailableView(
                        "Search Isn’t Available",
                        systemImage: "exclamationmark.magnifyingglass",
                        description: Text("Xenia couldn’t search this conversation. Check your connection and try again.")
                    )
                } else if search.trimmed.isEmpty {
                    ContentUnavailableView("No Matching Messages", systemImage: "magnifyingglass", description: Text("Try other filters."))
                } else {
                    ContentUnavailableView.search(text: search.trimmed)
                }
            }
        }
        .animation(Theme.Motion.contentFade, value: search.hasCriteria)
    }

    @ViewBuilder
    private func row(_ hit: MessageHit) -> some View {
        #if os(macOS)
        // A button as well as a selection, so a click opens it wherever the focus was, and
        // clicking the selected one again goes back to it.
        Button {
            if selection == hit.eventId { openMessage(hit.eventId) } else { selection = hit.eventId }
        } label: {
            ConversationHitRow(hit: hit, query: search.trimmed)
        }
        .buttonStyle(.plain)
        .tag(hit.eventId)
        #else
        Button { openMessage(hit.eventId) } label: {
            ConversationHitRow(hit: hit, query: search.trimmed)
        }
        .buttonStyle(.plain)
        #endif
    }

    /// Typed filters (`from:maya `) leave the words for the filter bar.
    @discardableResult
    private func absorbTypedFilters(_ query: String, isDirect: Bool, finishing: Bool = false) -> Bool {
        guard let (words, absorbed) = SearchSyntax.absorb(
            query: query, into: refinements, members: members, isDirect: isDirect, finishing: finishing
        ) else { return false }
        current.refinements = absorbed
        search.query = words
        return true
    }
}

/// One conversation's search: the words, the filters and what they found.
@Observable
final class ConversationSearchState {
    let search = SearchModel()
    var refinements = SearchRefinements()
}

/// What a search's results depend on, so a change to either starts it again.
private struct SearchKey: Equatable {
    let query: String
    let refinements: SearchRefinements
}

/// A result in one conversation: who, when, and the words with the matches marked. A photo or
/// file without words says what it is.
private struct ConversationHitRow: View {
    let hit: MessageHit
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            AvatarView(name: hit.senderName, seed: hit.senderId, url: hit.senderAvatarUrl, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hit.isOwn ? String(localized: "You") : hit.senderName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.s)
                    Text(TimeFormat.list(hit.timestampMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let kind = hit.body.kind {
                        Image(systemName: kind.systemImage)
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(words)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var words: AttributedString {
        guard !hit.text.isEmpty else { return AttributedString(Copy.preview(of: hit.body)) }
        var out = AttributedString()
        for mark in markMatches(text: searchSnippet(text: hit.text, query: query), query: query) {
            var piece = AttributedString(mark.text)
            if mark.isMatch {
                piece.foregroundColor = .primary
                piece.font = .subheadline.weight(.semibold)
            }
            out.append(piece)
        }
        return out
    }
}

/// Under the results: how far back the search has looked, and a way on after a long stretch
/// without matches.
private struct SearchStatusRow: View {
    let search: SearchModel
    let isEncrypted: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if search.isSearchingMessages {
                ProgressView().controlSize(.small)
            }
            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if search.isPaused {
                Button("Search Older Messages") { Task { await search.keepSearching() } }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        let coverage = search.coverage
        let reached = coverage.searchedBackToMs.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000).formatted(date: .abbreviated, time: .omitted)
        }
        if search.isSearchingMessages {
            if let reached { return String(localized: "Searching messages from \(reached)…") }
            return String(localized: "Searching…")
        }
        if search.messagesDone {
            if coverage.historyFailed {
                return String(localized: "Xenia couldn’t read older messages. Check your connection and try again.")
            }
            let complete = coverage.walksHistory ? coverage.reachedStart : coverage.includesServer
            if complete { return String(localized: "Searched every message.") }
            return isEncrypted
                ? String(localized: "Searched messages on this device.")
                : String(localized: "No more results.")
        }
        // Stopped with enough to show, or paused after a long stretch without a match.
        if let reached { return String(localized: "Searched back to \(reached).") }
        return ""
    }
}

/// Before anything's typed: what search can do, with the common filters a click away.
private struct SearchSuggestions: View {
    let room: RoomSummary?
    @Binding var refinements: SearchRefinements

    var body: some View {
        ContentUnavailableView {
            Label("Search \(room?.name ?? String(localized: "Conversation"))", systemImage: "magnifyingglass")
        } description: {
            Text("Finds messages back to the start of the conversation. Type words, or choose a filter.")
        } actions: {
            // Stacked, two to a row: the Mac's search panel is narrow.
            VStack(spacing: Theme.Spacing.m) {
                Grid(horizontalSpacing: Theme.Spacing.s, verticalSpacing: Theme.Spacing.s) {
                    GridRow {
                        suggestion(.photo)
                        suggestion(.link)
                    }
                    GridRow {
                        suggestion(.file)
                        if room?.isDm != true {
                            Button("Mentions", systemImage: "at") { refinements.mentionsMe = true }
                                .frame(maxWidth: .infinity)
                        } else {
                            suggestion(.video)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .fixedSize()
                #if os(macOS)
                .controlSize(.small)
                #endif
                Text("Tip: type from:name, has:link or before:2024-05-01.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func suggestion(_ kind: MessageKind) -> some View {
        Button(kind.title, systemImage: kind.systemImage) { refinements.kinds = [kind] }
            .frame(maxWidth: .infinity)
    }
}

extension Body {
    /// The kind of message a search filter would call it, for its icon.
    var kind: MessageKind? {
        switch self {
        case .image, .gallery, .sticker: .photo
        case .video: .video
        case .file: .file
        case .audio, .voice: .audio
        case .poll: .poll
        default: nil
        }
    }
}
