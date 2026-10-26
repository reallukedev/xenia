import XeniaCore
import SwiftUI

enum SettingsPane: String {
    case general, account, notifications, privacy, security
    static let storageKey = "xenia.settings.pane"
}

/// Xenia Settings on the Mac: a pane per area, each opening on where it stands.
struct MacSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsPane.storageKey) private var pane = SettingsPane.general

    var body: some View {
        if model.phase == .signedIn {
            TabView(selection: $pane) {
                Tab("General", systemImage: "gearshape", value: .general) {
                    GeneralPane()
                }
                Tab("Account", systemImage: "person.crop.circle", value: .account) {
                    AccountPane()
                }
                Tab("Notifications", systemImage: "bell.badge", value: .notifications) {
                    Form { NotificationSettingsSections() }.settingsPane()
                }
                Tab("Privacy", systemImage: "hand.raised", value: .privacy) {
                    PrivacyPane()
                }
                Tab("Security", systemImage: "lock.shield", value: .security) {
                    SecurityPane()
                }
            }
            .verificationSheet(isHost: model.verification?.fromSettings == true)
            .task {
                await model.refreshNotificationPermission()
                if model.devices == nil { model.refreshDevices() }
            }
        } else {
            ContentUnavailableView("Sign In to Change Settings", systemImage: "person.crop.circle.badge.questionmark")
                .frame(width: 520, height: 300)
        }
    }
}

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            SettingsHero(
                Text("General"),
                subtitle: Text(SettingsCopy.conversationsHero(
                    layout: model.preferences.listLayout, membership: model.preferences.showMembershipChanges
                )).foregroundStyle(.secondary),
                systemImage: "gearshape.fill", tint: .gray
            )
            ConversationSettingsSections()
            StorageSection()
        }
        .settingsPane()
    }
}

private struct AccountPane: View {
    var body: some View {
        Form {
            Section { AccountHero() }
            Section { DisplayNameRow() }
            CloudSection()
            AboutSection()
            SignOutSection()
        }
        .settingsPane()
    }
}

private struct PrivacyPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            SettingsHero(
                Text("Privacy"),
                subtitle: Text(SettingsCopy.privacyHero(
                    receipts: model.preferences.sendReadReceipts, typing: model.preferences.sendTypingNotifications,
                    blocked: model.blockedCount
                )).foregroundStyle(.secondary),
                systemImage: "hand.raised.fill", tint: .blue
            )
            PrivacySettingsSections()
        }
        .settingsPane()
    }
}

/// Chat backup and devices: what keeps encrypted messages readable, and where you're signed in.
private struct SecurityPane: View {
    @Environment(AppModel.self) private var model
    @State private var showingBackup = false
    @State private var resetting = false
    @State private var backupKeyUnsaved = false

    var body: some View {
        let backup = model.encryption?.backup
        Form {
            DevicesSections(openChatBackup: { showingBackup = true }, resetEncryption: { resetting = true })
            Section {
                SettingsDetailRow(
                    title: Text("Chat Backup"),
                    detail: (backup == .off || backup == .needsKey ? SettingsCopy.Tone.warning : .secondary)
                        .apply(to: Text(SettingsCopy.backupHero(backup))),
                    systemImage: "lock.icloud.fill",
                    tint: .teal
                ) {
                    Button(backup == .off ? "Turn On…" : backup == .needsKey ? "Unlock…" : "Manage…") {
                        showingBackup = true
                    }
                }
            }
        }
        .settingsPane()
        .deviceAlerts()
        .sheet(isPresented: $resetting) { ResetEncryptionView() }
        .sheet(isPresented: $showingBackup) {
            // A Mac sheet: the form's hero names it, so no title band; Done sits at the bottom.
            VStack(spacing: 0) {
                ChatBackupView()
                    .onPreferenceChange(UnsavedRecoveryKey.self) { backupKeyUnsaved = $0 }
                Divider()
                HStack {
                    Spacer()
                    // A new recovery key can't be closed away before it's saved.
                    // Escape, not Return: Return belongs to the recovery key field.
                    Button("Done") { showingBackup = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(backupKeyUnsaved)
                }
                .padding(Theme.Spacing.l)
            }
            .frame(width: 480)
            .frame(minHeight: 520)
        }
    }
}
