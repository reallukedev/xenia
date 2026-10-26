import AppIntents
import XeniaCore
import SwiftUI

@main
struct XeniaApp: App {
    static let mainWindowID = "main"

    @State private var model: AppModel
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var appDelegate: XeniaAppDelegate
    #else
    @NSApplicationDelegateAdaptor private var appDelegate: XeniaAppDelegate
    #endif

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Shortcuts, Siri and Spotlight act through the same model as the windows.
        AppDependencyManager.shared.add(dependency: model)
        XeniaAppDelegate.model = model
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup(id: Self.mainWindowID) {
            MainWindow(model: model)
                // A matrix: link opens in the window that's there, not a new one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["matrix"])
        .defaultSize(width: 1080, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            // View > Show Sidebar (⌃⌘S), as in every Mac app with one.
            SidebarCommands()
            // Includes Edit's Find, Spelling and Grammar, Substitutions, Transformations and Speech.
            XeniaCommands(model: model)
        }

        Settings {
            MacSettingsView()
                .environment(model)
        }
        #else
        WindowGroup {
            MainWindow(model: model)
        }
        #endif
    }
}

private struct MainWindow: View {
    let model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        RootView()
            .environment(model)
            .task { await model.start() }
            .continuesConversations(model)
            #if os(macOS)
            .onAppear {
                model.openMainWindow = { [openWindow] in openWindow(id: XeniaApp.mainWindowID) }
            }
            #endif
    }
}
