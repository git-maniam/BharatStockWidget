import BharatStockCore
import Foundation

/// Fixed data for the widget gallery snapshot and the preview matrix.
///
/// The numbers are real values captured from the BharatStock API on 2026-09-28, including the fact
/// that the latest published session was 2026-09-25 — so the previews show the same
/// completed-session behaviour the running widget does, rather than a prettier fiction.
enum SampleData {
    static let tradingDate = "2026-09-25"

    static var cache: QuoteCache {
        QuoteCache(
            generatedAtUTC: .now,
            lastSuccessfulFetchUTC: .now.addingTimeInterval(-120),
            sourceTradingDate: tradingDate,
            budget: .init(spent: 6, limit: 50),
            status: .ok,
            rows: rows
        )
    }

    /// Fifteen rows, so the Extra Large layout is exercised fully.
    static var rows: [CacheRow] {
        var rows: [CacheRow] = []

        for (index, stock) in stocks.enumerated() {
            rows.append(
                CacheRow(
                    order: index,
                    type: .stock,
                    symbol: stock.symbol,
                    displayName: stock.display,
                    fullName: stock.full,
                    state: .fresh,
                    stock: StockValues(
                        low: stock.low, high: stock.high, last: stock.close,
                        previousClose: stock.previousClose, changePercent: stock.change,
                        tradeDate: tradingDate
                    ),
                    asOfUTC: NumberFormatting.marketDate(tradingDate)
                )
            )
        }

        for (offset, fund) in funds.enumerated() {
            rows.append(
                CacheRow(
                    order: stocks.count + offset,
                    type: .mutualFund,
                    symbol: fund.code,
                    displayName: fund.display,
                    fullName: fund.full,
                    state: .fresh,
                    mf: FundValues(
                        nav: fund.nav, navDate: tradingDate,
                        previousNav: fund.previousNav,
                        changePercent: (fund.nav - fund.previousNav) / fund.previousNav * 100
                    ),
                    asOfUTC: NumberFormatting.marketDate(tradingDate)
                )
            )
        }
        return rows
    }

    /// A cache in every degraded state, so §10's legibility requirement can be eyeballed.
    static func degraded(_ status: CacheStatus) -> QuoteCache {
        var cache = self.cache
        cache.status = status
        cache.messages = [message(for: status)]
        if status != .ok {
            cache.rows = cache.rows.map { row in
                var row = row
                row.state = status == .authError || status == .configError ? .stale : .stale
                row.note = message(for: status)
                return row
            }
        }
        if status == .budgetExhausted {
            cache.budget = .init(spent: 50, limit: 50)
        }
        return cache
    }

    static func message(for status: CacheStatus) -> String {
        switch status {
        case .ok: "Up to date"
        case .partial: "2 instruments have no data"
        case .stale: "Network error: The Internet connection appears to be offline."
        case .budgetExhausted: "Daily request limit reached (50 of 50); resets at midnight IST"
        case .configError: "Config file is not valid JSON: unexpected character at line 4"
        case .authError: "API key rejected — check or replace it in setup"
        }
    }

    static let empty = QuoteCache.empty(
        status: .stale, message: "No data yet — open BharatStock Widget to set up"
    )

    // MARK: - Source values

    private struct Stock {
        let symbol: String, display: String, full: String
        let low: Double, high: Double, close: Double, previousClose: Double, change: Double
    }

    private static let stocks: [Stock] = [
        .init(symbol: "RELIANCE", display: "Reliance", full: "Reliance Industries Limited",
              low: 1210.5, high: 1227.4, close: 1226.0, previousClose: 1219.2, change: 0.56),
        .init(symbol: "TCS", display: "Tata Consultancy…", full: "Tata Consultancy Services Limited",
              low: 2038.1, high: 2090.2, close: 2082.0, previousClose: 2087.0, change: -0.24),
        .init(symbol: "HDFCBANK", display: "HDFC Bank", full: "HDFC Bank Limited",
              low: 723.0, high: 739.65, close: 735.6, previousClose: 728.9, change: 0.92),
        .init(symbol: "INFY", display: "Infosys", full: "Infosys Limited",
              low: 1402.3, high: 1428.8, close: 1421.05, previousClose: 1418.6, change: 0.17),
        .init(symbol: "ICICIBANK", display: "ICICI Bank", full: "ICICI Bank Limited",
              low: 1288.4, high: 1310.0, close: 1305.2, previousClose: 1296.75, change: 0.65),
        .init(symbol: "SBIN", display: "SBI", full: "State Bank of India",
              low: 812.15, high: 829.4, close: 814.3, previousClose: 826.0, change: -1.42),
        .init(symbol: "BHARTIARTL", display: "Bharti Airtel", full: "Bharti Airtel Limited",
              low: 1866.0, high: 1901.55, close: 1898.2, previousClose: 1874.4, change: 1.27),
        .init(symbol: "LT", display: "Larsen & Toubro", full: "Larsen & Toubro Limited",
              low: 3544.0, high: 3612.85, close: 3601.1, previousClose: 3588.25, change: 0.36),
        .init(symbol: "ASIANPAINT", display: "Asian Paints", full: "Asian Paints Limited",
              low: 2410.0, high: 2448.3, close: 2414.65, previousClose: 2441.9, change: -1.12),
        .init(symbol: "TITAN", display: "Titan", full: "Titan Company Limited",
              low: 3288.5, high: 3341.0, close: 3336.4, previousClose: 3302.15, change: 1.04),
        .init(symbol: "MARUTI", display: "Maruti Suzuki", full: "Maruti Suzuki India Limited",
              low: 12_880.0, high: 13_104.5, close: 13_066.0, previousClose: 12_944.3, change: 0.94),
        .init(symbol: "SUNPHARMA", display: "Sun Pharmaceutical", full: "Sun Pharmaceutical Industries Limited",
              low: 1702.2, high: 1728.9, close: 1706.5, previousClose: 1724.05, change: -1.02),
    ]

    private struct Fund {
        let code: String, display: String, full: String
        let nav: Double, previousNav: Double
    }

    private static let funds: [Fund] = [
        .init(code: "122639", display: "Parag Parikh… Dir",
              full: "Parag Parikh Flexi Cap Fund - Direct Plan - Growth",
              nav: 108.1525, previousNav: 108.0528),
        .init(code: "120828", display: "Quant SmallCap",
              full: "Quant Small Cap Fund - Direct Plan Growth Option",
              nav: 289.4471, previousNav: 291.0132),
        .init(code: "119551", display: "ICICI Pru Bluechip",
              full: "ICICI Prudential Bluechip Fund - Direct Plan - Growth",
              nav: 118.7204, previousNav: 118.1990),
    ]
}
