import XeniaCore
import SwiftUI

/// One message: the sender's name and avatar in groups, the bubble, and what hangs off it
/// (reactions, a thread, whether it was read).
struct MessageRowView: View {
    let message: TimelineMessage

    @Environment(\.conversationContext) private var context
    @Environment(ConversationModel.self) private var conversation
    @ScaledMetric(relativeTo: .body) private var tapbackSize = Theme.Metrics.tapback

    /// Tapbacks grow with the text, but not so far that they cover it.
    private var tapback: CGFloat { min(tapbackSize, Theme.Metrics.tapback * 1.6) }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
            if message.isOwn {
                Spacer(minLength: Theme.Spacing.xxxl)
            } else if context.isGroup {
                AvatarSlot(message: message)
            }
            VStack(alignment: message.isOwn ? .trailing : .leading, spacing: 3) {
                if message.showSender {
                    SenderName(message: message)
                        .lineLimit(1)
                        .padding(.horizontal, Theme.Spacing.m)
                        // Tapbacks rise above the bubble's far corner: the name, on the near side,
                        // sits as close as it would without them.
                        .padding(.bottom, message.reactions.isEmpty ? 0 : -TapbackCluster.rise(for: tapback))
                        .accessibilityHidden(true)
                }
                HStack(alignment: .center, spacing: Theme.Spacing.s) {
                    if message.sendState == .failed {
                        FailedButton(message: message)
                    }
                    BubbleWithTapbacks(message: message, tapback: tapback, readBy: readBy)
                        .overlay(alignment: .leading) {
                            if message.isOwn, message.sendState == .sending {
                                SlowSendSpinner()
                                    .offset(x: -Theme.Spacing.xxl - Theme.Spacing.xs)
                            }
                        }
                        #if os(macOS)
                        .tapbackOnDoubleTap(message)
                        .macMessageMenu(MessageMenuActions(
                            message: message, conversation: conversation, context: context,
                            confirmDelete: { conversation.deleting = message }
                        ))
                        #else
                        // Held, it lifts with its Tapbacks and menu; double-tapped, with Tapbacks only.
                        .liftable(message)
                        #endif
                }
                if let thread = message.thread, !context.isThread, let root = message.eventId {
                    ThreadSummaryButton(summary: thread) { context.openThread(root) }
                }
                StatusLine(message: message)
            }
            .frame(maxWidth: context.bubbleMaxWidth, alignment: message.isOwn ? .trailing : .leading)
            if !message.isOwn {
                Spacer(minLength: Theme.Spacing.xxxl)
            }
        }
        .padding(.top, message.run.isFirst ? Theme.Spacing.s : Theme.Spacing.xxs)
        .padding(.bottom, message.run.isLast ? Theme.Spacing.xs : 0)
        .padding(.horizontal, Theme.Spacing.m)
        .overlay(alignment: Alignment(horizontal: .trailing, vertical: .bubbleCenter)) {
            RevealedDetail(message: message)
        }
        .swipeToReply(message)
        .background {
            // Only the message a search jumped to carries the flash and its timer.
            if message.isHighlighted { HighlightFlash() }
        }
    }
}

extension MessageRowView {
    /// Who has read the run this message ends, for VoiceOver's More Content.
    fileprivate var readBy: Text? {
        guard let seen = message.seen, seen.readCount > 0 else { return nil }
        if seen.others > ReadShare.facesUpTo {
            return Text("^[\(seen.readCount) person](inflect: true) of \(seen.others)")
        }
        let names = seen.read.map(\.name)
        let more = Int(seen.readCount) - names.count
        guard more > 0 else { return Text(names.formatted(.list(type: .and))) }
        return Text((names + [String(localized: "^[\(more) other](inflect: true)")]).formatted(.list(type: .and)))
    }
}

/// The bubble with its Tapbacks on its top corner, as the conversation draws it and as it's
/// lifted to react to it.
struct BubbleWithTapbacks: View {
    let message: TimelineMessage
    let tapback: CGFloat
    var readBy: Text?

    var body: some View {
        MessageBubble(message: message)
            .accessibilityCustomContent(AccessibilityCustomContentKey("Read By"), readBy)
            .alignmentGuide(.bubbleCenter) { $0[VerticalAlignment.center] }
            .overlay(alignment: message.isOwn ? .topLeading : .topTrailing) {
                // A box straddling the bubble's top corner; the badges grow from its inner
                // corner, up and out, so their inner corner sits on the bubble.
                Color.clear
                    .frame(width: 28, height: 24)
                    .overlay(alignment: message.isOwn ? .bottomTrailing : .bottomLeading) {
                        TapbackCluster(message: message, size: tapback)
                    }
                    .offset(x: message.isOwn ? -14 : 14, y: -12)
            }
            .padding(.top, message.reactions.isEmpty ? 0 : TapbackCluster.rise(for: tapback))
    }
}

extension VerticalAlignment {
    private enum BubbleCenter: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
    }

    /// The middle of a message's bubble, whatever hangs above or below it.
    static let bubbleCenter = VerticalAlignment(BubbleCenter.self)
}

/// The message's time, waiting just past the trailing edge: swiping the conversation left
/// brings it in beside the bubble, as in Messages. The last bubble of a run also shows who has
/// read the run.
private struct RevealedDetail: View {
    let message: TimelineMessage

    var body: some View {
        let gap = Theme.Spacing.s
        VStack(alignment: .leading, spacing: 3) {
            Text(TimeFormat.clock(message.timestampMs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let seen = message.seen {
                if seen.others > ReadShare.facesUpTo {
                    ReadShare(seen: seen)
                } else {
                    ReadFaces(seen: seen)
                }
            }
        }
        .fixedSize()
        .alignmentGuide(HorizontalAlignment.trailing) { $0[.leading] - gap }
        .accessibilityHidden(true)
    }
}

/// In a small conversation, the faces of who has read: four at most, then a count.
private struct ReadFaces: View {
    let seen: Seen

    private static let limit = 5
    private static let size: CGFloat = 16

    var body: some View {
        let total = Int(seen.readCount)
        let shown = min(seen.read.count, total > Self.limit ? Self.limit - 1 : total)
        HStack(spacing: Theme.Spacing.xxs + 1) {
            HStack(spacing: -4) {
                ForEach(seen.read.prefix(shown), id: \.userId) { reader in
                    AvatarView(name: reader.name, seed: reader.userId, url: reader.avatarUrl, size: Self.size)
                        .padding(1)
                        // Opaque, so a face never shows through the one overlapping it.
                        .background(Color.conversationBackground, in: .circle)
                }
            }
            if total > shown {
                Text("+\(total - shown)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// In a bigger room, how much of it has read: "62% read".
private struct ReadShare: View {
    let seen: Seen

    /// Rooms with more people than this show the share instead of faces.
    static let facesUpTo: UInt32 = 5

    /// Rounded down, so it only says 100% once everyone has.
    private var share: Double {
        guard seen.others > 0 else { return 0 }
        let exact = min(1, Double(seen.readCount) / Double(seen.others))
        return max(0.01, (exact * 100).rounded(.down) / 100)
    }

    var body: some View {
        Text("\(share, format: .percent.precision(.fractionLength(0))) read")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(height: 18, alignment: .leading)
    }
}

/// Above the first bubble of a run in a group: gray and quiet, as in Messages, or the person's
/// own color when Settings color-codes people.
private struct SenderName: View {
    let message: TimelineMessage
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(message.senderName)
            .font(model.preferences.colorCodePeople ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(model.preferences.colorCodePeople ? AnyShapeStyle(Color.person(message.senderId)) : AnyShapeStyle(.secondary))
    }
}

/// The avatar column in groups: the face on the last bubble of a run, space on the others.
private struct AvatarSlot: View {
    let message: TimelineMessage

    var body: some View {
        Group {
            if message.run.isLast {
                AvatarView(name: message.senderName, seed: message.senderId, url: message.senderAvatarUrl, size: Theme.Metrics.messageAvatar)
            } else {
                Color.clear
            }
        }
        .frame(width: Theme.Metrics.messageAvatar, height: Theme.Metrics.messageAvatar)
    }
}

/// Beside my message when sending takes more than a moment (a weak signal, a server that's down),
/// so a dimmed bubble never looks forgotten. It draws outside the row, changing no heights.
private struct SlowSendSpinner: View {
    @State private var isSlow = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: Theme.Spacing.xl)
            .opacity(isSlow ? 1 : 0)
            .task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(Theme.Motion.contentFade) { isSlow = true }
            }
            .accessibilityLabel(Text("Sending"))
            .accessibilityHidden(!isSlow)
    }
}

/// A red mark beside a message that didn't send, with Try Again and Delete.
private struct FailedButton: View {
    let message: TimelineMessage
    @Environment(ConversationModel.self) private var conversation

    var body: some View {
        Menu {
            Button("Try Again", systemImage: "arrow.clockwise") { conversation.retry(message) }
            Button("Delete", systemImage: "trash", role: .destructive) { conversation.delete(message) }
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.red)
                .frame(minWidth: Theme.Metrics.minTarget, minHeight: Theme.Metrics.minTarget)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Not Delivered"))
        .accessibilityHint(Text("Shows options to try again or delete"))
    }
}

/// Under a message: Edited, Not Delivered, or on my newest message, Delivered or Read.
private struct StatusLine: View {
    let message: TimelineMessage
    @Environment(\.conversationContext) private var context

    var body: some View {
        let parts = parts
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2.weight(message.sendState == .failed ? .semibold : .medium))
                .foregroundStyle(message.sendState == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .padding(.horizontal, Theme.Spacing.xs)
                .transition(.opacity)
                .contentTransition(.opacity)
                .animation(Theme.Motion.contentFade, value: parts)
        }
    }

    private var parts: [String] {
        var out: [String] = []
        if message.isEdited { out.append(String(localized: "Edited")) }
        if message.sendState == .failed {
            out.append(String(localized: "Not Delivered"))
        } else if let delivery = message.delivery {
            if !delivery.isRead {
                out.append(String(localized: "Delivered"))
            } else if context.isGroup, !delivery.readers.isEmpty {
                out.append(readBy(delivery.readers))
            } else {
                out.append(String(localized: "Read"))
            }
        }
        return out
    }

    private func readBy(_ readers: [Reader]) -> String {
        let names = readers.map { firstName(name: $0.name) }
        switch names.count {
        case 1: return String(localized: "Read by \(names[0])")
        case 2: return String(localized: "Read by \(names[0]) and \(names[1])")
        default: return String(localized: "Read by \(names.count) people")
        }
    }
}

/// A soft yellow wash that fades, marking the message a search jumped to.
private struct HighlightFlash: View {
    @State private var visible = false

    var body: some View {
        Rectangle()
            .fill(Color.yellow.opacity(visible ? 0.16 : 0))
            .task {
                visible = true
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.8)) { visible = false }
            }
            .accessibilityHidden(true)
    }
}
