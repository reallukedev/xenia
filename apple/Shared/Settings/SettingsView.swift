import XeniaCore
import SwiftUI

/// iPhone Settings: the account first, then a page for each area, each row saying where it
/// stands before you open it.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { AccountHero() }
                Section {
                    DisplayNameRow()
                }
                Section {
                    NavigationLink {
                        NotificationsPage()
                    } label: {
                        SettingsRowLabel(
                            title: "Notifications", systemImage: "bell.badge.fill", tint: .red,
                            value: model.notificationPermission.map {
                                SettingsCopy.notificationsValue($0, roomsNotifyForAll: model.preferences.roomsNotifyForAll)
                            },
                            valueTone: model.notificationPermission == .denied ? .warning : .secondary
                        )
                    }
                    NavigationLink {
                        PrivacyPage()
                    } label: {
                        SettingsRowLabel(title: "Privacy", systemImage: "hand.raised.fill", tint: .blue, value: nil)
                    }
                    NavigationLink {
                        ConversationsPage()
                    } label: {
                        SettingsRowLabel(
                            title: "Conversations", systemImage: "bubble.left.and.bubble.right.fill", tint: .green,
                            value: SettingsCopy.listLayoutValue(model.preferences.listLayout)
                        )
                    }
                }
                Section {
                    NavigationLink {
                        DevicesPage()
                    } label: {
                        let verified = model.encryption?.isDeviceVerified
                        SettingsRowLabel(
                            title: "Devices", systemImage: "laptopcomputer.and.iphone", tint: .indigo,
                            value: verified.map { SettingsCopy.verifiedValue($0) },
                            valueTone: verified == false ? .warning : .secondary
                        )
                    }
                    NavigationLink {
                        ChatBackupView()
                    } label: {
                        let backup = model.encryption?.backup
                        SettingsRowLabel(
                            title: "Chat Backup", systemImage: "lock.icloud.fill", tint: .teal,
                            value: SettingsCopy.backupValue(backup),
                            valueTone: backup == .off || backup == .needsKey ? .warning : .secondary
                        )
                    }
                } header: {
                    Text("Security")
                }
                CloudSection()
                Section {
                    NavigationLink {
                        StoragePage()
                    } label: {
                        SettingsRowLabel(title: "Storage", systemImage: "internaldrive.fill", tint: .gray,
                                         value: model.storage.map { SettingsCopy.bytes($0.mediaBytes) })
                    }
                }
                AboutSection()
                SignOutSection()
            }
            .navigationTitle("Settings")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .close) { dismiss() }
                }
            }
            .task {
                // What the rows report, read once when Settings opens.
                await model.refreshNotificationPermission()
                await model.refreshStorage()
                if model.devices == nil { model.refreshDevices() }
            }
        }
        // On the stack, not a page: the alerts open from any page in Settings.
        .deviceAlerts()
    }
}

private struct NotificationsPage: View {
    var body: some View {
        Form { NotificationSettingsSections() }
            #if os(iOS)
            .settingsPage("Notifications")
            #endif
    }
}

private struct PrivacyPage: View {
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
        #if os(iOS)
        .settingsPage("Privacy")
        #endif
    }
}

private struct ConversationsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            SettingsHero(
                Text("Conversations"),
                subtitle: Text(SettingsCopy.conversationsHero(
                    layout: model.preferences.listLayout, membership: model.preferences.showMembershipChanges
                )).foregroundStyle(.secondary),
                systemImage: "bubble.left.and.bubble.right.fill", tint: .green
            )
            ConversationSettingsSections()
        }
        #if os(iOS)
        .settingsPage("Conversations")
        #endif
    }
}

private struct DevicesPage: View {
    @Environment(AppModel.self) private var model
    @State private var showingBackup = false
    @State private var resetting = false

    var body: some View {
        Form {
            DevicesSections(openChatBackup: { showingBackup = true }, resetEncryption: { resetting = true })
        }
        .navigationDestination(isPresented: $showingBackup) { ChatBackupView() }
        .sheet(isPresented: $resetting) { ResetEncryptionView() }
        .refreshable { model.refreshDevices() }
        #if os(iOS)
        .settingsPage("Devices")
        #endif
    }
}

private struct StoragePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            SettingsHero(
                Text("Storage"),
                subtitle: Text(SettingsCopy.storageHero(model.storage?.mediaBytes)).foregroundStyle(.secondary),
                systemImage: "internaldrive.fill", tint: .gray
            )
            StorageSection()
        }
        #if os(iOS)
        .settingsPage("Storage")
        #endif
    }
}
