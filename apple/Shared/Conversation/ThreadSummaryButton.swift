import XeniaCore
import SwiftUI

/// "5 Replies" under a message that started a thread, with the latest replier and when.
struct ThreadSummaryButton: View {
    let summary: ThreadSummary
    let action: () -> Void

    @Environment(AppModel.self) private var model
    /// Where the button is, kept outside SwiftUI's state: it moves on every frame of a scroll,
    /// and only the tap reads it.
    @State private var place = Place()

    var body: some View {
        Button {
            model.navigation.threadOrigin = place.center
            action()
        } label: {
            HStack(spacing: Theme.Spacing.xs + 2) {
                // New replies, or one that mentions you, marked as the list marks a conversation.
                if summary.unread != .none {
                    UnreadMark(kind: summary.unread)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                if let id = summary.latestSenderId {
                    AvatarView(name: summary.latestSenderName ?? id, seed: id, url: summary.latestSenderAvatarUrl, size: 18)
                }
                Text("^[\(summary.replyCount) Reply](inflect: true)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                if let at = summary.latestTimestampMs {
                    Text(TimeFormat.relative(at))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minHeight: Theme.Metrics.minTarget * 0.75)
            // A full-size target without a taller row: it reaches past the row's edges.
            .padding(.vertical, Theme.Metrics.minTarget / 8)
            .contentShape(.rect)
            .padding(.vertical, -Theme.Metrics.minTarget / 8)
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .global)
            return CGPoint(x: frame.midX, y: frame.midY)
        } action: { place.center = $0 }
        .animation(Theme.Motion.flip, value: summary.unread)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text("Opens the thread"))
    }

    private var accessibilityLabel: Text {
        let replies = Text("^[\(summary.replyCount) reply](inflect: true) in thread")
        switch summary.unread {
        case .mention: return Text("\(replies), mentions you")
        case .unread: return Text("\(replies), unread")
        case .none: return replies
        }
    }

    private final class Place {
        var center: CGPoint?
    }
}
