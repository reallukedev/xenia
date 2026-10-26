import XeniaCore
import SwiftUI

/// What shows for the moment it takes to open the saved session: the window's own background,
/// so launch reads as the app appearing, not as a loading screen.
struct LaunchView: View {
    /// Signing in from iCloud Keychain on a new device: that takes a moment, so it says so.
    var isSigningInFromCloud = false

    var body: some View {
        ZStack {
            Color.clear
            if isSigningInFromCloud {
                VStack(spacing: Theme.Spacing.m) {
                    ProgressView()
                    Text("Signing In with iCloud Keychain…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(isSigningInFromCloud ? "Signing In with iCloud Keychain" : "Opening Xenia"))
    }
}
