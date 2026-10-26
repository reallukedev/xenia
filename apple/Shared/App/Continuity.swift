import CoreSpotlight
import Intents
import OSLog
import XeniaCore
import SwiftUI

/// Handoff: the conversation open on one device continues on the other, as in Messages. Only the
/// room's ID travels; the other device opens it from its own list. Spotlight already has the
/// conversation names (ConversationIndex), so the activity isn't indexed a second time.
enum Handoff {
    /// Declared under NSUserActivityTypes in both Info.plists, from the same bundle ID.
    static let conversationType = (Bundle.main.bundleIdentifier ?? "dev.xenia.matrix") + ".conversation"
    private static let roomKey = "roomID"

    static func describe(_ activity: NSUserActivity, room: RoomSummary) {
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif
        activity.targetContentIdentifier = room.id
        activity.requiredUserInfoKeys = [roomKey]
        activity.addUserInfoEntries(from: [roomKey: room.id])
    }

    static func roomID(in activity: NSUserActivity) -> String? {
        activity.userInfo?[roomKey] as? String
    }
}

extension View {
    /// Offers this conversation to the person's other devices while it's on screen.
    func continuesOnOtherDevices(_ room: RoomSummary?) -> some View {
        modifier(ContinuesOnOtherDevices(room: room))
    }
}

private struct ContinuesOnOtherDevices: ViewModifier {
    let room: RoomSummary?

    private var isActive: Bool {
        guard let room, !room.isInvite else { return false }
        #if os(iOS)
        // Behind the lock, the conversation isn't open yet.
        return !AppLock.shared.isLocked
        #else
        return true
        #endif
    }

    func body(content: Content) -> some View {
        content.userActivity(Handoff.conversationType, isActive: isActive) { activity in
            if let room { Handoff.describe(activity, room: room) }
        }
    }
}

extension View {
    /// Opens the conversation another device, Spotlight or Siri points Xenia at.
    func continuesConversations(_ model: AppModel) -> some View {
        onContinueUserActivity(Handoff.conversationType, perform: model.continueConversation)
            // A Spotlight result, when the system opens it as an activity rather than through
            // Open Conversation.
            .onContinueUserActivity(CSSearchableItemActionType, perform: model.continueFromSpotlight)
            // Siri's "Open in Xenia", a message Siri couldn't send, a suggested conversation.
            .onContinueUserActivity(String(describing: INSendMessageIntent.self), perform: model.continueMessage)
    }
}

extension AppModel {
    /// A conversation handed off from another device: opened once the list has it. On iPhone
    /// the lock's cover stays over it until Xenia is unlocked.
    func continueConversation(_ activity: NSUserActivity) {
        guard let roomID = Handoff.roomID(in: activity) else { return }
        openWhenListed { $0[roomID] }
    }

    func continueFromSpotlight(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        openWhenListed { rooms in
            // App Intents may wrap the entity's ID in its own: the longest room ID inside it is the one.
            rooms[identifier] ?? rooms.values.filter { identifier.contains($0.id) }.max { $0.id.count < $1.id.count }
        }
    }

    func continueMessage(_ activity: NSUserActivity) {
        guard let intent = activity.interaction?.intent as? INSendMessageIntent else { return }
        let request = MessageRequest(intent)
        openWhenListed { rooms in
            let targets = rooms.values.filter { !$0.isInvite }.map { MessageTarget($0) }
            return MessageRecipients.destination(of: request, in: targets).flatMap { rooms[$0.id] }
        }
    }

    /// Opens a conversation once the list has it; another account's, or one left since, opens nothing.
    private func openWhenListed(_ find: @escaping ([String: RoomSummary]) -> RoomSummary?) {
        Task {
            await start()
            guard phase == .signedIn else { return }
            if find(roomsByID) == nil { await waitForRooms() }
            guard let room = find(roomsByID), !room.isInvite else { return }
            #if os(macOS)
            showMainWindow()
            #endif
            navigation.open(roomID: room.id, scope: room.scope)
        }
    }
}

extension MessageRequest {
    /// The names and IDs in a Siri request: what was said, and what Xenia donated or resolved.
    nonisolated init(_ intent: INSendMessageIntent) {
        conversationID = intent.conversationIdentifier
        groupName = intent.speakableGroupName?.spokenPhrase
        groupID = intent.speakableGroupName?.vocabularyIdentifier
        people = (intent.recipients ?? []).map(SpokenPerson.init)
    }
}

extension SpokenPerson {
    nonisolated init(_ person: INPerson) {
        let fullName = person.nameComponents.map { PersonNameComponentsFormatter().string(from: $0) }
        names = [person.displayName, fullName, person.nameComponents?.nickname].compactMap(\.self).filter { !$0.isEmpty }
        identifiers = [person.customIdentifier, person.personHandle?.value].compactMap(\.self)
    }
}

/// Tells the system who you write to, so the share sheet and Siri suggest Xenia conversations.
/// Built as the communication notifications build theirs (the room as the conversation, people
/// by their Matrix IDs), so incoming and outgoing line up. Names and IDs only, never the words.
enum MessageDonation {
    private static let log = Logger(subsystem: "dev.xenia.matrix", category: "donations")
    /// Enough people to draw a group; its name says the rest.
    private static let groupRecipients = 8

    static func donate(sendingTo room: RoomSummary, members: [Member]) {
        guard !room.isInvite else { return }
        let recipients: [INPerson] = if room.isDirect {
            [person(id: room.dmUserId ?? room.id, name: room.name)]
        } else {
            members.filter { !$0.isYou && !$0.isInvited }.prefix(groupRecipients).map { person(id: $0.userId, name: $0.name) }
        }
        let intent = INSendMessageIntent(
            recipients: recipients,
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: room.isDirect ? nil : INSpeakableString(spokenPhrase: room.name),
            conversationIdentifier: room.id,
            serviceName: nil,
            sender: nil,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        // So leaving the conversation can take its suggestions away.
        interaction.groupIdentifier = room.id
        Task {
            do {
                try await interaction.donate()
            } catch {
                log.error("Couldn't donate a sent message: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Conversations that are gone stop being suggested.
    static func forget(_ roomIDs: [String]) async {
        for roomID in roomIDs {
            try? await INInteraction.delete(with: roomID)
        }
    }

    /// Signing out: nothing of the account stays suggested.
    static func forgetAll() async {
        try? await INInteraction.deleteAll()
    }

    private static func person(id: String, name: String) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: id, type: .unknown),
            nameComponents: nil,
            displayName: name,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: id
        )
    }
}
