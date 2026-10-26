import Foundation
import XeniaCore

/// When to search: a span back from now, or dates typed as filters.
enum SearchDate: Hashable {
    case anyTime
    case today
    case pastWeek
    case pastMonth
    case pastYear
    /// From `after` (inclusive) to `before` (exclusive); either end can be open.
    case range(after: Date?, before: Date?)

    static let presets: [SearchDate] = [.anyTime, .today, .pastWeek, .pastMonth, .pastYear]

    func bounds(now: Date, calendar: Calendar) -> (after: Date?, before: Date?) {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .anyTime: return (nil, nil)
        case .today: return (today, nil)
        case .pastWeek: return (calendar.date(byAdding: .day, value: -7, to: today), nil)
        case .pastMonth: return (calendar.date(byAdding: .month, value: -1, to: today), nil)
        case .pastYear: return (calendar.date(byAdding: .year, value: -1, to: today), nil)
        case .range(let after, let before): return (after, before)
        }
    }
}

/// The filters chosen for one conversation's search, as the filter bar shows them.
struct SearchRefinements: Equatable {
    var sender: Member?
    var mentionsMe = false
    var kinds: Set<MessageKind> = []
    var date: SearchDate = .anyTime

    var isEmpty: Bool { self == SearchRefinements() }

    func filters(now: Date = .now, calendar: Calendar = .current) -> SearchFilters {
        let (after, before) = date.bounds(now: now, calendar: calendar)
        return SearchFilters(
            senders: sender.map { [$0.userId] } ?? [],
            mentionsMe: mentionsMe,
            // A stable order, so the same choices make the same search.
            kinds: kinds.sorted { $0.order < $1.order },
            afterMs: after.map(Self.milliseconds),
            beforeMs: before.map(Self.milliseconds)
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

extension MessageKind {
    static let all: [MessageKind] = [.photo, .video, .file, .link, .audio, .poll]

    var order: Int { Self.all.firstIndex(of: self) ?? 0 }
}

/// Filters typed into the search field, as Slack and Mail take them: `from:maya`, `has:link`,
/// `@me`, `before:2024-05-01`. A finished filter (a space after it) leaves the words and becomes
/// a choice in the filter bar; Return finishes the last one too.
enum SearchSyntax {
    /// The words left and the filters with any typed ones added, or `nil` when nothing in the
    /// query is a filter. `finishing` also takes a filter at the very end (Return).
    static func absorb(
        query: String,
        into refinements: SearchRefinements,
        members: [Member],
        isDirect: Bool = false,
        finishing: Bool = false,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> (query: String, refinements: SearchRefinements)? {
        var words = query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // The word being typed isn't finished until a space follows it.
        let last = finishing ? words.count : words.count - 1
        var result = refinements
        var changed = false
        for index in words.indices.reversed() where index < last {
            guard apply(words[index], to: &result, members: members, isDirect: isDirect, now: now, calendar: calendar)
            else { continue }
            words.remove(at: index)
            changed = true
        }
        guard changed else { return nil }
        let rest = words.joined(separator: " ")
        // "lunch from:maya " leaves "lunch ", ready for the next word.
        let trimmedFront = rest.drop { $0 == " " }
        return (String(trimmedFront), result)
    }

    private static func apply(
        _ token: String,
        to refinements: inout SearchRefinements,
        members: [Member],
        isDirect: Bool,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let lower = token.lowercased()
        // A one-to-one chat has no Mentions filter: every message there is to you.
        if !isDirect, lower == "@me" || lower == "mentions:me" || lower == "is:mention" {
            refinements.mentionsMe = true
            return true
        }
        guard let colon = lower.firstIndex(of: ":") else { return false }
        let key = String(lower[..<colon])
        let value = String(token[token.index(after: colon)...])
        guard !value.isEmpty else { return false }
        switch key {
        case "from":
            guard let member = member(named: value, in: members) else { return false }
            refinements.sender = member
        case "has", "is", "type":
            guard let kind = kind(named: value.lowercased()) else { return false }
            refinements.kinds.insert(kind)
        case "before", "after", "on", "during":
            guard let day = date(value, now: now, calendar: calendar) else { return false }
            refinements.date = dateFilter(key, day: day, current: refinements.date, now: now, calendar: calendar)
        default:
            return false
        }
        return true
    }

    /// `me`, a Matrix ID with or without its server, or the start of one person's name.
    static func member(named value: String, in members: [Member]) -> Member? {
        let wanted = normalizeForSearch(text: value.hasPrefix("@") ? String(value.dropFirst()) : value)
        if wanted == "me" { return members.first(where: \.isYou) }
        if let exact = members.first(where: { member in
            let id = normalizeForSearch(text: member.userId)
            return id == "@" + wanted || id.hasPrefix("@" + wanted + ":")
        }) {
            return exact
        }
        // A name only when it picks out one person.
        let byName = members.filter { member in
            normalizeForSearch(text: member.name).split(separator: " ").contains { $0.hasPrefix(wanted) }
        }
        return byName.count == 1 ? byName[0] : nil
    }

    private static func kind(named value: String) -> MessageKind? {
        switch value {
        case "photo", "photos", "image", "images", "picture", "pictures": .photo
        case "video", "videos": .video
        case "file", "files", "document", "documents": .file
        case "link", "links", "url", "urls": .link
        case "audio", "voice", "voicemessage", "recording": .audio
        case "poll", "polls": .poll
        default: nil
        }
    }

    /// A day as `2024-05-01`, `today` or `yesterday`.
    private static func date(_ value: String, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch value.lowercased() {
        case "today": return today
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        default: break
        }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        // Typed dates are ISO dates whatever calendar the device uses.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let day = gregorian.date(from: components),
              gregorian.component(.day, from: day) == parts[2] else { return nil }
        return day
    }

    /// `before:` and `after:` keep the other end of a range already typed.
    private static func dateFilter(_ key: String, day: Date, current: SearchDate, now: Date, calendar: Calendar) -> SearchDate {
        let (after, before) = current.bounds(now: now, calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)
        // An end that would leave nothing between them gives way to the one just typed.
        switch key {
        case "before": return .range(after: after.flatMap { $0 < day ? $0 : nil }, before: day)
        case "after":
            let keepsBefore = before.map { before in nextDay.map { before > $0 } ?? true } ?? false
            return .range(after: nextDay, before: keepsBefore ? before : nil)
        default: return .range(after: day, before: nextDay)
        }
    }
}
