import XeniaCore
import SwiftUI

/// Reactions as Messages draws Tapbacks: round badges on the bubble's top corner, toward the
/// middle of the conversation, the most popular in front, with how many reactions there are when
/// that's more than the badges show. Tapping lists who reacted and toggles mine.
struct TapbackCluster: View {
    let message: TimelineMessage
    /// A badge's diameter, which grows with the text size.
    let size: CGFloat

    @Environment(ConversationModel.self) private var conversation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether badges are showing, so the first reaction pops in rather than appearing.
    @State private var hasShown = false
    /// The last reactions there were, drawn while the badges leave after the last one goes.
    @State private var leaving: [Reaction] = []

    /// How far badges of a size rise above the bubble, which the row leaves room for.
    static func rise(for size: CGFloat) -> CGFloat { size - 12 }

    var body: some View {
        // Always present, so the first reaction can pop in: an empty message draws nothing here.
        let reactions = message.reactions.isEmpty ? leaving : message.reactions
        ZStack {
            if !reactions.isEmpty {
                badges(reactions)
            }
        }
        .scaleEffect(hasShown || reduceMotion ? 1 : 0.3, anchor: message.isOwn ? .bottomTrailing : .bottomLeading)
        .opacity(hasShown ? 1 : 0)
        .allowsHitTesting(hasShown)
        .onAppear { hasShown = !message.reactions.isEmpty }
        .onChange(of: message.reactions) { old, new in
            guard old.isEmpty != new.isEmpty else { return }
            if new.isEmpty { leaving = old }
            let animation = reduceMotion || new.isEmpty ? Theme.Motion.flip : .spring(duration: 0.35, bounce: 0.35)
            withAnimation(animation) {
                hasShown = !new.isEmpty
            } completion: {
                if new.isEmpty { leaving = [] }
            }
        }
    }

    private func badges(_ reactions: [Reaction]) -> some View {
        // Most reacted in front; ties keep the order they arrived in.
        let shown = reactions.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .prefix(3)
            .map(\.element)
        let people = reactions.reduce(0) { $0 + Int($1.count) }
        return Menu {
            ForEach(reactions, id: \.key) { reaction in
                Button {
                    conversation.toggleReaction(reaction.key, on: message)
                } label: {
                    if reaction.isMine {
                        Label("\(reaction.key)  \(names(reaction))", systemImage: "checkmark")
                    } else {
                        Text("\(reaction.key)  \(names(reaction))")
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                if message.isOwn { count(people, shown: shown.count) }
                ZStack(alignment: message.isOwn ? .trailing : .leading) {
                    ForEach(Array(shown.enumerated().reversed()), id: \.element.key) { index, reaction in
                        Badge(emoji: reaction.key, isMine: reaction.isMine, size: size)
                            .offset(x: CGFloat(index) * size * 0.55 * (message.isOwn ? -1 : 1))
                    }
                }
                .frame(
                    width: size * (1 + 0.55 * CGFloat(max(shown.count - 1, 0))),
                    alignment: message.isOwn ? .trailing : .leading
                )
                if !message.isOwn { count(people, shown: shown.count) }
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .animation(Theme.Motion.flip, value: reactions)
        .accessibilityLabel(Text(reactions.map { "\($0.key) \(names($0))" }.formatted(.list(type: .and))))
        .accessibilityHint(Text("Shows who reacted"))
    }

    private func names(_ reaction: Reaction) -> String {
        reaction.senderNames.map { $0.isEmpty ? String(localized: "You") : $0 }.formatted(.list(type: .and))
    }

    /// How many reactions there are, when the badges alone don't say.
    @ViewBuilder
    private func count(_ people: Int, shown: Int) -> some View {
        if people > shown {
            Text(people, format: .number)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(people)))
        }
    }

    /// One reaction: the emoji in a round bubble, blue when it's mine, ringed in the background so
    /// it stands clear of the message under it.
    private struct Badge: View {
        let emoji: String
        let isMine: Bool
        let size: CGFloat

        var body: some View {
            Text(emoji)
                .font(.system(size: size * 0.52))
                .frame(width: size, height: size)
                .background(isMine ? Color.ownBubble : Color.incomingBubble, in: .circle)
                .background(Circle().fill(.background).padding(-2))
        }
    }
}
