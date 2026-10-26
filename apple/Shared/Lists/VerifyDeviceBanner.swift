import XeniaCore
import SwiftUI

/// At the top of the lists while this device isn't verified and there's encrypted history it
/// can't read yet: one line on why, Verify, and Not Now (until the next launch).
struct VerifyDeviceBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    static func isNeeded(_ model: AppModel) -> Bool {
        guard !model.verifyBannerDismissed else { return false }
        // Until the status is known, the card stays as the saved list left it, so nothing moves.
        guard let encryption = model.encryption, encryption.backup != .checking else { return model.savedNeedsVerification }
        return wouldShow(encryption)
    }

    /// Backup off means a fresh account with nothing locked away; there's nothing to unlock.
    static func wouldShow(_ encryption: EncryptionStatus) -> Bool {
        !encryption.isDeviceVerified && encryption.backup != .off && encryption.backup != .checking
    }

    var body: some View {
        let card = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.m))
        card {
            SettingsIconTile(systemImage: "lock.shield.fill", color: .orange, baseSide: 32)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Verify This \(SettingsCopy.deviceKind)")
                    .font(.subheadline.weight(.semibold))
                Text("Verify to read older messages here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    #if os(macOS)
                    // The sidebar sizes its rows to one line unless a text says how many it takes.
                    .lineLimit(4)
                    #endif
                // Side by side, or one above the other at accessibility sizes.
                let buttons = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.s))
                    : AnyLayout(HStackLayout(spacing: Theme.Spacing.m))
                buttons {
                    #if os(macOS)
                    // Push buttons, as a Mail banner offers them; an accent fill would vanish
                    // into the sidebar's selection.
                    Button("Verify…", action: verify)
                    Button("Not Now", action: dismiss)
                    #else
                    Button("Verify…", action: verify)
                        .buttonStyle(.borderedProminent)
                    Button("Not Now", action: dismiss)
                        .buttonStyle(.borderless)
                    #endif
                }
                .controlSize(.small)
                #if os(macOS)
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                #endif
                .lineLimit(1)
                .padding(.top, Theme.Spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func dismiss() {
        withAnimation(Theme.Motion.row) { model.verifyBannerDismissed = true }
    }

    private func verify() {
        #if os(macOS)
        UserDefaults.standard.set(SettingsPane.security.rawValue, forKey: SettingsPane.storageKey)
        openSettings()
        #else
        model.navigation.sheet = .settings
        #endif
    }
}
