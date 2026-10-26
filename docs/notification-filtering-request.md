# Requesting the notification filtering entitlement

Xenia's notification extension decrypts each push on the device. Some pushes shouldn't alert
(a public room you only follow for mentions, a message deleted before it arrived), and only an
extension with Apple's filtering entitlement may drop them. Without it they land quietly in
Notification Center instead.

Apple grants it on request, to the team that publishes the app:
https://developer.apple.com/contact/request/notification-service. This page keeps what Xenia's
request says, so a fork shipping under its own bundle ID can file the same one.

## What to fill in

- **App name:** Xenia
- **Bundle ID of the extension:** dev.xenia.matrix.notifications (or your fork's)
- **Explanation** (paste):

> Xenia is an end-to-end encrypted Matrix chat client. To keep message content private, the push
> payload sent through Apple Push Notification service contains only a room ID and an event ID.
> Our Notification Service Extension fetches the event from the user's Matrix server and decrypts
> it on the device with the user's keys.
>
> Only after decryption can the extension apply the user's notification settings: for example,
> a large public room the user follows only for mentions, a message that was deleted before it
> arrived, or a message from someone the user has blocked. In these cases there is nothing to
> show, and today the user sees an empty or placeholder notification. The filtering entitlement
> lets us suppress those notifications so users only see notifications for messages they asked
> to be notified about.
>
> We never use the extension to track users, collect data, or deliver anything other than the
> user's own messages.

## Once it's granted

1. Add `com.apple.developer.usernotifications.filtering` (Boolean, YES) to
   `apple/NotificationService/XeniaNotifications.entitlements` and
   `XeniaNotifications-macOS.entitlements`.
2. Set `XENIA_CAN_SILENCE_PUSHES: YES` in `apple/project.yml`, then run `xcodegen`.
