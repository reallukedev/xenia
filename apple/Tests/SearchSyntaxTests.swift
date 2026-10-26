import Foundation
import XeniaCore
import Testing
@testable import Xenia

@Suite("Typed search filters")
struct SearchSyntaxTests {
    private static func member(_ name: String, _ userID: String, isYou: Bool = false) -> Member {
        Member(userId: userID, name: name, avatarUrl: nil, isInvited: false, isAdmin: false, isYou: isYou)
    }

    private static let luke = member("Luke", "@luke:example.org", isYou: true)
    private static let maya = member("Maya Lin", "@maya:example.org")
    private static let mark = member("Mark Okafor", "@mark:example.org")
    private static let members = [luke, maya, mark]

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    /// 26 October 2026, mid-afternoon.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15))!

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static func absorb(_ query: String, finishing: Bool = false, into refinements: SearchRefinements = SearchRefinements())
        -> (query: String, refinements: SearchRefinements)? {
        SearchSyntax.absorb(query: query, into: refinements, members: members, finishing: finishing, now: now, calendar: calendar)
    }

    @Test("A finished filter leaves the words; the word being typed stays until it's finished")
    func finishing() throws {
        #expect(Self.absorb("lunch from:maya") == nil)
        let typed = try #require(Self.absorb("lunch from:maya "))
        #expect(typed.query == "lunch ")
        #expect(typed.refinements.sender == Self.maya)
        let submitted = try #require(Self.absorb("from:maya", finishing: true))
        #expect(submitted.query == "")
        #expect(submitted.refinements.sender == Self.maya)
    }

    @Test("From takes me, an ID with or without its server, or a name that picks out one person", arguments: [
        ("from:me", "@luke:example.org"),
        ("from:@mark:example.org", "@mark:example.org"),
        ("from:mark", "@mark:example.org"),
        ("from:lin", "@maya:example.org"),
        ("from:okaf", "@mark:example.org"),
    ])
    func from(token: String, expected: String) throws {
        let result = try #require(Self.absorb(token + " "))
        #expect(result.refinements.sender?.userId == expected)
    }

    @Test("A name shared by several people, or nobody's, stays as words", arguments: ["from:ma ", "from:zed ", "from: "])
    func ambiguousFrom(query: String) {
        #expect(Self.absorb(query) == nil)
    }

    @Test("Kinds add up, under any of their usual names")
    func kinds() throws {
        let result = try #require(Self.absorb("has:links is:photos type:voice x"))
        #expect(result.refinements.kinds == [.link, .photo, .audio])
        #expect(result.query == "x")
        #expect(Self.absorb("has:spreadsheet ") == nil)
    }

    @Test("Mentions of me")
    func mentions() throws {
        #expect(try #require(Self.absorb("@me ")).refinements.mentionsMe)
        #expect(try #require(Self.absorb("mentions:me ")).refinements.mentionsMe)
    }

    @Test("Dates: on a day, before, after, and both making a range")
    func dates() throws {
        let on = try #require(Self.absorb("on:2024-05-01 ")).refinements.date
        #expect(on == .range(after: Self.day(2024, 5, 1), before: Self.day(2024, 5, 2)))

        let after = try #require(Self.absorb("after:2024-05-01 ")).refinements
        let both = try #require(Self.absorb("before:2024-06-01 ", into: after)).refinements.date
        #expect(both == .range(after: Self.day(2024, 5, 2), before: Self.day(2024, 6, 1)))

        let yesterday = try #require(Self.absorb("on:yesterday ")).refinements.date
        #expect(yesterday == .range(after: Self.day(2026, 10, 25), before: Self.day(2026, 10, 26)))
    }

    @Test("Mentions of me don't apply in a one-to-one chat, where everything is to you")
    func mentionsInDirectChat() {
        #expect(SearchSyntax.absorb(query: "@me ", into: SearchRefinements(), members: Self.members, isDirect: true) == nil)
    }

    @Test("A later date that would leave an empty range replaces the other end")
    func invertedRange() throws {
        let before = try #require(Self.absorb("before:2024-05-01 ")).refinements
        let after = try #require(Self.absorb("after:2024-06-01 ", into: before)).refinements.date
        #expect(after == .range(after: Self.day(2024, 6, 2), before: nil))
    }

    @Test("Typed dates are ISO dates on any calendar")
    func otherCalendars() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = Self.calendar.timeZone
        let result = try #require(SearchSyntax.absorb(
            query: "on:2024-05-01 ", into: SearchRefinements(), members: Self.members, now: Self.now, calendar: buddhist
        ))
        #expect(result.refinements.date == .range(after: Self.day(2024, 5, 1), before: Self.day(2024, 5, 2)))
    }

    @Test("Days that don't exist stay as words", arguments: ["on:2024-02-30 ", "before:2024-13-01 ", "after:soon "])
    func invalidDates(query: String) {
        #expect(Self.absorb(query) == nil)
    }

    @Test("Refinements become the core's filters, with dates as the start of each day")
    func filters() {
        var refinements = SearchRefinements(sender: Self.maya, mentionsMe: true, kinds: [.poll, .photo], date: .pastWeek)
        var filters = refinements.filters(now: Self.now, calendar: Self.calendar)
        #expect(filters.senders == ["@maya:example.org"])
        #expect(filters.mentionsMe)
        #expect(filters.kinds == [.photo, .poll])
        #expect(filters.afterMs == Int64(Self.day(2026, 10, 19).timeIntervalSince1970 * 1000))
        #expect(filters.beforeMs == nil)

        refinements = SearchRefinements()
        filters = refinements.filters(now: Self.now, calendar: Self.calendar)
        #expect(filters.isEmpty)
    }
}
