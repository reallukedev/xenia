import XeniaCore
import Foundation

/// Timestamps written the way Messages writes them.
enum TimeFormat {
    private static var calendar: Calendar { .autoupdatingCurrent }

    private static func days(from date: Date, to now: Date) -> Int {
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: start, to: today).day ?? 0
    }

    static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    /// A conversation row: "9:41 AM", "Yesterday", "Tuesday", then "9/12/26".
    static func list(_ ms: Int64, now: Date = .now) -> String {
        guard ms > 0 else { return "" }
        let then = date(ms)
        switch days(from: then, to: now) {
        case ...0: return then.formatted(date: .omitted, time: .shortened)
        case 1: return String(localized: "Yesterday")
        case 2..<7: return then.formatted(.dateTime.weekday(.wide))
        default: return then.formatted(date: .numeric, time: .omitted)
        }
    }

    /// The header above a sitting: ("Today", "9:41 AM"), ("Tuesday", "8:15 AM"),
    /// ("Tue, Sep 12", "at 9:41 AM"), with the year when it isn't this year.
    static func header(_ ms: Int64, now: Date = .now) -> (day: String, time: String) {
        let then = date(ms)
        let time = then.formatted(date: .omitted, time: .shortened)
        switch days(from: then, to: now) {
        case ...0: return (String(localized: "Today"), time)
        case 1: return (String(localized: "Yesterday"), time)
        case 2..<7: return (then.formatted(.dateTime.weekday(.wide)), time)
        default:
            let sameYear = calendar.isDate(then, equalTo: now, toGranularity: .year)
            let day = sameYear
                ? then.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                : then.formatted(.dateTime.month(.abbreviated).day().year())
            return (day, String(localized: "at \(time)"))
        }
    }

    /// "9:41 AM", for a message's own time.
    static func clock(_ ms: Int64) -> String {
        date(ms).formatted(date: .omitted, time: .shortened)
    }

    /// Compact, for thread summaries: "Now", "2m", "3h", then like the list.
    static func relative(_ ms: Int64, now: Date = .now) -> String {
        let then = date(ms)
        let minutes = Int(now.timeIntervalSince(then) / 60)
        if minutes < 1 { return String(localized: "Now") }
        if minutes < 60 { return String(localized: "\(minutes)m") }
        let hours = minutes / 60
        if hours < 24 && days(from: then, to: now) == 0 { return String(localized: "\(hours)h") }
        return list(ms, now: now)
    }
}
