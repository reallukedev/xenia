import XeniaCore
import SwiftUI

/// Chooses between launch, sign-in and the app, and keeps the core told whether Xenia is in
/// front.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                LaunchView(isSigningInFromCloud: model.isSigningInFromCloud)
                    .transition(.opacity)
            case .signedOut where model.isSigningInFromCloud:
                LaunchView(isSigningInFromCloud: true)
                    .transition(.opacity)
            case .signedOut(let reason):
                SignInView(endedReason: reason)
                    .transition(.opacity)
            case .signedIn:
                #if os(macOS)
                MacRootView()
                    .matrixLinks(model.links)
                    .transition(.opacity)
                #else
                PhoneRootView()
                    .matrixLinks(model.links)
                    .transition(.opacity)
                #endif
            }
        }
        .animation(Theme.Motion.contentFade, value: model.phase)
        .onChange(of: scenePhase) { _, phase in
            model.setScenePhase(phase)
        }
        #if os(iOS)
        .onAppear { AppLock.shared.start() }
        #endif
    }
}
