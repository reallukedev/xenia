import XeniaCore
import SwiftUI

/// A room's threads, most recently active first.
struct ThreadListView: View {
    let roomID: String
    let open: (String) -> Void

    @Environment(AppModel.self) private var model
    @State private var threads = ThreadListModel()

    var body: some View {
        List {
            ForEach(threads.entries, id: \.root.eventId) { entry in
                Button { open(entry.root.eventId) } label: {
                    ThreadRow(entry: entry)
                }
                .buttonStyle(.plain)
                .listRowSeparator(entry.root.eventId == threads.entries.first?.root.eventId ? .hidden : .automatic, edges: .top)
                .onAppear {
                    if entry.root.eventId == threads.entries.last?.root.eventId { threads.loadMore() }
                }
            }
            if threads.isLoading && !threads.entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .overlay {
            if threads.entries.isEmpty {
                if let failure = threads.failure {
                    ContentUnavailableView {
                        Label("Couldn’t Load Threads", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try Again") {
                            Task { await threads.open(roomID: roomID, model: model) }
                        }
                    }
                } else if threads.isLoading || !threads.hasLoaded {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("No Threads", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        #if os(macOS)
                        Text("Reply in a thread to keep a side conversation out of the main one. Control-click a message and choose Reply in Thread.")
                        #else
                        Text("Reply in a thread to keep a side conversation out of the main one. Touch and hold a message and choose Reply in Thread.")
                        #endif
                    }
                }
            }
        }
        .task(id: roomID) { await threads.open(roomID: roomID, model: model) }
    }
}

private struct ThreadRow: View {
    let entry: ThreadEntry

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            AvatarView(name: entry.root.senderName, seed: entry.root.senderId, url: entry.root.senderAvatarUrl, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.root.isOwn ? String(localized: "You") : entry.root.senderName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.s)
                    Text(TimeFormat.relative(entry.activityMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Copy.preview(of: entry.root.body, sender: entry.root.senderName))
                    .font(.subheadline)
                    .lineLimit(3)
                HStack(spacing: Theme.Spacing.xs) {
                    if entry.unread != .none {
                        UnreadMark(kind: entry.unread)
                    }
                    Text("^[\(entry.replyCount) Reply](inflect: true)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                    if let latest = entry.latest {
                        Text("· \(latest.isOwn ? String(localized: "You") : firstName(name: latest.senderName)): \(Copy.preview(of: latest.body))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(.rect)
    }
}

@Observable
final class ThreadListModel {
    private(set) var entries: [ThreadEntry] = []
    private(set) var isLoading = true
    private(set) var hasLoaded = false
    private(set) var isAtEnd = false
    /// Why the list couldn't open (offline, say), until Try Again.
    private(set) var failure: String?
    @ObservationIgnored private var list: ThreadList?
    @ObservationIgnored private var openedRoom: String?

    func open(roomID: String, model: AppModel) async {
        // Coming back from a thread keeps the list already open.
        guard list == nil, openedRoom != roomID else { return }
        openedRoom = roomID
        failure = nil
        isLoading = true
        let events = ThreadEvents()
        events.model = self
        do {
            list = try await model.client.threadList(roomId: roomID, listener: events)
        } catch {
            // Not "No Threads": say what happened, and let Try Again open it afresh.
            failure = Copy.error(error)
            openedRoom = nil
            isLoading = false
            hasLoaded = true
        }
    }

    func apply(_ update: ThreadListUpdate) {
        entries = update.threads
        isLoading = update.isLoading
        isAtEnd = update.isAtEnd
        if !update.isLoading { hasLoaded = true }
    }

    func loadMore() {
        guard let list, !isLoading, !isAtEnd else { return }
        Task { await list.loadMore() }
    }
}

final class ThreadEvents: ThreadListListener, @unchecked Sendable {
    nonisolated(unsafe) weak var model: ThreadListModel?

    nonisolated init() {}

    nonisolated func onUpdate(update: ThreadListUpdate) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.model?.apply(update) }
        }
    }
}
