import XeniaCore
import SwiftUI

/// People to mention, as you type "@" and their name.
struct MentionSuggestions: View {
    let members: [Member]
    let query: String
    let pick: (Member) -> Void

    static func matches(_ members: [Member], _ query: String) -> [Member] {
        // Comparing with the cached list is quick: an unchanged array shares its storage.
        if index?.members != members { index = MentionIndex(members) }
        return index?.matches(query) ?? []
    }

    /// The conversation's members, ready to match.
    private static var index: MentionIndex?

    var body: some View {
        let matches = Self.matches(members, query)
        if !matches.isEmpty {
            VStack(spacing: 0) {
                ForEach(matches, id: \.userId) { member in
                    Button { pick(member) } label: {
                        HStack(spacing: Theme.Spacing.s) {
                            AvatarView(name: member.name, seed: member.userId, url: member.avatarUrl, size: 26)
                            Text(member.name).lineLimit(1)
                            Text(member.userId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Spacing.m)
                        .frame(minHeight: Theme.Metrics.minTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if member.userId != matches.last?.userId {
                        Divider().padding(.leading, 26 + Theme.Spacing.m + Theme.Spacing.s)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
        }
    }
}

/// Members' names and IDs normalized once per member list, since each normalization goes through
/// the core and a big room has thousands of members; and the last answer, since the view asks
/// again on every pass while the query stays the same.
private final class MentionIndex {
    private struct Entry {
        let member: Member
        let name: String
        let userID: Substring
    }

    let members: [Member]
    private let entries: [Entry]
    private var last: (query: String, matches: [Member])?

    init(_ members: [Member]) {
        self.members = members
        entries = members.filter { !$0.isYou }.map { member in
            // "@maya:example.org" matches from "maya".
            Entry(member: member, name: normalizeForSearch(text: member.name), userID: normalizeForSearch(text: member.userId).dropFirst())
        }
    }

    func matches(_ query: String) -> [Member] {
        if let last, last.query == query { return last.matches }
        let q = normalizeForSearch(text: query)
        let found: [Member] = q.isEmpty
            ? entries.prefix(5).map(\.member)
            : Array(entries.lazy.filter { entry in
                entry.name.split(separator: " ").contains { $0.hasPrefix(q) } || entry.name.hasPrefix(q) || entry.userID.hasPrefix(q)
            }.prefix(5).map(\.member))
        last = (query, found)
        return found
    }
}
