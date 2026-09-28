import Foundation

/// Overall health of the last refresh (§6).
public enum CacheStatus: String, Codable, Sendable, Equatable {
    case ok
    case partial
    case stale
    case budgetExhausted = "budget_exhausted"
    case configError = "config_error"
    case authError = "auth_error"

    /// Unknown values decode to `partial` rather than throwing, so a cache written by a future
    /// version still renders (§8: "forward-compatible read of a schemaVersion: 2 file").
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CacheStatus(rawValue: raw) ?? .partial
    }

    /// True when the footer should carry a status glyph and explanation (§7).
    public var needsAttention: Bool { self != .ok }
}

/// Per-row freshness (§6).
public enum RowState: String, Codable, Sendable, Equatable {
    /// Refreshed successfully this cycle.
    case fresh
    /// Real data from an earlier fetch that this cycle failed to refresh. Values are kept.
    case stale
    /// The fetch failed and there is no earlier value to fall back on.
    case error
    /// The API resolved the symbol but has nothing to publish — typically a bad ticker,
    /// which the API reports as `found: false` rather than as an HTTP error.
    case unavailable

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RowState(rawValue: raw) ?? .unavailable
    }

    public var hasValues: Bool { self == .fresh || self == .stale }
}

/// A stock row's numbers.
public struct StockValues: Codable, Sendable, Equatable {
    public var low: Double?
    public var high: Double?
    public var last: Double?
    public var previousClose: Double?
    public var changePercent: Double?
    public var currency: String
    /// The session this bar belongs to, `yyyy-MM-dd`.
    ///
    /// Not in the spec's schema, and added because the API turns out to publish only completed
    /// sessions: at 15:40 IST on a trading day the latest bar was still the previous Friday's
    /// (`docs/decisions.md` F8). Without this the UI would have to imply the range is intraday,
    /// which would be a lie.
    public var tradeDate: String?

    public init(
        low: Double? = nil,
        high: Double? = nil,
        last: Double? = nil,
        previousClose: Double? = nil,
        changePercent: Double? = nil,
        currency: String = "INR",
        tradeDate: String? = nil
    ) {
        self.low = low
        self.high = high
        self.last = last
        self.previousClose = previousClose
        self.changePercent = changePercent
        self.currency = currency
        self.tradeDate = tradeDate
    }
}

/// A fund row's numbers.
public struct FundValues: Codable, Sendable, Equatable {
    public var nav: Double?
    /// `yyyy-MM-dd`. Always shown beside the NAV so the user is never misled about which day
    /// they are looking at (§6).
    public var navDate: String?
    public var previousNav: Double?
    public var changePercent: Double?
    public var currency: String

    public init(
        nav: Double? = nil,
        navDate: String? = nil,
        previousNav: Double? = nil,
        changePercent: Double? = nil,
        currency: String = "INR"
    ) {
        self.nav = nav
        self.navDate = navDate
        self.previousNav = previousNav
        self.changePercent = changePercent
        self.currency = currency
    }
}

/// One rendered row.
public struct CacheRow: Codable, Sendable, Equatable, Identifiable {
    /// Position in config order. Determines which widget sizes show this row (§4).
    public var order: Int
    public var type: InstrumentType
    public var symbol: String
    /// Shortened per §7 at write time, so the widget does no string work in its timeline provider.
    public var displayName: String
    /// Untruncated. Carried into the accessibility label and tooltip (§7).
    public var fullName: String
    public var state: RowState
    public var stock: StockValues?
    public var mf: FundValues?
    public var asOfUTC: Date?
    /// Why this row is not `fresh`. Shown in the tooltip, never in the compact layout.
    public var note: String?

    public var id: String { "\(type.rawValue):\(symbol)" }

    public init(
        order: Int,
        type: InstrumentType,
        symbol: String,
        displayName: String,
        fullName: String,
        state: RowState,
        stock: StockValues? = nil,
        mf: FundValues? = nil,
        asOfUTC: Date? = nil,
        note: String? = nil
    ) {
        self.order = order
        self.type = type
        self.symbol = symbol
        self.displayName = displayName
        self.fullName = fullName
        self.state = state
        self.stock = stock
        self.mf = mf
        self.asOfUTC = asOfUTC
        self.note = note
    }

    /// The change figure, whichever kind of row this is.
    public var changePercent: Double? {
        type == .stock ? stock?.changePercent : mf?.changePercent
    }
}

/// The file the widget renders. The only thing the two targets share (§6).
public struct QuoteCache: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAtUTC: Date
    /// Last time a fetch actually succeeded. Drives the catch-up rule and the "stale" footer.
    public var lastSuccessfulFetchUTC: Date?
    /// The market session the stock bars came from, `yyyy-MM-dd`.
    public var sourceTradingDate: String?
    /// `"rest"` today; `"mcp"` if the MCP path is ever enabled (`docs/decisions.md` §2).
    public var dataSource: String
    public var budget: BudgetSnapshot
    public var status: CacheStatus
    /// Short strings the widget may show in its footer.
    public var messages: [String]
    public var rows: [CacheRow]

    public struct BudgetSnapshot: Codable, Sendable, Equatable {
        public var spent: Int
        public var limit: Int

        public init(spent: Int, limit: Int) {
            self.spent = spent
            self.limit = limit
        }
    }

    public init(
        schemaVersion: Int = QuoteCache.currentSchemaVersion,
        generatedAtUTC: Date,
        lastSuccessfulFetchUTC: Date? = nil,
        sourceTradingDate: String? = nil,
        dataSource: String = "rest",
        budget: BudgetSnapshot,
        status: CacheStatus,
        messages: [String] = [],
        rows: [CacheRow] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAtUTC = generatedAtUTC
        self.lastSuccessfulFetchUTC = lastSuccessfulFetchUTC
        self.sourceTradingDate = sourceTradingDate
        self.dataSource = dataSource
        self.budget = budget
        self.status = status
        self.messages = messages
        self.rows = rows
    }

    /// The first `limit` rows, in config order — the "Top N" rule of §2.
    public func rows(limit: Int) -> [CacheRow] {
        Array(rows.sorted { $0.order < $1.order }.prefix(limit))
    }

    /// Placeholder for previews and for a widget that has never had a successful fetch.
    public static func empty(status: CacheStatus = .stale, message: String? = nil) -> QuoteCache {
        QuoteCache(
            generatedAtUTC: .now,
            budget: BudgetSnapshot(spent: 0, limit: RefreshSettings.default.maxRequestsPerDay),
            status: status,
            messages: message.map { [$0] } ?? []
        )
    }
}
