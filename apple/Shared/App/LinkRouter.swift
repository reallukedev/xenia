import Foundation
import Observation
import XeniaCore
import SwiftUI

/// Matrix links (matrix.to and `matrix:`) open in Xenia: a person opens your chat with them, a
/// room or message opens there. Anything that would start or join something new asks first.
@Observable
final class LinkRouter {
    enum Prompt: Identifiable {
        case message(userID: String, name: String)
        case join(address: String, via: [String], eventID: String?)

        var id: String {
            switch self {
            case .message(let userID, _): userID
            case .join(let address, _, let eventID): address + (eventID ?? "")
            }
        }
    }

    var prompt: Prompt?
    var error: String?
    private(set) var isWorking = false
    @ObservationIgnored weak var model: AppModel?

    /// For `openURL`: Matrix links are handled here, everything else goes to the system.
    func handle(_ url: URL) -> OpenURLAction.Result {
        guard let link = parseMatrixLink(url: url.absoluteString) else { return .systemAction }
        Task { await open(link) }
        return .handled
    }

    func open(_ link: MatrixLink) async {
        guard let model else { return }
        await model.session.wait()
        switch link {
        case .user(let userID):
            guard userID != model.account?.userId else { return }
            if let chat = model.rooms.first(where: { $0.dmUserId == userID && !$0.isInvite }) {
                model.navigation.open(roomID: chat.id, scope: chat.scope)
                return
            }
            let profile = try? await model.client.profile(userId: userID)
            let name = profile?.displayName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? userID
            ask(.message(userID: userID, name: name))
        case .room(let address, let via):
            await openRoom(address: address, via: via, eventID: nil)
        case .message(let address, let eventID, let via):
            await openRoom(address: address, via: via, eventID: eventID)
        }
    }

    private func openRoom(address: String, via: [String], eventID: String?) async {
        guard let model else { return }
        do {
            if let roomID = try await model.client.joinedRoom(address: address) {
                show(roomID, eventID: eventID)
            } else {
                ask(.join(address: address, via: via, eventID: eventID))
            }
        } catch {
            self.error = Copy.error(error)
        }
    }

    /// Asks from the window itself: a sheet or thread on top would hide the question.
    private func ask(_ question: Prompt) {
        model?.navigation.sheet = nil
        model?.navigation.thread = nil
        prompt = question
    }

    /// The answer to a prompt: start the chat or join the room, then open it.
    func confirm(_ prompt: Prompt) {
        guard let model, !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch prompt {
                case .message(let userID, _):
                    let roomID = try await model.client.startDirectChat(userId: userID)
                    model.navigation.open(roomID: roomID, scope: .chats)
                case .join(let address, let via, let eventID):
                    let roomID = try await model.client.joinLink(address: address, via: via)
                    show(roomID, eventID: eventID)
                }
            } catch {
                self.error = Copy.error(error)
            }
        }
    }

    private func show(_ roomID: String, eventID: String?) {
        guard let model else { return }
        let scope = model.roomsByID[roomID]?.scope ?? .rooms
        model.navigation.sheet = nil
        model.navigation.open(roomID: roomID, scope: scope, eventID: eventID)
    }
}

extension View {
    /// Routes Matrix links tapped anywhere below, or opened from other apps, into Xenia.
    func matrixLinks(_ router: LinkRouter) -> some View {
        modifier(MatrixLinksModifier(router: router))
    }
}

private struct MatrixLinksModifier: ViewModifier {
    @Bindable var router: LinkRouter

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { router.handle($0) })
            .onOpenURL { _ = router.handle($0) }
            .alert(title, isPresented: isPrompting, presenting: router.prompt) { prompt in
                Button("Cancel", role: .cancel) {}
                switch prompt {
                case .message:
                    Button("Message") { router.confirm(prompt) }
                        .keyboardShortcut(.defaultAction)
                case .join:
                    Button("Join") { router.confirm(prompt) }
                        .keyboardShortcut(.defaultAction)
                }
            } message: { prompt in
                switch prompt {
                case .message(let userID, let name):
                    Text(name == userID ? "Start a conversation with \(userID)." : "Start a conversation with \(name) (\(userID)).")
                case .join:
                    Text("You’re not in this room yet. Once you join, people in it can see you’re there.")
                }
            }
            .errorAlert("Couldn’t Open the Link", message: $router.error)
    }

    private var title: Text {
        switch router.prompt {
        case .message(_, let name): Text("Message \(name)?")
        case .join(let address, _, _): Text("Join \(address)?")
        case nil: Text("")
        }
    }

    private var isPrompting: Binding<Bool> {
        Binding(get: { router.prompt != nil }, set: { if !$0 { router.prompt = nil } })
    }
}
