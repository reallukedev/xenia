import Foundation
import Observation
import XeniaCore
import UIKit
import UserNotifications

/// The conversation behind a notification: its latest messages, loaded from the server by the
/// extension's own session, and replies sent from the notification.
@Observable
final class ConversationPreviewModel {
    struct Line: Identifiable, Equatable {
        enum Status { case delivered, sending, failed }

        let id: String
        var senderID: String
        var senderName: String
        var isYou: Bool
        var text: String
        var picture: String?
        var status = Status.delivered
    }

    private(set) var title = ""
    private(set) var isDirect = true
    private(set) var lines: [Line] = []
    private(set) var pictures: [String: UIImage] = [:]
    /// Previews are off: the expanded notification says no more than the banner did.
    private(set) var isPrivate = false

    @ObservationIgnored private var roomID: String?
    @ObservationIgnored private static var decoder: PushDecoder?

    /// Shows the notified message at once, then (unless Xenia is locked) the conversation around it.
    func show(_ notification: UNNotification, loadsHistory: Bool) {
        let content = notification.request.content
        let info = content.userInfo
        roomID = info["roomID"] as? String
        isDirect = info["isDirect"] as? Bool ?? true
        title = content.title
        isPrivate = !NotificationContent.Preferences.current.showPreviews
        // The banner's title is "Xenia" when private, so it can't stand in for a name either.
        let senderName = isPrivate ? "" : info["senderName"] as? String ?? (content.subtitle.isEmpty ? content.title : content.subtitle)
        lines = [Line(
            id: info["eventID"] as? String ?? notification.request.identifier,
            senderID: isPrivate ? "" : info["senderID"] as? String ?? "",
            senderName: senderName,
            isYou: false,
            text: content.body
        )]
        guard !isPrivate, loadsHistory else { return }
        Task { await load() }
    }

    private func load() async {
        guard let roomID, let decoder = await Self.openDecoder() else { return }
        guard let fetched = try? await decoder.recentMessages(roomId: roomID, limit: 12), !fetched.isEmpty else { return }
        let sending = lines.filter { $0.status != .delivered }
        lines = fetched.map { line in
            Line(
                id: line.eventId,
                senderID: line.senderId,
                senderName: line.senderName,
                isYou: line.isYou,
                text: Copy.preview(of: line.body, sender: nil),
                picture: line.picture
            )
        } + sending
        for source in fetched.compactMap(\.picture) where pictures[source] == nil {
            let side: UInt32 = 600
            guard let data = try? await decoder.loadThumbnail(source: source, widthPx: side, heightPx: side),
                  let image = await Self.decode(data, maxPixels: CGFloat(side)) else { continue }
            pictures[source] = image
        }
    }

    /// Sends a reply typed into the notification. Returns whether it went: if not, the app
    /// gets the reply and tries again.
    func send(_ text: String) async -> Bool {
        guard let roomID, let decoder = await Self.openDecoder() else { return false }
        let id = UUID().uuidString
        lines.append(Line(id: id, senderID: "", senderName: "", isYou: true, text: text, status: .sending))
        do {
            try await decoder.sendReply(roomId: roomID, text: text)
            setStatus(.delivered, for: id)
            return true
        } catch {
            setStatus(.failed, for: id)
            return false
        }
    }

    private func setStatus(_ status: Line.Status, for id: String) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].status = status
    }

    /// The saved session the decoder was opened with: signed out or signed in as someone else
    /// since, the process (which outlives one notification) opens the new one.
    @ObservationIgnored private static var openedWith: String?
    /// The open in progress: loading and a quick reply share it rather than each opening the
    /// stores.
    @ObservationIgnored private static var opening: (session: String, task: Task<PushDecoder?, Never>)?

    private static func openDecoder() async -> PushDecoder? {
        let secrets = AppEnvironment.secretStore()
        guard let session = secrets.load(key: AppEnvironment.sessionKey) else {
            decoder = nil
            openedWith = nil
            return nil
        }
        if let decoder, openedWith == session { return decoder }
        if let opening, opening.session == session { return await opening.task.value }
        decoder = nil
        openedWith = nil
        let task = Task {
            (try? await openPushDecoder(
                config: AppEnvironment.clientConfig(forExtension: true),
                secrets: secrets,
                extension: .content
            )) ?? nil
        }
        opening = (session, task)
        let opened = await task.value
        // Another session may have started opening meanwhile; it owns the result then.
        guard opening?.session == session else { return opened }
        opening = nil
        decoder = opened
        openedWith = opened == nil ? nil : session
        return opened
    }

    /// Decodes a picture at the size it's shown, off the main thread.
    @concurrent
    private static func decode(_ data: Data, maxPixels: CGFloat) async -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return await image.byPreparingThumbnail(ofSize: image.size.fitting(maxPixels))
    }
}

private extension CGSize {
    func fitting(_ side: CGFloat) -> CGSize {
        let scale = min(1, side / max(width, height, 1))
        return CGSize(width: width * scale, height: height * scale)
    }
}
