import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// Face ID for Xenia, and a cover that hides conversations in the App Switcher. The cover is its
/// own window above everything (sheets and alerts included), shown as Xenia steps back, so iOS
/// snapshots the cover instead of the messages. Both settings stay on this device.
@Observable
final class AppLock {
    static let shared = AppLock()

    enum Delay: Int, CaseIterable, Identifiable {
        case immediately = 0
        case oneMinute = 60
        case fifteenMinutes = 900
        case oneHour = 3600

        var id: Int { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .immediately: "Immediately"
            case .oneMinute: "After 1 Minute"
            case .fifteenMinutes: "After 15 Minutes"
            case .oneHour: "After 1 Hour"
            }
        }
    }

    /// Ask for Face ID (or the passcode) when coming back to Xenia.
    private(set) var requiresUnlock: Bool {
        didSet {
            defaults.set(requiresUnlock, forKey: Keys.requiresUnlock)
            AppGroup.isAppLockOn = requiresUnlock
            Notifier.registerCategories()
        }
    }
    var hidesInAppSwitcher: Bool {
        didSet { defaults.set(hidesInAppSwitcher, forKey: Keys.hidesInAppSwitcher) }
    }
    var delay: Delay {
        didSet { defaults.set(delay.rawValue, forKey: Keys.delay) }
    }
    private(set) var isLocked = false
    /// Face ID, Touch ID or Optic ID, or none with only a passcode.
    private(set) var biometry: LABiometryType = .none
    /// The device has a passcode (or biometrics), so it can lock Xenia at all.
    private(set) var canLock = false

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var cover: UIWindow?
    @ObservationIgnored private var isCovering = false
    @ObservationIgnored private var promptOnActivate = false
    /// A clock that keeps counting while the iPhone sleeps and can't be set back in Settings to
    /// skip the lock.
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    @ObservationIgnored private var isAuthenticating = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private enum Keys {
        static let requiresUnlock = "xenia.lock.requiresUnlock"
        static let hidesInAppSwitcher = "xenia.lock.hidesInAppSwitcher"
        static let delay = "xenia.lock.delay"
    }

    private init() {
        requiresUnlock = defaults.bool(forKey: Keys.requiresUnlock)
        hidesInAppSwitcher = defaults.bool(forKey: Keys.hidesInAppSwitcher)
        delay = Delay(rawValue: defaults.integer(forKey: Keys.delay)) ?? .immediately
        // For the notification extensions, which can't read this app's own defaults.
        AppGroup.isAppLockOn = requiresUnlock
        refreshCapability()
    }

    /// The name the settings use: "Require Face ID", or "Require Passcode" without biometrics.
    var methodName: String {
        switch biometry {
        case .faceID: String(localized: "Face ID")
        case .touchID: String(localized: "Touch ID")
        case .opticID: String(localized: "Optic ID")
        default: String(localized: "Passcode")
        }
    }

    /// The symbol for the way Xenia unlocks.
    var methodSymbol: String {
        switch biometry {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        default: "lock.fill"
        }
    }

    func refreshCapability() {
        let context = LAContext()
        var error: NSError?
        canLock = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        biometry = context.biometryType
    }

    /// Starts following the scene. Locks at once when Xenia launches locked.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willDeactivate() }
            },
            center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didActivate() }
            },
        ]
        if requiresUnlock, canStillLock() {
            isLocked = true
            promptOnActivate = true
            showCover()
        }
    }

    /// The passcode was turned off after the lock was turned on: nothing could ever unlock Xenia,
    /// so the lock turns itself off, as Apple's apps do.
    private func canStillLock() -> Bool {
        refreshCapability()
        guard !canLock else { return true }
        requiresUnlock = false
        isLocked = false
        return false
    }

    /// Turning the lock on asks first, so nobody locks themselves out by accident.
    func setRequiresUnlock(_ on: Bool) async {
        guard on != requiresUnlock else { return }
        if on {
            guard await authenticate(reason: String(localized: "Turn on the lock for Xenia")) else { return }
        }
        requiresUnlock = on
    }

    func unlock() {
        guard isLocked, !isAuthenticating else { return }
        guard canStillLock() else {
            hideCover()
            return
        }
        Task {
            if await authenticate(reason: String(localized: "Unlock your conversations")) {
                isLocked = false
                hideCover()
            }
        }
    }

    // MARK: Scene

    private func willDeactivate() {
        guard !isAuthenticating, requiresUnlock || hidesInAppSwitcher else { return }
        showCover()
    }

    private func didEnterBackground() {
        guard !isAuthenticating else { return }
        backgroundedAt = ContinuousClock.now
        promptOnActivate = true
        if requiresUnlock, delay == .immediately { isLocked = true }
        if requiresUnlock || hidesInAppSwitcher { showCover() }
    }

    private func didActivate() {
        guard !isAuthenticating else { return }
        if requiresUnlock, let away = backgroundedAt, ContinuousClock.now - away >= .seconds(delay.rawValue) {
            isLocked = true
        }
        backgroundedAt = nil
        // Asks by itself only on coming back to Xenia. After Cancel, the Unlock button asks;
        // otherwise closing the Face ID sheet would bring it straight back.
        let prompts = promptOnActivate
        promptOnActivate = false
        if isLocked {
            showCover()
            if prompts { unlock() }
        } else {
            hideCover()
        }
    }

    private func authenticate(reason: String) async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    // MARK: Cover

    private func showCover() {
        if cover == nil {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState != .unattached })
            else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: LockCover(lock: self))
            host.view.backgroundColor = .systemBackground
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            cover = window
        }
        isCovering = true
        // The keyboard sits above every app window: put it away, and take typing with it.
        cover?.windowScene?.windows.filter { $0 !== cover }.forEach { $0.endEditing(true) }
        cover?.layer.removeAllAnimations()
        cover?.alpha = 1
        cover?.makeKeyAndVisible()
    }

    private func hideCover() {
        guard let cover, isCovering else { return }
        isCovering = false
        UIView.animate(withDuration: 0.22) {
            cover.alpha = 0
        } completion: { [weak self] _ in
            // Covered again while fading: stay.
            guard self?.isCovering == false else { return }
            cover.isHidden = true
            cover.alpha = 1
            cover.windowScene?.windows.first { $0 !== cover && !$0.isHidden }?.makeKey()
        }
    }
}

/// What shows over Xenia while it's locked or in the App Switcher.
private struct LockCover: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            if lock.isLocked {
                VStack(spacing: Theme.Spacing.xs) {
                    Text("Xenia Is Locked")
                        .font(.title2.bold())
                }
                Button {
                    lock.unlock()
                } label: {
                    Label("Unlock with \(lock.methodName)", systemImage: lock.methodSymbol)
                        .padding(.horizontal, Theme.Spacing.s)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, Theme.Spacing.s)
            }
        }
        .padding(Theme.Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .animation(Theme.Motion.contentFade, value: lock.isLocked)
    }
}

/// Settings > Privacy: the lock and the App Switcher cover.
struct AppLockSection: View {
    @State private var lock = AppLock.shared

    var body: some View {
        Section {
            Toggle("Require \(lock.methodName)", isOn: Binding(
                get: { lock.requiresUnlock },
                set: { on in Task { await lock.setRequiresUnlock(on) } }
            ))
            .disabled(!lock.canLock)
            if lock.requiresUnlock {
                Picker("Lock", selection: $lock.delay) {
                    ForEach(AppLock.Delay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
            }
        } footer: {
            if lock.canLock {
                Text("Xenia asks for \(lock.methodName) when you return to it.")
            } else {
                Text("Set a passcode in Settings to use this.")
            }
        }
        // The delay row slides in once Face ID has said yes, as Settings reveals a dependent row.
        .animation(Theme.Motion.row, value: lock.requiresUnlock)
        Section {
            Toggle("Hide in App Switcher", isOn: Binding(
                get: { lock.hidesInAppSwitcher || lock.requiresUnlock },
                set: { lock.hidesInAppSwitcher = $0 }
            ))
            .disabled(lock.requiresUnlock)
        } footer: {
            Text("Hide conversations when switching apps.")
        }
        .onAppear { lock.refreshCapability() }
    }
}
