import XeniaCore
import SwiftUI

/// A poll, drawn as Messages draws one: a card rather than a bubble, the same for everyone, with
/// the question on top and each choice a row you tap to vote. Once results show, a bar grows
/// behind each choice and the faces of who chose it sit at its end. Nothing here changes size
/// when votes arrive, so the measured timeline never jumps.
struct PollCard: View {
    let message: TimelineMessage
    let question: String
    let answers: [PollAnswer]
    let isDisclosed: Bool
    let maxSelections: UInt32
    let voterCount: UInt32
    let isEnded: Bool

    @Environment(ConversationModel.self) private var conversation
    @Environment(\.conversationContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize

    private var showsResults: Bool { isDisclosed || isEnded }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(question)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                subtitle
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Theme.Motion.flip, value: voterCount)
            }
            VStack(spacing: Theme.Spacing.xs + 2) {
                ForEach(answers, id: \.id) { answer in
                    ChoiceRow(
                        answer: answer,
                        showsResults: showsResults,
                        share: voterCount == 0 ? 0 : min(1, Double(answer.votes) / Double(voterCount)),
                        isLeading: answer.isWinner,
                        isEnded: isEnded,
                        allowsMultiple: maxSelections > 1
                    ) {
                        conversation.vote(answer.id, in: message)
                    }
                }
            }
        }
        .padding(Theme.Spacing.m + 2)
        .frame(width: width, alignment: .leading)
        .background(Color.incomingBubble, in: .rect(cornerRadius: Theme.Metrics.bubbleRadius + 2, style: .continuous))
        .foregroundStyle(.primary)
    }

    private var subtitle: Text {
        let votes = Text("^[\(voterCount) vote](inflect: true)")
        if isEnded { return Text("Final Results · \(votes)") }
        if !isDisclosed { return Text("Poll · Results when it ends") }
        if maxSelections > 1 { return Text("Poll · Choose up to \(maxSelections) · \(votes)") }
        return Text("Poll · \(votes)")
    }

    /// At the largest text sizes, as wide as any bubble, so the choices still read.
    private var width: CGFloat {
        typeSize.isAccessibilitySize ? context.bubbleMaxWidth : min(Self.width, context.bubbleMaxWidth)
    }

    #if os(macOS)
    private static let width: CGFloat = 320
    #else
    private static let width: CGFloat = 296
    #endif
}

private struct ChoiceRow: View {
    let answer: PollAnswer
    let showsResults: Bool
    /// This choice's share of the voters, 0 to 1.
    let share: Double
    let isLeading: Bool
    let isEnded: Bool
    let allowsMultiple: Bool
    let vote: () -> Void

    /// Grows with the text, so the count never clips at large sizes.
    @ScaledMetric(relativeTo: .footnote) private var votersWidth: CGFloat = 50
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if isEnded {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(answer.text))
                .accessibilityValue(accessibilityValue)
                .accessibilityAddTraits(answer.isMine ? .isSelected : [])
        } else {
            Button(action: vote) { row }
                .buttonStyle(PressScaleButtonStyle(pressed: 0.97))
                .accessibilityLabel(Text(answer.text))
                .accessibilityValue(accessibilityValue)
                .accessibilityAddTraits(answer.isMine ? .isSelected : [])
        }
    }

    private var row: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(answer.isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                // An ended poll keeps only my own choice marked.
                .opacity(isEnded && !answer.isMine ? 0 : 1)
            if typeSize.isAccessibilitySize {
                // The choice gets the row's width; who chose it goes under it.
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    choice
                    if showsResults {
                        Voters(voters: answer.voters, count: answer.votes)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                choice
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Always the same width, so faces arriving never rewrap the choice.
                Voters(voters: answer.voters, count: answer.votes)
                    .opacity(showsResults ? 1 : 0)
                    .frame(width: votersWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.Spacing.s + 2)
        .padding(.vertical, Theme.Spacing.xs + 2)
        .frame(minHeight: Theme.Metrics.minTarget)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.opacity(0.7))
                .overlay(alignment: .leading) {
                    // A scale, not a width, so a new count never lays the row out again.
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(answer.isMine ? 0.34 : 0.22))
                        .scaleEffect(x: showsResults ? share : 0, anchor: .leading)
                }
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
        }
        .contentShape(.rect(cornerRadius: 10))
        // The bars glide to their new lengths, and grow in when the results first show.
        .animation(Theme.Motion.row, value: share)
        .animation(Theme.Motion.row, value: showsResults)
        .animation(Theme.Motion.flip, value: answer.isMine)
    }

    private var choice: some View {
        Text(answer.text)
            .fontWeight(isLeading ? .semibold : .regular)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var symbol: String {
        if answer.isMine { return allowsMultiple ? "checkmark.square.fill" : "checkmark.circle.fill" }
        return allowsMultiple ? "square" : "circle"
    }

    private var accessibilityValue: Text {
        guard showsResults else { return Text("") }
        guard !answer.voters.isEmpty else { return Text("^[\(answer.votes) vote](inflect: true)") }
        let names = answer.voters.map(\.name).formatted(.list(type: .and))
        return Text("^[\(answer.votes) vote](inflect: true): \(names)")
    }
}

/// Up to three faces of who chose an answer, overlapping, then how many in all.
private struct Voters: View {
    let voters: [Reader]
    let count: UInt32

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs + 1) {
            HStack(spacing: -8) {
                ForEach(voters.prefix(3), id: \.userId) { voter in
                    AvatarView(name: voter.name, seed: voter.userId, url: voter.avatarUrl, size: 16)
                        .overlay { Circle().strokeBorder(Color.incomingBubble, lineWidth: 1.5) }
                }
            }
            Text(count, format: .number)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(count)))
        }
        .accessibilityHidden(true)
    }
}
