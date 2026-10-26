import XeniaCore
import SwiftUI

/// All, Unread or Pinned, plus Mark All as Read.
struct FilterMenu: View {
    let scope: Scope
    @Environment(AppModel.self) private var model

    var body: some View {
        let filter = model.filters[scope] ?? .all
        Menu {
            Picker("Show", selection: Binding(get: { filter }, set: { model.filters[scope] = $0 })) {
                Label("All", systemImage: "tray").tag(ListFilter.all)
                Label("Unread", systemImage: "message.badge").tag(ListFilter.unread)
                Label("Pinned", systemImage: "pin").tag(ListFilter.favourites)
            }
            .pickerStyle(.inline)
            Section {
                Button("Mark All as Read", systemImage: "checkmark.message") {
                    RoomActions(model: model).markAllRead(model.isUnified ? nil : scope)
                }
                .disabled((model.unreadTotals[scope] ?? 0) == 0)
            }
        } label: {
            Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .contentTransition(.symbolEffect(.replace))
        }
    }
}
