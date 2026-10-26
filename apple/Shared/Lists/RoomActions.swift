import XeniaCore
import SwiftUI

/// What you can do to a conversation from outside it. The context menu, swipe actions, the Mac
/// menu bar and the info page all call these, so every door does the same thing.
@MainActor
struct RoomActions {
    let model: AppModel

    func toggleRead(_ room: RoomSummary) {
        run { try await model.client.setMarkedUnread(roomId: room.id, unread: !room.isUnread) }
        if room.isUnread { model.notifier.clear(roomID: room.id) }
    }

    func toggleFavourite(_ room: RoomSummary) {
        run { try await model.client.setFavourite(roomId: room.id, favourite: !room.isFavourite) }
    }

    /// Saves the pins' order after one was dragged to a new place. `failed` puts them back.
    func arrangePins(_ ids: [String], pins: [RoomSummary], failed: @escaping @MainActor () -> Void) {
        let current = Dictionary(pins.compactMap { pin in pin.favouriteOrder.map { (pin.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let changes = PinOrder.changes(for: ids, current: current)
        guard !changes.isEmpty else { return }
        run(failed: failed) {
            for (id, order) in changes {
                try await model.client.setFavouriteOrder(roomId: id, order: order)
            }
        }
    }

    /// How the room notifies this device: its own mode, or the defaults Settings describes.
    func notificationMode(_ room: RoomSummary) -> NotificationMode {
        effectiveNotificationMode(room: room, roomsNotifyForAll: model.preferences.roomsNotifyForAll)
    }

    func setMode(_ room: RoomSummary, _ mode: NotificationMode) {
        run { try await model.client.setNotificationMode(roomId: room.id, mode: mode) }
    }

    func toggleMute(_ room: RoomSummary) {
        setMode(room, room.isMuted ? .allMessages : .mute)
    }

    func leave(_ room: RoomSummary) {
        let navigation = model.navigation
        navigation.forget(roomID: room.id)
        // Every stack showing the room goes back to before it, on every tab; the others stay.
        func closing(_ path: [Route]) -> [Route]? {
            path.firstIndex { $0.roomID == room.id }.map { Array(path[..<$0]) }
        }
        if let path = closing(navigation.chatsPath) { navigation.chatsPath = path }
        if let path = closing(navigation.roomsPath) { navigation.roomsPath = path }
        run { try await model.client.leave(roomId: room.id) }
    }

    func markAllRead(_ scope: Scope?) {
        run { try await model.client.markAllRead(scope: scope) }
    }

    func acceptInvite(_ room: RoomSummary) async throws {
        await model.session.wait()
        try await model.client.acceptInvite(roomId: room.id)
    }

    func declineInvite(_ room: RoomSummary) async throws {
        await model.session.wait()
        try await model.client.declineInvite(roomId: room.id)
    }

    private func run(failed: (@MainActor () -> Void)? = nil, _ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                // Acting on the saved list at launch: done once the session is live. Signed out
                // meanwhile, it's dropped rather than run on whoever signs in next.
                await model.session.wait()
                guard model.session.isOpen else { return }
                try await work()
            } catch {
                failed?()
                model.presentError(Copy.error(error))
            }
        }
    }
}

/// The context menu for a conversation.
struct RoomContextMenu: View {
    let room: RoomSummary
    /// Asks before leaving (the list owns the confirmation dialog).
    let confirmLeave: (RoomSummary) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let actions = RoomActions(model: model)
        if room.isInvite {
            Button("Accept Invitation", systemImage: "checkmark") {
                Task {
                    do { try await actions.acceptInvite(room) } catch { model.presentError(Copy.error(error)) }
                }
            }
            Button("Decline Invitation", systemImage: "xmark", role: .destructive) {
                Task {
                    do { try await actions.declineInvite(room) } catch { model.presentError(Copy.error(error)) }
                }
            }
        } else {
            Button(room.isUnread ? "Mark as Read" : "Mark as Unread",
                   systemImage: room.isUnread ? "checkmark.message" : "message.badge") {
                actions.toggleRead(room)
            }
            Button(room.isFavourite ? "Unpin" : "Pin",
                   systemImage: room.isFavourite ? "pin.slash" : "pin") {
                actions.toggleFavourite(room)
            }
            Menu {
                NotificationModePicker(room: room)
            } label: {
                Label("Notifications", systemImage: room.isMuted ? "bell.slash" : "bell")
            }
            Divider()
            Button(room.isDm ? "Delete Chat…" : "Leave…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                confirmLeave(room)
            }
        }
    }
}

extension View {
    /// Asks before leaving a room or deleting a chat, from the list, the menu bar or Details.
    /// `onLeave` runs after the room is left (Details closes itself).
    func leaveConfirmation(_ room: Binding<RoomSummary?>, onLeave: @escaping () -> Void = {}) -> some View {
        modifier(LeaveConfirmation(room: room, onLeave: onLeave))
    }
}

private struct LeaveConfirmation: ViewModifier {
    @Binding var room: RoomSummary?
    let onLeave: () -> Void

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(get: { room != nil }, set: { if !$0 { room = nil } }),
            titleVisibility: .visible,
            presenting: room
        ) { room in
            Button(room.isDm ? "Delete Chat" : "Leave", role: .destructive) {
                RoomActions(model: model).leave(room)
                onLeave()
            }
        } message: { room in
            Text(room.isDm
                 ? "You’ll leave the chat and it disappears from your list. \(room.name) keeps the messages sent so far."
                 : "You won’t get new messages from “\(room.name)”. To come back, you’ll need to be invited again unless it’s public.")
        }
    }

    private var title: Text {
        guard let room else { return Text(verbatim: "") }
        return room.isDm ? Text("Delete Chat with \(room.name)?") : Text("Leave “\(room.name)”?")
    }
}

/// All Messages, Mentions Only or Mute, as a checked list.
struct NotificationModePicker: View {
    let room: RoomSummary

    @Environment(AppModel.self) private var model

    var body: some View {
        let actions = RoomActions(model: model)
        Picker("Notifications", selection: Binding(
            get: { actions.notificationMode(room) },
            set: { actions.setMode(room, $0) }
        )) {
            Label("All Messages", systemImage: "bell").tag(NotificationMode.allMessages)
            Label("Mentions Only", systemImage: "at").tag(NotificationMode.mentionsOnly)
            Label("Mute", systemImage: "bell.slash").tag(NotificationMode.mute)
        }
        .pickerStyle(.inline)
    }
}
