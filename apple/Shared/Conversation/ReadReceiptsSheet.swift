import XeniaCore
import SwiftUI

/// Read Receipts for one of my messages: who has read it and when, then everyone in the
/// conversation who hasn't yet. It refreshes as more people read.
struct ReadReceiptsSheet: View {
    let message: TimelineMessage

    @Environment(ConversationModel.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var receipts: ReadReceipts?
    @State private var failed = false
    @State private var query = ""

    /// Long lists get a search field.
    private static let searchFrom = 20

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.l)
        }
        .frame(width: 400, height: 520)
        .task(id: readCount) { await load() }
        #else
        NavigationStack {
            content
                .navigationTitle("Read Receipts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .close) { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .task(id: readCount) { await load() }
        #endif
    }

    /// How many the timeline says have read the run, so the lists load again as it grows.
    private var readCount: UInt32 {
        let row = conversation.rows.lazy.compactMap(\.message).first { $0.id == message.id }
        return row?.seen?.readCount ?? 0
    }

    @ViewBuilder
    private var content: some View {
        if let receipts {
            lists(receipts)
        } else if failed {
            ContentUnavailableView {
                Label("Couldn’t Load Read Receipts", systemImage: "exclamationmark.bubble")
            } description: {
                Text("Check your connection, then try again.")
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func lists(_ receipts: ReadReceipts) -> some View {
        let read = receipts.read.filter { matches($0.reader) }
        let unread = receipts.unread.filter(matches)
        let list = List {
            Section {
                MessageSummary(message: message)
            }
            Section {
                if receipts.read.isEmpty {
                    Text("No one yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(read, id: \.reader.userId) { receipt in
                    ReceiptRow(reader: receipt.reader, detail: receipt.timestampMs.map { TimeFormat.list($0) })
                }
            } header: {
                SectionTitle(title: "Read", count: receipts.read.count)
            }
            if !receipts.unread.isEmpty {
                Section {
                    ForEach(unread, id: \.userId) { reader in
                        ReceiptRow(reader: reader, detail: nil)
                    }
                } header: {
                    SectionTitle(title: "Not Yet Read", count: receipts.unread.count)
                } footer: {
                    Text("People who keep read receipts private are listed here too.")
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
        if receipts.read.count + receipts.unread.count >= Self.searchFrom {
            list.searchable(text: $query, prompt: Text("Search People"))
        } else {
            list
        }
    }

    private func matches(_ reader: Reader) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || reader.name.localizedStandardContains(query) || reader.userId.localizedStandardContains(query)
    }

    private func load() async {
        do {
            receipts = try await conversation.readReceipts(for: message)
            failed = false
        } catch {
            // A refresh that fails keeps the lists already showing.
            if receipts == nil { failed = true }
        }
    }
}

/// The message the receipts are for: what it said, and when.
private struct MessageSummary: View {
    let message: TimelineMessage

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(Copy.preview(of: message.body, sender: String(localized: "You")))
                .lineLimit(2)
            Text(sent)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var sent: String {
        let (day, time) = TimeFormat.header(message.timestampMs)
        return time.hasPrefix(String(localized: "at")) ? "\(day) \(time)" : String(localized: "\(day) at \(time)")
    }
}

private struct SectionTitle: View {
    let title: LocalizedStringKey
    let count: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(count, format: .number)
                .monospacedDigit()
        }
    }
}

private struct ReceiptRow: View {
    let reader: Reader
    let detail: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarView(name: reader.name, seed: reader.userId, url: reader.avatarUrl, size: Theme.Metrics.memberAvatar)
            Text(reader.name)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.s)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
