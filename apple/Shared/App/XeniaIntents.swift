import AppIntents
import CoreSpotlight
import ImageIO
import Intents
import XeniaCore
import SwiftUI
import UniformTypeIdentifiers

/// A conversation, for Shortcuts, Siri and Spotlight.
struct ConversationEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static let defaultQuery = ConversationQuery()

    let id: String
    let name: String
    let isDirect: Bool
    /// For a DM, the other person's Matrix ID.
    let userID: String?
    let alias: String?
    let lastActivity: Date?
    /// The photo, shaped as Xenia draws it, when it's already on this device.
    let face: Data?

    @MainActor
    init(_ room: RoomSummary, face: Data? = nil) {
        id = room.id
        name = room.name
        isDirect = room.isDirect
        userID = room.dmUserId
        alias = room.alias
        lastActivity = room.timestampMs > 0 ? Date(timeIntervalSince1970: TimeInterval(room.timestampMs) / 1000) : nil
        self.face = face ?? ConversationIndex.faces[room.id]
    }

    /// Who or where: the Matrix ID tells two people with the same name apart.
    private var subtitle: String {
        if let userID { return userID }
        if let alias { return alias }
        return isDirect ? String(localized: "Chat") : String(localized: "Room")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: face.map { .init(data: $0) } ?? .init(systemName: isDirect ? "person.crop.circle" : "number")
        )
    }

    /// Names, addresses and when it was last active; never what's said in it.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = name
        attributes.contentDescription = subtitle
        attributes.keywords = keywords
        attributes.thumbnailData = face
        // Spotlight ranks what was active lately above what wasn't.
        attributes.lastUsedDate = lastActivity
        attributes.contentModificationDate = lastActivity
        return attributes
    }

    /// The handle on its own as well, so "@maya" or "design" finds the conversation too.
    private var keywords: [String] {
        [userID, alias].compactMap(\.self).flatMap { address in
            [address, String(address.dropFirst().prefix { $0 != ":" })]
        }
    }
}

struct ConversationQuery: EntityStringQuery {
    @Dependency private var model: AppModel

    @MainActor
    func entities(for identifiers: [ConversationEntity.ID]) async throws -> [ConversationEntity] {
        identifiers.compactMap { model.roomsByID[$0] }.map { ConversationEntity($0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ConversationEntity] {
        // Xenia's lock keeps who you talk to out of Shortcuts too.
        guard !model.isLockedForIntents else { return [] }
        return model.rooms.filter { room in
            !room.isInvite && [room.name, room.dmUserId, room.alias].contains { $0?.localizedStandardContains(string) == true }
        }.map { ConversationEntity($0) }
    }

    /// Favorites first, then the most recent.
    @MainActor
    func suggestedEntities() async throws -> [ConversationEntity] {
        guard !model.isLockedForIntents else { return [] }
        let rooms = model.rooms.filter { !$0.isInvite }
        let favorites = PinOrder.sorted(rooms.filter(\.isFavourite))
        let recent = rooms.filter { !$0.isFavourite }.prefix(12)
        return (favorites + recent).map { ConversationEntity($0) }
    }
}

struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens a chat or room in Xenia.")

    @Parameter(title: "Conversation")
    var target: ConversationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        // Opened from Spotlight or Siri with Xenia closed: the list may still be on its way.
        if model.roomsByID[target.id] == nil {
            try await model.readyForIntent()
            await model.waitForRooms()
        }
        guard let room = model.roomsByID[target.id], !room.isInvite else {
            throw IntentError(message: String(localized: "You’re no longer in that conversation."))
        }
        model.navigation.open(roomID: room.id, scope: room.scope)
        #if os(macOS)
        // Xenia keeps running with its windows closed.
        model.showMainWindow()
        #endif
        return .result()
    }
}

struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription("Sends a message to a chat or room without opening Xenia.")

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$conversation)")
    }

    @Dependency private var model: AppModel

    // Sends as you: only from an unlocked device.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw $message.needsValueError("What do you want to say?")
        }
        try model.checkNotLockedForIntent()
        try await model.readyForIntent()
        do {
            try await model.client.sendMessage(roomId: conversation.id, message: composeMessage(text: text, mentions: []))
        } catch {
            throw IntentError(message: Copy.error(error))
        }
        return .result(dialog: "Sent to \(conversation.name).")
    }
}

struct MarkAllReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark All as Read"
    static let description = IntentDescription("Marks every chat and room in Xenia as read.")

    @Dependency private var model: AppModel

    // Sends read receipts as you: only from an unlocked device.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try model.checkNotLockedForIntent()
        try await model.readyForIntent()
        do {
            try await model.client.markAllRead(scope: nil)
        } catch {
            throw IntentError(message: Copy.error(error))
        }
        model.notifier.clearAll()
        return .result(dialog: "Everything is marked as read.")
    }
}

/// Siri and Spotlight's "Search in Xenia": opens Search Everything with the words.
struct SearchInXeniaIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search in Xenia"
    static let description = IntentDescription("Searches your people, chats, rooms and messages in Xenia.")
    static let searchScopes: [StringSearchScope] = [.general]
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Search For", requestValueDialog: "What do you want to search for?")
    var criteria: StringSearchCriteria

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.navigation.everythingQuery = criteria.term.trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(macOS)
        model.showMainWindow()
        #endif
        return .result()
    }
}

/// "Anything new in Xenia?": which conversations want you, and where you were mentioned. The
/// core decides what's unread, so muted conversations count only when they mention you.
struct UnreadConversationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Unread Conversations"
    static let description = IntentDescription("Tells you which chats and rooms have messages you haven’t read, and where you were mentioned.")

    @Dependency private var model: AppModel

    // Reads conversation names aloud: only from an unlocked device.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ConversationEntity]> & ProvidesDialog {
        try model.checkNotLockedForIntent()
        try await model.readyForIntent()
        await model.waitForRooms()
        let unread = model.rooms.filter { $0.isUnread && !$0.isInvite }
        let mentioned = unread.filter { $0.unreadKind == .mention }
        let summary = IntentCopy.unread(conversations: unread.map(\.name), mentionedIn: mentioned.map(\.name))
        return .result(value: unread.map { ConversationEntity($0) }, dialog: "\(summary)")
    }
}

extension AppModel {
    /// Waits a little for the first full conversation list, so an action that launched Xenia
    /// finds a conversation that's only missing because it hasn't loaded yet.
    func waitForRooms() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !roomsLoaded, phase == .signedIn, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// With Xenia's own lock on, what's in it stays behind Face ID: actions that would read or
    /// send messages without opening Xenia say so instead.
    /// Xenia's own lock is on (iPhone): actions that read or act on conversations stop short.
    var isLockedForIntents: Bool {
        #if os(iOS)
        AppLock.shared.requiresUnlock
        #else
        false
        #endif
    }

    func checkNotLockedForIntent() throws {
        if isLockedForIntents {
            throw IntentError(message: String(localized: "Xenia is locked. Open Xenia to continue."))
        }
    }

    /// Back in session for an action run from Shortcuts or Siri, which may have launched Xenia;
    /// signed out, the action says so instead of waiting for a session that won't come.
    func readyForIntent() async throws {
        await start()
        guard phase == .signedIn else {
            throw IntentError(message: String(localized: "Sign in to Xenia first."))
        }
        // A saved session that fails to come back mustn't leave Shortcuts waiting forever.
        let opened = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.session.wait(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard opened, phase == .signedIn else {
            throw IntentError(message: String(localized: "Xenia couldn’t connect. Open Xenia and try again."))
        }
    }
}

/// A failure Shortcuts and Siri show in plain words.
struct IntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

struct XeniaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: ["Send a message with \(.applicationName)", "Send a \(.applicationName) message"],
            shortTitle: "Send Message",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: ["Open \(\.$target) in \(.applicationName)", "Open a conversation in \(.applicationName)"],
            shortTitle: "Open Conversation",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: UnreadConversationsIntent(),
            phrases: [
                "Check \(.applicationName)",
                "Any new messages in \(.applicationName)",
                "Show unread messages in \(.applicationName)",
            ],
            shortTitle: "Unread",
            systemImageName: "message.badge"
        )
        AppShortcut(
            intent: SearchInXeniaIntent(),
            phrases: ["Search \(.applicationName)", "Search in \(.applicationName)", "Find a message in \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: MarkAllReadIntent(),
            phrases: ["Mark everything as read in \(.applicationName)", "Mark all as read in \(.applicationName)"],
            shortTitle: "Mark All as Read",
            systemImageName: "checkmark.message"
        )
    }
}

/// Keeps Spotlight's copy of the conversation list current: names, addresses, faces and when
/// each was last active, never messages, so typing a name in Spotlight opens the chat.
@MainActor
final class ConversationIndex {
    /// The faces Spotlight has, so Shortcuts and Siri show the same ones.
    private(set) static var faces: [String: Data] = [:]
    /// Faces go to the conversations people look for most: favorites and the most recent.
    private static let faceLimit = 60

    /// What Spotlight holds for a conversation: it's indexed again only when this changes.
    private struct Entry: Equatable {
        let name: String
        let isDirect: Bool
        let userID: String?
        let alias: String?
        let avatarURL: String?
        /// To the hour: ranking needs no finer, and a busy chat isn't indexed on every message.
        let activeHour: Int64

        init(_ room: RoomSummary) {
            name = room.name
            isDirect = room.isDirect
            userID = room.dmUserId
            alias = room.alias
            avatarURL = room.avatarUrl
            activeHour = room.timestampMs / 3_600_000
        }
    }

    private var task: Task<Void, Never>?
    private var indexed: [String: Entry] = [:]
    /// Indexed without the photo they have, which wasn't on this device yet.
    private var faceless: Set<String> = []
    /// Bumped on sign-out, so an update already running doesn't index the old account after it.
    private var generation = 0

    func update(_ rooms: [RoomSummary]) {
        let live = rooms.filter { !$0.isInvite }
        let current = Dictionary(live.map { ($0.id, Entry($0)) }, uniquingKeysWith: { first, _ in first })
        guard current != indexed else { return }
        task?.cancel()
        let started = generation
        task = Task {
            // The list settles in bursts at launch: index once it's quiet.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, started == generation else { return }
            let wantsFace = Self.wantsFace(live)
            // A conversation indexed without its face gets it on the next pass that finds it.
            let changed = live.filter { room in
                current[room.id] != indexed[room.id] || (faceless.contains(room.id) && wantsFace.contains(room.id))
            }
            let gone = indexed.keys.filter { current[$0] == nil }
            let found = await Self.faces(for: changed.filter { wantsFace.contains($0.id) })
            guard !Task.isCancelled, started == generation else { return }
            for room in changed {
                if let face = found[room.id] {
                    Self.faces[room.id] = face
                } else if indexed[room.id]?.avatarURL != room.avatarUrl {
                    Self.faces[room.id] = nil
                }
                if room.avatarUrl != nil, Self.faces[room.id] == nil {
                    faceless.insert(room.id)
                } else {
                    faceless.remove(room.id)
                }
            }
            let renamed = !gone.isEmpty || changed.contains { indexed[$0.id]?.name != $0.name }
            let index = CSSearchableIndex.default()
            try? await index.indexAppEntities(changed.map { ConversationEntity($0) })
            guard started == generation else {
                try? await index.deleteAppEntities(ofType: ConversationEntity.self)
                return
            }
            if !gone.isEmpty {
                try? await index.deleteAppEntities(identifiedBy: gone, ofType: ConversationEntity.self)
                await MessageDonation.forget(gone)
                for id in gone {
                    Self.faces[id] = nil
                    faceless.remove(id)
                }
            }
            indexed = current
            if renamed {
                // Siri learns the names "Open … in Xenia" can take.
                XeniaShortcuts.updateAppShortcutParameters()
                #if os(iOS)
                // And the group names "Send a message to … on Xenia" can, most recent first.
                let groups = live.filter { !$0.isDm }.map(\.name)
                INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: groups), of: .contactGroupName)
                #endif
            }
        }
    }

    func removeAll() {
        task?.cancel()
        generation += 1
        indexed = [:]
        faceless = []
        Self.faces = [:]
        #if os(iOS)
        INVocabulary.shared().removeAllVocabularyStrings()
        #endif
        Task {
            try? await CSSearchableIndex.default().deleteAppEntities(ofType: ConversationEntity.self)
            await MessageDonation.forgetAll()
        }
    }

    private static func wantsFace(_ rooms: [RoomSummary]) -> Set<String> {
        Set(rooms.filter(\.isFavourite).map(\.id) + rooms.prefix(faceLimit).map(\.id))
    }

    /// Faces already on this device, as the list draws them. Nothing is downloaded here: a
    /// face that isn't on the device yet goes in once the list has shown it.
    private static func faces(for rooms: [RoomSummary]) async -> [String: Data] {
        let wanted = rooms.compactMap { room in
            room.avatarUrl.map { (room, MediaLoader.avatarKey($0, points: Theme.Metrics.rowAvatar)) }
        }
        guard !wanted.isEmpty, let media = XeniaAppDelegate.model?.media else { return [:] }
        // Read from disk off the main thread, so `cached` below finds them in memory.
        await media.warmAvatars(wanted.map(\.1))
        var faces: [String: Data] = [:]
        for (room, key) in wanted {
            guard let image = media.cached(key).flatMap(cgImage) else { continue }
            faces[room.id] = await shape(image, isRoom: room.isRoom)
        }
        return faces
    }

    private static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if os(macOS)
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        image.cgImage
        #endif
    }

    /// A PNG cut to the avatar's shape (round for people, rounded square for rooms), sized for
    /// Spotlight's results.
    @concurrent
    private static func shape(_ image: CGImage, isRoom: Bool) async -> Data? {
        let side = 120
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.addPath(AvatarShape(isRoom: isRoom).path(in: bounds).cgPath)
        context.clip()
        context.interpolationQuality = .high
        // Filled, as the list draws it.
        let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(origin: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), size: size))
        guard let shaped = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, shaped, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
