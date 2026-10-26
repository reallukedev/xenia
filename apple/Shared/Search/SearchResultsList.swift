import XeniaCore
import SwiftUI

/// Results grouped by kind: Conversations, People, Public Rooms, Messages.
struct SearchResultsList: View {
    let search: SearchModel
    /// Opens a conversation (and, for a message, at that message).
    let openRoom: (String, Scope, String?) -> Void

    @Environment(AppModel.self) private var model
    @State private var starter = ConversationStarter()

    var body: some View {
        List {
            if !search.conversations.isEmpty {
                Section("Conversations") {
                    ForEach(search.conversations.prefix(8)) { room in
                        Button { openRoom(room.id, room.scope, nil) } label: {
                            SearchRoomRow(room: room)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !search.people.isEmpty || search.isSearchingPeople {
                Section {
                    ForEach(search.people.prefix(8), id: \.userId) { person in
                        Button { startChat(person) } label: {
                            PersonRow(person: person, isWorking: starter.pending == person.userId)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    SectionHeaderWithProgress(title: "People", isLoading: search.isSearchingPeople && search.people.isEmpty)
                }
            }
            if !search.publicRooms.isEmpty || search.isSearchingPeople {
                Section {
                    ForEach(search.publicRooms.prefix(8), id: \.id) { room in
                        Button { join(room) } label: {
                            DirectoryRow(room: room, isJoining: starter.pending == room.id, avatarSize: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(!room.canJoin)
                    }
                } header: {
                    SectionHeaderWithProgress(title: "Public Rooms", isLoading: search.isSearchingPeople && search.publicRooms.isEmpty)
                }
            }
            if !search.messages.isEmpty || search.isSearchingMessages || search.messagesFailed {
                Section {
                    ForEach(search.messages, id: \.eventId) { hit in
                        Button { openRoom(hit.roomId, model.roomsByID[hit.roomId]?.scope ?? .rooms, hit.eventId) } label: {
                            MessageHitRow(hit: hit, query: search.trimmed, roomName: model.room(hit.roomId)?.name)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if hit.eventId == search.messages.last?.eventId {
                                Task { await search.loadMoreMessages() }
                            }
                        }
                    }
                    if search.messagesFailed {
                        Text("Message search isn’t available right now.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    SectionHeaderWithProgress(title: "Messages", isLoading: search.isSearchingMessages)
                } footer: {
                    if search.messagesDone, !search.messages.isEmpty {
                        Text(search.coverage.includesServer
                             ? "Includes messages on your server, and encrypted messages on this device."
                             : "Search covers messages this device has received, including encrypted ones.")
                    }
                }
            }
        }
        .overlay {
            if search.isEmptyResult {
                ContentUnavailableView.search(text: search.trimmed)
            }
        }
        .errorAlert(starter.errorTitle, message: $starter.error)
    }

    private func startChat(_ person: Person) {
        starter.chat(with: person.userId, client: model.client) { openRoom($0, .chats, nil) }
    }

    private func join(_ room: DirectoryRoom) {
        starter.join(room.id, client: model.client) { [model] roomID in
            openRoom(roomID, model.roomsByID[roomID]?.scope ?? .rooms, nil)
        }
    }
}

struct SectionHeaderWithProgress: View {
    let title: LocalizedStringKey
    let isLoading: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(title)
            if isLoading {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

struct SearchRoomRow: View {
    let room: RoomSummary
    var avatarSize: CGFloat = 36

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: avatarSize, isRoom: room.isRoom)
            VStack(alignment: .leading, spacing: 1) {
                Text(room.name).lineLimit(1)
                Text(room.scope == .chats ? "Chat" : (room.alias ?? String(localized: "Room")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

struct PersonRow: View {
    let person: Person
    var isWorking = false
    var isSelected = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(name: person.name, seed: person.userId, url: person.avatarUrl, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name).lineLimit(1)
                Text(person.userId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isWorking {
                ProgressView().controlSize(.small)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .contentShape(.rect)
        .animation(Theme.Motion.flip, value: isSelected)
    }
}

extension Person {
    var name: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty { return displayName }
        return userId
    }
}

struct MessageHitRow: View {
    let hit: MessageHit
    let query: String
    let roomName: String?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            AvatarView(name: hit.senderName, seed: hit.senderId, url: hit.senderAvatarUrl, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hit.isOwn ? String(localized: "You") : hit.senderName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let roomName, roomName != hit.senderName {
                        Text(roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    Text(TimeFormat.list(hit.timestampMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(highlighted)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .contentShape(.rect)
    }

    private var highlighted: AttributedString {
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
