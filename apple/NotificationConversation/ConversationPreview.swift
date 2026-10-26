import XeniaCore
import SwiftUI

/// A long-pressed notification: the conversation's latest messages as bubbles, the newest at
/// the bottom, as Messages shows them. Replies typed below appear here as they send.
struct ConversationPreview: View {
    let model: ConversationPreviewModel

    var body: some View {
        VStack(spacing: 0) {
            Text(model.title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.m)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
                        LineView(
                            line: line,
                            picture: line.picture.flatMap { model.pictures[$0] },
                            showsName: !model.isPrivate && !model.isDirect && !line.isYou && !line.senderName.isEmpty
                                && (index == 0 || model.lines[index - 1].senderID != line.senderID),
                            hasTail: index == model.lines.count - 1 || model.lines[index + 1].senderID != line.senderID
                                || model.lines[index + 1].isYou != line.isYou
                        )
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, Theme.Metrics.pageMargin)
                .padding(.bottom, Theme.Spacing.m)
                .animation(Theme.Motion.row, value: model.lines)
            }
            // The newest message stays in view as replies arrive and the keyboard takes room.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
    }
}

private struct LineView: View {
    let line: ConversationPreviewModel.Line
    let picture: UIImage?
    let showsName: Bool
    let hasTail: Bool

    var body: some View {
        VStack(alignment: line.isYou ? .trailing : .leading, spacing: 2) {
            if showsName {
                Text(line.senderName)
                    .font(.caption)
                    .foregroundStyle(Color.person(line.senderID))
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.top, Theme.Spacing.s)
            }
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius, style: .continuous))
                    .accessibilityLabel(Text(line.text))
            } else {
                Text(line.text)
                    .foregroundStyle(line.isYou ? .white : .primary)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Metrics.bubbleVerticalPadding)
                    .background(
                        line.isYou ? Color.ownBubble : Color.incomingBubble,
                        in: BubbleShape(radius: Theme.Metrics.bubbleRadius, tail: hasTail ? (line.isYou ? .trailing : .leading) : nil)
                    )
                    .opacity(line.status == .sending ? 0.6 : 1)
            }
            if line.status == .failed {
                Label("Not Delivered", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: line.isYou ? .trailing : .leading)
        .padding(line.isYou ? .leading : .trailing, 48)
        .padding(.bottom, hasTail ? Theme.Spacing.xs : 0)
    }
}
