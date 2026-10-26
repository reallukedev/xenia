import XeniaCore
import SwiftUI

/// Where the account is signed in, which devices are verified, and verifying this one.
/// A page on iPhone; on the Mac the same sections sit in the Security pane.
struct DevicesSections: View {
    @Environment(AppModel.self) private var model
    var showsHero = true
    /// Opens Chat Backup, for verifying with the recovery key.
    var openChatBackup: () -> Void = {}
    /// Opens Reset Encryption (the page presents it: a sheet inside a list row closes itself).
    var resetEncryption: () -> Void = {}
    @State private var showingAll = false

    /// The Mac pane lists the latest few; the rest wait behind Show All.
    private var shownLimit: Int {
        #if os(macOS)
        showingAll ? .max : 5
        #else
        .max
        #endif
    }

    var body: some View {
        let devices = model.devices
        let current = devices?.first(where: \.isCurrent)
        let others = devices?.filter { !$0.isCurrent } ?? []
        let verified = model.encryption?.isDeviceVerified
        if showsHero {
            let status = SettingsCopy.devicesHero(thisVerified: devices == nil ? nil : verified, others: others.count)
            SettingsHero(Text("Devices"), subtitle: status.tone.apply(to: Text(status.text)),
                         systemImage: "laptopcomputer.and.iphone", tint: .blue)
        }

        Section {
            if let current {
                DeviceRow(session: current, isVerified: verified ?? current.isVerified)
            } else {
                PlaceholderRow(failed: model.devicesFailed)
            }
            if verified == false {
                VerifyThisDeviceButtons(canUseDevice: !others.isEmpty, openChatBackup: openChatBackup, reset: resetEncryption)
            }
        } header: {
            Text("This \(SettingsCopy.deviceKind)")
        }

        if !others.isEmpty {
            Section {
                ForEach(others.prefix(shownLimit), id: \.deviceId) { session in
                    OtherDeviceRow(session: session)
                }
                if others.count > shownLimit {
                    Button("Show All \(others.count) Devices") {
                        withAnimation(Theme.Motion.row) { showingAll = true }
                    }
                }
                if others.count > 1 {
                    Button("Sign Out of Other Devices…", role: .destructive) {
                        DeviceEditor.shared.signOutOthers = others.map(\.deviceId)
                    }
                }
            } header: {
                Text("Other Devices")
            } footer: {
                Text("Sign out of any device you don’t recognize.")
            }
        }
    }
}

private struct PlaceholderRow: View {
    let failed: Bool

    var body: some View {
        HStack {
            Text(failed ? "Couldn’t load your devices." : "Loading…")
                .foregroundStyle(.secondary)
            Spacer()
            if !failed { ProgressView().controlSize(.small) }
        }
    }
}

/// Verify with another device, or with the recovery key.
private struct VerifyThisDeviceButtons: View {
    let canUseDevice: Bool
    let openChatBackup: () -> Void
    let reset: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if canUseDevice {
            Button {
                model.verify(.thisDevice, fromSettings: true)
            } label: {
                Label("Verify with Another Device…", systemImage: "laptopcomputer.and.iphone")
            }
        }
        if model.encryption?.backup == .needsKey || model.encryption?.backup == .on {
            Button(action: openChatBackup) {
                Label("Verify with Recovery Key…", systemImage: "key")
            }
        }
        Button(action: reset) {
            Label("Can’t Verify? Reset Encryption…", systemImage: "arrow.counterclockwise")
        }
    }
}

/// A device: its kind, name, when it was last used, and whether it's verified.
struct DeviceRow: View {
    let session: Session
    let isVerified: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            SettingsIconTile(systemImage: SettingsCopy.deviceSymbol(name: session.name), color: .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsCopy.deviceName(session))
                    .lineLimit(1)
                Text(facts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            VerifiedBadge(isVerified: isVerified)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var facts: String {
        let active = session.isCurrent ? String(localized: "This \(SettingsCopy.deviceKind)") : SettingsCopy.lastActive(session.lastSeenMs)
        return [active, session.deviceId].compactMap { $0 }.joined(separator: " · ")
    }
}

struct VerifiedBadge: View {
    let isVerified: Bool

    var body: some View {
        Label(SettingsCopy.verifiedValue(isVerified),
              systemImage: isVerified ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(isVerified ? AnyShapeStyle(.secondary) : AnyShapeStyle(.ink(.orange)))
            .symbolRenderingMode(.hierarchical)
            .fixedSize()
    }
}

/// Another device: a page on iPhone, a menu of actions on the Mac.
private struct OtherDeviceRow: View {
    let session: Session

    var body: some View {
        #if os(iOS)
        NavigationLink {
            DeviceDetailPage(deviceID: session.deviceId)
        } label: {
            DeviceRow(session: session, isVerified: session.isVerified)
        }
        #else
        HStack(spacing: Theme.Spacing.s) {
            DeviceRow(session: session, isVerified: session.isVerified)
            DeviceActionsMenu(session: session)
        }
        .contextMenu { DeviceActions(session: session) }
        #endif
    }
}

#if os(macOS)
private struct DeviceActionsMenu: View {
    let session: Session

    var body: some View {
        Menu {
            DeviceActions(session: session)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel(Text("More for \(SettingsCopy.deviceName(session))"))
    }
}

/// The same actions in the ••• menu and the row's context menu.
private struct DeviceActions: View {
    let session: Session
    @Environment(AppModel.self) private var model

    var body: some View {
        if !session.isVerified {
            Button("Verify…") {
                model.verify(.session(deviceID: session.deviceId, name: SettingsCopy.deviceName(session)), fromSettings: true)
            }
        }
        Button("Rename…") { DeviceEditor.shared.rename = session }
        Divider()
        Button("Sign Out…", role: .destructive) { DeviceEditor.shared.signOut = session }
    }
}
#endif

/// Which device the rename and sign-out alerts are about (the Mac's menus open them).
@Observable
final class DeviceEditor {
    static let shared = DeviceEditor()
    var rename: Session?
    var signOut: Session?
    /// Every other device, for Sign Out of Other Devices.
    var signOutOthers: [String]?
}

extension View {
    /// The rename and sign-out alerts for devices, shown by whichever screen lists them.
    func deviceAlerts() -> some View {
        modifier(DeviceAlerts())
    }
}

private struct DeviceAlerts: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var editor = DeviceEditor.shared
    @State private var newName = ""
    @State private var password = ""
    @State private var error: String?
    @State private var succeeded = 0

    func body(content: Content) -> some View {
        content
            .alert("Rename Device", isPresented: renaming, presenting: editor.rename) { session in
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { rename(session) }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: { _ in
                Text("Others may see this name.")
            }
            .alert(signOutTitle, isPresented: signingOut, presenting: editor.signOut) { session in
                SecureField("Password", text: $password)
                Button("Cancel", role: .cancel) { password = "" }
                Button("Sign Out", role: .destructive) { signOut(session) }
            } message: { _ in
                Text("Enter your password to sign out this device.")
            }
            .alert(othersTitle, isPresented: signingOutOthers, presenting: editor.signOutOthers) { ids in
                SecureField("Password", text: $password)
                Button("Cancel", role: .cancel) { password = "" }
                Button("Sign Out ^[\(ids.count) Device](inflect: true)", role: .destructive) { signOut(ids) }
            } message: { _ in
                Text("Enter your password. Only this \(SettingsCopy.deviceKind) stays signed in.")
            }
            .errorAlert("Couldn’t Change the Device", message: $error)
            .sensoryFeedback(.success, trigger: succeeded)
            .onChange(of: editor.rename?.deviceId) { _, _ in
                newName = editor.rename.map(SettingsCopy.deviceName) ?? ""
            }
    }

    private var signOutTitle: String {
        editor.signOut.map { String(localized: "Sign Out of “\(SettingsCopy.deviceName($0))”?") } ?? ""
    }

    private var othersTitle: String {
        editor.signOutOthers.map { String(inflecting: "Sign Out of ^[\($0.count) Other Device](inflect: true)?") } ?? ""
    }

    private var signingOutOthers: Binding<Bool> {
        Binding(get: { editor.signOutOthers != nil }, set: { if !$0 { editor.signOutOthers = nil } })
    }

    private var renaming: Binding<Bool> {
        Binding(get: { editor.rename != nil }, set: { if !$0 { editor.rename = nil } })
    }

    private var signingOut: Binding<Bool> {
        Binding(get: { editor.signOut != nil }, set: { if !$0 { editor.signOut = nil } })
    }

    private func rename(_ session: Session) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await model.client.renameSession(deviceId: session.deviceId, name: name)
                succeeded += 1
                model.refreshDevices()
            } catch {
                self.error = Copy.error(error)
            }
        }
    }

    private func signOut(_ session: Session) {
        signOut([session.deviceId])
    }

    private func signOut(_ ids: [String]) {
        let typed = password
        password = ""
        Task {
            do {
                try await model.client.signOutSessions(deviceIds: ids, password: typed)
                for id in ids { model.removeDevice(id) }
                succeeded += 1
                model.refreshDevices()
            } catch XeniaError.PasswordRequired {
                self.error = String(localized: "Enter your password, then try again.")
            } catch {
                self.error = Copy.error(error)
            }
        }
    }
}

#if os(iOS)
/// One device on iPhone: its name, facts, verifying it and signing it out.
struct DeviceDetailPage: View {
    let deviceID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let session = model.devices?.first(where: { $0.deviceId == deviceID }) {
            Form {
                SettingsHero(
                    Text(SettingsCopy.deviceName(session)),
                    subtitle: session.isVerified
                        ? Text(SettingsCopy.verifiedValue(true)).foregroundStyle(.secondary)
                        : Text(SettingsCopy.verifiedValue(false)).foregroundStyle(.ink(.orange)),
                    systemImage: SettingsCopy.deviceSymbol(name: session.name),
                    tint: .gray
                )
                Section {
                    if let active = SettingsCopy.lastActive(session.lastSeenMs) {
                        LabeledContent("Last Active", value: active)
                    }
                    LabeledContent("Device ID") {
                        Text(session.deviceId).font(.body.monospaced()).textSelection(.enabled)
                    }
                    if let ip = session.lastSeenIp {
                        LabeledContent("IP Address") {
                            Text(ip).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    if !session.isVerified {
                        Button("Verify…") {
                            model.verify(.session(deviceID: session.deviceId, name: SettingsCopy.deviceName(session)), fromSettings: true)
                        }
                    }
                    Button("Rename…") { DeviceEditor.shared.rename = session }
                } footer: {
                    if !session.isVerified {
                        Text("Compare emoji on both devices to verify.")
                    }
                }
                Section {
                    Button("Sign Out of This Device…", role: .destructive) { DeviceEditor.shared.signOut = session }
                }
            }
            .settingsPage(LocalizedStringKey(SettingsCopy.deviceName(session)))
        } else {
            // Signed out a moment ago.
            Color.clear.onAppear { dismiss() }
        }
    }
}
#endif
