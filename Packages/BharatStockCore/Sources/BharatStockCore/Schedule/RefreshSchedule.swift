import Foundation

/// The daily refresh windows, expressed in a fixed market zone.
///
/// The spec originally drove these through `launchd` `StartCalendarInterval`, which fires in the
/// machine's local time and therefore had to be rewritten on every time-zone change. Because the
/// widget now schedules itself, all reasoning happens in absolute `Date` instants computed from
/// IST wall-clock times, so travel and the user's own DST transitions need no special handling:
/// 21:30 IST is the same instant everywhere.
public struct RefreshSchedule: Sendable, Equatable {
    public let times: [DayTime]
    public let timeZone: TimeZone

    public init(times: [DayTime], timeZone: TimeZone) {
        // Sorted and deduplicated so boundary maths can assume ascending order.
        self.times = Array(Set(times)).sorted()
        self.timeZone = timeZone
    }

    public init(_ settings: RefreshSettings) {
        self.init(times: settings.times, timeZone: settings.timeZone)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The window instants that fall on the market-zone calendar day containing `date`.
    public func boundaries(onDayOf date: Date) -> [Date] {
        let calendar = self.calendar
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return times.compactMap { time in
            var components = DateComponents()
            components.year = day.year
            components.month = day.month
            components.day = day.day
            components.hour = time.hour
            components.minute = time.minute
            components.second = 0
            components.timeZone = timeZone
            return calendar.date(from: components)
        }
    }

    /// The latest window boundary at or before `now`, looking back into previous days if needed.
    ///
    /// Never nil for a non-empty schedule: the search walks back a bounded number of days, which
    /// is enough for any real gap, and any schedule with at least one time has a boundary yesterday.
    public func mostRecentBoundary(at now: Date) -> Date? {
        guard !times.isEmpty else { return nil }
        let calendar = self.calendar
        for dayOffset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            if let boundary = boundaries(onDayOf: day).last(where: { $0 <= now }) {
                return boundary
            }
        }
        return nil
    }

    /// The first window boundary strictly after `now`. Used for the timeline reload request.
    public func nextBoundary(after now: Date) -> Date? {
        guard !times.isEmpty else { return nil }
        let calendar = self.calendar
        for dayOffset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            if let boundary = boundaries(onDayOf: day).first(where: { $0 > now }) {
                return boundary
            }
        }
        return nil
    }

    /// Midnight in the market zone at or before `now`. The budget window rolls here (§5).
    public func mostRecentMarketMidnight(at now: Date) -> Date {
        calendar.startOfDay(for: now)
    }

    /// The market-zone calendar date of `now`, as `yyyy-MM-dd`.
    /// Used to decide whether a NAV date is genuinely "today" (§6).
    public func marketDateString(at now: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
