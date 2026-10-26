import Foundation
import OSLog
import XeniaCore
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Tells the server where to send this device's pushes, so notifications arrive while Xenia is
/// suspended or closed. The notification extension turns each push into a notification.
///
/// Only when a push gateway is configured (`XeniaPushGateway` in the Info.plist) and
/// notifications are allowed. On the Mac, only team-signed builds can receive pushes; local
/// debug builds notify while Xenia runs.
@Observable
final class PushRegistrar {
    @ObservationIgnored weak var model: AppModel?
    /// The token and device the pusher was last registered for: a new session on the same phone
    /// has the same token but needs its own pusher.
    @ObservationIgnored private var registered: (key: String, device: String)?

    enum Problem: Equatable {
        /// Apple didn't give this iPhone a push token (offline, or the build can't receive pushes).
        case noToken
        /// The homeserver didn't accept the pusher.
        case serverRefused
    }

    /// Why pushes won't reach this iPhone while Xenia is closed, for Settings. Nil when they will,
    /// or before the first try.
    private(set) var problem: Problem?

    private static let log = Logger(subsystem: "dev.xenia.matrix", category: "push")

    /// The gateway identifies the app by this, and sends to the APNs environment it names. That
    /// follows how the app was signed, not its configuration: App Store and TestFlight builds get
    /// production tokens; anything installed from Xcode is signed for development and gets
    /// sandbox ones, Release builds included. Named after the bundle ID ("dev.xenia.matrix.ios"),
    /// so a build under another ID never registers as Xenia's.
    static let appID: String = {
        let base = Bundle.main.bundleIdentifier ?? "dev.xenia.matrix"
        #if os(iOS)
        let production = "\(base).ios", sandbox = "\(base).ios.dev"
        #if targetEnvironment(simulator)
        return sandbox
        #else
        // Store builds carry no provisioning profile.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? String(contentsOf: url, encoding: .isoLatin1) else { return production }
        let isDevelopment = profile.range(
            of: "<key>aps-environment</key>\\s*<string>development</string>", options: .regularExpression
        ) != nil
        return isDevelopment ? sandbox : production
        #endif
        #else
        let environment = AppGroup.entitlement("com.apple.developer.aps-environment") as? String
        return environment == "development" ? "\(base).mac.dev" : "\(base).mac"
        #endif
    }()

    /// This build can receive pushes at all (Mac builds signed to run locally can't).
    private static var canReceivePushes: Bool {
        #if os(iOS)
        true
        #else
        AppGroup.hasEntitlement("com.apple.developer.aps-environment") && AppGroup.isAvailable
        #endif
    }

    /// Asks the system for a push token, once notifications are allowed. The token arrives in
    /// `didReceive(token:)`. Cheap to repeat: the app does on every return to the front, so a
    /// token that changed or a pusher the server dropped is set up again.
    func register() {
        guard Self.canReceivePushes, AppEnvironment.pushGateway != nil,
              !AppEnvironment.launchFlag("XeniaQuietNotifications") else { return }
        Task {
            guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized else { return }
            #if targetEnvironment(simulator) && DEBUG
            // The simulator has no real APNs token; the development gateway (scripts/dev)
            // delivers to it by its device ID instead.
            if let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] {
                await registerPusher(key: "simulator:\(udid)")
                return
            }
            #endif
            #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            #else
            NSApplication.shared.registerForRemoteNotifications()
            #endif
        }
    }

    func didReceive(token: Data) {
        let key = token.map { String(format: "%02x", $0) }.joined()
        // `-XeniaLogPushToken YES`, in any build: the token, for sending test pushes to this
        // device by hand. On its own it can't send anything; that takes Xenia's APNs key.
        if UserDefaults.standard.bool(forKey: "XeniaLogPushToken") {
            Self.log.notice("Push token: \(key, privacy: .public)")
        }
        Task { await registerPusher(key: key) }
    }

    func didFail(_ error: Error) {
        Self.log.error("Push registration failed: \(String(describing: error), privacy: .private)")
        problem = .noToken
    }

    /// Before signing out: stop this device's pushes, in case the server keeps the pusher when
    /// the session ends (it shouldn't, but a failed logout would leave it).
    func unregister() async {
        guard let registered, let model else { return }
        self.registered = nil
        try? await model.client.unregisterPusher(pushKey: registered.key, appId: Self.appID)
    }

    var isRegistered: Bool { registered != nil }

    /// The session ended: the next one registers afresh.
    func reset() {
        registered = nil
        problem = nil
    }

    private func registerPusher(key: String) async {
        guard let model, let gateway = AppEnvironment.pushGateway, let device = model.account?.deviceId,
              registered?.key != key || registered?.device != device else { return }
        do {
            try await model.client.registerPusher(registration: PushRegistration(
                pushKey: key,
                appId: Self.appID,
                gatewayUrl: gateway,
                appName: "Xenia",
                deviceName: AppEnvironment.deviceName,
                lang: Locale.current.language.languageCode?.identifier ?? "en"
            ))
            registered = (key, device)
            problem = nil
            Self.log.info("Pushes go to this device through \(gateway, privacy: .public)")
        } catch {
            Self.log.error("Registering the pusher failed: \(String(describing: error), privacy: .private)")
            problem = .serverRefused
        }
    }
}

#if os(iOS)
/// Receives the push token from UIKit.
final class XeniaAppDelegate: NSObject, UIApplicationDelegate {
    /// Set as the app starts: a push or a token can arrive before any window exists.
    static weak var model: AppModel?
    private var push: PushRegistrar? { Self.model?.push }

    /// The gateway's silent push after something was read on another device.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard userInfo["xenia_read"] != nil, let model = Self.model else { return .noData }
        await model.catchUp()
        return .newData
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        push?.didReceive(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        push?.didFail(error)
    }
}
#else
/// Receives the push token from AppKit.
final class XeniaAppDelegate: NSObject, NSApplicationDelegate {
    /// Set as the app starts: the token can arrive before any window exists.
    static weak var model: AppModel?
    private var push: PushRegistrar? { Self.model?.push }
    /// Checked as launching finishes, while the launch's Apple event is still the current one.
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = OpenAtLogin.launchedAtLogin
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OpenAtLogin.turnOnOnce()
        // Opened at login: run in the background, as after closing the window, until you open it.
        if launchedAtLogin {
            DispatchQueue.main.async { NSApp.windows.filter(\.isVisible).forEach { $0.close() } }
        }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        push?.didReceive(token: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        push?.didFail(error)
    }
}
#endif

#if DEBUG && os(iOS)
/// Development only: the notification extension's work, run in the app.
enum PushSelfTest {
    private static let log = Logger(subsystem: "dev.xenia.matrix", category: "push")

    static func run(roomID: String, eventID: String) async {
        do {
            guard let decoder = try await openPushDecoder(
                config: AppEnvironment.clientConfig(forExtension: true), secrets: AppEnvironment.secretStore(), extension: .service
            ) else {
                log.info("PUSHTEST no session")
                return
            }
            guard let pushed = try await decoder.describe(
                roomId: roomID, eventId: eventID, roomsNotifyForAll: NotificationContent.Preferences.current.roomsNotifyForAll
            ) else {
                log.info("PUSHTEST filtered out")
                return
            }
            let worded = NotificationContent.make(pushed.message, preferences: .current)
            if pushed.isQuiet { worded.interruptionLevel = .passive }
            let content = await NotificationExtras.finish(worded, message: pushed.message, preferences: .current, media: NotificationMedia(
                avatar: { mxc, size in try? await decoder.loadAvatar(mxcUrl: mxc, sizePx: size) },
                picture: { source in try? await decoder.loadThumbnail(source: source, widthPx: 1200, heightPx: 1200) }
            ))
            log.info("PUSHTEST \(content.title, privacy: .public) | \(content.subtitle, privacy: .public) | \(content.body, privacy: .public)\(pushed.isQuiet ? " | quiet" : "", privacy: .public) | attachments \(content.attachments.count) | person \(pushed.message.senderFullName ?? "-", privacy: .public) photo \(pushed.message.senderAvatarUrl != nil)")
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: eventID, content: content, trigger: nil))
            // What the expanded notification shows.
            if let viewer = try await openPushDecoder(
                config: AppEnvironment.clientConfig(forExtension: true), secrets: AppEnvironment.secretStore(), extension: .content
            ) {
                let lines = try await viewer.recentMessages(roomId: roomID, limit: 8)
                log.info("PUSHTEST conversation: \(lines.count) messages, last \(lines.last.map { "\($0.senderName): \(Copy.preview(of: $0.body, sender: nil))" } ?? "-", privacy: .public)")
            }
        } catch {
            log.error("PUSHTEST failed: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
