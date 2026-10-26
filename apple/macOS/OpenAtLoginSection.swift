import AppKit
import OSLog
import ServiceManagement
import SwiftUI

/// Xenia words its notifications itself while it runs on the Mac (macOS 27.2 kills its
/// notification extension before it starts, leaving pushes as "New Message"), so it opens at
/// login unless you turn that off, and then waits quietly.
enum OpenAtLogin {
    private static let offeredKey = "xenia.openAtLogin.offered.v2"

    /// The first launch turns it on, once: after that the switch in Settings is yours.
    static func turnOnOnce(defaults: UserDefaults = .standard) {
        // Development and test copies never add themselves to your login items.
        #if DEBUG
        return
        #else
        guard !defaults.bool(forKey: offeredKey) else { return }
        defaults.set(true, forKey: offeredKey)
        // Never registered reads as "not registered" or "not found", depending on the Mac.
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return
        default:
            let log = Logger(subsystem: "dev.xenia.matrix", category: "app")
            do {
                try SMAppService.mainApp.register()
                log.notice("Opens at login now")
            } catch {
                log.error("Couldn't open at login: \(error, privacy: .public)")
            }
        }
        #endif
    }

    /// macOS started Xenia as a login item, rather than someone opening it.
    static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// Settings' switch for opening at login.
struct OpenAtLoginSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = SMAppService.mainApp.status
    @State private var failed = false

    var body: some View {
        Section {
            Toggle("Open at Login", isOn: Binding(get: { isOn }, set: set))
            if status == .requiresApproval {
                Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
            }
        } footer: {
            Text(footer)
        }
        // Approving in System Settings happens outside Xenia: look again on return.
        .task(id: scenePhase) { status = SMAppService.mainApp.status }
    }

    private var isOn: Bool { status == .enabled || status == .requiresApproval }

    private var footer: String {
        if failed {
            return String(localized: "Add Xenia in System Settings > General > Login Items.")
        }
        if status == .requiresApproval {
            return String(localized: "Allow Xenia in System Settings > General > Login Items.")
        }
        return String(localized: "Xenia notifies you only while it’s open, even with no windows.")
    }

    private func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failed = false
        } catch {
            failed = true
        }
        status = SMAppService.mainApp.status
    }
}
