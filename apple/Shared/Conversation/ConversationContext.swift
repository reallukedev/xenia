import XeniaCore
import SwiftUI

/// What rows need to know about the conversation they're in.
struct ConversationContext {
    var isGroup = true
    var isThread = false
    /// The widest a bubble may be in this conversation's width.
    var bubbleMaxWidth: CGFloat = Theme.Metrics.bubbleMaxWidth
    /// Opens a thread from its root message.
    var openThread: (String) -> Void = { _ in }
    /// Scrolls to a message by its event ID (a reply's original), if it's loaded.
    var scrollToEvent: (String) -> Void = { _ in }
    /// Opens photos and files in Quick Look, and hands them to Save, Share and Copy.
    var previewer: AttachmentPreviewer?
}

extension EnvironmentValues {
    @Entry var conversationContext = ConversationContext()
}
