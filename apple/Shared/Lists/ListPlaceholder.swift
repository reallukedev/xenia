import XeniaCore
import SwiftUI

/// What an empty list says: loading, nothing yet, nothing matching a filter or a search.
/// It lives in place of the rows and offers the next step.
struct ListPlaceholder: View {
    let scope: Scope
    let isEmpty: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if isEmpty {
                content
                    .transition(.opacity)
            }
        }
        // Fades as the last row leaves or the first arrives, rather than cutting.
        .animation(Theme.Motion.contentFade, value: isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        let filter = model.filters[scope] ?? .all
        let query = model.queries[scope] ?? ""
        if !model.roomsLoaded {
            // The list draws its own blank rows meanwhile.
            EmptyView()
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: query)
        } else if filter != .all {
            ContentUnavailableView {
                Label(filterTitle(filter), systemImage: filter == .unread ? "checkmark.message" : "pin")
            } description: {
                Text(filter == .unread ? "You’re all caught up." : "Pin a conversation from its menu to keep it at the top.")
            } actions: {
                Button("Show All") { model.filters[scope] = .all }
            }
        } else if model.isUnified {
            ContentUnavailableView {
                Label("No Conversations Yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Start a chat with someone, or join a room on your server.")
            } actions: {
                Button("Start a Chat") { model.navigation.sheet = .newMessage }
                    .buttonStyle(.borderedProminent)
                Button("Browse Rooms") { model.navigation.sheet = .browseRooms }
            }
        } else if scope == .chats {
            ContentUnavailableView {
                Label("No Chats Yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Chats are your conversations with people, one on one or in a small group.")
            } actions: {
                Button("Start a Chat") { model.navigation.sheet = .newMessage }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("No Rooms Yet", systemImage: "number")
            } description: {
                Text("Rooms are groups and communities. Join one on your server, or start your own.")
            } actions: {
                Button("Browse Rooms") { model.navigation.sheet = .browseRooms }
                    .buttonStyle(.borderedProminent)
                Button("New Group") { model.navigation.sheet = .newGroup }
            }
        }
    }

    private func filterTitle(_ filter: ListFilter) -> LocalizedStringKey {
        switch (filter, scope) {
        case (.unread, .chats): "No Unread Chats"
        case (.unread, .rooms): "No Unread Rooms"
        case (.favourites, _): "No Pinned Conversations"
        default: "Nothing Here"
        }
    }
}
