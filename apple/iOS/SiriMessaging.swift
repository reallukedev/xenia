import Intents
import XeniaCore
import UIKit

extension XeniaAppDelegate {
    /// "Send a message to Maya on Xenia", handled in the app rather than an extension: the
    /// session, its keys and the conversation list are already here, and only one process may
    /// hold the stores at a time.
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INSendMessageIntent ? MessageIntentHandler() : nil
    }
}

/// Siri's messaging: finds the conversation by the name that was said, asks which one when
/// several fit, and sends as Send Message does.
nonisolated final class MessageIntentHandler: NSObject, INSendMessageIntentHandling {
    /// Enough to choose from by voice.
    private static let choices = 8

    func resolveRecipients(for intent: INSendMessageIntent) async -> [INSendMessageRecipientResolutionResult] {
        // Behind Xenia's lock, Siri learns no names: confirming hands over to the app.
        if await SiriMessaging.isLocked { return [.notRequired()] }
        let request = MessageRequest(intent)
        let people = intent.recipients ?? []
        guard let targets = await SiriMessaging.targets() else {
            return [.unsupported(forReason: .noAccount)]
        }
        // A suggested conversation, or a group by name: the people in it are already settled.
        let suggested = targets.contains { $0.id == request.conversationID }
        let group = request.groupName.map { MessageRecipients.groups(named: $0, id: request.groupID, in: targets) } ?? []
        if suggested || group.count == 1 {
            return people.isEmpty ? [.notRequired()] : people.map { .success(with: $0) }
        }
        guard !people.isEmpty else {
            return request.groupName == nil ? [.needsValue()] : [.notRequired()]
        }
        // A Matrix conversation has no ad hoc groups to start by naming several people.
        guard request.people.count == 1 else { return people.map { _ in .unsupported() } }
        let matches = MessageRecipients.matches(for: request.people[0], in: targets)
        switch matches.count {
        case 0: return [.unsupported(forReason: .noValidHandle)]
        case 1: return [.success(with: Self.person(matches[0]))]
        default: return [.disambiguation(with: matches.prefix(Self.choices).map(Self.person))]
        }
    }

    func resolveSpeakableGroupName(for intent: INSendMessageIntent) async -> INSpeakableStringResolutionResult {
        let request = MessageRequest(intent)
        let isLocked = await SiriMessaging.isLocked
        guard let name = request.groupName, !isLocked else { return .notRequired() }
        guard let targets = await SiriMessaging.targets() else { return .unsupported() }
        if let id = request.conversationID, let room = targets.first(where: { $0.id == id }) {
            return .success(with: Self.group(room))
        }
        let matches = MessageRecipients.groups(named: name, id: request.groupID, in: targets)
        switch matches.count {
        // Someone was named as well: the message goes to them.
        case 0: return request.people.isEmpty ? .unsupported() : .notRequired()
        case 1: return .success(with: Self.group(matches[0]))
        default: return .disambiguation(with: matches.prefix(Self.choices).map(Self.group))
        }
    }

    func resolveContent(for intent: INSendMessageIntent) async -> INStringResolutionResult {
        let text = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? .needsValue() : .success(with: text)
    }

    func resolveOutgoingMessageType(for intent: INSendMessageIntent) async -> INOutgoingMessageTypeResolutionResult {
        intent.outgoingMessageType == .outgoingMessageAudio ? .unsupported() : .success(with: .outgoingMessageText)
    }

    func confirm(intent: INSendMessageIntent) async -> INSendMessageIntentResponse {
        let ready = if await SiriMessaging.isLocked { false } else { await SiriMessaging.targets() != nil }
        return INSendMessageIntentResponse(code: ready ? .ready : .failureRequiringAppLaunch, userActivity: nil)
    }

    func handle(intent: INSendMessageIntent) async -> INSendMessageIntentResponse {
        if await SiriMessaging.isLocked {
            return INSendMessageIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil)
        }
        let text = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let code: INSendMessageIntentResponseCode = switch await SiriMessaging.send(text, for: MessageRequest(intent)) {
        case .sent: .success
        case .notSent: .failure
        // Signed out, or the conversation isn't clear: Xenia opens to it (`continueMessage`).
        case .needsApp: .failureRequiringAppLaunch
        }
        return INSendMessageIntentResponse(code: code, userActivity: nil)
    }

    /// Who Siri shows and says, carrying the ID that finds the conversation again: the person's
    /// for a DM (as donations name them), the room's otherwise.
    private static func person(_ target: MessageTarget) -> INPerson {
        let id = target.userID ?? target.id
        return INPerson(
            personHandle: INPersonHandle(value: id, type: .unknown),
            nameComponents: nil,
            displayName: target.name,
            image: target.face.map { INImage(imageData: $0) },
            contactIdentifier: nil,
            customIdentifier: id
        )
    }

    private static func group(_ target: MessageTarget) -> INSpeakableString {
        INSpeakableString(vocabularyIdentifier: target.id, spokenPhrase: target.name, pronunciationHint: nil)
    }
}

/// The app's side of Siri messaging, on the main actor with the model.
enum SiriMessaging {
    enum Outcome: Sendable {
        case sent, notSent, needsApp
    }

    /// Xenia's own lock is on: Siri continues in the app, behind Face ID.
    static var isLocked: Bool { AppLock.shared.requiresUnlock }

    /// Every conversation a message can go to, or nil when signed out. Launched by Siri, the
    /// saved list answers at once; without one, it waits for the live list.
    static func targets() async -> [MessageTarget]? {
        guard let model = XeniaAppDelegate.model else { return nil }
        if model.rooms.isEmpty {
            try? await model.readyForIntent()
            await model.waitForRooms()
        }
        guard model.phase == .signedIn else { return nil }
        return model.rooms.filter { !$0.isInvite }.map { MessageTarget($0, face: ConversationIndex.faces[$0.id]) }
    }

    static func send(_ text: String, for request: MessageRequest) async -> Outcome {
        guard !text.isEmpty, let model = XeniaAppDelegate.model else { return .notSent }
        guard let targets = await targets(), let target = MessageRecipients.destination(of: request, in: targets) else {
            return .needsApp
        }
        do {
            try await model.readyForIntent()
            try await model.client.sendMessage(roomId: target.id, message: composeMessage(text: text, mentions: []))
            return .sent
        } catch is IntentError {
            return .needsApp
        } catch {
            return .notSent
        }
    }
}
