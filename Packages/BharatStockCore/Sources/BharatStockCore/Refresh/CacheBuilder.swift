import Foundation

/// Turns config order plus fetch results into the rows the widget renders.
///
/// All the display decisions — name shortening, change-percent derivation, stale fallback — happen
/// here, at write time, so the widget's timeline provider does no work beyond decoding JSON. That
/// matters: the extension is given very little wall clock before the system gives up on it.
struct CacheBuilder: Sendable {
    let shortener: NameShortener
    let display: DisplaySettings

    func build(
        instruments: [Instrument],
        results: RefreshCoordinator.FetchResults,
        previous: QuoteCache?,
        budget: BudgetLedger,
        generatedAt: Date,
        diagnostics: [ConfigDiagnostic],
        truncationNotice: String?
    ) -> QuoteCache {
        let quotesBySymbol = Dictionary(
            results.quotes.map { ($0.symbol.uppercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previousRows = Dictionary(
            (previous?.rows ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Resolve values first, then name everything in one pass so collisions can be seen.
        let resolutions = instruments.enumerated().map { index, instrument in
            resolve(
                instrument: instrument,
                order: index,
                quote: quotesBySymbol[instrument.symbol.uppercased()],
                nav: results.navs[instrument.symbol],
                failure: results.failures[instrument.id] ?? results.failures[batchKey(for: instrument)],
                previousRow: previousRows[instrument.id]
            )
        }

        let labels = shortener.shortenAll(
            resolutions.map {
                NameShortener.Request(
                    type: $0.instrument.type,
                    symbol: $0.instrument.symbol,
                    fullName: $0.fullName,
                    explicitName: $0.instrument.name
                )
            },
            maxLength: display.maxNameLength
        )

        let rows = zip(resolutions, labels).map { resolution, label in
            CacheRow(
                order: resolution.order,
                type: resolution.instrument.type,
                symbol: resolution.instrument.symbol,
                displayName: label,
                fullName: resolution.fullName,
                state: resolution.state,
                stock: resolution.stock,
                mf: resolution.fund,
                asOfUTC: resolution.asOf,
                note: resolution.note
            )
        }

        let status = resolveStatus(rows: rows, failures: results.failures)
        let anythingFresh = rows.contains { $0.state == .fresh }

        return QuoteCache(
            generatedAtUTC: generatedAt,
            lastSuccessfulFetchUTC: anythingFresh ? generatedAt : previous?.lastSuccessfulFetchUTC,
            sourceTradingDate: dominantTradeDate(in: rows) ?? previous?.sourceTradingDate,
            dataSource: "rest",
            budget: QuoteCache.BudgetSnapshot(spent: budget.spent, limit: budget.limit),
            status: status,
            messages: messages(
                status: status, rows: rows, failures: results.failures,
                diagnostics: diagnostics, truncationNotice: truncationNotice
            ),
            rows: rows
        )
    }

    // MARK: - Per-row resolution

    private struct Resolution {
        var instrument: Instrument
        var order: Int
        var fullName: String
        var state: RowState
        var stock: StockValues?
        var fund: FundValues?
        var asOf: Date?
        var note: String?
    }

    /// A batch-wide stock failure is recorded under `"*"`, so every stock row inherits it.
    private func batchKey(for instrument: Instrument) -> String {
        instrument.type == .stock ? "*" : instrument.id
    }

    private func resolve(
        instrument: Instrument,
        order: Int,
        quote: StockQuote?,
        nav: FundNAV?,
        failure: APIError?,
        previousRow: CacheRow?
    ) -> Resolution {
        var resolution = Resolution(
            instrument: instrument,
            order: order,
            fullName: previousRow?.fullName ?? instrument.name ?? instrument.symbol,
            state: .error
        )

        switch instrument.type {
        case .stock:
            if let quote, quote.found, quote.close != nil {
                resolution.fullName = quote.companyName ?? resolution.fullName
                resolution.state = .fresh
                resolution.stock = StockValues(
                    low: quote.low,
                    high: quote.high,
                    last: quote.close,
                    previousClose: quote.previousClose,
                    changePercent: quote.changePercent ?? derivedChange(
                        last: quote.close, previous: quote.previousClose
                    ),
                    tradeDate: quote.tradeDate
                )
                resolution.asOf = quote.tradeDate.flatMap(NumberFormatting.marketDate)
                return resolution
            }
            if let quote, !quote.found {
                // The API resolved the request but knows nothing about this ticker: a typo, not an
                // outage. Says so plainly instead of pretending the network failed.
                resolution.state = .unavailable
                resolution.note = "\(instrument.symbol) is not a recognised NSE/BSE ticker"
                return resolution
            }

        case .mutualFund:
            if let nav {
                resolution.fullName = nav.schemeName ?? resolution.fullName
                resolution.state = .fresh
                resolution.fund = FundValues(
                    nav: nav.nav,
                    navDate: nav.navDate,
                    previousNav: nav.previousNAV,
                    changePercent: nav.changePercent
                )
                resolution.asOf = NumberFormatting.marketDate(nav.navDate)
                return resolution
            }
            if case .noData = failure {
                resolution.state = .unavailable
                resolution.note = "No NAV published for scheme \(instrument.symbol)"
                return resolution
            }
        }

        // Nothing new. Keep the old numbers and label them stale rather than blanking the row (§6).
        if let previousRow, previousRow.state.hasValues {
            resolution.state = .stale
            resolution.stock = previousRow.stock
            resolution.fund = previousRow.mf
            resolution.asOf = previousRow.asOfUTC
            resolution.note = failure?.userFacingReason ?? "Could not refresh this row"
            return resolution
        }

        resolution.state = .error
        resolution.note = failure?.userFacingReason ?? "No data yet"
        return resolution
    }

    /// The API supplies `change_pct`, but it is derived here too so a row is never silently
    /// missing its direction when the field comes back null.
    private func derivedChange(last: Double?, previous: Double?) -> Double? {
        guard let last, let previous, previous != 0 else { return nil }
        return (last - previous) / previous * 100
    }

    // MARK: - Status and messages

    private func resolveStatus(rows: [CacheRow], failures: [String: APIError]) -> CacheStatus {
        if failures.values.contains(where: \.isAuthFailure) { return .authError }
        if rows.isEmpty { return .configError }
        if rows.allSatisfy({ $0.state == .fresh }) { return .ok }
        if rows.contains(where: { $0.state == .fresh }) { return .partial }
        if rows.contains(where: { $0.state == .stale }) { return .stale }
        return .partial
    }

    private func messages(
        status: CacheStatus,
        rows: [CacheRow],
        failures: [String: APIError],
        diagnostics: [ConfigDiagnostic],
        truncationNotice: String?
    ) -> [String] {
        var messages: [String] = []

        // The most actionable thing first: the footer has room for roughly one line.
        if let authFailure = failures.values.first(where: \.isAuthFailure) {
            messages.append(authFailure.userFacingReason)
        } else if let anyFailure = failures.values.first, status != .ok {
            messages.append(anyFailure.userFacingReason)
        }

        let unavailable = rows.filter { $0.state == .unavailable }
        if !unavailable.isEmpty {
            messages.append(
                unavailable.count == 1
                    ? "\(unavailable[0].symbol): no data"
                    : "\(unavailable.count) instruments have no data"
            )
        }

        let configErrors = diagnostics.filter { $0.severity == .error }
        if !configErrors.isEmpty {
            messages.append(
                configErrors.count == 1
                    ? "Config: \(configErrors[0].reason)"
                    : "\(configErrors.count) config entries were skipped"
            )
        }
        if let truncationNotice { messages.append(truncationNotice) }

        return messages
    }

    /// The session the stock rows came from. Rows can disagree if a ticker stopped trading,
    /// so the most common date wins over the latest.
    private func dominantTradeDate(in rows: [CacheRow]) -> String? {
        let dates = rows.compactMap { $0.stock?.tradeDate }
        guard !dates.isEmpty else { return nil }
        let counts = Dictionary(dates.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key
    }
}
