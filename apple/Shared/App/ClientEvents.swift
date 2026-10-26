import Foundation
import XeniaCore

/// Receives the core's reports on its threads and hands them to the model on the main thread,
/// in the order they were sent.
final class ClientEvents: ClientListener, @unchecked Sendable {
    // Set once, right after init, on the main thread; read only from main-thread blocks.
    nonisolated(unsafe) weak var model: AppModel?

    nonisolated init() {}

    private nonisolated func deliver(_ work: @escaping @MainActor (AppModel) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let model = self.model { work(model) }
            }
        }
    }

    nonisolated func onSessionChanged(state: SessionState) {
        deliver { $0.apply(session: state) }
    }

    nonisolated func onAccountChanged(account: Account) {
        deliver { $0.apply(account: account) }
    }

    nonisolated func onConnectionChanged(state: ConnectionState) {
        deliver { $0.apply(connection: state) }
    }

    nonisolated func onRoomsChanged(rooms: [RoomSummary], isLoaded: Bool) {
        deliver { $0.apply(rooms: rooms, loaded: isLoaded) }
    }

    nonisolated func onIncomingMessage(message: IncomingMessage) {
        deliver { $0.apply(incoming: message) }
    }

    nonisolated func onEncryptionChanged(status: EncryptionStatus) {
        deliver { $0.apply(encryption: status) }
    }

    nonisolated func onVerificationRequest(peer: VerificationPeer) {
        deliver { $0.apply(verificationRequest: peer) }
    }
}
