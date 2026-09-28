import Foundation

/// One stock's latest published daily bar.
///
/// Every price is optional because the API returns `found: false` with null prices for an
/// unrecognised ticker rather than an HTTP error — a typo in the config must therefore render as
/// an unavailable row, not as a failed refresh.
public struct StockQuote: Sendable, Equatable {
    public var symbol: String
    public var companyName: String?
    /// The session this bar belongs to, `yyyy-MM-dd`, exactly as published.
    ///
    /// Kept as a string rather than a `Date` on purpose: it is a market calendar date with no
    /// time and no zone, and converting it to an instant would invite an off-by-one-day bug.
    public var tradeDate: String?
    public var open: Double?
    public var high: Double?
    public var low: Double?
    public var close: Double?
    public var previousClose: Double?
    public var changePercent: Double?
    public var volume: Int?
    public var found: Bool

    public init(
        symbol: String,
        companyName: String? = nil,
        tradeDate: String? = nil,
        open: Double? = nil,
        high: Double? = nil,
        low: Double? = nil,
        close: Double? = nil,
        previousClose: Double? = nil,
        changePercent: Double? = nil,
        volume: Int? = nil,
        found: Bool = true
    ) {
        self.symbol = symbol
        self.companyName = companyName
        self.tradeDate = tradeDate
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.previousClose = previousClose
        self.changePercent = changePercent
        self.volume = volume
        self.found = found
    }

    /// True when there is at least a price to show.
    public var hasUsablePrices: Bool { found && close != nil }
}

/// One fund's latest NAV, with the preceding point so a change can be shown.
public struct FundNAV: Sendable, Equatable {
    public var schemeCode: String
    public var schemeName: String?
    public var nav: Double
    /// `yyyy-MM-dd`, as published by AMFI. Always displayed next to the NAV (§6).
    public var navDate: String
    public var previousNAV: Double?
    public var previousNAVDate: String?

    public init(
        schemeCode: String,
        schemeName: String? = nil,
        nav: Double,
        navDate: String,
        previousNAV: Double? = nil,
        previousNAVDate: String? = nil
    ) {
        self.schemeCode = schemeCode
        self.schemeName = schemeName
        self.nav = nav
        self.navDate = navDate
        self.previousNAV = previousNAV
        self.previousNAVDate = previousNAVDate
    }

    /// Computed rather than taken from the API, which has no NAV change field.
    public var changePercent: Double? {
        guard let previousNAV, previousNAV != 0 else { return nil }
        return (nav - previousNAV) / previousNAV * 100
    }
}

/// The data dependency the refresh cycle is written against.
///
/// Exists so the cycle can be unit-tested offline against fixtures (§8), and so the MCP path can
/// be slotted in later without touching the cycle — the only reason it is REST today is that the
/// supplied key's plan refuses MCP (`docs/decisions.md` F1).
public protocol QuoteSource: Sendable {
    /// Resolves many tickers. Implementations should use the batch endpoint: it is one request
    /// regardless of count, which is what makes the daily ceiling comfortable (§5).
    func fetchStockQuotes(symbols: [String]) async throws -> [StockQuote]

    /// Resolves one fund. There is no batch NAV endpoint, so funds cost one request each.
    func fetchFundNAV(schemeCode: String) async throws -> FundNAV
}

/// What a source charges, so the cycle can pre-authorise its worst case against the budget.
public enum RequestCost {
    /// Batch stock quotes: one request for up to `batchLimit` symbols.
    public static let batchLimit = 50

    public static func stockRequests(symbolCount: Int) -> Int {
        symbolCount == 0 ? 0 : (symbolCount + batchLimit - 1) / batchLimit
    }

    public static func fundRequests(fundCount: Int) -> Int { fundCount }
}
