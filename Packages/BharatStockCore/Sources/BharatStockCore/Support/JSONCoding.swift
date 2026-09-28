import Foundation

/// One shared JSON convention for every file the product writes.
///
/// All timestamps are ISO-8601 in UTC with a `Z` suffix, matching the schemas in spec §5 and §6.
/// Files are pretty-printed with sorted keys: they are user-inspectable, and stable key order
/// keeps diffs readable when someone version-controls their config.
public enum JSONCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601String(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseISO8601(text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an ISO-8601 UTC timestamp, got \"\(text)\""
                ))
            }
            return date
        }
        return decoder
    }()

    // `ISO8601DateFormatter` is a non-Sendable class and cannot be a shared `static let` under
    // strict concurrency. `Date.ISO8601FormatStyle` is a value type, so it can.
    private static let plainStyle = Date.ISO8601FormatStyle(timeZone: .gmt)
    private static let fractionalStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true, timeZone: .gmt
    )

    public static func iso8601String(_ date: Date) -> String {
        date.formatted(plainStyle)
    }

    /// Parses the timestamp shapes this product actually meets.
    ///
    /// Our own files use `2026-09-28T05:00:12Z`, but the API mixes in a `+00:00` offset and
    /// microsecond precision (`/v1/status` returns `2026-09-25T16:15:47.009186+00:00`), neither of
    /// which `ISO8601FormatStyle` accepts. Normalising first is cheaper than hand-rolling a parser
    /// and keeps one code path for both.
    public static func parseISO8601(_ text: String) -> Date? {
        let normalised = normalise(text)
        if let date = try? fractionalStyle.parse(normalised) { return date }
        return try? plainStyle.parse(normalised)
    }

    /// Forces a literal `Z` zone and exactly three fractional digits.
    private static func normalise(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip an explicit zero offset in favour of `Z`. A non-zero offset is left alone; the
        // parse then fails and the caller gets nil, which is the honest outcome — we have no
        // business guessing at a zone we did not expect.
        for suffix in ["+00:00", "-00:00", "+0000", "-0000"] where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count)) + "Z"
            break
        }
        guard body.hasSuffix("Z") else { return body }

        guard let dot = body.firstIndex(of: ".") else {
            // No fraction at all: give it one, so a single style handles every input.
            return String(body.dropLast()) + ".000Z"
        }
        let digits = body[body.index(after: dot)..<body.index(before: body.endIndex)]
        let padded = digits.count >= 3
            ? String(digits.prefix(3))
            : digits + String(repeating: "0", count: 3 - digits.count)
        return String(body[body.startIndex..<dot]) + "." + padded + "Z"
    }
}
