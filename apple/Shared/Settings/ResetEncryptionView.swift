import XeniaCore
import SwiftUI

/// The way out when this device can't be verified: no other device to compare emoji with and no
/// recovery key. New encryption keys make this device the verified one; what's lost is said first.
struct ResetEncryptionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var newKey: String?
    @State private var newKeyOffersCloud = false
    @State private var confirming = false

    var body: some View {
        #if os(macOS)
        // A Mac sheet: the hero names it, so no title band; Cancel sits at the bottom.
        VStack(spacing: 0) {
            form
            if newKey == nil {
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(Theme.Spacing.l)
            }
        }
        .frame(width: 520, height: 560)
        .errorAlert("Couldn’t Reset Encryption", message: $error)
        .interactiveDismissDisabled(working || newKey != nil)
        #else
        NavigationStack {
            form
                .navigationTitle("")
                .inlineTitle()
                .toolbar {
                    if newKey == nil {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
                }
                .errorAlert("Couldn’t Reset Encryption", message: $error)
                .interactiveDismissDisabled(working || newKey != nil)
        }
        #endif
    }

    private var form: some View {
        Form {
            SettingsHero(
                Text(newKey == nil ? "Reset Encryption" : "Encryption Reset"),
                subtitle: Text(newKey == nil
                               ? "Only if you can’t verify another way."
                               : "Save your new recovery key.")
                    .foregroundStyle(.secondary),
                systemImage: newKey == nil ? "arrow.counterclockwise.circle.fill" : "checkmark.shield.fill",
                tint: newKey == nil ? .orange : .green
            )
            if let newKey {
                RecoveryKeySection(key: newKey, offersCloud: newKeyOffersCloud) { dismiss() }
            } else {
                Section {
                    Label("This \(SettingsCopy.deviceKind) gets new keys and becomes verified.", systemImage: "checkmark.shield")
                    Label("Your other devices will need verifying again.", systemImage: "laptopcomputer.and.iphone")
                    Label("Messages only in your old backup can’t be read.", systemImage: "lock.slash")
                } header: {
                    Text("What Happens")
                }
                Section {
                    SecureField("Password", text: $password, prompt: Text("Account Password"))
                        .textContentType(.password)
                        .onSubmit { if canReset { confirming = true } }
                }
                Section {
                    Button(role: .destructive) {
                        confirming = true
                    } label: {
                        WorkingLabel(title: "Reset Encryption…", working: working)
                    }
                    .disabled(!canReset)
                    .confirmationDialog("Reset Encryption?", isPresented: $confirming, titleVisibility: .visible) {
                        Button("Reset Encryption", role: .destructive, action: reset)
                    } message: {
                        Text("This can’t be undone.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var canReset: Bool { !password.isEmpty && !working }

    private func reset() {
        working = true
        let typed = password
        Task {
            defer { working = false }
            do {
                let key = try await model.client.resetEncryptionIdentity(password: typed)
                newKeyOffersCloud = model.rememberRecoveryKey(key)
                password = ""
                withAnimation(Theme.Motion.row) { newKey = key }
                model.refreshDevices()
            } catch {
                self.error = Copy.error(error)
            }
        }
    }
}
