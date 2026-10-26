import XeniaCore
import SwiftUI

extension View {
    /// iPhone: drag a message to the right to reply, as in Messages. The arrow fills, with a tap
    /// of haptics, once the drag goes far enough; letting go there replies.
    func swipeToReply(_ message: TimelineMessage) -> some View {
        #if os(iOS)
        modifier(SwipeToReply(message: message))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct SwipeToReply: ViewModifier {
    let message: TimelineMessage

    @Environment(ConversationModel.self) private var conversation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var armed = false

    private let threshold: CGFloat = 64

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(armed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 30, height: 30)
                    .background(.fill.tertiary, in: .circle)
                    .scaleEffect(armed ? 1.1 : 0.8)
                    .opacity(Double(min(offset / threshold, 1)))
                    .padding(.leading, Theme.Spacing.m)
                    .animation(Theme.Motion.flip, value: armed)
                    .accessibilityHidden(true)
            }
            .gesture(drag)
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new }
    }

    private var drag: ReplyPan {
        ReplyPan(isEnabled: message.canReply) { dx in
            // Resist past the threshold, like a rubber band.
            let dx = max(0, dx)
            offset = dx < threshold ? dx : threshold + (dx - threshold) * 0.25
            armed = offset >= threshold
        } onEnd: {
            if armed { conversation.reply(to: message) }
            armed = false
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.2)) {
                offset = 0
            }
        }
    }
}

/// A pan that only begins for a mostly sideways drag to the right, so a drag that starts on a
/// bubble still scrolls the conversation, and the edge swipe still goes back. A SwiftUI
/// `DragGesture` on scroll content claims vertical drags too.
private struct ReplyPan: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChange(recognizer.translation(in: recognizer.view).x)
        case .ended, .cancelled, .failed:
            onEnd()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            // Leave the screen's left edge to the back swipe.
            if let window = view.window, pan.location(in: window).x < 28 { return false }
            let velocity = pan.velocity(in: view)
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.8
        }
    }
}
#endif
