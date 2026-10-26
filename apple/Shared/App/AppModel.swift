import Foundation
import OSLog
import Observation
import XeniaCore
import SwiftUI

/// The app's state, mirrored from the Rust core. One per process.
///
/// The core reports through `ClientEvents`; this class holds what the views draw and forwards
/// what the person does. It never decides Matrix rules itself (which list a room belongs in,
/// what counts as unread): those come from the core, so every platform agrees.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut(SignOutReason?)
        case signedIn
    }

    private(set) var phase: Phase = .launching
    private(set) var account: Account?
    private(set) var connection: ConnectionState = .connecting
    /// What the lists say about the connection. A connection that's coming up says nothing for
    /// its first two seconds, so a normal launch doesn't flash "Connecting…" and shift the title.
    private(set) var connectionNotice: ConnectionState = .connected
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    private(set) var encryption: EncryptionStatus?
    /// A failed action's message, shown in an alert over the whole window.
    var errorMessage: String?
    /// The verification in progress, shown as a sheet.
    var verification: VerificationModel?
    /// "Not Now" on the list's Verify prompt, until the next launch.
    var verifyBannerDismissed = false

    /// The account's signed-in devices, loaded when Settings asks (nil until then).
    private(set) var devices: [Session]?
    private(set) var devicesFailed = false
    /// How many people are blocked, once Settings has looked.
    var blockedCount: Int?
    /// What Xenia's caches take on this device, once Settings has looked.
    private(set) var storage: StorageUsage?
    /// Whether this device lets Xenia notify, as Settings last checked.
    private(set) var notificationPermission: SettingsCopy.Permission?

    /// Every conversation, newest activity first.
    private(set) var rooms: [RoomSummary] = []
    /// Every conversation by ID, unobserved: views read one through `room(_:)`, so a message in
    /// another conversation doesn't draw them again.
    @ObservationIgnored private(set) var roomsByID: [String: RoomSummary] = [:] {
        didSet {
            for (id, box) in roomBoxes where box.summary != roomsByID[id] {
                box.summary = roomsByID[id]
            }
        }
    }
    @ObservationIgnored private var roomBoxes: [String: RoomBox] = [:]

    /// One conversation, observed on its own.
    func room(_ id: String) -> RoomSummary? {
        if let box = roomBoxes[id] { return box.summary }
        let box = RoomBox(summary: roomsByID[id])
        roomBoxes[id] = box
        return box.summary
    }
    /// The first full page has arrived: an empty list now really means no conversations.
    private(set) var roomsLoaded = false
    /// Whether the latest change to the lists is small enough to animate: a message moving one
    /// conversation to the top. A first sync or a catch-up reorders many rows while their
    /// previews fill in and change height, and animating that slides rows over each other.
    private(set) var animatesListChanges = false

    /// Each list keeps its own filter and find-as-you-type text, as each tab keeps its place.
    var filters: [Scope: ListFilter] = [.chats: .all, .rooms: .all] { didSet { rebuildLists() } }
    var queries: [Scope: String] = [.chats: "", .rooms: ""] { didSet { rebuildLists() } }
    /// What each list shows, derived from `rooms`, `filters` and `queries`.
    private(set) var lists: [Scope: [RoomSummary]] = [.chats: [], .rooms: []]
    private(set) var unreadTotals: [Scope: Int] = [.chats: 0, .rooms: 0]

    let navigation = Navigation()
    let links = LinkRouter()
    @ObservationIgnored private let spotlight = ConversationIndex()
    let push = PushRegistrar()
    /// Settings follow the iCloud account across devices (nil without iCloud).
    let cloudPreferences: CloudPreferences?
    /// Drafts between your devices; nil without iCloud (a Mac debug build, or signed out of it).
    @ObservationIgnored let draftSync: DraftSync?
    @ObservationIgnored let cloudAccounts = CloudAccountStore()
    /// The account is in iCloud Keychain, so other devices sign in by themselves.
    private(set) var isAccountInCloud = false
    /// This account's recovery key is in iCloud Keychain too, for Chat Backup to say so.
    private(set) var isRecoveryKeyInCloud = false
    /// Signing in from iCloud Keychain on launch, for the launch screen's words.
    private(set) var isSigningInFromCloud = false
    let preferences = Preferences()
    let media: MediaLoader
    let linkPreviews: LinkPreviews
    let notifier: Notifier
    /// Open while the session is live; the saved list's photos and conversations wait on it.
    @ObservationIgnored let session = SessionGate()
    /// The list on screen is last launch's, until the live one has caught up with it.
    private(set) var isShowingSavedList = false
    /// From the saved list: its verify card was showing, until the live status says otherwise.
    private(set) var savedNeedsVerification = false
    @ObservationIgnored private var savedListCount = 0
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    /// The saved session the list snapshot belongs to.
    @ObservationIgnored private var savedSession: String?

    @ObservationIgnored let client: XeniaClient
    /// Xenia is in front: the app is active with a conversation window showing. Only then does
    /// a conversation mark what arrives as read.
    private(set) var isActive = true

    init() {
        let config = AppEnvironment.clientConfig()
        let events = ClientEvents()
        let secrets = AppEnvironment.secretStore()
        client = XeniaClient(config: config, secrets: secrets, listener: events)
        // With a saved session, open straight into the app's shell (lists show their loading
        // shape) instead of a blank window while the stores open.
        if let saved = secrets.load(key: AppEnvironment.sessionKey), !AppEnvironment.launchFlag("XeniaResetSession") {
            phase = .signedIn
            savedSession = saved
        }
        media = MediaLoader(client: client, session: session)
        linkPreviews = LinkPreviews(client: client, media: media)
        notifier = Notifier()
        cloudPreferences = CloudPreferences.systemStore.map { [preferences] in CloudPreferences(preferences: preferences, store: $0) }
        draftSync = CloudPreferences.systemStore.map { DraftSync(store: $0) }
        events.model = self
        notifier.model = self
        push.model = self
        links.model = self
        draftSync?.onReceive = { [weak self] entry in self?.receive(draft: entry) }
        preferences.onChange = { [weak self] in self?.applyPreferences() }
        applyPreferences()
        cloudPreferences?.start()
        isAccountInCloud = cloudAccounts.load() != nil
        // The connection starts out coming up: say so if it takes a while.
        apply(connection: .connecting)
        // The list as it last looked, on the first frame, while the stores open.
        if let session = savedSession, let saved = ListSnapshotStore.load(session: session), !saved.rooms.isEmpty {
            account = saved.account
            rooms = saved.rooms
            roomsByID = Dictionary(saved.rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            savedListCount = saved.rooms.count
            savedNeedsVerification = saved.needsVerification
            isShowingSavedList = true
            rebuildLists()
        }
        #if os(macOS)
        trackFrontmost()
        #endif
    }

    #if os(macOS)
    @ObservationIgnored private var frontmostObservers: [NSObjectProtocol] = []

    /// On the Mac, Xenia is in front while it's the active app with a main window showing. A
    /// window's scene phase can't say so: closing the window ends its view without a last update,
    /// which would leave Xenia "in front" and every notification held back.
    private func trackFrontmost() {
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        frontmostObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A closing window still counts as shown until it's gone: look once it has.
                Task { @MainActor in self?.updateFrontmost() }
            }
        }
        Task { @MainActor [weak self] in self?.updateFrontmost() }
    }

    private func updateFrontmost() {
        let hasMainWindow = NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.identifier?.rawValue.hasPrefix(XeniaApp.mainWindowID) == true
        }
        setActive(NSApp.isActive && hasMainWindow)
    }
    /// Opens a main window, set by the first one (SwiftUI's `openWindow` lives in views).
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Brings Xenia forward with a main window, opening one if they're all closed: a notification
    /// clicked after closing the window must still land somewhere.
    func showMainWindow() {
        NSApp.activate()
        let hasMain = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix(XeniaApp.mainWindowID) == true }
        if !hasMain { openMainWindow?() }
    }
    #endif

    // MARK: Lifecycle

    /// Restores the saved session, or lands on sign-in. Once per process: a reopened Mac window
    /// shares the session that's already running.
    func start() async {
        guard !AppEnvironment.isHostingTests else { return }
        // Every caller waits for the same start: a notification action that launched the app
        // must not act before the session is back.
        if let startTask { return await startTask.value }
        let task = Task { await performStart() }
        startTask = task
        await task.value
    }

    @ObservationIgnored private var startTask: Task<Void, Never>?

    private func performStart() async {
        Task { await AttachmentMaker.removeLeftovers() }
        #if DEBUG && os(iOS)
        // `-XeniaPushSelfTest "!room:server $event"`: decodes a push exactly as the notification
        // extension does (its own lock holder on the shared stores), before this app opens them,
        // and shows the result. The simulator can't run the extension itself.
        if let test = UserDefaults.standard.string(forKey: "XeniaPushSelfTest") {
            let parts = test.split(separator: " ").map(String.init)
            if parts.count == 2 { await PushSelfTest.run(roomID: parts[0], eventID: parts[1]) }
        }
        #endif
        if AppEnvironment.launchFlag("XeniaResetSession") {
            await client.signOut()
        }
        if AppEnvironment.launchFlag("XeniaSimulateNewDevice") {
            // Development: this device forgets its session, as a new one would start, and signs
            // in from iCloud Keychain like one.
            await client.signOut()
            AppGroup.defaults.removeObject(forKey: Self.signedOutHereKey)
        }
        // No session here but one in iCloud Keychain: say so from the first frame, instead of
        // flashing the sign-in form while it signs in.
        if phase != .signedIn, canSignInFromCloud { isSigningInFromCloud = true }
        await client.restore()
        // A session that couldn't be opened just now is kept for the next launch; signing in
        // from iCloud would replace it and its keys.
        if case .signedOut(let reason) = phase, reason != .restoreFailed {
            await signInFromCloud()
        }
        isSigningInFromCloud = false
        if case .signedOut = phase, let credentials = AppEnvironment.devSignIn() {
            // Development and UI automation only: `-XeniaDevSignIn user:password`.
            _ = try? await client.signIn(server: client.defaultServer(), username: credentials.user, password: credentials.password)
        }
    }

    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var lastUnified: Bool?
    @ObservationIgnored private var lifecycle: Task<Void, Never>?

    /// The app came to the front, stepped aside (Control Center, the app switcher) or went to
    /// the background.
    /// Room list snapshots so far, so catching up can wait for the next one.
    @ObservationIgnored private var snapshots = 0
    /// The next loaded snapshot takes down notifications for what's been read meanwhile.
    @ObservationIgnored private var sweepsReadNotifications = true
    @ObservationIgnored private var isCatchingUp = false

    #if os(iOS)
    /// Woken in the background because something was read on another device: sync for a moment,
    /// so the notifications of what was read leave and the badge settles, then stop again.
    func catchUp() async {
        guard !isCatchingUp else { return }
        isCatchingUp = true
        sweepsReadNotifications = true
        defer {
            isCatchingUp = false
            sweepsReadNotifications = false
        }
        // iOS allows about 30 seconds in all; a launch for this push opens the session first.
        let started = ContinuousClock.now
        func elapsed() -> Duration { ContinuousClock.now - started }
        while phase == .launching, elapsed() < .seconds(10) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard phase == .signedIn else { return }
        let before = snapshots
        let wasPaused = isPaused
        if wasPaused {
            lifecycle = Task { [previous = lifecycle, client] in
                await previous?.value
                await client.resume()
            }
            await lifecycle?.value
        }
        // The first snapshot can come from the stores; a moment more lets the server's arrive.
        let caughtUp = elapsed()
        while elapsed() < .seconds(22) {
            if snapshots > before, elapsed() - caughtUp > .seconds(3) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Opened meanwhile, or never stopped: sync stays as it was.
        guard wasPaused, isPaused else { return }
        lifecycle = Task { [previous = lifecycle, client] in
            await previous?.value
            await client.pause()
        }
        await lifecycle?.value
    }
    #endif

    func setScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        setActive(phase == .active)
        if phase == .active { sweepsReadNotifications = true }
        // iPhone suspends apps in the background, so sync stops cleanly there and resumes on
        // return. Stepping aside for a moment (inactive) keeps it running. The Mac keeps syncing
        // in the background, as Messages does, so notifications arrive.
        if phase == .background, !isPaused {
            isPaused = true
            lifecycle = Task { [previous = lifecycle, client] in
                await previous?.value
                await client.pause()
            }
        } else if phase == .active, isPaused {
            isPaused = false
            // After any pause still stopping, so sync never ends up stopped while in front.
            lifecycle = Task { [previous = lifecycle, client] in
                await previous?.value
                await client.resume()
            }
        }
        #endif
    }

    /// Xenia is in front: the core then banners only from another conversation.
    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            activeSince = Int64(Date.now.timeIntervalSince1970 * 1000)
            // Notifications may have been allowed in Settings meanwhile, or the token changed.
            if roomsLoaded { push.register() }
        }
        pushNotificationContext()
    }

    func signOut() async {
        // Signed out here on purpose: this device doesn't sign itself back in from iCloud.
        AppGroup.defaults.set(true, forKey: Self.signedOutHereKey)
        await push.unregister()
        await client.signOut()
    }

    // MARK: iCloud Keychain

    private static let signedOutHereKey = "xenia.cloud.signedOutHere"
    /// Turned off in Settings: signing in with a password doesn't turn it back on.
    private static let optedOutKey = "xenia.cloud.optedOut"
    /// The saved password was refused: don't try it again until a sign-in saves a new one.
    private static let refusedKey = "xenia.cloud.passwordRefused"

    /// After signing in with a password: keep the account in iCloud Keychain (end-to-end
    /// encrypted) so your other devices sign in by themselves.
    func rememberAccount(_ account: Account, password: String, turningOn: Bool = false) {
        AppGroup.defaults.removeObject(forKey: Self.signedOutHereKey)
        if turningOn { AppGroup.defaults.removeObject(forKey: Self.optedOutKey) }
        guard !AppEnvironment.launchFlag("XeniaNoCloud"), !AppGroup.defaults.bool(forKey: Self.optedOutKey) else { return }
        AppGroup.defaults.removeObject(forKey: Self.refusedKey)
        var saved = CloudAccount(homeserver: account.homeserver, userID: account.userId, password: password)
        // Keep the recovery key when it's the same account signing in again.
        if let existing = cloudAccounts.load(), existing.userID == account.userId {
            saved.recoveryKey = existing.recoveryKey
        }
        isAccountInCloud = cloudAccounts.save(saved)
        refreshCloudState()
    }

    /// A recovery key was made or used here. One already kept in iCloud Keychain is replaced, so
    /// your other devices never hold a key that stopped working; otherwise it goes there only if
    /// you say so. Returns whether to ask.
    @discardableResult
    func rememberRecoveryKey(_ key: String) -> Bool {
        guard let userID = account?.userId, let saved = cloudAccounts.load(), saved.userID == userID else { return false }
        guard saved.recoveryKey != nil else { return true }
        cloudAccounts.update { $0.recoveryKey = key }
        return false
    }

    /// Yes to keeping the recovery key in iCloud Keychain: your devices that sign in from there
    /// unlock older messages by themselves.
    func keepRecoveryKeyInCloud(_ key: String) {
        guard let userID = account?.userId, cloudAccounts.load()?.userID == userID else { return }
        cloudAccounts.update { $0.recoveryKey = key }
        refreshCloudState()
    }

    /// Takes the recovery key out of iCloud Keychain, on every device. The password stays, so
    /// they still sign in by themselves, then ask for the key.
    func removeRecoveryKeyFromCloud() {
        guard let userID = account?.userId, cloudAccounts.load()?.userID == userID else { return }
        cloudAccounts.update { $0.recoveryKey = nil }
        refreshCloudState()
    }

    /// Turns signing in on other devices off: the account leaves iCloud Keychain everywhere.
    func forgetCloudAccount() {
        AppGroup.defaults.set(true, forKey: Self.optedOutKey)
        if let saved = cloudAccounts.load(), saved.userID == account?.userId { cloudAccounts.delete() }
        isAccountInCloud = false
        isRecoveryKeyInCloud = false
    }

    /// Whether iCloud Keychain holds this account (signed in), or any account to sign in with.
    private func refreshCloudState() {
        let saved = cloudAccounts.load()
        isAccountInCloud = saved != nil && (account == nil || saved?.userID == account?.userId)
        isRecoveryKeyInCloud = account != nil && saved?.userID == account?.userId && saved?.recoveryKey != nil
    }

    /// Signs this device in from iCloud Keychain: a new device (or a new install) that has never
    /// been signed out on purpose. It becomes its own session, then unlocks with the recovery key.
    private var canSignInFromCloud: Bool {
        !AppEnvironment.launchFlag("XeniaNoCloud") && !AppEnvironment.launchFlag("XeniaResetSession")
            && !AppGroup.defaults.bool(forKey: Self.signedOutHereKey) && !AppGroup.defaults.bool(forKey: Self.refusedKey)
            && isAccountInCloud
    }

    private func signInFromCloud() async {
        guard canSignInFromCloud, let saved = cloudAccounts.load() else { return }
        isSigningInFromCloud = true
        defer { isSigningInFromCloud = false }
        Self.log.info("Signing in from iCloud Keychain as \(saved.userID, privacy: .private)")
        let localpart = SignInModel.localpart(of: saved.userID)
        do {
            _ = try await client.signIn(server: saved.homeserver, username: localpart, password: saved.password)
        } catch XeniaError.InvalidCredentials {
            // The password changed elsewhere: stop trying it; the sign-in screen asks, and signing
            // in there saves the new one.
            AppGroup.defaults.set(true, forKey: Self.refusedKey)
            return
        } catch {
            // Offline or the server's down: try again next launch.
            return
        }
        if let key = saved.recoveryKey {
            do {
                try await client.recover(recoveryKey: key)
            } catch {
                Self.log.error("Unlocking with the saved recovery key failed: \(String(describing: error), privacy: .private)")
            }
        } else {
            Self.log.info("Signed in from iCloud Keychain; no recovery key saved")
        }
    }

    private static let log = Logger(subsystem: "dev.xenia.matrix", category: "cloud")

    // MARK: Drafts

    /// Keeps a draft here and, with Sync Drafts on, on your other devices.
    func saveDraft(roomID: String, threadRoot: String?, text: String) async {
        await client.saveDraft(roomId: roomID, threadRoot: threadRoot, text: text)
        if draftSync?.isRunning == true {
            draftSync?.publish(room: roomID, thread: threadRoot, text: text)
        }
    }

    /// Sync runs while signed in with the setting on. Turning it off takes this account's drafts
    /// out of iCloud; each device keeps its own.
    private func followDraftSync() {
        guard let draftSync else { return }
        if preferences.syncDrafts, phase == .signedIn, let userID = account?.userId {
            draftSync.start(account: userID)
        } else if draftSync.isRunning {
            if !preferences.syncDrafts { draftSync.removeAll() }
            draftSync.stop()
        }
    }

    /// A draft from another device: kept here, and shown in its conversation if that's open with
    /// nothing typed.
    private func receive(draft entry: DraftSync.Entry) {
        Task {
            await client.saveDraft(roomId: entry.room, threadRoot: entry.thread, text: entry.text)
            NotificationCenter.default.post(name: .xeniaDraftArrived, object: nil, userInfo: [
                "room": entry.room, "thread": entry.thread as Any, "text": entry.text,
            ])
        }
    }

    // MARK: Events from the core

    func apply(session: SessionState) {
        switch session {
        case .restoring:
            if phase != .signedIn { phase = .launching }
        case .signedOut(let reason):
            // Removed from another device (a lost phone, say): it stays signed out, even with
            // the account in iCloud Keychain.
            if reason == .sessionRevoked {
                AppGroup.defaults.set(true, forKey: Self.signedOutHereKey)
            }
            push.reset()
            phase = .signedOut(reason)
            self.session.close()
            snapshotTask?.cancel()
            ListSnapshotStore.remove()
            spotlight.removeAll()
            isShowingSavedList = false
            account = nil
            draftSync?.stop()
            isRecoveryKeyInCloud = false
            rooms = []
            roomsByID = [:]
            roomsLoaded = false
            encryption = nil
            devices = nil
            verification = nil
            blockedCount = nil
            storage = nil
            // The next account starts with its own lists, not this one's searches and choices.
            filters = [.chats: .all, .rooms: .all]
            queries = [.chats: "", .rooms: ""]
            verifyBannerDismissed = false
            savedNeedsVerification = false
            savedListCount = 0
            DeviceEditor.shared.rename = nil
            DeviceEditor.shared.signOut = nil
            DeviceEditor.shared.signOutOthers = nil
            rebuildLists()
            navigation.reset()
            media.clear()
            linkPreviews.clear()
            notifier.clearAll()
        case .signedIn(let account):
            // The core learns the photo a moment later; keep the saved one meanwhile.
            if account.avatarUrl == nil, let saved = self.account, saved.userId == account.userId {
                self.account = Account(userId: account.userId, displayName: account.displayName ?? saved.displayName,
                                       avatarUrl: saved.avatarUrl, deviceId: account.deviceId, homeserver: account.homeserver)
            } else {
                self.account = account
            }
            phase = .signedIn
            self.session.open()
            refreshCloudState()
            pushNotificationContext()
            followDraftSync()
        }
    }

    func apply(account: Account) {
        self.account = account
    }

    func apply(connection: ConnectionState) {
        self.connection = connection
        noticeTask?.cancel()
        if connection == .connecting, connectionNotice == .connected {
            noticeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.connection == .connecting else { return }
                self.connectionNotice = .connecting
            }
        } else {
            connectionNotice = connection
        }
    }

    func apply(encryption: EncryptionStatus) {
        let wasVerified = self.encryption?.isDeviceVerified
        self.encryption = encryption
        if wasVerified == false, encryption.isDeviceVerified, devices != nil {
            refreshDevices()
        }
    }

    // MARK: Verification and devices

    /// Someone asked this device to verify. One at a time: a request during another waits for
    /// that one to finish (the other side can ask again).
    func apply(verificationRequest peer: VerificationPeer) {
        if let current = verification, !current.isFinished { return }
        let incoming = VerificationModel(kind: .incoming(peer))
        incoming.requesterName = rooms.first { $0.dmUserId == peer.userId }?.name
        verification = incoming
        Task { await incoming.start(model: self) }
    }

    /// Starts a verification and shows it.
    func verify(_ kind: VerificationModel.Kind, fromSettings: Bool = false) {
        if let current = verification, !current.isFinished { current.cancel() }
        let started = VerificationModel(kind: kind, fromSettings: fromSettings)
        verification = started
        Task { await started.start(model: self) }
    }

    /// Reloads the device list. Calls while one is loading ask for one more pass afterwards,
    /// so the list always ends on the newest answer and never on a stale one.
    func refreshDevices() {
        guard !isRefreshingDevices else {
            devicesNeedRefresh = true
            return
        }
        isRefreshingDevices = true
        Task {
            defer { isRefreshingDevices = false }
            repeat {
                devicesNeedRefresh = false
                do {
                    devices = try await client.sessions()
                    devicesFailed = false
                } catch {
                    devicesFailed = devices == nil
                }
            } while devicesNeedRefresh
        }
    }

    @ObservationIgnored private var isRefreshingDevices = false
    @ObservationIgnored private var devicesNeedRefresh = false

    func refreshNotificationPermission() async {
        notificationPermission = SettingsCopy.permission(await notifier.authorizationStatus())
    }

    func refreshStorage() async {
        storage = await client.storageUsage()
    }

    func removeDevice(_ deviceID: String) {
        devices?.removeAll { $0.deviceId == deviceID }
    }


    /// At most one conversation added, removed or moved, and no preview filling in for the
    /// first time.
    nonisolated static func isSmallChange(from old: [RoomSummary], to new: [RoomSummary]) -> Bool {
        let before = Dictionary(old.map { ($0.id, $0.preview) }, uniquingKeysWith: { first, _ in first })
        let fillsIn = new.contains { room in
            guard case .empty? = before[room.id] else { return false }
            if case .empty = room.preview { return false }
            return true
        }
        guard !fillsIn else { return false }
        let changes = new.map(\.id).difference(from: old.map(\.id)).inferringMoves()
        // A move is a removal and an insertion.
        return changes.count <= 2
    }

    func apply(rooms: [RoomSummary], loaded: Bool) {
        // The saved list stays until the live one is complete, so it never shrinks to the
        // first few rooms and grows back.
        if isShowingSavedList {
            guard loaded || rooms.count >= savedListCount else { return }
            isShowingSavedList = false
        }
        let firstLoad = loaded && !roomsLoaded
        // Read here or on another device: its notifications leave Notification Center.
        let nowRead = rooms.filter { !$0.isUnread && roomsByID[$0.id]?.isUnread == true }.map(\.id)
        if !nowRead.isEmpty { notifier.clear(roomIDs: Set(nowRead)) }
        if loaded { notifier.removePlaceholdersSoon() }
        animatesListChanges = roomsLoaded && loaded && Self.isSmallChange(from: self.rooms, to: rooms)
        self.rooms = rooms
        roomsByID = Dictionary(rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        roomsLoaded = loaded
        rebuildLists()
        notifier.updateBadge(chats: unreadTotals[.chats] ?? 0, rooms: unreadTotals[.rooms] ?? 0)
        snapshots += 1
        // Back from the background, or woken to catch up: notifications that arrived meanwhile
        // for conversations read on another device leave too, which `nowRead` can't see.
        if loaded, sweepsReadNotifications {
            sweepsReadNotifications = isCatchingUp
            notifier.clearRead(in: rooms)
        }
        if loaded {
            saveSnapshotSoon()
            spotlight.update(rooms)
        }
        if firstLoad {
            Task {
                await notifier.requestAuthorizationIfNeeded()
                push.register()
            }
            #if DEBUG
            // Development and screenshots: `-XeniaOpenRoom "Coffee Chat"` opens it once loaded.
            if let name = UserDefaults.standard.string(forKey: "XeniaOpenRoom"),
               let room = rooms.first(where: { $0.name == name || $0.id == name }) {
                navigation.open(roomID: room.id, scope: room.isDm ? .chats : .rooms)
            }
            #endif
        }
    }

    /// Saves the list a moment after it settles, not on every change.
    private func saveSnapshotSoon() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, phase == .signedIn, roomsLoaded,
                  let session = AppEnvironment.secretStore().load(key: AppEnvironment.sessionKey)
            else { return }
            let needsVerification = encryption.map(VerifyDeviceBanner.wouldShow) ?? savedNeedsVerification
            ListSnapshotStore.save(ListSnapshot(account: account, rooms: rooms, needsVerification: needsVerification), session: session)
        }
    }

    func apply(incoming message: IncomingMessage) {
        // Back in front on iPhone, the catch-up sync finds messages that arrived while Xenia was
        // away; their pushes already showed, so only newer ones get a banner from here.
        if push.isRegistered, message.timestampMs < activeSince {
            return
        }
        #if os(macOS)
        // Xenia keeps running in the background on the Mac, where a push may show it first.
        let pushMayShow = push.isRegistered && !isActive
        #else
        let pushMayShow = false
        #endif
        notifier.post(message, preferences: preferences, unlessPushed: pushMayShow)
    }

    /// When Xenia last came to the front, in ms since 1970. It starts in front, so messages the
    /// first sync finds from before launch (their pushes already showed) don't banner again.
    @ObservationIgnored private var activeSince = Int64(Date.now.timeIntervalSince1970 * 1000)

    func presentError(_ message: String) {
        errorMessage = message
    }

    // MARK: Lists

    /// Chats and rooms in one list: it lives under `.chats`, with Chats' filter and search.
    var isUnified: Bool { preferences.unifiedList }
    /// The one list split under Chats and Rooms headings.
    var isSectioned: Bool { preferences.unifiedList && preferences.sectionedList }

    private func rebuildLists() {
        var totals: [Scope: Int] = [:]
        for scope in [Scope.chats, .rooms] {
            // The list in one tab isn't worked out twice when the tabs are one list.
            if !(isUnified && scope == .chats) {
                setList(scope, client.filterRooms(
                    rooms: rooms, scope: scope, filter: filters[scope] ?? .all, query: queries[scope] ?? ""
                ))
            }
            totals[scope] = rooms.reduce(0) { $0 + ($1.scope == scope && $1.isUnread ? 1 : 0) }
        }
        if isUnified {
            setList(.chats, client.filterAllRooms(rooms: rooms, filter: filters[.chats] ?? .all, query: queries[.chats] ?? ""))
            totals[.chats] = rooms.reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
            totals[.rooms] = 0
        }
        // The tab badges read these: setting the same counts would draw the tabs again on every sync.
        if totals != unreadTotals { unreadTotals = totals }
    }

    /// A list that hasn't changed (a message in a room it filters out) isn't drawn again.
    private func setList(_ scope: Scope, _ list: [RoomSummary]) {
        if lists[scope] != list { lists[scope] = list }
    }

    // MARK: Settings that reach the core

    private func applyPreferences() {
        client.setSendReadReceipts(enabled: preferences.sendReadReceipts)
        client.setShowMembershipChanges(show: preferences.showMembershipChanges)
        if lastUnified != preferences.unifiedList {
            lastUnified = preferences.unifiedList
            navigation.isUnified = preferences.unifiedList
            rebuildLists()
        }
        pushNotificationContext()
        followDraftSync()
    }

    func pushNotificationContext() {
        client.setNotificationContext(context: NotificationContext(
            isActive: isActive,
            openRoomId: navigation.openRoomID,
            roomsNotifyForAll: preferences.roomsNotifyForAll
        ))
    }
}

/// One conversation's summary, so a view can follow it without following every conversation.
@Observable
final class RoomBox {
    var summary: RoomSummary?

    init(summary: RoomSummary?) {
        self.summary = summary
    }
}

extension Notification.Name {
    /// A draft came from another device: `room`, `thread` (optional) and `text`.
    static let xeniaDraftArrived = Notification.Name("xenia.draftArrived")
}
