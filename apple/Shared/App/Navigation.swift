import Foundation
import Observation
import XeniaCore

/// A place in the app a conversation list can lead to.
enum Route: Hashable {
    case conversation(roomID: String)
    /// A conversation opened at one message (from search).
    case message(roomID: String, eventID: String)
    case info(roomID: String)
    /// Words in one conversation.
    case search(roomID: String)
}

/// A thread, by its conversation and the message that started it.
struct ThreadRef: Hashable, Identifiable {
    let roomID: String
    let root: String

    var id: String { roomID + root }
}

/// A menu bar command for the conversation or sidebar on screen (Mac).
enum MenuRequest: Equatable {
    case findInSidebar
    /// ⌘F with the conversation's search already open: back to its field.
    case findInConversation
    case tapback
    case jumpToLatest
    case leave
}

/// Files dropped on a conversation's row in the sidebar (Mac), for it to send once it's open.
struct DroppedFiles: Equatable {
    let roomID: String
    let urls: [URL]
}

/// Where the person is: the selected tab or sidebar list, the open conversation, and the sheets.
@Observable
final class Navigation {
    enum Tab: Hashable {
        case chats, rooms
    }

    enum Sheet: Identifiable, Hashable {
        case newMessage
        case newGroup
        case browseRooms
        case settings
        case addPeople(roomID: String)

        var id: Self { self }
    }

    // iPhone: a stack per tab.
    var tab: Tab = .chats
    var chatsPath: [Route] = []
    var roomsPath: [Route] = []

    // Mac: the sidebar's list and the conversation beside it. Each list remembers its own
    // selection, so switching between Chats and Rooms returns to where you were.
    var scope: Scope = .chats {
        didSet { if scope != oldValue { selectedRoomID = selections[scope] } }
    }
    var selectedRoomID: String? {
        didSet { selections[scope] = selectedRoomID }
    }
    private var selections: [Scope: String] = [:]
    /// The thread open over its conversation, as Messages opens inline replies.
    var thread: ThreadRef?
    /// Where on screen the thread was opened from (its "Replies" button), for it to grow out of.
    @ObservationIgnored var threadOrigin: CGPoint?
    /// The conversation whose list of threads is showing.
    var threadsRoomID: String?
    /// The conversation whose mentions of me are listed (Mac, in a popover from the toolbar).
    var mentionsRoomID: String?
    /// The conversation being searched (Mac, beside it, so results scroll it in place).
    var searchRoomID: String?
    /// The open thread hides its conversation (iPhone, and a narrow Mac window). Beside it, the
    /// conversation stays in view and keeps marking what arrives as read.
    var threadCoversConversation = true
    /// A message to scroll to and highlight in the selected conversation (Mac).
    var focusedEventID: String?
    /// The conversation whose Details are showing (Mac, in a popover from the toolbar).
    var detailsRoomID: String?
    /// Carried out once by the view that owns it, then cleared. It goes through here rather
    /// than the focused scene so the menu bar works wherever the keyboard focus is: the message
    /// field, the timeline or the sidebar.
    var menuRequest: MenuRequest?
    var droppedFiles: DroppedFiles?
    /// Search Everything opens with these words (⌘K, or Siri and Spotlight's "Search in Xenia").
    /// Taken and cleared by the view that shows it: the palette on the Mac, the list's search on iPhone.
    var everythingQuery: String?

    var sheet: Sheet?

    /// Chats and rooms share one list (a setting): everything opens there.
    var isUnified = false {
        didSet {
            guard isUnified, !oldValue else { return }
            // The open conversation stays open in the one list.
            let open = selectedRoomID
            scope = .chats
            if let open { selectedRoomID = open }
            if tab == .rooms { tab = .chats }
        }
    }

    /// The conversation on screen, for notifications (don't banner what's already showing).
    var openRoomID: String? {
        #if os(macOS)
        return selectedRoomID
        #else
        let path: [Route] = switch tab {
        case .chats: chatsPath
        case .rooms: roomsPath
        }
        return path.last.flatMap(\.roomID)
        #endif
    }

    /// Opens a conversation from anywhere: a notification, search, a new chat.
    func open(roomID: String, scope: Scope, eventID: String? = nil) {
        let scope = isUnified ? .chats : scope
        // From a notification or a link: whatever sheet or thread was up would cover the
        // conversation.
        sheet = nil
        thread = nil
        threadsRoomID = nil
        mentionsRoomID = nil
        detailsRoomID = nil
        // Another conversation's search would sit beside the wrong one.
        if searchRoomID != roomID { searchRoomID = nil }
        #if os(macOS)
        self.scope = scope
        selectedRoomID = roomID
        focusedEventID = eventID
        #else
        let route: Route = eventID.map { .message(roomID: roomID, eventID: $0) } ?? .conversation(roomID: roomID)
        switch scope {
        case .chats:
            tab = .chats
            chatsPath = [route]
        case .rooms:
            tab = .rooms
            roomsPath = [route]
        }
        #endif
    }

    /// The files dropped on this conversation's row, handed over once.
    func takeDroppedFiles(for roomID: String) -> [URL] {
        guard let dropped = droppedFiles, dropped.roomID == roomID else { return [] }
        droppedFiles = nil
        return dropped.urls
    }

    /// A room that's gone (left, deleted) leaves every list's remembered selection.
    func forget(roomID: String) {
        selections = selections.filter { $0.value != roomID }
        if selectedRoomID == roomID { selectedRoomID = nil }
    }

    func reset() {
        tab = .chats
        chatsPath = []
        roomsPath = []
        selections = [:]
        scope = .chats
        selectedRoomID = nil
        thread = nil
        threadsRoomID = nil
        mentionsRoomID = nil
        searchRoomID = nil
        detailsRoomID = nil
        menuRequest = nil
        droppedFiles = nil
        sheet = nil
    }
}

extension Route {
    var roomID: String? {
        switch self {
        case .conversation(let id), .message(let id, _), .info(let id), .search(let id): id
        }
    }
}
