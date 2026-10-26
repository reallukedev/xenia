import XeniaCore
import SwiftUI

/// One row of a conversation, by kind.
struct TimelineRowView: View {
    let row: TimelineRow

    var body: some View {
        switch row {
        case .message(let message):
            MessageRowView(message: message)
        case .header(_, let timestamp):
            SessionHeader(timestamp: timestamp)
        case .note(let line):
            NoteText(text: Copy.note(line.note))
        case .noteGroup(let id, let notes):
            NoteGroupRow(id: id, notes: notes)
        case .readMarker:
            NewMessagesDivider()
        case .start:
            // Drawn by the conversation itself once the beginning is loaded.
            EmptyView()
        }
    }
}

/// "Today 9:41 AM" above a sitting, with the day in a heavier weight, as Messages sets it.
private struct SessionHeader: View {
    let timestamp: Int64

    var body: some View {
        let parts = TimeFormat.header(timestamp)
        let day = Text(parts.day).fontWeight(.semibold)
        Text("\(day) \(parts.time)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NoteText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.xxxl)
            .padding(.vertical, Theme.Spacing.xs)
    }
}

/// Several changes in a row, folded into one line; tapping unfolds them.
private struct NoteGroupRow: View {
    let id: String
    let notes: [NoteLine]
    @Environment(ConversationModel.self) private var conversation

    var body: some View {
        Button {
            conversation.expandNotes(id)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(Copy.noteGroup(notes))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.xxxl)
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows each change"))
    }
}

/// Where the messages you haven't seen begin.
private struct NewMessagesDivider: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Rectangle().fill(.tint.opacity(0.5)).frame(height: 1)
            Text("New Messages")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .fixedSize()
            Rectangle().fill(.tint.opacity(0.5)).frame(height: 1)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

/// The very top of a conversation: who it's with.
struct ConversationStart: View {
    @Environment(ConversationModel.self) private var conversation
    @Environment(AppModel.self) private var model

    var body: some View {
        if let room = model.room(conversation.roomID) {
            VStack(spacing: Theme.Spacing.s) {
                AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: 64, isRoom: room.isRoom)
                Text(room.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(conversation.historyStartsAtJoin
                     ? "Messages from before you joined aren’t available."
                     : room.isDm
                     ? "This is the beginning of your chat with \(room.name)."
                     : "This is the beginning of “\(room.name)”.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if room.isEncrypted {
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.s)
        }
    }
}
