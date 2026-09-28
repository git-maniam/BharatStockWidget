import Foundation

/// What a refresh attempt did, so the caller knows whether to reload widget timelines.
public struct RefreshOutcome: Sendable, Equatable {
    public var cache: QuoteCache
    /// False when the gate declined — nothing was fetched and nothing was written.
    public var didFetch: Bool
    public var reason: String

    public init(cache: QuoteCache, didFetch: Bool, reason: String) {
        self.cache = cache
        self.didFetch = didFetch
        self.reason = reason
    }
}

/// Runs one refresh cycle: read config, decide whether to spend a request, fetch, write the cache.
///
/// Every failure path ends in a *written cache with a legible status* rather than a thrown error,
/// because the widget has no way to show an exception. §10's requirement — "network off, API down,
/// bad key, and malformed config each produce a legible widget state, never a blank or crashed
/// widget" — is enforced here rather than in the view.
public struct RefreshCoordinator: Sendable {
    /// §8's ceiling on a whole cycle. Shorter than the spec's 60s because this now runs inside a
    /// widget extension, whose wall-clock budget is measured in seconds.
    public static let defaultCycleTimeout: Duration = .seconds(25)

    private let paths: AppPaths
    private let cacheStore: CacheStore
    private let fileStore: FileStore
    private let gate: RefreshGate
    private let log: LogSink
    private let cycleTimeout: Duration
    /// Injected so tests can drive the clock.
    private let now: @Sendable () -> Date
    /// Injected so tests supply a fixture-backed source without reaching the network.
    private let makeSource: @Sendable (String, RequestBudget) -> any QuoteSource

    public init(
        paths: AppPaths,
        gate: RefreshGate,
        log: LogSink = .none,
        cycleTimeout: Duration = RefreshCoordinator.defaultCycleTimeout,
        fileStore: FileStore = FileStore(),
        now: @escaping @Sendable () -> Date = { .now },
        makeSource: (@Sendable (String, RequestBudget) -> any QuoteSource)? = nil
    ) {
        self.paths = paths
        self.gate = gate
        self.log = log
        self.cycleTimeout = cycleTimeout
        self.fileStore = fileStore
        self.cacheStore = CacheStore(paths: paths, store: fileStore)
        self.now = now
        self.makeSource = makeSource ?? { key, budget in
            BharatStockRESTClient(apiKey: key, budget: budget, log: log)
        }
    }

    // MARK: - Entry points

    /// System-initiated refresh. Honours the window gate, so extra wake-ups cost nothing.
    public func refreshIfDue() async -> RefreshOutcome {
        await run(isManual: false)
    }

    /// User-initiated refresh. Ignores the window gate but honours the five-minute cooldown.
    public func refreshNow() async -> RefreshOutcome {
        await run(isManual: true)
    }

    // MARK: - The cycle

    private func run(isManual: Bool) async -> RefreshOutcome {
        let startedAt = now()
        let previous = cacheStore.load()

        // 1. Config. A file we cannot parse must never be overwritten, and the last good cache
        //    keeps serving (§4).
        let loadResult: ConfigLoadResult
        do {
            loadResult = try loadConfiguration()
        } catch let error as ConfigError {
            log.error("config: \(error.userFacingReason)", category: .config)
            return await write(
                cache: degraded(
                    from: previous, status: .configError,
                    message: error.userFacingReason, at: startedAt
                ),
                didFetch: false, reason: error.userFacingReason
            )
        } catch {
            return await write(
                cache: degraded(
                    from: previous, status: .configError,
                    message: error.localizedDescription, at: startedAt
                ),
                didFetch: false, reason: error.localizedDescription
            )
        }

        let configuration = loadResult.configuration
        let log = self.log.scrubbing(apiKey: configuration.apiKey)
        let schedule = RefreshSchedule(configuration.refresh)
        let instruments = configuration.renderableInstruments

        if instruments.isEmpty {
            let reason = loadResult.diagnostics.first { $0.severity == .error }?.reason
                ?? "No instruments configured"
            return await write(
                cache: degraded(from: previous, status: .configError, message: reason, at: startedAt),
                didFetch: false, reason: reason
            )
        }

        // 2. The gate. This, not launchd, is what caps the day's fetches.
        let decision = isManual
            ? await gate.decideManual(now: startedAt)
            : await gate.decideScheduled(schedule: schedule, now: startedAt)

        guard decision.shouldFetch else {
            let reason = Self.describe(decision)
            log.debug("gate: \(reason)", category: .widget)
            // Nothing fetched, nothing written — the existing cache is still correct.
            if let previous {
                return RefreshOutcome(cache: previous, didFetch: false, reason: reason)
            }
            return RefreshOutcome(
                cache: degraded(from: nil, status: .stale, message: reason, at: startedAt),
                didFetch: false, reason: reason
            )
        }

        guard !configuration.apiKey.isEmpty else {
            let reason = APIError.missingAPIKey.userFacingReason
            return await write(
                cache: degraded(from: previous, status: .authError, message: reason, at: startedAt),
                didFetch: false, reason: reason
            )
        }

        // 3. Budget. Pre-authorise the whole cycle's worst case so it either has room to finish,
        //    retries included, or never starts and leaves a half-refreshed cache behind.
        let budget = RequestBudget(
            paths: paths,
            limit: configuration.refresh.maxRequestsPerDay,
            schedule: schedule,
            store: fileStore
        )
        let stocks = instruments.filter { $0.type == .stock }
        let funds = instruments.filter { $0.type == .mutualFund }
        let plannedRequests = RequestCost.stockRequests(symbolCount: stocks.count)
            + RequestCost.fundRequests(fundCount: funds.count)
        let worstCase = plannedRequests * RetryPolicy.maxAttempts

        do {
            try await budget.authoriseCycle(worstCaseCost: worstCase, now: startedAt)
        } catch let error as BudgetError {
            let reason = Self.describe(error)
            log.warning("budget: \(reason)", category: .budget)
            return await write(
                cache: degraded(
                    from: previous, status: .budgetExhausted, message: reason, at: startedAt,
                    budget: await budget.current(now: startedAt)
                ),
                didFetch: false, reason: reason
            )
        } catch {
            return await write(
                cache: degraded(
                    from: previous, status: .partial,
                    message: error.localizedDescription, at: startedAt
                ),
                didFetch: false, reason: error.localizedDescription
            )
        }

        // 4. Fetch, under a hard ceiling on the whole cycle.
        let source = makeSource(configuration.apiKey, budget)
        let fetched: FetchResults
        do {
            fetched = try await withCycleTimeout {
                await Self.fetchAll(stocks: stocks, funds: funds, using: source, log: log)
            }
        } catch {
            let reason = "Refresh timed out after \(cycleTimeout)"
            log.warning(reason, category: .api)
            return await write(
                cache: degraded(
                    from: previous, status: .partial, message: reason, at: startedAt,
                    budget: await budget.current(now: startedAt)
                ),
                didFetch: true, reason: reason
            )
        }

        // 5. Build the cache.
        let builder = CacheBuilder(
            shortener: NameShortener(rules: NameRules.load(paths: paths)),
            display: configuration.display
        )
        let cache = builder.build(
            instruments: instruments,
            results: fetched,
            previous: previous,
            budget: await budget.current(now: startedAt),
            generatedAt: now(),
            diagnostics: loadResult.diagnostics,
            truncationNotice: loadResult.truncationNotice
        )

        // A cycle that resolved nothing at all must not be credited with serving the window,
        // or a transient outage at 10:30 would suppress the retry the next wake-up would give us.
        let resolvedAnything = fetched.quotes.contains(where: \.hasUsablePrices) || !fetched.navs.isEmpty
        if resolvedAnything {
            try? await gate.recordSuccess(
                window: decision.creditedWindow, isManual: isManual, now: now()
            )
        } else {
            try? await gate.recordAttempt(now: now())
            if isManual {
                // Still stamp the cooldown, or a failing key invites click-spamming.
                try? await gate.recordSuccess(window: nil, isManual: true, now: now())
            }
        }

        log.info(
            "refresh \(cache.status.rawValue): \(cache.rows.count) rows, "
            + "\(await budget.summary(now: now()))",
            category: .widget
        )
        return await write(cache: cache, didFetch: true, reason: "Refreshed")
    }

    // MARK: - Fetching

    struct FetchResults: Sendable {
        var quotes: [StockQuote] = []
        var navs: [String: FundNAV] = [:]
        /// Keyed by `Instrument.id`, or `"*"` for a whole-batch failure.
        var failures: [String: APIError] = [:]
    }

    /// Stocks in one batch call, then funds one at a time.
    ///
    /// Sequential rather than concurrent on purpose: the budget actor serialises spending anyway,
    /// and firing fifteen NAV requests at once is a good way to earn a 429 that costs more
    /// requests than it saves.
    private static func fetchAll(
        stocks: [Instrument],
        funds: [Instrument],
        using source: any QuoteSource,
        log: LogSink
    ) async -> FetchResults {
        var results = FetchResults()

        if !stocks.isEmpty {
            do {
                results.quotes = try await source.fetchStockQuotes(symbols: stocks.map(\.symbol))
            } catch let error as APIError {
                log.warning("stocks: \(error.userFacingReason)", category: .api)
                results.failures["*"] = error
            } catch let error as BudgetError {
                log.warning("stocks: \(describe(error))", category: .budget)
                results.failures["*"] = .transport(describe(error))
            } catch {
                results.failures["*"] = .transport(error.localizedDescription)
            }
        }

        for fund in funds {
            do {
                results.navs[fund.symbol] = try await source.fetchFundNAV(schemeCode: fund.symbol)
            } catch let error as APIError {
                log.warning("nav \(fund.symbol): \(error.userFacingReason)", category: .api)
                results.failures[fund.id] = error
            } catch let error as BudgetError {
                // Out of budget mid-cycle: stop, rather than failing every remaining fund in turn.
                log.warning("nav \(fund.symbol): \(describe(error))", category: .budget)
                results.failures[fund.id] = .transport(describe(error))
                break
            } catch {
                results.failures[fund.id] = .transport(error.localizedDescription)
            }
        }
        return results
    }

    /// Races the cycle against `cycleTimeout`, so a hung socket cannot hold a timeline provider open.
    private func withCycleTimeout(
        _ body: @escaping @Sendable () async -> FetchResults
    ) async throws -> FetchResults {
        try await withThrowingTaskGroup(of: FetchResults?.self) { group in
            group.addTask { await body() }
            group.addTask { [cycleTimeout] in
                try await Task.sleep(for: cycleTimeout)
                return nil
            }
            defer { group.cancelAll() }

            while let result = try await group.next() {
                if let result { return result }
                throw CancellationError()
            }
            throw CancellationError()
        }
    }

    // MARK: - Writing

    private func write(cache: QuoteCache, didFetch: Bool, reason: String) async -> RefreshOutcome {
        do {
            try cacheStore.save(cache)
        } catch {
            log.error("cache: write failed — \(error.localizedDescription)", category: .cache)
        }
        return RefreshOutcome(cache: cache, didFetch: didFetch, reason: reason)
    }

    /// A cache that preserves the previous rows as `stale` and carries an explanatory status.
    ///
    /// Keeping the old numbers is deliberate (§6): a row that silently blanks is worse than one
    /// labelled as out of date.
    private func degraded(
        from previous: QuoteCache?,
        status: CacheStatus,
        message: String,
        at date: Date,
        budget: BudgetLedger? = nil
    ) -> QuoteCache {
        let snapshot = budget.map { QuoteCache.BudgetSnapshot(spent: $0.spent, limit: $0.limit) }
            ?? previous?.budget
            ?? QuoteCache.BudgetSnapshot(spent: 0, limit: RefreshSettings.default.maxRequestsPerDay)

        return QuoteCache(
            generatedAtUTC: date,
            lastSuccessfulFetchUTC: previous?.lastSuccessfulFetchUTC,
            sourceTradingDate: previous?.sourceTradingDate,
            dataSource: previous?.dataSource ?? "rest",
            budget: snapshot,
            status: status,
            messages: [message],
            rows: (previous?.rows ?? []).map { row in
                var row = row
                if row.state == .fresh { row.state = .stale }
                return row
            }
        )
    }

    // MARK: - Config loading

    private func loadConfiguration() throws -> ConfigLoadResult {
        // §2: re-assert 0600 on every start and warn if it had drifted.
        if let previousMode = fileStore.enforceOwnerOnly(paths.config) {
            log.warning(
                String(
                    format: "config: file was mode %o (group/world readable); reset to 0600",
                    previousMode
                ),
                category: .config
            )
        }
        return try ConfigLoader().load(contentsOf: paths.config)
    }

    // MARK: - Descriptions

    static func describe(_ decision: RefreshDecision) -> String {
        switch decision {
        case .fetch: "Fetching"
        case .alreadyServed(let window):
            "Already refreshed for the \(NumberFormatting.istClockTime(window)) window"
        case .noWindowElapsed: "No refresh window has come round yet"
        case .manualThrottled(let retryAt):
            "Refreshed recently — try again at \(NumberFormatting.localClockTime(retryAt))"
        }
    }

    static func describe(_ error: BudgetError) -> String {
        switch error {
        case .exhausted(let spent, let limit):
            "Daily request limit reached (\(spent) of \(limit)); resets at midnight IST"
        case .insufficientHeadroom(let required, let available, let reserve):
            "Not enough requests left for a full refresh (needs up to \(required), "
            + "\(available) available after the \(reserve)-request reserve)"
        }
    }
}

extension RefreshDecision {
    /// The window a successful fetch should be credited against. Nil for manual refreshes, which
    /// must not consume a scheduled window.
    var creditedWindow: Date? {
        if case .fetch(let window) = self { return window }
        return nil
    }
}
