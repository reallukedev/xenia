import SwiftUI

/// The shape of a conversation while its first messages load: runs of bubbles with the real
/// bubbles' padding, line height, tails and spacing, so messages land where the shapes were.
/// It waits a moment before showing, so a conversation that opens quickly never flashes it.
struct LoadingBubbles: View {
    let isGroup: Bool

    @Environment(\.conversationContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShown = false
    @State private var isDim = false

    /// A run of bubbles from one side, oldest first: each bubble's width as a share of the widest
    /// a bubble may be, and its number of lines.
    private struct Run {
        let isOwn: Bool
        let bubbles: [(width: CGFloat, lines: Int)]
    }

    private static let runs: [Run] = [
        Run(isOwn: false, bubbles: [(0.62, 1), (0.9, 2)]),
        Run(isOwn: true, bubbles: [(0.5, 1)]),
        Run(isOwn: false, bubbles: [(0.4, 1)]),
        Run(isOwn: true, bubbles: [(0.8, 2), (0.34, 1)]),
        Run(isOwn: false, bubbles: [(0.72, 1), (0.5, 1)]),
        Run(isOwn: true, bubbles: [(0.58, 1)]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.runs.indices, id: \.self) { index in
                RunView(run: Self.runs[index], isGroup: isGroup, maxWidth: context.bubbleMaxWidth)
            }
        }
        .padding(.bottom, Theme.Spacing.xs)
        .opacity(isShown ? (isDim ? 0.55 : 1) : 0)
        // The pulse runs only while it's on screen and Xenia is in front.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return stopPulse() }
            if !isShown {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { isShown = true }
            }
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { isDim = true }
        }
        .onDisappear(perform: stopPulse)
        .accessibilityElement()
        .accessibilityLabel(Text("Loading Messages"))
    }

    private func stopPulse() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isDim = false }
    }

    private struct RunView: View {
        let run: Run
        let isGroup: Bool
        let maxWidth: CGFloat

        var body: some View {
            ForEach(run.bubbles.indices, id: \.self) { index in
                let isFirst = index == 0
                let isLast = index == run.bubbles.count - 1
                HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                    if run.isOwn {
                        Spacer(minLength: Theme.Spacing.xxxl)
                    } else if isGroup {
                        Circle()
                            .fill(.fill.tertiary)
                            .frame(width: Theme.Metrics.messageAvatar, height: Theme.Metrics.messageAvatar)
                            .opacity(isLast ? 1 : 0)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if isFirst, isGroup, !run.isOwn {
                            // Where the sender's name goes.
                            Text(verbatim: " ")
                                .font(.caption)
                                .frame(width: 72)
                                .background(.fill.quaternary, in: .capsule)
                                .padding(.horizontal, Theme.Spacing.m)
                        }
                        PlaceholderBubble(
                            width: run.bubbles[index].width * maxWidth,
                            lines: run.bubbles[index].lines,
                            tail: isLast ? (run.isOwn ? .trailing : .leading) : nil
                        )
                    }
                    if !run.isOwn {
                        Spacer(minLength: Theme.Spacing.xxxl)
                    }
                }
                .padding(.top, isFirst ? Theme.Spacing.s : Theme.Spacing.xxs)
                .padding(.bottom, isLast ? Theme.Spacing.xs : 0)
                .padding(.horizontal, Theme.Spacing.m)
            }
        }
    }

    /// A bubble as tall as real text of that many lines, at the person's text size.
    private struct PlaceholderBubble: View {
        let width: CGFloat
        let lines: Int
        let tail: BubbleShape.Edge?

        var body: some View {
            Text(verbatim: Array(repeating: " ", count: lines).joined(separator: "\n"))
                .font(.body)
                .foregroundStyle(.clear)
                .frame(width: max(width - 2 * Theme.Spacing.m, 24), alignment: .leading)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Metrics.bubbleVerticalPadding)
                .background(.fill.tertiary, in: BubbleShape(radius: Theme.Metrics.bubbleRadius, tail: tail))
        }
    }
}

#Preview("Loading, Group") {
    LoadingBubbles(isGroup: true)
        .environment(\.conversationContext, ConversationContext(bubbleMaxWidth: 300))
}

#Preview("Loading, Chat") {
    LoadingBubbles(isGroup: false)
        .environment(\.conversationContext, ConversationContext(bubbleMaxWidth: 300))
}
