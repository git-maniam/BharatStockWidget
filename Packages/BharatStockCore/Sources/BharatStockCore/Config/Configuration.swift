import Foundation

/// The kind of instrument a config entry refers to.
///
/// Serialised as `"ST"` / `"MF"`. Reading is case-insensitive per spec §4; anything
/// else is rejected with a per-entry diagnostic rather than failing the whole file.
public enum InstrumentType: String, Sendable, Codable, CaseIterable {
    case stock = "ST"
    case mutualFund = "MF"

    init?(lenient raw: String) {
        self.init(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
}

/// One entry from the ordered `instruments` array.
public struct Instrument: Sendable, Equatable, Codable, Identifiable {
    public var type: InstrumentType
    public var symbol: String
    /// User-supplied short label. When present it overrides the API name verbatim (§7 rule 1).
    public var name: String?

    public var id: String { "\(type.rawValue):\(symbol)" }

    public init(type: InstrumentType, symbol: String, name: String? = nil) {
        self.type = type
        self.symbol = symbol
        self.name = name
    }
}

/// Refresh windows, expressed as wall-clock times in `timeZone`.
///
/// The spec shipped a single `time`; we now support two windows (see `docs/decisions.md` §2).
/// A legacy single `time` string still decodes, so old files keep working.
public struct RefreshSettings: Sendable, Equatable {
    public var times: [DayTime]
    public var timeZoneIdentifier: String
    public var maxRequestsPerDay: Int

    public static let `default` = RefreshSettings(
        times: [DayTime(hour: 10, minute: 30), DayTime(hour: 21, minute: 30)],
        timeZoneIdentifier: "Asia/Kolkata",
        maxRequestsPerDay: 50
    )

    public init(times: [DayTime], timeZoneIdentifier: String, maxRequestsPerDay: Int) {
        self.times = times
        self.timeZoneIdentifier = timeZoneIdentifier
        self.maxRequestsPerDay = maxRequestsPerDay
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? DayTime.indiaStandardTime
    }
}

/// An hour-and-minute wall-clock time, with no date or zone of its own.
public struct DayTime: Sendable, Equatable, Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    /// India has no DST, so IST is a fixed UTC+05:30 anchor (spec §5).
    public static let indiaStandardTime = TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60)!

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Parses `"HH:mm"`. Returns nil for anything out of range so the caller can emit a diagnostic.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public var minutesFromMidnight: Int { hour * 60 + minute }

    public var formatted: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: DayTime, rhs: DayTime) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }
}

/// Presentation knobs from the `display` object.
public struct DisplaySettings: Sendable, Equatable {
    public var currencySymbol: String
    public var maxNameLength: Int
    public var showChangePercent: Bool
    /// Decimal places for stock prices. NAV always uses 4 per AMFI convention (§7).
    public var decimalPlaces: Int

    public static let `default` = DisplaySettings(
        currencySymbol: "₹",
        maxNameLength: 18,
        showChangePercent: true,
        decimalPlaces: 2
    )

    public init(currencySymbol: String, maxNameLength: Int, showChangePercent: Bool, decimalPlaces: Int) {
        self.currencySymbol = currencySymbol
        self.maxNameLength = maxNameLength
        self.showChangePercent = showChangePercent
        self.decimalPlaces = decimalPlaces
    }
}

/// The user's whole configuration, after permissive parsing.
public struct Configuration: Sendable, Equatable {
    public static let currentSchemaVersion = 1

    /// Rows beyond this index are parsed and kept but never rendered (§4, §7).
    public static let maxRenderableInstruments = 15

    public var schemaVersion: Int
    /// Plaintext by design (§2). Never log, cache, or display this.
    public var apiKey: String
    public var refresh: RefreshSettings
    public var display: DisplaySettings
    public var instruments: [Instrument]

    public init(
        schemaVersion: Int = Configuration.currentSchemaVersion,
        apiKey: String,
        refresh: RefreshSettings = .default,
        display: DisplaySettings = .default,
        instruments: [Instrument]
    ) {
        self.schemaVersion = schemaVersion
        self.apiKey = apiKey
        self.refresh = refresh
        self.display = display
        self.instruments = instruments
    }

    /// Shipped on first run. The key is deliberately empty: the owner rotates the spec's key,
    /// and the setup screen collects the replacement (see `docs/decisions.md` §2).
    ///
    /// Scheme codes here are the *verified* ones — the spec's `120503` is Axis ELSS Tax Saver,
    /// not Parag Parikh Flexi Cap.
    public static let starter = Configuration(
        apiKey: "",
        instruments: [
            Instrument(type: .stock, symbol: "RELIANCE", name: "Reliance Industries"),
            Instrument(type: .stock, symbol: "TCS"),
            Instrument(type: .stock, symbol: "HDFCBANK", name: "HDFC Bank"),
            Instrument(type: .mutualFund, symbol: "122639", name: "Parag Parikh Flexi Cap"),
            Instrument(type: .mutualFund, symbol: "120828", name: "Quant Small Cap Fund"),
        ]
    )

    /// Deduplicated, truncated to what any widget size could render. This is the fetch set.
    ///
    /// Dedup is by `type` + `symbol` (§5: "If the user lists RELIANCE twice, fetch it once"),
    /// keeping the first occurrence so config order is preserved.
    public var renderableInstruments: [Instrument] {
        var seen = Set<String>()
        var result: [Instrument] = []
        for instrument in instruments where seen.insert(instrument.id).inserted {
            result.append(instrument)
            if result.count == Configuration.maxRenderableInstruments { break }
        }
        return result
    }
}
