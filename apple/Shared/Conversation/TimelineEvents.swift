import Foundation
import XeniaCore

/// Receives a timeline's updates on the core's threads and applies them on the main thread, in
/// order.
final class TimelineEvents: TimelineListener, @unchecked Sendable {
    nonisolated(unsafe) weak var conversation: ConversationModel?

    nonisolated init() {}

    nonisolated func onUpdate(update: TimelineUpdate) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.conversation?.apply(update) }
        }
    }

    nonisolated func onTyping(people: [Reader]) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.conversation?.apply(typing: people) }
        }
    }
}
