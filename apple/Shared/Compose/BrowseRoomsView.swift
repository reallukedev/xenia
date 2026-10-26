import XeniaCore
import SwiftUI

/// Your server's public rooms, and joining any room by its address.
struct BrowseRoomsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var rooms: [DirectoryRoom] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var starter = ConversationStarter()

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Browse Rooms").font(.title2.bold())
                Text("Public rooms on \(serverName). Join one, or enter a room’s address.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.m)
            SearchField(text: $query)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.s)
            list.frame(minHeight: 320, maxHeight: 420)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 480)
        .task(id: query) { await load() }
        .errorAlert("Couldn’t Join", message: $starter.error)
        #else
        NavigationStack {
            list
                .navigationTitle("Browse Rooms")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or #room:server")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .close) { dismiss() }
                    }
                }
        }
        .task(id: query) { await load() }
        .errorAlert("Couldn’t Join", message: $starter.error)
        #endif
    }

    private var serverName: String {
        model.account.map { $0.userId.split(separator: ":").dropFirst().joined(separator: ":") } ?? String(localized: "your server")
    }

    private var address: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard (text.hasPrefix("#") || text.hasPrefix("!")), text.contains(":"), !text.contains(" ") else { return nil }
        return text
    }

    private var list: some View {
        List {
            if let address {
                Section {
                    Button { join(address) } label: {
                        HStack {
                            Label("Join \(address)", systemImage: "arrow.right.circle.fill")
                            Spacer()
                            if starter.pending == address { ProgressView().controlSize(.small) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                ForEach(rooms, id: \.id) { room in
                    DirectoryRow(room: room, isJoining: starter.pending == room.id) {
                        if room.isJoined { open(room.id) } else { join(room.id) }
                    }
                }
            } footer: {
                if !rooms.isEmpty {
                    Text("Rooms are listed by the server. Anyone can read a public room’s messages after joining.")
                }
            }
        }
        .overlay {
            if isLoading && rooms.isEmpty {
                ProgressView()
            } else if failed {
                ContentUnavailableView {
                    Label("Can’t Load Rooms", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Xenia couldn’t reach the room directory. Check your connection.")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if rooms.isEmpty && address == nil {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label("No Public Rooms", systemImage: "number")
                    } description: {
                        Text("\(serverName) doesn’t list any rooms. If you know a room’s address, type it above, like #design:matrix.org.")
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        failed = false
        let asked = query
        do {
            if !asked.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            let found = try await model.client.publicRooms(query: asked)
            guard !Task.isCancelled, asked == query else { return }
            rooms = found
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, asked == query else { return }
            // The failure stands alone, not over the last search's rooms.
            rooms = []
            failed = true
        }
        isLoading = false
    }

    private func join(_ id: String) {
        starter.join(id, client: model.client, then: open)
    }

    private func open(_ roomID: String) {
        dismiss()
        model.navigation.open(roomID: roomID, scope: model.roomsByID[roomID]?.scope ?? .rooms)
    }
}

/// A room in the server's directory. With an `action`, it carries its own Join or Open button;
/// without one, the whole row is the button (in search results) and says what choosing it does.
struct DirectoryRow: View {
    let room: DirectoryRoom
    let isJoining: Bool
    var avatarSize: CGFloat = 40
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(name: room.name, seed: room.id, url: room.avatarUrl, size: avatarSize, isRoom: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).font(.body.weight(.semibold)).lineLimit(1)
                if let topic = room.topic {
                    Text(topic).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("^[\(room.memberCount) member](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.s)
            if isJoining {
                ProgressView().controlSize(.small)
            } else if let action {
                Button(room.isJoined ? "Open" : "Join", action: action)
                    .buttonStyle(.bordered)
                    #if os(iOS)
                    .buttonBorderShape(.capsule)
                    #endif
                    .controlSize(.small)
                    .disabled(!room.isJoined && !room.canJoin)
            } else if room.isJoined || room.canJoin {
                Text(room.isJoined ? "Open" : "Join")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(.rect)
    }
}

/// A search field for sheets, where `.searchable` would jump to the window's toolbar.
struct SearchField: View {
    @Binding var text: String
    var prompt: LocalizedStringKey = "Search"

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: .rect(cornerRadius: 8, style: .continuous))
    }
}
