import Foundation

/// Creates and updates `config.json`, plus the two explanatory files that sit beside it (§4, §9).
///
/// Writing is hand-rolled rather than `Codable`-generated so key order matches the documentation
/// the user is reading, and so a file created by this app looks like the one in the README.
public struct ConfigWriter: Sendable {
    private let store: FileStore

    public init(store: FileStore = FileStore()) {
        self.store = store
    }

    // MARK: - Creating

    /// Writes `config.json` at mode 0600 if it does not already exist, and always refreshes the
    /// sibling `config.example.json` and `README.txt`.
    ///
    /// Never overwrites an existing config: a user who has spent time curating a watchlist should
    /// not lose it to a reinstall.
    @discardableResult
    public func bootstrap(
        at paths: AppPaths,
        configuration: Configuration = .starter
    ) throws -> BootstrapResult {
        try store.ensureDirectory(paths.root)
        try store.ensureDirectory(paths.cacheDirectory)

        let created = !store.exists(paths.config)
        if created {
            try write(configuration, to: paths.config)
        } else {
            // §2: re-assert 0600 on a file that already exists.
            store.enforceOwnerOnly(paths.config)
        }

        try store.writeAtomically(Data(Self.exampleJSON.utf8), to: paths.configExample)
        try store.writeAtomically(Data(Self.readmeText.utf8), to: paths.configReadme)

        return BootstrapResult(createdConfig: created, configURL: paths.config)
    }

    public struct BootstrapResult: Sendable, Equatable {
        public var createdConfig: Bool
        public var configURL: URL
    }

    /// Serialises a configuration and writes it at mode 0600.
    public func write(_ configuration: Configuration, to url: URL) throws {
        try store.writeAtomically(
            Data(Self.serialise(configuration).utf8), to: url, mode: FileStore.ownerOnly
        )
    }

    /// Replaces only the `apiKey` field, leaving every other byte of the user's file alone.
    ///
    /// A full rewrite would discard formatting, comments-by-convention and any forward-compatible
    /// keys the user has added, so the key is patched in place instead.
    public func updateAPIKey(_ key: String, in url: URL) throws {
        guard store.exists(url) else { throw ConfigWriteError.configMissing(url.path) }
        let original = try String(decoding: store.read(url), as: UTF8.self)

        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let patched: String
        if let range = original.range(
            of: "\"apiKey\"\\s*:\\s*\"[^\"]*\"", options: .regularExpression
        ) {
            patched = original.replacingCharacters(in: range, with: "\"apiKey\": \"\(escaped)\"")
        } else if let brace = original.firstIndex(of: "{") {
            patched = original.replacingCharacters(
                in: brace...brace, with: "{\n  \"apiKey\": \"\(escaped)\","
            )
        } else {
            throw ConfigWriteError.unpatchable(url.path)
        }

        try store.writeAtomically(Data(patched.utf8), to: url, mode: FileStore.ownerOnly)
    }

    // MARK: - Serialisation

    static func serialise(_ configuration: Configuration) -> String {
        let instruments = configuration.instruments.map { instrument -> String in
            let name = instrument.name.map { ", \"name\": \"\($0)\"" } ?? ""
            return "    { \"type\": \"\(instrument.type.rawValue)\", "
                + "\"symbol\": \"\(instrument.symbol)\"\(name) }"
        }

        return """
        {
          "schemaVersion": \(configuration.schemaVersion),
          "apiKey": "\(configuration.apiKey)",
          "refresh": {
            "times": [\(configuration.refresh.times.map { "\"\($0.formatted)\"" }.joined(separator: ", "))],
            "timeZone": "\(configuration.refresh.timeZoneIdentifier)",
            "maxRequestsPerDay": \(configuration.refresh.maxRequestsPerDay)
          },
          "display": {
            "currencySymbol": "\(configuration.display.currencySymbol)",
            "maxNameLength": \(configuration.display.maxNameLength),
            "showChangePercent": \(configuration.display.showChangePercent),
            "decimalPlaces": \(configuration.display.decimalPlaces)
          },
          "instruments": [
        \(instruments.joined(separator: ",\n"))
          ]
        }

        """
    }

    // MARK: - Generated documentation

    /// A known-good file, also written beside the real config as `config.example.json`.
    public static let exampleJSON = """
    {
      "schemaVersion": 1,

      "apiKey": "bsk_live_replace_me",

      "refresh": {
        "times": ["10:30", "21:30"],
        "timeZone": "Asia/Kolkata",
        "maxRequestsPerDay": 50
      },

      "display": {
        "currencySymbol": "\u{20B9}",
        "maxNameLength": 18,
        "showChangePercent": true,
        "decimalPlaces": 2
      },

      "instruments": [
        { "type": "ST", "symbol": "RELIANCE" },
        { "type": "ST", "symbol": "TCS" },
        { "type": "ST", "symbol": "HDFCBANK", "name": "HDFC Bank" },
        { "type": "MF", "symbol": "122639", "name": "Parag Parikh Flexi" },
        { "type": "MF", "symbol": "120828", "name": "Quant Small Cap" }
      ]
    }

    """

    /// The generated `README.txt`, documenting every field the loader reads.
    public static let readmeText = """
    BharatStock Widget — configuration
    ==================================

    This folder holds everything the widget reads. The file you edit is:

        config.json

    It is plain JSON. Save it and the widget picks the change up at the next refresh, or
    immediately if you press "Refresh now" in the BharatStock Widget app. No rebuild, no restart.

    -- IMPORTANT --------------------------------------------------------------------------------
    config.json contains your API key in plain text. Do not share this file, do not attach it to
    a bug report, and do not commit it to a repository. It is created with permissions 0600
    (readable only by you) and the app resets those permissions every time it starts.
    ---------------------------------------------------------------------------------------------


    THE FIELDS
    ----------

    schemaVersion   Always 1 for now. If a future version of the app writes 2, this version will
                    still read the file and will ignore anything it does not recognise.

    apiKey          Your BharatStock API key, e.g. "bsk_live_...". Get one at
                    https://bharatstockapi.com. You can also leave this as "" and set the
                    BHARATSTOCK_API_KEY environment variable instead, but note that this only
                    works for the app itself -- the widget is launched by macOS and does not
                    inherit your shell environment, so for the widget to work the key has to be
                    in this file.

    refresh.times   When to fetch, as "HH:mm" in refresh.timeZone. Two windows by default:

                        "10:30"  during market hours
                        "21:30"  after the evening NAV publication

                    Fetches are best-effort, not alarms. macOS decides when to wake the widget,
                    so a refresh may land any time from on the minute to a few hours late. This
                    costs you nothing in practice: the API publishes completed trading sessions
                    only, so the numbers do not change between the two windows anyway.

                    Each window is fetched at most once per day, however many times macOS wakes
                    the widget. Set a single time if you prefer: "times": ["21:30"].

    refresh.timeZone
                    An IANA time-zone name. Keep this as "Asia/Kolkata" unless you have a good
                    reason: the windows are about Indian market hours, not about where you are.
                    Travel and daylight saving in your own zone are handled automatically.

    refresh.maxRequestsPerDay
                    A hard ceiling on API requests, counted per day and reset at midnight IST.
                    50 matches the free plan's daily limit. The app will refuse to start a
                    refresh that could exceed it, and always keeps 5 requests in reserve so a
                    manual refresh is still possible. One refresh of a typical watchlist costs
                    one request for all your stocks together, plus one per mutual fund.

    display.currencySymbol
                    Prefixed to NAV values. Default "\u{20B9}".

    display.maxNameLength
                    How many characters a row label may use (4-64, default 18). Longer names are
                    shortened intelligently -- "Reliance Industries Limited" becomes "Reliance",
                    "Parag Parikh Flexi Cap Fund - Direct Plan - Growth" becomes
                    "Parag Parikh... Dir" -- and the full name is always in the tooltip.

    display.showChangePercent
                    Show the change column. Hidden automatically at the Small size and at the
                    largest Dynamic Type sizes, where the name matters more.

    display.decimalPlaces
                    Decimal places for stock prices (0-6, default 2). NAV always uses 4, which is
                    the AMFI convention.


    INSTRUMENTS
    -----------

    An ordered list. Order is the only thing that decides what appears where:

        Small        first 3 entries
        Medium       first 5 entries
        Large        first 10 entries
        Extra Large  first 15 entries

    Entries past the 15th are kept in the file but never shown. Put what you care about first.

    Each entry has:

        type      "ST" for a stock, "MF" for a mutual fund. Case does not matter on reading.
        symbol    For "ST", the NSE ticker as BharatStock spells it:  "RELIANCE", "TCS", "SBIN".
                  For "MF", the AMFI scheme code:  "122639".
        name      Optional. Your own label for the row, used exactly as written. Leave it out and
                  the API's name is used and shortened for you.

    Finding a scheme code: https://bharatstockapi.com/v1/mf/schemes?q=parag+parikh gives you the
    code for each plan. Be careful to pick the right one -- Direct and Regular plans of the same
    scheme have different codes and different NAVs.


    THREE WORKED EXAMPLES
    ---------------------

    1. A small watchlist for the Medium widget, with your own short labels:

        "instruments": [
          { "type": "ST", "symbol": "RELIANCE", "name": "Reliance" },
          { "type": "ST", "symbol": "HDFCBANK", "name": "HDFC Bk" },
          { "type": "ST", "symbol": "INFY" },
          { "type": "MF", "symbol": "122639", "name": "PPFCF" },
          { "type": "MF", "symbol": "120828", "name": "Quant SC" }
        ]

    2. Funds only, refreshed once a day after NAVs are published. NAV is published in the evening,
       so a single late window is all you need and it costs 3 requests a day:

        "refresh": { "times": ["21:30"], "timeZone": "Asia/Kolkata", "maxRequestsPerDay": 50 },
        "instruments": [
          { "type": "MF", "symbol": "122639", "name": "Parag Parikh Flexi" },
          { "type": "MF", "symbol": "120828", "name": "Quant Small Cap" },
          { "type": "MF", "symbol": "119551", "name": "ICICI Pru Bluechip" }
        ]

    3. Both plans of one scheme. They are different instruments with different codes; the app
       notices that the shortened names would be identical and tells them apart for you:

        "instruments": [
          { "type": "MF", "symbol": "122639" },
          { "type": "MF", "symbol": "122640" }
        ]


    WHAT ELSE IS IN THIS FOLDER
    ---------------------------

    config.example.json     A known-good file to copy from if you break config.json.
    README.txt              This file. Rewritten by the app on every launch, so do not edit it.
    budget.json             How many requests have been used today. Safe to delete.
    refresh-state.json      Which refresh windows have been served. Safe to delete.
    Library/Caches/quotes.json
                            The data the widget renders. Safe to delete; it will be refetched.

    Deleting any of the last three is harmless. Deleting config.json loses your watchlist.


    WHEN SOMETHING LOOKS WRONG
    --------------------------

    The widget never goes blank. It tells you what happened in its footer, and the app's window
    shows the same thing in more detail:

        "Stale - last updated ..."   the last fetch failed; these numbers are from before it
        "API key rejected"           check apiKey, or paste a new key in the app
        "Check config.json"          the file does not parse; the app shows the line
        "Daily request limit ..."    the ceiling was hit; it resets at midnight IST

    A malformed config never overwrites your file and never blanks the widget -- the last good
    data keeps showing, labelled as out of date.

    Logs, if you need them:

        ~/Library/Logs/BharatStockWidget/helper.log

    The key is redacted there, so it is safe to attach to a bug report.


    A NOTE ON THE NUMBERS
    ---------------------

    Stock rows show the low and high of a trading session, and the date that session belongs to.
    The API publishes completed sessions only -- there is no intraday data -- so during market
    hours you are looking at the previous session's range, not today's so far. The date beside
    each row is not decoration; it tells you which day you are reading.

    Mutual fund NAV is published once a day, after markets close, typically 21:00-23:00 IST. A
    NAV is labelled with its own date ("NAV \u{B7} 25 Sep") and only ever says "NAV today" when
    that date really is today in India.
    """
}

public enum ConfigWriteError: Error, Sendable, Equatable {
    case configMissing(String)
    case unpatchable(String)
}
