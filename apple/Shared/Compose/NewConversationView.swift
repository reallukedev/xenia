import XeniaCore
import SwiftUI

/// New Message (pick a person, and the chat opens) and New Group (pick people, name it, create).
struct NewConversationView: View {
    enum Mode: Equatable {
        case message
        case group
        /// Adding people to an existing room.
        case invite(roomID: String)

        var picksMany: Bool { self != .message }
    }

    let mode: Mode

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var directory: [Person] = []
    @State private var isSearching = false
    @State private var selected: [Person] = []
    @State private var groupName = ""
    @State private var working: String?
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.m)
            fields
                .padding(.horizontal, Theme.Spacing.xl)
            results
                .frame(minHeight: 280, maxHeight: 380)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if mode.picksMany {
                    Button(confirmTitle, action: confirm)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty || working != nil)
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 440)
        .task(id: query) { await searchDirectory() }
        .errorAlert("Couldn’t Start the Conversation", message: $error)
        #else
        NavigationStack {
            VStack(spacing: 0) {
                fields
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.s)
                results
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                if mode.picksMany {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmTitle, role: .confirm, action: confirm)
                            .disabled(selected.isEmpty || working != nil)
                    }
                }
            }
        }
        .task(id: query) { await searchDirectory() }
        .errorAlert("Couldn’t Start the Conversation", message: $error)
        .sensoryFeedback(.selection, trigger: selected.count)
        #endif
    }

    private var title: LocalizedStringKey {
        switch mode {
        case .message: "New Message"
        case .group: "New Group"
        case .invite: "Add People"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch mode {
        case .message: "Choose someone to chat with."
        case .group: "Choose people, then name the group if you like."
        case .invite: "They’ll get an invitation to join."
        }
    }

    private var confirmTitle: LocalizedStringKey {
        if case .invite = mode { return "Add" }
        return "Create"
    }

    private func confirm() {
        if case .invite(let roomID) = mode { invite(roomID) } else { createGroup() }
    }

    private func invite(_ roomID: String) {
        guard !selected.isEmpty, working == nil else { return }
        working = "invite"
        Task {
            defer { working = nil }
            do {
                try await model.client.invite(roomId: roomID, userIds: selected.map(\.userId))
                dismiss()
            } catch {
                self.error = Copy.error(error)
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if mode == .group {
                TextField("Group Name (Optional)", text: $groupName)
                    .textFieldStyle(.roundedBorder)
            }
            if !selected.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(selected, id: \.userId) { person in
                            Button {
                                toggle(person)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(person.name).lineLimit(1)
                                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                                }
                                .font(.subheadline)
                                .padding(.horizontal, Theme.Spacing.s)
                                .padding(.vertical, 5)
                                .background(.tint.opacity(0.15), in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove \(person.name)"))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            HStack(spacing: Theme.Spacing.s) {
                Text("To:").foregroundStyle(.secondary)
                TextField("Name or @name:server", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(chooseFirst)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
        }
        .onAppear { searchFocused = true }
    }

    private var results: some View {
        let people = candidates
        return List {
            if let typed = typedUserID, !people.contains(where: { $0.userId == typed }) {
                Section {
                    Button { choose(Person(userId: typed, displayName: nil, avatarUrl: nil)) } label: {
                        PersonRow(person: Person(userId: typed, displayName: nil, avatarUrl: nil), isWorking: working == typed)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section(query.isEmpty ? "Recent" : "People") {
                ForEach(people, id: \.userId) { person in
                    Button { choose(person) } label: {
                        PersonRow(person: person, isWorking: working == person.userId, isSelected: selected.contains(where: { $0.userId == person.userId }))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay {
            if people.isEmpty, typedUserID == nil, !isSearching {
                if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    ContentUnavailableView {
                        Label("No One Found", systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text("Type their full address, like @maya:matrix.org, to reach someone the directory doesn’t list.")
                    }
                } else if query.isEmpty {
                    ContentUnavailableView {
                        Label("Find People", systemImage: "person.2")
                    } description: {
                        Text("Search by name, or type a full address like @maya:matrix.org.")
                    }
                }
            }
        }
    }

    /// People you already chat with first, then the directory's matches.
    private var candidates: [Person] {
        let term = normalizeForSearch(text: query.trimmingCharacters(in: .whitespaces))
        let known: [Person] = model.rooms.compactMap { room in
            guard room.isDm, let user = room.dmUserId else { return nil }
            return Person(userId: user, displayName: room.name, avatarUrl: room.avatarUrl)
        }
        let matchingKnown = term.isEmpty ? Array(known.prefix(12)) : known.filter {
            normalizeForSearch(text: $0.name).contains(term) || normalizeForSearch(text: $0.userId).contains(term)
        }
        var seen = Set(matchingKnown.map(\.userId))
        let extra = directory.filter { seen.insert($0.userId).inserted && $0.userId != model.account?.userId }
        return matchingKnown + extra
    }

    /// A full Matrix ID typed into the field.
    private var typedUserID: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("@"), text.contains(":"), text.count > 3, !text.contains(" ") else { return nil }
        return text
    }

    private func searchDirectory() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else {
            directory = []
            isSearching = false
            return
        }
        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            let found = try await model.client.searchPeople(query: term)
            // Only the answer for what's typed now counts.
            guard !Task.isCancelled, term == query.trimmingCharacters(in: .whitespaces) else { return }
            directory = found
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            directory = []
        }
        isSearching = false
    }

    /// Return takes the top result: a typed address, or the first person listed. With the field
    /// empty and people chosen, it creates the group (the field would otherwise keep the Return).
    private func chooseFirst() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            if mode.picksMany, !selected.isEmpty { confirm() }
        } else if let typed = typedUserID, !candidates.contains(where: { $0.userId == typed }) {
            choose(Person(userId: typed, displayName: nil, avatarUrl: nil))
        } else if let first = candidates.first {
            choose(first)
        }
    }

    private func toggle(_ person: Person) {
        if let index = selected.firstIndex(where: { $0.userId == person.userId }) {
            selected.remove(at: index)
        } else {
            selected.append(person)
        }
    }

    private func choose(_ person: Person) {
        switch mode {
        case .group, .invite:
            toggle(person)
            query = ""
        case .message:
            guard working == nil else { return }
            working = person.userId
            Task {
                defer { working = nil }
                do {
                    let roomID = try await model.client.startDirectChat(userId: person.userId)
                    dismiss()
                    model.navigation.open(roomID: roomID, scope: .chats)
                } catch {
                    self.error = Copy.error(error)
                }
            }
        }
    }

    private func createGroup() {
        guard !selected.isEmpty, working == nil else { return }
        working = "group"
        Task {
            defer { working = nil }
            do {
                let roomID = try await model.client.createGroup(name: groupName, userIds: selected.map(\.userId))
                dismiss()
                model.navigation.open(roomID: roomID, scope: .rooms)
            } catch {
                self.error = Copy.error(error)
            }
        }
    }
}
