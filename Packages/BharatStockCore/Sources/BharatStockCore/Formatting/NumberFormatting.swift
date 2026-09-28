import Foundation

/// Number formatting for the widget (§7).
///
/// Grouping follows the Indian lakh/crore convention — `1,23,456.78`, not `123,456.78` — by
/// pinning the locale to `en_IN` rather than trusting the user's locale, because the numbers are
/// Indian market prices whatever the machine is set to.
///
/// Uses `FormatStyle` rather than the `NumberFormatter` the spec names: both draw grouping from the
/// same ICU data, but `NumberFormatter` is a non-`Sendable` class and cannot be shared safely under
/// strict concurrency.
public enum NumberFormatting {
    public static let indianLocale = Locale(identifier: "en_IN")

    /// §7: stock prices at `display.decimalPlaces` (2 by default).
    public static func price(_ value: Double, decimals: Int = 2) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(decimals))
                .grouping(.automatic)
                .locale(indianLocale)
        )
    }

    /// §7: NAV always at four decimal places, per AMFI convention.
    public static func nav(_ value: Double) -> String {
        price(value, decimals: 4)
    }

    /// The session range in full, e.g. `2,812.40 – 2,877.95`.
    public static func range(low: Double?, high: Double?, decimals: Int = 2) -> String? {
        guard let low, let high else { return nil }
        return "\(price(low, decimals: decimals)) – \(price(high, decimals: decimals))"
    }

    /// §7: at Small, space permits only one number — `2,812–2,878`, no decimals.
    public static func compactRange(low: Double?, high: Double?) -> String? {
        guard let low, let high else { return nil }
        return "\(price(low.rounded(), decimals: 0))–\(price(high.rounded(), decimals: 0))"
    }

    /// Signed change, e.g. `0.71%`. The sign is carried by the glyph, not a `+`/`-`,
    /// so the two never disagree.
    public static func changePercent(_ value: Double, decimals: Int = 2) -> String {
        "\(price(abs(value), decimals: decimals))%"
    }

    /// §7: colour is never the sole carrier of meaning, so every change gets a glyph.
    /// Deuteranopia-safe because the shape differs, not just the hue.
    public static func directionGlyph(_ value: Double?) -> String {
        guard let value else { return "·" }
        if value > 0 { return "▲" }
        if value < 0 { return "▼" }
        return "→"
    }

    /// `"2026-09-25"` → `"25 Sep"`, for the `NAV · 26 Sep` label of §7.
    ///
    /// Formats in IST: these are market calendar dates, and rendering them in the machine's zone
    /// would shift them by a day for anyone west of India.
    public static func shortMarketDate(_ isoDate: String) -> String? {
        guard let date = marketDate(isoDate) else { return nil }
        return shortDate(date)
    }

    /// `"25 Sep"` for an instant, in IST.
    public static func shortDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(locale: indianLocale, timeZone: DayTime.indiaStandardTime)
                .day().month(.abbreviated)
        )
    }

    /// `"Fri 25 Sep"`, for the explicit stale footer of §7.
    public static func weekdayAndShortDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(locale: indianLocale, timeZone: DayTime.indiaStandardTime)
                .weekday(.abbreviated).day().month(.abbreviated)
        )
    }

    /// Parses a bare `yyyy-MM-dd` market date as midnight IST.
    public static func marketDate(_ isoDate: String) -> Date? {
        let parts = isoDate.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = DayTime.indiaStandardTime

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DayTime.indiaStandardTime
        return calendar.date(from: components)
    }

    /// `"21:30 IST"`.
    ///
    /// Uses a verbatim 24-hour style rather than `.hour(.twoDigits(amPM: .omitted))`, which is a
    /// trap: `en_IN` is a 12-hour locale, so omitting the AM/PM marker renders 21:30 as "09:30" —
    /// off by twelve hours, and silently so. A verbatim style is locale-independent.
    public static func istClockTime(_ date: Date) -> String {
        "\(verbatimClock(date, timeZone: DayTime.indiaStandardTime)) IST"
    }

    /// 24-hour `HH:mm` in the machine's own zone, for the local half of the footer.
    public static func localClockTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        verbatimClock(date, timeZone: timeZone)
    }

    private static func verbatimClock(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return date.formatted(
            Date.VerbatimFormatStyle(
                format: """
                    \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
                    """,
                timeZone: timeZone,
                calendar: calendar
            )
        )
    }

    /// `"2m ago"`, `"3h ago"`, `"Fri"` — a compact age for the footer.
    public static func relativeAge(of date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        let days = Int(seconds / 86_400)
        return days == 1 ? "yesterday" : "\(days)d ago"
    }
}
