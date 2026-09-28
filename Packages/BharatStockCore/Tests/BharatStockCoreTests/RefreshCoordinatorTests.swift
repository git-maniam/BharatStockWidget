import Foundation
import Testing
@testable import BharatStockCore

@Suite("Refresh cycle")
struct RefreshCoordinatorTests {
    static let defaultConfig = """
    {
      "apiKey": "bsk_live_testkey_0123456789",
      "refresh": { "times": ["10:30", "21:30"], "timeZone": "Asia/Kolkata", "maxRequestsPerDay": 50 },
      "display": { "maxNameLength": 18, "decimalPlaces": 2 },
      "instruments": [
        { "type": "ST", "symbol": "RELIANCE" },
        { "type": "ST", "symbol": "TCS" },
        { "type": "MF", "symbol": "122639" }
      ]
    }
    """

    static func liveQuotes() -> [StockQuote] {
        [
            StockQuote(
                symbol: "RELIANCE", companyName: "Reliance Industries Limited",
                tradeDate: "2026-09-25", open: 1210.5, high: 1227.4, low: 1210.5,
                close: 1226.0, previousClose: 1219.2, changePercent: 0.56, volume: 13138735
            ),
            StockQuote(
                symbol: "TCS", companyName: "Tata Consultancy Services Limited",
                tradeDate: "2026-09-25", open: 2054.0, high: 2090.2, low: 2038.1,
                close: 2082.0, previousClose: 2087.0, changePercent: -0.24, volume: 3342195
            ),
        ]
    }

    static let liveNAV = FundNAV(
        schemeCode: "122639", schemeName: "Parag Parikh Flexi Cap Fund",
        nav: 108.1525, navDate: "2026-09-25",
        previousNAV: 108.0528, previousNAVDate: "2026-09-24"
    )

    private func makeCoordinator(
        root: borrowing TempRoot,
        source: FakeQuoteSource,
        now: Date
    ) -> RefreshCoordinator {
        RefreshCoordinator(
            paths: root.paths,
            gate: RefreshGate(paths: root.paths),
            now: { now },
            makeSource: { _, _ in source }
        )
    }

    // MARK: - Happy path

    @Test("A successful cycle writes fresh rows in config order")
    func happyPath() async throws {
        let root = TempRoot()
        try root.writeConfig(Self.defaultConfig)

        let source = FakeQuoteSource(quotes: Self.liveQuotes(), navs: ["122639": Self.liveNAV])
        let outcome = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 31)
        ).refreshIfDue()

        #expect(outcome.didFetch)
        #expect(outcome.cache.status == .ok)
        #expect(outcome.cache.rows.map(\.symbol) == ["RELIANCE", "TCS", "122639"])
        #expect(outcome.cache.rows.allSatisfy { $0.state == .fresh })
        #expect(outcome.cache.sourceTradingDate == "2026-09-25")
        #expect(outcome.cache.dataSource == "rest")

        // Stocks arrive in ONE batch request, not one per symbol. This is what makes the 50/day
        // ceiling comfortable, so it is asserted rather than assumed.
        #expect(source.stockCalls.count == 1)
        #expect(source.navCalls.count == 1)
        #expect(outcome.cache.budget.limit == 50)

        let reliance = try #require(outcome.cache.rows.first)
        #expect(reliance.displayName == "Reliance")
        #expect(reliance.fullName == "Reliance Industries Limited")
        #expect(reliance.stock?.low == 1210.5)
        #expect(reliance.stock?.high == 1227.4)
        #expect(reliance.stock?.tradeDate == "2026-09-25")

        let fund = try #require(outcome.cache.rows.last)
        #expect(fund.mf?.nav == 108.1525)
        #expect(fund.mf?.navDate == "2026-09-25")
        #expect(fund.mf?.changePercent != nil)

        // And the cache is actually on disk for the widget to read.
        #expect(CacheStore(paths: root.paths).load() == outcome.cache)
    }

    @Test("The gate stops a second wake-up in the same window from spending anything")
    func secondWakeUpInSameWindowIsFree() async throws {
        let root = TempRoot()
        try root.writeConfig(Self.defaultConfig)
        let source = FakeQuoteSource(quotes: Self.liveQuotes(), navs: ["122639": Self.liveNAV])

        _ = await makeCoordinator(root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 31))
            .refreshIfDue()
        #expect(source.stockCalls.count == 1)

        // WidgetKit wakes the extension again 20 minutes later.
        let second = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 51)
        ).refreshIfDue()

        #expect(!second.didFetch)
        #expect(source.stockCalls.count == 1, "no extra request may be issued")
        #expect(second.cache.rows.count == 3, "the existing cache is still served")
        #expect(second.reason.contains("Already refreshed"))
    }

    @Test("The evening window is eligible even though the morning one was served")
    func eveningWindowFetchesAgain() async throws {
        let root = TempRoot()
        try root.writeConfig(Self.defaultConfig)
        let source = FakeQuoteSource(quotes: Self.liveQuotes(), navs: ["122639": Self.liveNAV])

        _ = await makeCoordinator(root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 31)).refreshIfDue()
        let evening = await makeCoordinator(root: root, source: source, now: Instant.ist(2026, 9, 28, 21, 35)).refreshIfDue()

        #expect(evening.didFetch)
        #expect(source.stockCalls.count == 2)
        #expect(evening.cache.status == .ok)
    }

    // MARK: - Degraded states (§10)

    @Test("Network failure keeps the previous values and labels them stale")
    func networkFailureFallsBackToStale() async throws {
        let root = TempRoot()
        try root.writeConfig(Self.defaultConfig)

        let good = FakeQuoteSource(quotes: Self.liveQuotes(), navs: ["122639": Self.liveNAV])
        _ = await makeCoordinator(root: root, source: good, now: Instant.ist(2026, 9, 28, 10, 31)).refreshIfDue()

        let offline = FakeQuoteSource(
            stockError: .transport("The Internet connection appears to be offline."),
            navErrors: ["122639": .transport("offline")]
        )
        let outcome = await makeCoordinator(
            root: root, source: offline, now: Instant.ist(2026, 9, 28, 21, 35)
        ).refreshIfDue()

        #expect(outcome.cache.status == .stale)
        #expect(outcome.cache.rows.count == 3)
        // §6: keep the old values rather than blanking the row.
        #expect(outcome.cache.rows.allSatisfy { $0.state == .stale })
        #expect(outcome.cache.rows.first?.stock?.last == 1226.0)
        #expect(outcome.cache.rows.first?.note?.isEmpty == false)
        #expect(outcome.cache.messages.contains { $0.contains("Network error") })
        // The last *successful* fetch time is preserved, so the footer can say how old this is.
        #expect(outcome.cache.lastSuccessfulFetchUTC == Instant.ist(2026, 9, 28, 10, 31))
    }

    @Test("A failed cycle does not consume its window, so the next wake-up retries")
    func failedCycleDoesNotBurnTheWindow() async throws {
        let root = TempRoot()
        try root.writeConfig(Self.defaultConfig)

        let offline = FakeQuoteSource(
            stockError: .transport("offline"), navErrors: ["122639": .transport("offline")]
        )
        _ = await makeCoordinator(root: root, source: offline, now: Instant.ist(2026, 9, 28, 10, 31)).refreshIfDue()

        // The network comes back ten minutes later. The 10:30 window must still be due — otherwise
        // a momentary outage at the window boundary would cost the user the whole day's update.
        let recovered = FakeQuoteSource(quotes: Self.liveQuotes(), navs: ["122639": Self.liveNAV])
        let outcome = await makeCoordinator(
            root: root, source: recovered, now: Instant.ist(2026, 9, 28, 10, 41)
        ).refreshIfDue()

        #expect(outcome.didFetch)
        #expect(outcome.cache.status == .ok)
    }

    @Test("A bad API key surfaces as an auth error, not a generic failure")
    func badKeyIsAnAuthError() async throws {
        let root = TempRoot()
        try root.writeConfig(Self.defaultConfig)

        let rejected = FakeQuoteSource(
            stockError: .http(status: 401, detail: "Invalid API key", retryAfter: nil),
            navErrors: ["122639": .http(status: 401, detail: "Invalid API key", retryAfter: nil)]
        )
        let outcome = await makeCoordinator(
            root: root, source: rejected, now: Instant.ist(2026, 9, 28, 10, 31)
        ).refreshIfDue()

        #expect(outcome.cache.status == .authError)
        #expect(outcome.cache.messages.contains { $0.contains("API key rejected") })
        // The key itself must never reach the cache file.
        let raw = try String(decoding: Data(contentsOf: root.paths.quotesCache), as: UTF8.self)
        #expect(!raw.contains("bsk_live_testkey_0123456789"))
    }

    @Test("An empty API key is reported before any request is attempted")
    func missingKeyShortCircuits() async throws {
        let root = TempRoot()
        try root.writeConfig("""
        { "apiKey": "", "instruments": [ { "type": "ST", "symbol": "TCS" } ] }
        """)

        let source = FakeQuoteSource(quotes: Self.liveQuotes())
        let outcome = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 31)
        ).refreshIfDue()

        #expect(outcome.cache.status == .authError)
        #expect(source.stockCalls.count == 0, "no point spending a request without a key")
        #expect(outcome.cache.messages.contains { $0.contains("No API key set") })
    }

    @Test("Malformed config keeps serving the last good cache and does not overwrite the file")
    func malformedConfigPreservesEverything() async throws {
        let root = TempRoot()
        try root.writeConfig(Self.defaultConfig)
        let good = FakeQuoteSource(quotes: Self.liveQuotes(), navs: ["122639": Self.liveNAV])
        _ = await makeCoordinator(root: root, source: good, now: Instant.ist(2026, 9, 28, 10, 31)).refreshIfDue()

        let broken = "{ this is not json"
        try root.writeConfig(broken)

        let outcome = await makeCoordinator(
            root: root, source: good, now: Instant.ist(2026, 9, 28, 21, 35)
        ).refreshIfDue()

        #expect(outcome.cache.status == .configError)
        #expect(outcome.cache.rows.count == 3, "last good rows keep showing")
        #expect(outcome.cache.rows.allSatisfy { $0.state == .stale })
        #expect(outcome.cache.messages.contains { $0.contains("not valid JSON") })

        // §4: do not overwrite the user's file.
        #expect(try String(decoding: Data(contentsOf: root.paths.config), as: UTF8.self) == broken)
    }

    @Test("A bad ticker renders as unavailable rather than failing the cycle")
    func badTickerIsUnavailable() async throws {
        let root = TempRoot()
        try root.writeConfig("""
        {
          "apiKey": "bsk_live_testkey_0123456789",
          "instruments": [
            { "type": "ST", "symbol": "RELIANCE" },
            { "type": "ST", "symbol": "NOTATICKER" }
          ]
        }
        """)

        let source = FakeQuoteSource(quotes: Self.liveQuotes() + [
            StockQuote(symbol: "NOTATICKER", found: false)
        ])
        let outcome = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 31)
        ).refreshIfDue()

        #expect(outcome.cache.status == .partial)
        #expect(outcome.cache.rows[0].state == .fresh)
        #expect(outcome.cache.rows[1].state == .unavailable)
        #expect(outcome.cache.rows[1].note?.contains("not a recognised") == true)
        #expect(outcome.cache.messages.contains { $0.contains("NOTATICKER") })
    }

    @Test("An exhausted budget refuses the cycle without issuing a request")
    func exhaustedBudgetRefusesCycle() async throws {
        let root = TempRoot()
        try root.writeConfig("""
        {
          "apiKey": "bsk_live_testkey_0123456789",
          "refresh": { "maxRequestsPerDay": 6 },
          "instruments": [
            { "type": "ST", "symbol": "RELIANCE" },
            { "type": "MF", "symbol": "122639" }
          ]
        }
        """)

        // 2 planned requests × 3 attempts = 6 worst case; the limit is 6, so after the reserve
        // (6 - 0 - 5 = 1) there is not enough room and the cycle must not start.
        let source = FakeQuoteSource(quotes: Self.liveQuotes(), navs: ["122639": Self.liveNAV])
        let outcome = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 31)
        ).refreshIfDue()

        #expect(outcome.cache.status == .budgetExhausted)
        #expect(source.stockCalls.count == 0)
        #expect(source.navCalls.count == 0)
        #expect(outcome.cache.messages.contains { $0.contains("Not enough requests") })
    }

    @Test("A config with no valid instruments reports a config error")
    func noInstruments() async throws {
        let root = TempRoot()
        try root.writeConfig(#"{ "apiKey": "bsk_live_testkey_0123456789", "instruments": [] }"#)

        let source = FakeQuoteSource()
        let outcome = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 31)
        ).refreshIfDue()

        #expect(outcome.cache.status == .configError)
        #expect(outcome.cache.rows.isEmpty)
        #expect(source.stockCalls.count == 0)
    }

    @Test("Duplicated symbols are fetched once")
    func duplicatesFetchedOnce() async throws {
        let root = TempRoot()
        try root.writeConfig("""
        {
          "apiKey": "bsk_live_testkey_0123456789",
          "instruments": [
            { "type": "ST", "symbol": "RELIANCE" },
            { "type": "ST", "symbol": "reliance" },
            { "type": "MF", "symbol": "122639" },
            { "type": "MF", "symbol": "122639" }
          ]
        }
        """)

        let source = FakeQuoteSource(quotes: Self.liveQuotes(), navs: ["122639": Self.liveNAV])
        let outcome = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 31)
        ).refreshIfDue()

        #expect(outcome.cache.rows.map(\.symbol) == ["RELIANCE", "122639"])
        #expect(source.navCalls.count == 1, "§5: a symbol listed twice is fetched once")
    }

    // MARK: - Manual refresh

    @Test("Manual refresh ignores the window but honours the cooldown")
    func manualRefresh() async throws {
        let root = TempRoot()
        try root.writeConfig(Self.defaultConfig)
        let source = FakeQuoteSource(quotes: Self.liveQuotes(), navs: ["122639": Self.liveNAV])

        // 09:00 — before the morning window, so a scheduled refresh would decline.
        let manual = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 9, 0)
        ).refreshNow()
        #expect(manual.didFetch)
        #expect(manual.cache.status == .ok)

        // Clicking again a minute later must not spend anything.
        let spam = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 9, 1)
        ).refreshNow()
        #expect(!spam.didFetch)
        #expect(source.stockCalls.count == 1)

        // And the 10:30 scheduled window is still due afterwards.
        let scheduled = await makeCoordinator(
            root: root, source: source, now: Instant.ist(2026, 9, 28, 10, 30)
        ).refreshIfDue()
        #expect(scheduled.didFetch)
    }

    @Test("A full simulated day stays well under the 50-request ceiling")
    func fullDayUnderCeiling() async throws {
        let root = TempRoot()
        try root.writeConfig(Self.defaultConfig)

        // A real budget, shared across every cycle of the day, with a real client in front of a
        // stubbed transport — so the count is what the code would actually spend.
        let schedule = RefreshSchedule(.default)
        let budget = RequestBudget(paths: root.paths, limit: 50, schedule: schedule)
        let quotesURL = try #require(Bundle.module.url(forResource: "quotes-batch", withExtension: "json"))
        let navURL = try #require(Bundle.module.url(forResource: "mf-nav", withExtension: "json"))
        let quotesJSON = try Data(contentsOf: quotesURL)
        let navJSON = try Data(contentsOf: navURL)

        let transport = ScriptedTransport(quotes: quotesJSON, nav: navJSON)
        let client = BharatStockRESTClient(
            apiKey: "bsk_live_testkey_0123456789",
            budget: budget,
            transport: transport,
            retryPolicy: .deterministic,
            sleeper: { _ in }
        )

        let gate = RefreshGate(paths: root.paths)
        func coordinator(at moment: Date) -> RefreshCoordinator {
            RefreshCoordinator(
                paths: root.paths, gate: gate, now: { moment },
                makeSource: { _, _ in client }
            )
        }

        // Two scheduled windows, several spurious wake-ups in between, and two manual refreshes.
        _ = await coordinator(at: Instant.ist(2026, 9, 28, 10, 31)).refreshIfDue()
        _ = await coordinator(at: Instant.ist(2026, 9, 28, 11, 0)).refreshIfDue()
        _ = await coordinator(at: Instant.ist(2026, 9, 28, 12, 0)).refreshIfDue()
        _ = await coordinator(at: Instant.ist(2026, 9, 28, 13, 0)).refreshNow()
        _ = await coordinator(at: Instant.ist(2026, 9, 28, 13, 1)).refreshNow()  // throttled
        _ = await coordinator(at: Instant.ist(2026, 9, 28, 18, 0)).refreshIfDue()
        _ = await coordinator(at: Instant.ist(2026, 9, 28, 21, 31)).refreshIfDue()
        _ = await coordinator(at: Instant.ist(2026, 9, 28, 22, 0)).refreshNow()
        _ = await coordinator(at: Instant.ist(2026, 9, 28, 23, 0)).refreshIfDue()

        let ledger = await budget.current(now: Instant.ist(2026, 9, 28, 23, 30))
        // 4 actual cycles (2 scheduled + 2 manual) × (1 batch + 1 NAV) = 8.
        #expect(ledger.spent == 8, "spent \(ledger.spent)")
        #expect(ledger.spent < 50, "§10: provably fewer than 50 requests in a day")
        #expect(transport.calls.count == 8, "every HTTP call is budgeted")

        // And the window rolls the next morning.
        #expect(await budget.current(now: Instant.ist(2026, 9, 29, 0, 1)).spent == 0)
    }
}

/// Routes by URL path so one transport can serve both endpoints in the whole-day test.
struct ScriptedTransport: HTTPTransport {
    let quotes: Data
    let nav: Data
    let calls = Counter()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.increment()
        let path = request.url?.path ?? ""
        let body = path.contains("/nav") ? nav : quotes
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        return (body, response)
    }
}
