import XeniaCore
import SwiftUI

/// Forward: the message, then the conversations to send it to. Choosing one sends a copy and
/// closes; the person stays where they are, as in Messages.
struct ForwardSheet: View {
    let message: TimelineMessage
    let fromRoomID: String

    @Environment(AppModel.self) private var model
    @Environment(ConversationModel.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sending: String?
    @State private var sent: String?
    @State private var error: String?

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Forward")
                    .font(.title2.bold())
                quote
                SearchField(text: $query, prompt: "Search Conversations")
            }
            .padding([.horizontal, .top], Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.m)
            list
                .frame(minHeight: 280, maxHeight: 380)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 440)
        .errorAlert("Couldn’t Forward the Message", message: $error)
        #else
        NavigationStack {
            list
                .safeAreaInset(edge: .top, spacing: 0) {
                    quote
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, Theme.Spacing.s)
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Conversations")
                .navigationTitle("Forward")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
        }
        .errorAlert("Couldn’t Forward the Message", message: $error)
        #endif
    }

    /// What's being forwarded, as one line in a quiet bubble.
    private var quote: some View {
        let sender = message.isOwn ? String(localized: "You") : message.senderName
        return HStack(spacing: Theme.Spacing.s) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(sender)
                    .font(.caption.weight(.semibold))
                Text(Copy.preview(of: message.body, sender: nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var rooms: [RoomSummary] {
        let all = model.rooms.filter { !$0.isInvite }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(trimmed) }
    }

    private var list: some View {
        List(rooms, id: \.id) { room in
            ForwardRow(
                room: room,
                isHere: room.id == fromRoomID,
                state: sending == room.id ? .sending : sent == room.id ? .sent : .idle
            ) {
                forward(to: room)
            }
            .disabled(sending != nil || sent != nil)
            #if os(macOS)
            .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.m, bottom: 0, trailing: Theme.Spacing.m))
            #endif
        }
        .listStyle(.plain)
        .overlay {
            if rooms.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .sensoryFeedback(.success, trigger: sent)
    }

    private func forward(to room: RoomSummary) {
        sending = room.id
        Task {
            do {
                try await conversation.forward(message, to: room.id)
                sending = nil
                withAnimation(Theme.Motion.flip) { sent = room.id }
                // Long enough to see it went, then out of the way.
                try? await Task.sleep(for: .milliseconds(450))
                dismiss()
            } catch {
                sending = nil
                self.error = Copy.error(error)
            }
        }
    }
}

private struct ForwardRow: View {
    enum State { case idle, sending, sent }

    let room: RoomSummary
    let isHere: Bool
    let state: State
    let action: () -> Void

    @SwiftUI.State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: Theme.Metrics.memberAvatar, isRoom: room.isRoom)
                Text(room.name)
                    .lineLimit(1)
                if isHere {
                    Text("This Conversation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ZStack {
                    switch state {
                    case .sending:
                        ProgressView().controlSize(.small)
                    case .sent:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    case .idle:
                        EmptyView()
                    }
                }
                .frame(width: 20)
            }
            #if os(macOS)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            #endif
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) { isHovering = hovering }
        }
        #endif
        .accessibilityLabel(Text("Forward to \(room.name)"))
    }
}
