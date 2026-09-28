import Foundation
import Testing
@testable import BharatStockCore

@Suite("Number and date formatting")
struct NumberFormattingTests {
    @Test("Grouping follows the Indian lakh/crore convention")
    func indianGrouping() {
        #expect(NumberFormatting.price(123456.78) == "1,23,456.78")
        #expect(NumberFormatting.price(12345678.9) == "1,23,45,678.90")
        #expect(NumberFormatting.price(1226.0) == "1,226.00")
        #expect(NumberFormatting.price(735.6) == "735.60")
    }

    @Test("Stocks use two decimal places and NAV uses four")
    func decimalPlaces() {
        #expect(NumberFormatting.price(2860.1) == "2,860.10")
        #expect(NumberFormatting.nav(108.1525) == "108.1525")
        // A NAV with fewer published digits is still padded to the AMFI convention.
        #expect(NumberFormatting.nav(78.43) == "78.4300")
        #expect(NumberFormatting.price(2860.149, decimals: 0) == "2,860")
    }

    @Test("The compact range drops decimals for the Small size")
    func compactRange() {
        #expect(NumberFormatting.compactRange(low: 2812.40, high: 2877.95) == "2,812–2,878")
        #expect(NumberFormatting.range(low: 2812.40, high: 2877.95) == "2,812.40 – 2,877.95")
        #expect(NumberFormatting.compactRange(low: nil, high: 2877.95) == nil)
        #expect(NumberFormatting.range(low: 2812.40, high: nil) == nil)
    }

    @Test("Change is unsigned text paired with a direction glyph")
    func changeAndGlyph() {
        #expect(NumberFormatting.changePercent(0.71) == "0.71%")
        #expect(NumberFormatting.changePercent(-0.24) == "0.24%")
        #expect(NumberFormatting.directionGlyph(0.71) == "▲")
        #expect(NumberFormatting.directionGlyph(-0.24) == "▼")
        #expect(NumberFormatting.directionGlyph(0) == "→")
        #expect(NumberFormatting.directionGlyph(nil) == "·")
    }

    /// Regression test for a bug caught during development: `en_IN` is a 12-hour locale, so
    /// `.hour(.twoDigits(amPM: .omitted))` renders 21:30 as "09:30" — silently twelve hours out.
    @Test("An evening IST time renders as 21:30, not 09:30")
    func eveningClockIsTwentyFourHour() {
        #expect(NumberFormatting.istClockTime(Instant.ist(2026, 9, 28, 21, 30)) == "21:30 IST")
        #expect(NumberFormatting.istClockTime(Instant.ist(2026, 9, 28, 10, 30)) == "10:30 IST")
        #expect(NumberFormatting.istClockTime(Instant.ist(2026, 9, 28, 0, 5)) == "00:05 IST")
        #expect(NumberFormatting.istClockTime(Instant.ist(2026, 9, 28, 12, 0)) == "12:00 IST")
    }

    @Test("Market dates are parsed and rendered in IST, so they never shift by a day")
    func marketDates() {
        #expect(NumberFormatting.shortMarketDate("2026-09-25") == "25 Sep")
        #expect(NumberFormatting.shortMarketDate("2026-01-01") == "1 Jan")
        #expect(NumberFormatting.shortMarketDate("garbage") == nil)
        #expect(NumberFormatting.shortMarketDate("2026-09") == nil)

        // Midnight IST on the 25th is 18:30 UTC on the 24th. Formatting in the machine's zone
        // would show "24 Sep" for anyone west of India; this must not.
        let parsed = NumberFormatting.marketDate("2026-09-25")
        #expect(parsed == Instant.ist(2026, 9, 25, 0, 0))
        #expect(NumberFormatting.shortDate(parsed!) == "25 Sep")
    }

    @Test("Relative ages read naturally")
    func relativeAges() {
        let now = Instant.ist(2026, 9, 28, 12, 0)
        #expect(NumberFormatting.relativeAge(of: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(NumberFormatting.relativeAge(of: now.addingTimeInterval(-120), now: now) == "2m ago")
        #expect(NumberFormatting.relativeAge(of: now.addingTimeInterval(-7200), now: now) == "2h ago")
        #expect(NumberFormatting.relativeAge(of: now.addingTimeInterval(-90000), now: now) == "yesterday")
        #expect(NumberFormatting.relativeAge(of: now.addingTimeInterval(-300000), now: now) == "3d ago")
    }

    @Test("ISO-8601 round-trips, and the API's fractional form parses")
    func iso8601() {
        let date = Instant.ist(2026, 9, 28, 10, 30)
        let text = JSONCoding.iso8601String(date)
        #expect(text == "2026-09-28T05:00:00Z")
        #expect(JSONCoding.parseISO8601(text) == date)

        // Shapes the API actually returns.
        #expect(JSONCoding.parseISO8601("2026-09-25T16:15:47.009186+00:00") != nil)
        #expect(JSONCoding.parseISO8601("2026-09-28T05:00:12Z") != nil)
        #expect(JSONCoding.parseISO8601("not a date") == nil)
    }

    @Test("The API key is redacted to twelve characters, and scrubbed from free text")
    func redaction() {
        let key = "bsk_live_REDACTED_SEE_docs_decisions_md"
        #expect(Redaction.apiKey(key) == "bsk_live_0Rs…")
        #expect(Redaction.apiKey("") == "(unset)")
        #expect(Redaction.apiKey("short") == "…")

        // The full key must never survive a trip through a log line.
        let message = "GET /v1/stocks/RELIANCE key=\(key) failed"
        let scrubbed = Redaction.scrub(message, key: key)
        #expect(!scrubbed.contains(key))
        #expect(scrubbed.contains("bsk_live_0Rs…"))

        // Even a key we were never told about — e.g. echoed back in an API error body.
        let foreign = Redaction.scrub("rejected token bsk_live_SomeOtherKeyEntirely123", key: "")
        #expect(!foreign.contains("SomeOtherKeyEntirely123"))
    }
}
