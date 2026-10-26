import XeniaCore
import SwiftUI

/// Accept and Decline, right in the invitation's row.
struct InviteButtons: View {
    let roomID: String
    /// In a list row rather than the bar under an invitation.
    var inRow = true

    @Environment(AppModel.self) private var model
    @State private var working = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            accept
            Button("Decline", role: .destructive) { answer { try await $0.declineInvite($1) } }
                .buttonStyle(.bordered)
            if working {
                ProgressView().controlSize(.small)
            }
        }
        .controlSize(.small)
        #if os(iOS)
        .buttonBorderShape(.capsule)
        #else
        // Mac push buttons, as Mail answers a calendar invitation.
        .buttonBorderShape(.roundedRectangle)
        #endif
        .disabled(working)
        .errorAlert("Couldn’t Answer the Invitation", message: $error)
    }

    /// On the Mac an accent fill would vanish into the sidebar's selected row, so a row's
    /// buttons are both plain push buttons.
    @ViewBuilder
    private var accept: some View {
        let button = Button("Accept") { answer { try await $0.acceptInvite($1) } }
        #if os(macOS)
        if inRow {
            button.buttonStyle(.bordered)
        } else {
            button.buttonStyle(.borderedProminent)
        }
        #else
        button.buttonStyle(.borderedProminent)
        #endif
    }

    /// Tapped on last launch's list, it's answered once the session is back.
    private func answer(_ work: @escaping (RoomActions, RoomSummary) async throws -> Void) {
        guard let room = model.room(roomID) else { return }
        let actions = RoomActions(model: model)
        Task {
            working = true
            defer { working = false }
            do {
                try await work(actions, room)
            } catch {
                self.error = Copy.error(error)
            }
        }
    }
}

/// Accept and Decline for VoiceOver, on a row that reads as one element and so hides its buttons.
struct InviteAccessibilityActions: View {
    let room: RoomSummary

    @Environment(AppModel.self) private var model

    var body: some View {
        let actions = RoomActions(model: model)
        Button("Accept Invitation") { answer { try await actions.acceptInvite(room) } }
        Button("Decline Invitation") { answer { try await actions.declineInvite(room) } }
    }

    private func answer(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { model.presentError(Copy.error(error)) }
        }
    }
}
