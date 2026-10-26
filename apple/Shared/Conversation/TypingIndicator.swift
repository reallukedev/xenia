import XeniaCore
import SwiftUI

/// Who's typing: in groups, their photos where the sender's avatar goes, and three breathing
/// dots in a bubble. The Mac names them on hover; iPhone names them beside the dots in groups.
struct TypingIndicator: View {
    let people: [Reader]
    let isGroup: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    /// The dots breathe only while someone can see them.
    private var isPaused: Bool {
        reduceMotion || !isVisible || scenePhase != .active
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
            // Faces only where messages show them: in groups, not one-to-one chats.
            if isGroup {
                TypingFaces(people: people)
            }
            TimelineView(.animation(minimumInterval: 1 / 30, paused: isPaused)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(.secondary)
                            .frame(width: 7, height: 7)
                            .opacity(reduceMotion ? 0.6 : 0.35 + 0.55 * wave(t, index))
                            .scaleEffect(reduceMotion ? 1 : 0.9 + 0.12 * wave(t, index))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.incomingBubble, in: ThoughtBubbleShape(radius: Theme.Metrics.bubbleRadius))
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            #if os(iOS)
            if isGroup {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, Theme.Spacing.xs)
            }
            #endif
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.m)
        #if os(macOS)
        .help(Text(label))
        #endif
        .accessibilityElement()
        .accessibilityLabel(Text(label))
    }

    private func wave(_ t: TimeInterval, _ index: Int) -> Double {
        (sin(t * 6 - Double(index) * 0.9) + 1) / 2
    }

    private var label: String {
        let names = people.map { firstName(name: $0.name) }
        switch names.count {
        case 0: return String(localized: "Typing")
        case 1: return String(localized: "\(names[0]) is typing")
        case 2: return String(localized: "\(names[0]) and \(names[1]) are typing")
        default: return String(localized: "\(names[0]) and \(names.count - 1) others are typing")
        }
    }
}

/// Up to three faces, overlapping, the first in front.
private struct TypingFaces: View {
    let people: [Reader]

    var body: some View {
        let shown = Array(people.prefix(3))
        let size = Theme.Metrics.messageAvatar
        ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.userId) { index, person in
                AvatarView(name: person.name, seed: person.userId, url: person.avatarUrl, size: size)
                    .overlay { Circle().strokeBorder(.background, lineWidth: shown.count > 1 ? 1.5 : 0) }
                    .offset(x: CGFloat(index) * size * 0.45)
                    #if os(macOS)
                    .help(Text(person.name))
                    #endif
            }
        }
        .frame(width: size + CGFloat(max(shown.count - 1, 0)) * size * 0.45, height: size, alignment: .leading)
        .animation(Theme.Motion.flip, value: shown.map(\.userId))
    }
}

/// The typing bubble: rounded, with a trail of two small circles from its bottom leading
/// corner instead of a tail, as in Messages. The circles hang outside the frame, as a tail does.
nonisolated struct ThoughtBubbleShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: min(radius, rect.height / 2), style: .continuous)
        let big: CGFloat = 11
        let small: CGFloat = 5.5
        path.addEllipse(in: CGRect(x: rect.minX - 1, y: rect.maxY - big + 2.5, width: big, height: big))
        path.addEllipse(in: CGRect(x: rect.minX - 6, y: rect.maxY + 2.5, width: small, height: small))
        return path
    }
}

#Preview("Typing") {
    VStack(alignment: .leading, spacing: 24) {
        TypingIndicator(people: [Reader(userId: "@maya:localhost", name: "Maya Okafor", avatarUrl: nil)], isGroup: false)
        TypingIndicator(
            people: [
                Reader(userId: "@maya:localhost", name: "Maya Okafor", avatarUrl: nil),
                Reader(userId: "@sam:localhost", name: "Sam Reyes", avatarUrl: nil),
            ],
            isGroup: true
        )
    }
    .padding(.vertical, 40)
}
