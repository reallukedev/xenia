import XeniaCore
import SwiftUI
import UserNotifications

/// The hero: your photo, name, address and one line on how things stand.
struct AccountHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = SettingsCopy.hero(
            connection: model.connection, backup: model.encryption?.backup,
            deviceVerified: model.encryption?.isDeviceVerified
        )
        if let account = model.account {
            #if os(macOS)
            HStack(spacing: Theme.Spacing.m) {
                ProfilePhotoButton(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName ?? account.userId).font(.headline)
                    Text(account.userId).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    StatusText(text: status.text, tone: status.tone).font(.callout)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            #else
            VStack(spacing: Theme.Spacing.s) {
                ProfilePhotoButton(size: 88)
                    .padding(.bottom, Theme.Spacing.xs)
                Text(account.displayName ?? account.userId)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(account.userId)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                StatusText(text: status.text, tone: status.tone)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            #endif
        }
    }
}

struct StatusText: View {
    let text: String
    let tone: SettingsCopy.Tone

    var body: some View {
        tone.apply(to: Text(text))
            .contentTransition(.opacity)
            .animation(Theme.Motion.contentFade, value: text)
    }
}

/// Your display name, edited in place.
struct DisplayNameRow: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent("Name") {
            HStack {
                TextField("Name", text: $name, prompt: Text("Your Name"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit(save)
                    .submitLabel(.done)
                if saving { ProgressView().controlSize(.small) }
            }
        }
        .onAppear { name = model.account?.displayName ?? "" }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        .errorAlert("Couldn’t Change Your Name", message: $error)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != model.account?.displayName, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await model.client.setDisplayName(name: trimmed) } catch { self.error = Copy.error(error) }
        }
    }
}

/// Notifications: whether Xenia may notify, then how.
struct NotificationSettingsSections: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private var permission: SettingsCopy.Permission { model.notificationPermission ?? .allowed }

    var body: some View {
        @Bindable var preferences = model.preferences
        let status = SettingsCopy.notificationsHero(permission, roomsNotifyForAll: preferences.roomsNotifyForAll)
        SettingsHero(Text("Notifications"), subtitle: status.tone.apply(to: Text(status.text)),
                     systemImage: "bell.badge.fill", tint: .red) {
            #if os(macOS)
            permissionButton
            #endif
        }
        .task(id: scenePhase) { await refresh() }
        #if os(iOS)
        if permission != .allowed {
            Section {
                permissionButton
            } footer: {
                if permission == .denied {
                    Text("Turn on Allow Notifications for Xenia.")
                }
            }
        }
        #endif
        #if os(macOS)
        OpenAtLoginSection()
        #else
        if permission == .allowed, let problem = model.push.problem {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only While Xenia Is Open")
                        Text(SettingsCopy.pushProblem(problem))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Button("Try Again") { model.push.register() }
            }
        }
        #endif
        if permission == .allowed {
            #if os(macOS)
            Section {
                SettingsDetailRow(title: Text("Show Previews"), detail: Text(SettingsCopy.previewsFooter(preferences.showPreviews))) {
                    Toggle("Show Previews", isOn: $preferences.showPreviews).toggleStyle(.switch).labelsHidden()
                }
                SettingsDetailRow(title: Text("Sounds"), detail: Text(SettingsCopy.soundsFooter(preferences.sounds))) {
                    Toggle("Sounds", isOn: $preferences.sounds).toggleStyle(.switch).labelsHidden()
                }
            }
            #else
            Section {
                Toggle("Show Previews", isOn: $preferences.showPreviews)
                Toggle("Sounds", isOn: $preferences.sounds)
            } footer: {
                Text(SettingsCopy.previewsFooter(preferences.showPreviews))
            }
            #endif
            SettingsToggleSection(
                title: "Time-Sensitive Mentions",
                detail: SettingsCopy.timeSensitiveFooter(preferences.mentionsTimeSensitive),
                isOn: $preferences.mentionsTimeSensitive
            )
            Section {
                #if os(macOS)
                SettingsDetailRow(title: Text("Rooms Notify For"), detail: Text(SettingsCopy.roomsFooter(allMessages: preferences.roomsNotifyForAll))) {
                    RoomsNotifyPicker(selection: $preferences.roomsNotifyForAll)
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                }
                #else
                RoomsNotifyPicker(selection: $preferences.roomsNotifyForAll)
                #endif
            } footer: {
                #if os(iOS)
                Text(SettingsCopy.roomsFooter(allMessages: preferences.roomsNotifyForAll))
                #endif
            }
        }
        KeywordsSection()
    }

    @ViewBuilder
    private var permissionButton: some View {
        switch permission {
        case .notAsked:
            Button("Turn On Notifications…") {
                Task {
                    await model.notifier.requestAuthorizationIfNeeded()
                    await refresh()
                }
            }
        case .denied:
            Button("Open \(SettingsCopy.systemSettingsName)…", action: openSystemSettings)
        case .allowed:
            EmptyView()
        }
    }

    private func refresh() async {
        await model.refreshNotificationPermission()
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { openURL(url) }
        #endif
    }
}

/// Read receipts, typing and blocked people.
struct PrivacySettingsSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsToggleSection(
            title: "Send Read Receipts",
            detail: SettingsCopy.readReceiptsFooter(preferences.sendReadReceipts),
            isOn: $preferences.sendReadReceipts
        )
        SettingsToggleSection(
            title: "Share Typing Status",
            detail: SettingsCopy.typingFooter(preferences.sendTypingNotifications),
            isOn: $preferences.sendTypingNotifications
        )
        SettingsToggleSection(
            title: "Show Link Previews",
            detail: SettingsCopy.linkPreviewsFooter(preferences.linkPreviews),
            isOn: $preferences.linkPreviews
        )
        if preferences.linkPreviews {
            SettingsToggleSection(
                title: "Previews in Encrypted Conversations",
                detail: SettingsCopy.encryptedLinkPreviewsFooter(preferences.linkPreviewsEncrypted),
                isOn: $preferences.linkPreviewsEncrypted
            )
        }
        #if os(iOS)
        AppLockSection()
        Section {
            NavigationLink {
                Form { BlockedPeopleSections() }
                    .navigationTitle("Blocked")
                    .inlineTitle()
            } label: {
                LabeledContent("Blocked People") {
                    if let value = SettingsCopy.blockedValue(model.blockedCount) { Text(value) }
                }
            }
        }
        #else
        BlockedPeopleSections()
        #endif
    }
}

/// How conversations read.
struct ConversationSettingsSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Section {
            #if os(macOS)
            SettingsDetailRow(
                title: Text("Chats and Rooms"),
                detail: Text(SettingsCopy.listLayoutFooter(preferences.listLayout))
            ) {
                ListLayoutPicker(selection: $preferences.listLayout)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
            }
            #else
            ListLayoutPicker(selection: $preferences.listLayout)
                .pickerStyle(.inline)
                .labelsHidden()
            #endif
        } header: {
            #if os(iOS)
            Text("Chats and Rooms")
            #else
            Text("Lists")
            #endif
        } footer: {
            #if os(iOS)
            Text(SettingsCopy.listLayoutFooter(preferences.listLayout))
            #endif
        }
        SettingsToggleSection(
            title: "Show Joins and Leaves",
            detail: SettingsCopy.membershipFooter(preferences.showMembershipChanges),
            isOn: $preferences.showMembershipChanges,
            header: Self.togglesHeader
        )
        SettingsToggleSection(
            title: "Color-Code People",
            detail: SettingsCopy.colorCodeFooter(preferences.colorCodePeople),
            isOn: $preferences.colorCodePeople
        )
        SettingsToggleSection(
            title: "Sync Drafts with iCloud",
            detail: SettingsCopy.syncDraftsFooter(preferences.syncDrafts),
            isOn: $preferences.syncDrafts
        )
    }
}

extension ConversationSettingsSections {
    /// On iPhone the page is already called Conversations; on the Mac these share General.
    private static var togglesHeader: LocalizedStringKey? {
        #if os(macOS)
        "Conversations"
        #else
        nil
        #endif
    }
}

private struct ListLayoutPicker: View {
    @Binding var selection: ListLayout
    @State private var picks = 0

    var body: some View {
        Picker("Chats and Rooms", selection: $selection.picked(counting: $picks)) {
            ForEach(ListLayout.allCases, id: \.self) { layout in
                Text(SettingsCopy.listLayoutValue(layout)).tag(layout)
            }
        }
        .sensoryFeedback(.selection, trigger: picks)
    }
}

private struct RoomsNotifyPicker: View {
    @Binding var selection: Bool
    @State private var picks = 0

    var body: some View {
        Picker("Rooms Notify For", selection: $selection.picked(counting: $picks)) {
            Text("All Messages").tag(true)
            Text("Mentions Only").tag(false)
        }
        .sensoryFeedback(.selection, trigger: picks)
    }
}

private extension Binding where Value: Equatable {
    /// The same binding, counting each choice made through it. A haptic watching the count
    /// answers the person, never a preference arriving from iCloud.
    func picked(counting picks: Binding<Int>) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { new in
            if new != wrappedValue { picks.wrappedValue += 1 }
            wrappedValue = new
        })
    }
}

/// Server, device and version.
struct AboutSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("About") {
            if let account = model.account {
                LabeledContent("Server") {
                    Text(account.homeserver.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                        .textSelection(.enabled)
                }
                LabeledContent("Device ID") {
                    Text(account.deviceId).font(.body.monospaced()).textSelection(.enabled)
                }
            }
            LabeledContent("Version", value: version)
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// Sign Out, with what it costs said first.
struct SignOutSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var signingOut = false

    var body: some View {
        Section {
            #if os(macOS)
            // The Mac puts the account's action at the trailing edge, as System Settings does.
            SettingsDetailRow(
                title: Text("Sign Out"),
                detail: Text("Removes your account from this Mac.")
            ) {
                HStack(spacing: Theme.Spacing.s) {
                    if signingOut { ProgressView().controlSize(.small) }
                    Button("Sign Out…") { confirming = true }
                        .disabled(signingOut)
                }
            }
            #else
            Button(role: .destructive) {
                confirming = true
            } label: {
                HStack {
                    Text("Sign Out").foregroundStyle(.red)
                    if signingOut {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(signingOut)
            #endif
        }
        .confirmationDialog("Sign Out of Xenia?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                signingOut = true
                Task { await model.signOut() }
            }
        } message: {
            Text(SettingsCopy.signOutWarning(model.encryption?.backup))
        }
    }
}

/// iCloud: settings that follow you, and signing in on your other devices.
struct CloudSection: View {
    @Environment(AppModel.self) private var model
    @State private var askingPassword = false
    @State private var password = ""
    @State private var checking = false
    @State private var problem: String?
    @State private var problemIsPassword = false
    @State private var turnedOn = 0

    var body: some View {
        let isOn = Binding(
            get: { model.isAccountInCloud },
            set: { on in
                if on { askingPassword = true } else { model.forgetCloudAccount() }
            }
        )
        Section {
            #if os(macOS)
            SettingsDetailRow(
                title: Text("Sign In on Your Other Devices"),
                detail: Text(SettingsCopy.cloudSignInFooter(model.isAccountInCloud)),
                systemImage: "icloud.fill",
                tint: .blue
            ) {
                Toggle("Sign In on Your Other Devices", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(checking)
            }
            #else
            Toggle(isOn: isOn) {
                Label {
                    Text("Sign In on Your Other Devices")
                } icon: {
                    SettingsIconTile(systemImage: "icloud.fill", color: .blue)
                }
            }
            .disabled(checking)
            #endif
        } header: {
            Text("iCloud")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                #if os(iOS)
                Text(SettingsCopy.cloudSignInFooter(model.isAccountInCloud))
                #endif
                Text(SettingsCopy.cloudSettingsFooter(isAvailable: model.cloudPreferences != nil))
            }
        }
        .alert("Sign In on Your Other Devices", isPresented: $askingPassword) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { password = "" }
            Button("Turn On") { turnOn() }
        } message: {
            Text("Your password is saved in iCloud Keychain so your other devices can sign in.")
        }
        .errorAlert(problemIsPassword ? "Incorrect Password" : "Couldn’t Turn On Signing In", message: $problem)
        .sensoryFeedback(.success, trigger: turnedOn)
    }

    /// Checks the password with the server first: a typo kept in iCloud would leave every new
    /// device failing to sign in, with the toggle saying all is well.
    private func turnOn() {
        let typed = password
        password = ""
        guard let account = model.account, !typed.isEmpty else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                try await model.client.checkPassword(password: typed)
                model.rememberAccount(account, password: typed, turningOn: true)
                if model.isAccountInCloud {
                    turnedOn += 1
                } else {
                    problemIsPassword = false
                    problem = String(localized: "Turn on iCloud Keychain in \(SettingsCopy.systemSettingsName), then try again.")
                }
            } catch XeniaError.InvalidCredentials {
                problemIsPassword = true
                problem = String(localized: "Try again with your account password.")
            } catch {
                problemIsPassword = false
                problem = Copy.error(error)
            }
        }
    }
}
