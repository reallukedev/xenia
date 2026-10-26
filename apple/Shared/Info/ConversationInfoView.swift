import XeniaCore
import SwiftUI

/// Details: who or what this is, how it notifies, the people in it, and leaving.
struct ConversationInfoView: View {
    let roomID: String
    var openThreads: () -> Void = {}
    /// Opens search within this conversation.
    var openSearch: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var members: [Member] = []
    @State private var loadingMembers = true
    @State private var leaving: RoomSummary?
    @State private var showingAllMembers = false
    @State private var addingPeople = false
    @State private var trust: PersonTrust?
    @State private var isBlocked = false
    @State private var confirmingBlock = false
    @State private var error: String?

    var body: some View {
        if let room = model.room(roomID) {
            content(room)
        } else {
            ContentUnavailableView("Conversation Unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        }
    }

    private func content(_ room: RoomSummary) -> some View {
        let actions = RoomActions(model: model)
        let shownMembers = showingAllMembers ? members : Array(members.prefix(8))
        return Form {
            Section {
                VStack(spacing: Theme.Spacing.s) {
                    AvatarView(name: room.name, seed: room.avatarSeed, url: room.avatarUrl, size: Theme.Metrics.detailAvatar, isRoom: room.isRoom)
                    Text(room.name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(subtitle(room))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    QuickActions(room: room, search: openSearch, threads: openThreads)
                        .padding(.top, Theme.Spacing.s)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                #if os(macOS)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                #endif
            }

            if let topic = room.topic, !room.isDm {
                Section("Topic") {
                    Text(topic).textSelection(.enabled)
                }
            }

            Section {
                Picker(selection: Binding(get: { actions.notificationMode(room) }, set: { actions.setMode(room, $0) })) {
                    Text("All Messages").tag(NotificationMode.allMessages)
                    Text("Mentions Only").tag(NotificationMode.mentionsOnly)
                    Text("Mute").tag(NotificationMode.mute)
                } label: {
                    Label("Notifications", systemImage: room.isMuted ? "bell.slash" : "bell")
                        .contentTransition(.symbolEffect(.replace))
                }
            } footer: {
                Text(notificationFooter(room, mode: actions.notificationMode(room)))
            }

            if !room.isDm {
                Section {
                    Button {
                        #if os(macOS)
                        // A sheet belongs to the window, not to the Details popover.
                        dismiss()
                        model.navigation.sheet = .addPeople(roomID: roomID)
                        #else
                        addingPeople = true
                        #endif
                    } label: {
                        Label("Add People…", systemImage: "person.badge.plus")
                    }
                    ForEach(shownMembers, id: \.userId) { member in
                        MemberRow(member: member)
                    }
                    if members.count > shownMembers.count {
                        Button("Show All \(members.count) Members") {
                            withAnimation(Theme.Motion.row) { showingAllMembers = true }
                        }
                    }
                    if loadingMembers {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("^[\(room.memberCount) Member](inflect: true)")
                }
                .infoRowButtons()
            }

            Section {
                if room.isEncrypted {
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    if room.isDm, let userID = room.dmUserId, let trust, trust != .unknown {
                        TrustRow(name: room.name, trust: trust) {
                            #if os(macOS)
                            dismiss()
                            #endif
                            model.verify(.person(userID: userID, name: firstName(name: room.name)))
                        }
                    }
                } else {
                    Label("Not end-to-end encrypted", systemImage: "lock.open")
                        .foregroundStyle(.secondary)
                }
                if let alias = room.alias {
                    LabeledContent("Address") {
                        Text(alias).textSelection(.enabled)
                    }
                }
            }
            .infoRowButtons()

            Section {
                if room.isDm, let userID = room.dmUserId {
                    if isBlocked {
                        Button {
                            setBlocked(false, userID: userID)
                        } label: {
                            Label("Unblock \(firstName(name: room.name))", systemImage: "hand.raised.slash")
                        }
                    } else {
                        Button(role: .destructive) {
                            confirmingBlock = true
                        } label: {
                            Label("Block \(firstName(name: room.name))…", systemImage: "hand.raised")
                                .foregroundStyle(.red)
                        }
                        .confirmationDialog("Block \(room.name)?", isPresented: $confirmingBlock, titleVisibility: .visible) {
                            Button("Block", role: .destructive) { setBlocked(true, userID: userID) }
                        } message: {
                            Text("They won’t be able to message you or invite you, and they aren’t told. You can unblock them in Settings.")
                        }
                    }
                }
                Button(role: .destructive) {
                    leaving = room
                } label: {
                    Label(room.isDm ? "Delete Chat" : "Leave Room", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                }
            }
            .infoRowButtons()
        }
        .formStyle(.grouped)
        .navigationTitle(room.isDm ? "Details" : "Room Details")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: roomID) {
            if room.isDm, let userID = room.dmUserId {
                isBlocked = await model.client.blockedUserIds().contains(userID)
                if room.isEncrypted { trust = await model.client.personTrust(userId: userID) }
            }
            members = (try? await model.client.members(roomId: roomID)) ?? []
            loadingMembers = false
        }
        .onChange(of: model.verification?.state) { _, state in
            // A verification with this person just finished: show it here.
            if case .done = state, room.isDm, let userID = room.dmUserId {
                Task { trust = await model.client.personTrust(userId: userID) }
            }
        }
        .errorAlert("Something Went Wrong", message: $error)
        .sheet(isPresented: $addingPeople, onDismiss: reloadMembers) {
            NewConversationView(mode: .invite(roomID: roomID))
        }
        .leaveConfirmation($leaving) { dismiss() }
    }

    private func setBlocked(_ blocked: Bool, userID: String) {
        Task {
            do {
                if blocked { try await model.client.block(userId: userID) } else { try await model.client.unblock(userId: userID) }
                withAnimation(Theme.Motion.row) { isBlocked = blocked }
                model.blockedCount = nil
            } catch {
                self.error = Copy.error(error)
            }
        }
    }

    private func reloadMembers() {
        Task { members = (try? await model.client.members(roomId: roomID)) ?? members }
    }

    private func subtitle(_ room: RoomSummary) -> String {
        if room.isDm { return room.dmUserId ?? "" }
        var parts = [String(inflecting: "^[\(room.memberCount) member](inflect: true)")]
        if room.isPublic { parts.append(String(localized: "Public")) }
        return parts.joined(separator: " · ")
    }

    private func notificationFooter(_ room: RoomSummary, mode: NotificationMode) -> String {
        switch mode {
        case .allMessages:
            String(localized: "You’re notified of every new message.")
        case .mentionsOnly where room.hasOwnNotificationMode:
            String(localized: "You’re notified only when someone mentions you.")
        case .mentionsOnly where room.isPublic:
            String(localized: "Public rooms notify you only when someone mentions you. Choose All Messages to hear about everything here.")
        case .mentionsOnly:
            String(localized: "Rooms notify you only when someone mentions you, as set in Settings. Choose All Messages to hear about everything here.")
        case .mute:
            String(localized: "You won’t be notified, even when someone mentions you.")
        }
    }
}

private struct MemberRow: View {
    let member: Member

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(name: member.name, seed: member.userId, url: member.avatarUrl, size: Theme.Metrics.memberAvatar)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.isYou ? String(localized: "\(member.name) (You)") : member.name)
                    .lineLimit(1)
                Text(member.userId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if member.isInvited {
                Text("Invited").font(.caption).foregroundStyle(.secondary)
            } else if member.isAdmin {
                Text("Admin").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Whether you've verified the person in a chat, with Verify when you haven't.
private struct TrustRow: View {
    let name: String
    let trust: PersonTrust
    let verify: () -> Void

    var body: some View {
        switch trust {
        case .verified:
            Label("You’ve verified \(name)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.secondary)
        case .changedSinceVerified:
            Button(action: verify) {
                Label("\(name)’s keys changed. Verify Again…", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.ink(.orange))
            }
        case .notVerified, .unknown:
            Button(action: verify) {
                Label("Verify \(name)…", systemImage: "checkmark.shield")
            }
        }
    }
}

/// The row of quick actions under a conversation's name, as Contacts and Messages set them:
/// Search, Threads, Mute and Pin, each a symbol over a word.
private struct QuickActions: View {
    let room: RoomSummary
    let search: () -> Void
    let threads: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let actions = RoomActions(model: model)
        HStack(spacing: Theme.Spacing.s) {
            QuickActionButton(title: "Search", systemImage: "magnifyingglass", action: search)
            QuickActionButton(title: "Threads", systemImage: "bubble.left.and.text.bubble.right", action: threads)
            QuickActionButton(
                title: room.isMuted ? "Unmute" : "Mute",
                systemImage: room.isMuted ? "bell.slash.fill" : "bell.fill",
                isOn: room.isMuted
            ) { actions.toggleMute(room) }
            QuickActionButton(
                title: room.isFavourite ? "Unpin" : "Pin",
                systemImage: room.isFavourite ? "pin.fill" : "pin",
                isOn: room.isFavourite
            ) { actions.toggleFavourite(room) }
        }
        .frame(maxWidth: 380)
    }
}

private struct QuickActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    /// Set for a toggle (Mute, Pin); nil for a button that goes somewhere.
    var isOn: Bool?
    let action: () -> Void

    @State private var isHovering = false
    /// Counts taps, so the haptic answers the person and not a change synced from elsewhere.
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 22)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isOn == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
            .background(background, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.hover, value: isHovering)
        .animation(Theme.Motion.flip, value: isOn)
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
        // A toggle is felt; Search and Threads just open, as Contacts' buttons do.
        .sensoryFeedback(trigger: taps) { _, _ in isOn == nil ? nil : .selection }
    }

    /// White cells on iPhone's grouped gray, as Contacts sets them; a quiet fill in the Mac's
    /// popover that deepens on hover.
    private var background: AnyShapeStyle {
        #if os(iOS)
        AnyShapeStyle(Color.groupedCell)
        #else
        isHovering ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary)
        #endif
    }
}

private extension View {
    /// Rows that act, drawn like rows (a symbol and words, full width), not as push buttons, in
    /// the Mac's Details popover. iPhone's Form already draws buttons as rows.
    @ViewBuilder
    func infoRowButtons() -> some View {
        #if os(macOS)
        buttonStyle(InfoRowButtonStyle())
        #else
        self
        #endif
    }
}

private struct InfoRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
