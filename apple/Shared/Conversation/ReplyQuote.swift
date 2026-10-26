import XeniaCore
import SwiftUI

/// The message being replied to, quoted at the top of the reply's bubble. Tapping it scrolls to
/// the original when it's loaded.
struct ReplyQuote: View {
    let reply: ReplyPreview
    let isOwn: Bool

    @Environment(\.conversationContext) private var context

    var body: some View {
        Button {
            context.scrollToEvent(reply.eventId)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(barColor))
                    Text(text)
                        .font(.caption)
                        .lineLimit(2)
                        .opacity(0.85)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Theme.Spacing.xs)
            .padding(.horizontal, Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOwn ? Color.white.opacity(0.18) : Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Reply to \(name): \(text)"))
        .accessibilityHint(Text("Shows the original message"))
    }

    private var barColor: Color {
        if isOwn { return .white.opacity(0.8) }
        return reply.senderId.map(Color.person) ?? .secondary
    }

    private var name: String {
        if reply.isOwn { return String(localized: "You") }
        return reply.senderName ?? String(localized: "Message")
    }

    private var text: String {
        switch reply.state {
        case .loading: String(localized: "Loading…")
        case .unavailable: String(localized: "Original message unavailable")
        case .ready: reply.body.map { Copy.preview(of: $0, sender: reply.senderName) } ?? String(localized: "Message")
        }
    }
}
