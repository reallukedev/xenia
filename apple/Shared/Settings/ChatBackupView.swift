import XeniaCore
import SwiftUI

/// Chat Backup: where it stands, and the one thing to do about it (turn it on, unlock it with the
/// recovery key, or replace the key).
struct ChatBackupView: View {
    @Environment(AppModel.self) private var model
    @State private var recoveryKey = ""
    @State private var newKey: String?
    @State private var working = false
    @State private var error: String?
    @State private var errorTitle: LocalizedStringKey = ""
    @State private var confirmingReset = false
    @State private var unlocked = 0
    /// A key just used here, waiting for a yes or no to keeping it in iCloud Keychain.
    @State private var keyToOffer: String?
    @State private var newKeyOffersCloud = false
    @State private var confirmingRemove = false

    var body: some View {
        let backup = model.encryption?.backup
        Form {
            SettingsHero(
                Text("Chat Backup"),
                subtitle: (backup == .on || backup == .checking || backup == nil ? SettingsCopy.Tone.secondary : .warning)
                    .apply(to: Text(SettingsCopy.backupHero(backup))),
                systemImage: symbol(backup),
                tint: tint(backup)
            )

            if let newKey {
                RecoveryKeySection(key: newKey, offersCloud: newKeyOffersCloud) { self.newKey = nil }
            } else {
                switch backup {
                case .off:
                    Section {
                        Button(action: enable) {
                            WorkingLabel(title: "Turn On Chat Backup", working: working)
                        }
                        .disabled(working)
                    }
                case .needsKey:
                    Section {
                        SecureField("Recovery Key", text: $recoveryKey)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .onSubmit(unlock)
                        Button(action: unlock) {
                            WorkingLabel(title: "Unlock", working: working)
                        }
                        .disabled(recoveryKey.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    } footer: {
                        Text("The 48-character key you saved when you turned on chat backup.")
                    }
                    Section {
                        Button("Lost Your Key? Replace It…", role: .destructive) { confirmingReset = true }
                    }
                case .on:
                    Section {
                        Button("Change Recovery Key…") { confirmingReset = true }
                    }
                    if model.isRecoveryKeyInCloud {
                        Section {
                            Button("Remove Key from iCloud Keychain…", role: .destructive) { confirmingRemove = true }
                        } footer: {
                            Text("Saved in iCloud Keychain, so your devices unlock older messages automatically.")
                        }
                    }
                case .checking, nil:
                    Section {
                        HStack {
                            Text("Checking…").foregroundStyle(.secondary)
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .settingsPage("Chat Backup")
        #else
        .navigationTitle("Chat Backup")
        #endif
        .animation(Theme.Motion.row, value: backup)
        .animation(Theme.Motion.row, value: newKey)
        // A new key is shown once: leaving before "I've Saved My Key" would lose it.
        .navigationBarBackButtonHidden(newKey != nil)
        .interactiveDismissDisabled(newKey != nil)
        .preference(key: UnsavedRecoveryKey.self, value: newKey != nil)
        .sensoryFeedback(.success, trigger: unlocked)
        .errorAlert(errorTitle, message: $error)
        .confirmationDialog("Replace Your Recovery Key?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Replace Key", role: .destructive, action: reset)
        } message: {
            Text("Your old key will stop working. You’ll get a new one to save.")
        }
        .confirmationDialog("Remove Your Recovery Key from iCloud Keychain?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { model.removeRecoveryKeyFromCloud() }
        } message: {
            Text("Your devices will ask for it to read older messages. Keep it somewhere safe.")
        }
        .offerRecoveryKeyToCloud($keyToOffer)
        .animation(Theme.Motion.row, value: model.isRecoveryKeyInCloud)
    }

    private func symbol(_ backup: BackupStatus?) -> String {
        switch backup {
        case .on: "checkmark.icloud.fill"
        case .needsKey: "key.fill"
        case .off: "exclamationmark.icloud.fill"
        case .checking, nil: "icloud.fill"
        }
    }

    private func tint(_ backup: BackupStatus?) -> Color {
        switch backup {
        case .on: .green
        case .needsKey, .off: .orange
        case .checking, nil: .gray
        }
    }

    private func enable() {
        run(failure: "Couldn’t Turn On Chat Backup") {
            let key = try await model.client.enableBackup()
            newKeyOffersCloud = model.rememberRecoveryKey(key)
            newKey = key
        }
    }

    private func unlock() {
        let key = recoveryKey
        run(failure: "Couldn’t Unlock Chat Backup") {
            try await model.client.recover(recoveryKey: key)
            if model.rememberRecoveryKey(key) { keyToOffer = key }
            recoveryKey = ""
            unlocked += 1
        }
    }

    private func reset() {
        run(failure: "Couldn’t Replace the Recovery Key") {
            let key = try await model.client.resetRecoveryKey()
            newKeyOffersCloud = model.rememberRecoveryKey(key)
            newKey = key
        }
    }

    private func run(failure title: LocalizedStringKey, _ work: @escaping @MainActor () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do {
                try await work()
            } catch {
                errorTitle = title
                self.error = Copy.error(error)
            }
        }
    }
}

/// Whether Chat Backup is showing a new recovery key that hasn't been saved yet, for a sheet's
/// own Done button to wait for it.
nonisolated struct UnsavedRecoveryKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The new key, shown once, with Copy and a clear "Done" once it's saved.
struct RecoveryKeySection: View {
    let key: String
    /// Asks about iCloud Keychain once the key is saved, before moving on.
    var offersCloud = false
    let done: () -> Void
    @State private var copied = false
    @State private var copies = 0
    @State private var keyToOffer: String?

    var body: some View {
        Section {
            Text(key)
                .font(.body.monospaced())
                // Copy Recovery Key keeps it off other devices and clears it; a selection's
                // Copy wouldn't.
                .privacySensitive()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.xs)
            Button {
                Pasteboard.copySecret(key)
                copies += 1
                withAnimation(Theme.Motion.contentFade) { copied = true }
            } label: {
                // Both labels take the same space, so the row never jitters.
                ZStack(alignment: .leading) {
                    Label("Copy Recovery Key", systemImage: "doc.on.doc").opacity(copied ? 0 : 1)
                    Label("Copied", systemImage: "checkmark").opacity(copied ? 1 : 0)
                }
            }
            // Nothing else shows the copy happened, so it's felt.
            .sensoryFeedback(.success, trigger: copies)
            Button("I’ve Saved My Key") {
                if offersCloud { keyToOffer = key } else { done() }
            }
        } header: {
            Text("Your Recovery Key")
        } footer: {
            Text("Keep it somewhere safe, like a password manager. You’ll need it on new devices, and it can’t be recovered.")
        }
        .offerRecoveryKeyToCloud($keyToOffer, then: done)
    }
}

extension View {
    /// Asks whether to keep a recovery key in iCloud Keychain, saying what that means. Only asked
    /// when the account is there already (Sign In on Your Other Devices is on).
    func offerRecoveryKeyToCloud(_ key: Binding<String?>, then: @escaping () -> Void = {}) -> some View {
        modifier(RecoveryKeyCloudOffer(key: key, then: then))
    }
}

private struct RecoveryKeyCloudOffer: ViewModifier {
    @Binding var key: String?
    let then: () -> Void
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(
            "Keep Your Recovery Key in iCloud Keychain?",
            isPresented: Binding(get: { key != nil }, set: { if !$0 { key = nil } }),
            presenting: key
        ) { key in
            Button("Keep in iCloud Keychain") {
                model.keepRecoveryKeyInCloud(key)
                then()
            }
            Button("Not Now", role: .cancel) { then() }
        } message: { _ in
            Text("Your devices will unlock older messages automatically. Anyone with access to your Apple Account could too.")
        }
    }
}
