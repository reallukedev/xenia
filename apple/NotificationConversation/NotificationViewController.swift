import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// The expanded notification on iPhone: the conversation so far, and a message field that's
/// ready to type in, as in Messages. Replying sends no read receipt and leaves the
/// conversation unread.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let model = ConversationPreviewModel()
    private let replyBar = ReplyBar()
    private static let replyAction = "xenia.reply"
    private static let markReadAction = "xenia.markRead"
    /// Xenia's lock is on: the notification shows what the banner did, with no history and no
    /// reply field, until Xenia itself is unlocked.
    private let isLocked = AppGroup.isAppLockOn

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ConversationPreview(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        preferredContentSize = CGSize(width: view.bounds.width, height: 400)
        replyBar.onSend = { [weak self] text in self?.send(text) }
    }

    override var canBecomeFirstResponder: Bool { !isLocked }
    override var inputAccessoryView: UIView? { isLocked ? nil : replyBar }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isLocked else { return }
        // Straight to typing: the field and the keyboard come up with the conversation.
        becomeFirstResponder()
        replyBar.focus()
    }

    func didReceive(_ notification: UNNotification) {
        model.show(notification, loadsHistory: !isLocked)
        // The field below replaces the Reply button; Mark as Read stays.
        extensionContext?.notificationActions = isLocked ? [] : [
            UNNotificationAction(
                identifier: Self.markReadAction, title: String(localized: "Mark as Read"), options: [.authenticationRequired]
            ),
        ]
    }

    private func send(_ text: String) {
        Task {
            if await !model.send(text) {
                replyBar.restore(text)
            }
        }
    }

    func didReceive(
        _ response: UNNotificationResponse,
        completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void
    ) {
        let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response.actionIdentifier == Self.replyAction, let text, !text.isEmpty, !isLocked else {
            // Opening the conversation and Mark as Read are the app's.
            completion(.dismissAndForwardAction)
            return
        }
        // Stay open to show the reply in the conversation. If it can't go from here, the app
        // gets it and tries.
        Task {
            completion(await model.send(text) ? .doNotDismiss : .dismissAndForwardAction)
        }
    }
}
