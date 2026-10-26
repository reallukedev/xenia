import XeniaCore
import SwiftUI

extension View {
    /// Double-tapping (or double-clicking) a text message opens its Tapbacks. Photos and files
    /// keep their single click for Quick Look; their Tapbacks are in the menu.
    func tapbackOnDoubleTap(_ message: TimelineMessage) -> some View {
        modifier(TapbackOnDoubleTap(message: message))
    }

    #if os(iOS)
    /// iPhone: holding a message lifts it with its Tapbacks and menu, double-tapping a text
    /// message with its Tapbacks only, as in Messages.
    func liftable(_ message: TimelineMessage) -> some View {
        modifier(TapbackOnDoubleTap(message: message))
    }
    #endif
}

private struct TapbackOnDoubleTap: ViewModifier {
    let message: TimelineMessage

    /// Text that has reached the server. Checked when tapped, not by changing the view, so the
    /// bubble keeps its identity (and its fade) as it finishes sending.
    private var canReact: Bool {
        if case .text = message.content, message.eventId != nil, message.sendState == .sent { true } else { false }
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        // On the Mac the Tapbacks live at the top of the message's menu.
        content
            .onTapGesture(count: 2) { if canReact { MessageMenuHost.host(for: message.id)?.popUp() } }
        #else
        content
            .modifier(Liftable(message: message, canReact: canReact))
        #endif
    }
}

#if os(iOS)
private struct Liftable: ViewModifier {
    let message: TimelineMessage
    let canReact: Bool

    @Environment(ConversationModel.self) private var conversation
    @Environment(\.conversationContext) private var context
    @State private var anchor = LiftAnchorBox()

    func body(content: Content) -> some View {
        content
            .background(LiftAnchor(box: anchor))
            .onTapGesture(count: 2) {
                if canReact { conversation.lift(message, from: anchor, context: context, showsMenu: false) }
            }
            .gesture(LiftPress(isEnabled: true) {
                conversation.lift(message, from: anchor, context: context, showsMenu: true)
            })
            // The lifted copy takes its place until it settles back.
            .opacity(conversation.lifted?.id == message.id ? 0 : 1)
            .accessibilityAction(named: Text("Show Actions")) {
                conversation.lift(message, from: anchor, context: context, showsMenu: true)
            }
            // The swipe that replies, for VoiceOver.
            .accessibilityActions {
                if message.canReply {
                    Button("Reply") { conversation.reply(to: message) }
                }
            }
    }
}
#endif
