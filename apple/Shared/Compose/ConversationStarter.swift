import XeniaCore
import SwiftUI

/// Starts a chat with someone or joins a room, then hands over the conversation to open. One at
/// a time: a second click while the first is working would start another.
@Observable
final class ConversationStarter {
    /// The person or room being started or joined, for its row's spinner.
    private(set) var pending: String?
    /// What failed, for an alert titled by `errorTitle`.
    var error: String?
    private(set) var errorTitle: LocalizedStringKey = "Couldn’t Start the Chat"

    func chat(with userID: String, client: XeniaClient, then open: @escaping (String) -> Void) {
        guard pending == nil else { return }
        pending = userID
        Task {
            defer { pending = nil }
            do {
                open(try await client.startDirectChat(userId: userID))
            } catch {
                errorTitle = "Couldn’t Start the Chat"
                self.error = Copy.error(error)
            }
        }
    }

    /// `address` is a room's ID or alias.
    func join(_ address: String, client: XeniaClient, then open: @escaping (String) -> Void) {
        guard pending == nil else { return }
        pending = address
        Task {
            defer { pending = nil }
            do {
                open(try await client.join(address: address))
            } catch {
                errorTitle = "Couldn’t Join"
                self.error = Copy.error(error)
            }
        }
    }
}
