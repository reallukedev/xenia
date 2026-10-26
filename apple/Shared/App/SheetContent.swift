import XeniaCore
import SwiftUI

/// The sheets any tab can open.
struct SheetContent: View {
    let sheet: Navigation.Sheet
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            // With a sheet up, a verification shows over it (a window shows one sheet at a time).
            .verificationSheet(isHost: model.verification?.fromSettings != true || isPhone)
    }

    private var isPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .newMessage:
            NewConversationView(mode: .message)
        case .newGroup:
            NewConversationView(mode: .group)
        case .browseRooms:
            BrowseRoomsView()
        case .settings:
            SettingsView()
        case .addPeople(let roomID):
            NewConversationView(mode: .invite(roomID: roomID))
        }
    }
}
