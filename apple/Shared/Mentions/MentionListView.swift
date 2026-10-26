import XeniaCore
import SwiftUI

/// Where choosing a mention leads: the message in the conversation, or the thread it's in.
enum MentionDestination: Equatable {
    case message(eventID: String)
    case thread(root: String)

    init(_ hit: MentionHit) {
        self = hit.threadRootId.map { .thread(root: $0) } ?? .message(eventID: hit.eventId)
    }
}

/// Messages in one conversation that mention you, newest first. Choosing one goes to it.
struct MentionListView: View {
    let roomID: String
    let open: (MentionDestination) -> Void

    @Environment(AppModel.self) private var model
    @State private var mentions = MentionListModel()

    var body: some View {
        List {
            ForEach(mentions.hits, id: \.eventId) { hit in
                Button { open(MentionDestination(hit)) } label: {
                    MentionRow(hit: hit)
                }
                .buttonStyle(.plain)
                .listRowSeparator(hit.eventId == mentions.hits.first?.eventId ? .hidden : .automatic, edges: .top)
            }
        }
        .listStyle(.plain)
        .overlay {
            if mentions.hits.isEmpty {
                if let failure = mentions.failure {
                    ContentUnavailableView {
                        Label("Couldn’t Load Mentions", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try Again") {
                            Task { await mentions.load(roomID: roomID, model: model) }
                        }
                    }
                } else if !mentions.hasLoaded {
                    // Most loads finish before a spinner would help; it shows only for slow ones.
                    ProgressView().opacity(mentions.isSlow ? 1 : 0)
                } else {
                    ContentUnavailableView {
                        Label("No Mentions", systemImage: "at")
                    } description: {
                        Text("When someone mentions you in this conversation, the message shows up here.")
                    }
                }
            }
        }
        .task(id: roomID) { await mentions.load(roomID: roomID, model: model) }
    }
}

private struct MentionRow: View {
    let hit: MentionHit

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            AvatarView(name: hit.senderName, seed: hit.senderId, url: hit.senderAvatarUrl, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hit.senderName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.s)
                    Text(TimeFormat.relative(hit.timestampMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(MentionPreview.attributed(hit))
                    .font(.subheadline)
                    .lineLimit(2)
                if hit.threadRootId != nil {
                    Label("In a Thread", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A mention's words, with the mention of you set as bubbles set it: semibold, in the accent.
enum MentionPreview {
    static func attributed(_ hit: MentionHit) -> AttributedString {
        // Words of their own (a photo's caption, say) come marked; anything else reads as in a list.
        guard hit.preview.contains(where: { !$0.text.isEmpty }) else {
            return AttributedString(Copy.preview(of: hit.body, sender: hit.senderName))
        }
        var out = AttributedString()
        if case .emote = hit.body {
            out.append(AttributedString(hit.senderName + " "))
        }
        for mark in hit.preview {
            var piece = AttributedString(mark.text)
            if mark.isMatch {
                piece.font = .subheadline.weight(.semibold)
                piece.foregroundColor = .accentColor
            }
            out.append(piece)
        }
        return out
    }
}

@Observable
final class MentionListModel {
    private(set) var hits: [MentionHit] = []
    private(set) var hasLoaded = false
    /// Still loading after a moment: worth a spinner.
    private(set) var isSlow = false
    /// Why the list couldn't load (offline, say), until Try Again.
    private(set) var failure: String?

    func load(roomID: String, model: AppModel) async {
        failure = nil
        hasLoaded = false
        isSlow = false
        let slow = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { isSlow = true }
        }
        defer { slow.cancel() }
        do {
            hits = try await model.client.mentions(roomId: roomID, limit: 100)
        } catch {
            // Not "No Mentions": say what happened, and let Try Again ask again.
            hits = []
            failure = Copy.error(error)
        }
        hasLoaded = true
    }
}

/// The Mentions toolbar button's look: an @, with an orange dot while mentions are unread, as
/// the conversation list marks them.
struct MentionsButtonLabel: View {
    let unread: UInt64

    var body: some View {
        Label {
            Text("Mentions")
        } icon: {
            Image(systemName: "at")
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .offset(x: 4, y: -3)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .animation(Theme.Motion.flip, value: unread > 0)
        }
        .accessibilityValue(unread > 0 ? Text("^[\(Int(unread)) Unread Mention](inflect: true)") : Text(""))
    }
}
