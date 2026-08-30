import Foundation

/// Date rendering for the conversation list and the transcript.
///
/// The formatters are cached. A scrolling list asks for a string once per row
/// per update, and building a `DateFormatter` each time is one of the classic
/// ways to make a list stutter. The cache rebuilds itself when the locale,
/// calendar, or time zone changes, so it stays correct across a trip abroad or
/// a settings change without anyone having to remember to invalidate it.
///
/// Everything here is main-actor isolated, which is the module default and also
/// where every caller lives.
enum Formatters {

    // MARK: - Conversation list

    /// The short stamp on a conversation row.
    ///
    /// "now" under a minute, "3m" under an hour, a clock time for the rest of
    /// today, "Yesterday", a weekday inside the last week, and a numeric date
    /// beyond that. Dates in the future read as "now": a clock that is a few
    /// seconds ahead of ours is not worth a strange-looking cell.
    static func listTimestamp(_ date: Date, now: Date = Date()) -> String {
        let calendar = cache.calendar
        let interval = now.timeIntervalSince(date)

        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return cache.time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if daysApart(date, now, calendar: calendar) < 7 { return cache.weekday.string(from: date) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return cache.shortDate.string(from: date)
        }
        return cache.shortDateWithYear.string(from: date)
    }

    // MARK: - Transcript

    /// The heading above the first message of a day: "Today", "Yesterday",
    /// "Tuesday" inside the last week, then a written-out date.
    static func dayHeader(_ date: Date, now: Date = Date()) -> String {
        let calendar = cache.calendar
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if daysApart(date, now, calendar: calendar) < 7 { return cache.fullWeekday.string(from: date) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return cache.longDate.string(from: date)
        }
        return cache.longDateWithYear.string(from: date)
    }

    /// The clock time shown under the last bubble of a run.
    static func messageTime(_ date: Date) -> String {
        cache.time.string(from: date)
    }

    // MARK: - VoiceOver

    /// A spoken-language stamp. Abbreviations like "3m" read badly aloud, so
    /// anything with a visible short form needs one of these beside it.
    static func spokenTimestamp(_ date: Date, now: Date = Date()) -> String {
        let calendar = cache.calendar
        let interval = now.timeIntervalSince(date)

        if interval < 60 { return "just now" }
        if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        if calendar.isDate(date, inSameDayAs: now) { return cache.time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "yesterday at \(cache.time.string(from: date))" }
        if daysApart(date, now, calendar: calendar) < 7 {
            return "\(cache.fullWeekday.string(from: date)) at \(cache.time.string(from: date))"
        }
        return "\(cache.longDateWithYear.string(from: date)) at \(cache.time.string(from: date))"
    }

    /// A whole-day description for the day separator, which otherwise reads as
    /// a bare word floating between messages.
    static func spokenDayHeader(_ date: Date, now: Date = Date()) -> String {
        dayHeader(date, now: now)
    }

    // MARK: - Internals

    /// Whole days between two instants, measured from midnight to midnight so
    /// that 11pm and 1am are one day apart rather than two hours.
    private static func daysApart(_ earlier: Date, _ later: Date, calendar: Calendar) -> Int {
        let from = calendar.startOfDay(for: earlier)
        let to = calendar.startOfDay(for: later)
        return calendar.dateComponents([.day], from: from, to: to).day ?? .max
    }

    private static var storage = FormatterCache()

    /// Returns the cache, rebuilding it first if the user's regional settings
    /// have moved underneath us.
    private static var cache: FormatterCache {
        if storage.isStale { storage = FormatterCache() }
        return storage
    }
}

/// One generation of formatters, all built against the same locale, calendar,
/// and time zone.
private struct FormatterCache {
    let locale: Locale
    let calendar: Calendar
    let timeZone: TimeZone

    let time: DateFormatter
    let weekday: DateFormatter
    let fullWeekday: DateFormatter
    let shortDate: DateFormatter
    let shortDateWithYear: DateFormatter
    let longDate: DateFormatter
    let longDateWithYear: DateFormatter

    init() {
        // Snapshots, not the autoupdating singletons: `DateFormatter` bakes in
        // its format on first use, so a cache generation has to be pinned to
        // the settings it was built against and replaced when they move.
        let locale = Locale.current
        let calendar = Calendar.current
        let timeZone = TimeZone.current
        self.locale = locale
        self.calendar = calendar
        self.timeZone = timeZone

        func make(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }

        // Templates rather than literal patterns: "jmm" is 9:41 AM in the US
        // and 09:41 in most of Europe, which is the whole point.
        time = make("jmm")
        weekday = make("EEE")
        fullWeekday = make("EEEE")
        shortDate = make("Md")
        shortDateWithYear = make("Mdyy")
        longDate = make("MMMMd")
        longDateWithYear = make("MMMMdyyyy")
    }

    var isStale: Bool {
        locale != Locale.current
            || calendar != Calendar.current
            || timeZone != TimeZone.current
    }
}
