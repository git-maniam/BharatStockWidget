import Foundation
import Testing
@testable import BharatStockCore

// Declared outside the suite: a `@Suite` trait cannot reference the type it is attached to.
enum LiveAPI {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BHARATSTOCK_LIVE_TEST"] == "1"
            && !(ProcessInfo.processInfo.environment["BHARATSTOCK_API_KEY"] ?? "").isEmpty
    }

    static var apiKey: String {
        ProcessInfo.processInfo.environment["BHARATSTOCK_API_KEY"] ?? ""
    }
}

/// End-to-end tests against the real API.
///
/// Disabled unless `BHARATSTOCK_LIVE_TEST=1` and `BHARATSTOCK_API_KEY` are both set, because they
/// need the network and each one spends from the same 50-requests-a-day ceiling the widget uses.
/// Everything else in this suite is offline and fixture-backed; these exist to catch the one class
/// of bug fixtures cannot — the API's actual response shape drifting away from what we decode.
///
///     make test-live      # or:
///     BHARATSTOCK_LIVE_TEST=1 BHARATSTOCK_API_KEY=bsk_live_… swift test --filter LiveAPITests
@Suite("Live API", .disabled(if: !LiveAPI.isEnabled, "set BHARATSTOCK_LIVE_TEST=1 to run"))
struct LiveAPITests {

    private func client(root: borrowing TempRoot) -> BharatStockRESTClient {
        BharatStockRESTClient(
            apiKey: LiveAPI.apiKey,
            budget: RequestBudget(paths: root.paths, limit: 50, schedule: RefreshSchedule(.default))
        )
    }

    @Test("A live batch quote decodes into the fields the widget renders")
    func liveBatchQuotes() async throws {
        let root = TempRoot()
        let quotes = try await client(root: root)
            .fetchStockQuotes(symbols: ["RELIANCE", "TCS", "HDFCBANK"])

        #expect(quotes.count == 3, "one request must return every symbol asked for")

        for quote in quotes {
            #expect(quote.found, "\(quote.symbol) was not found")
            #expect(quote.hasUsablePrices, "\(quote.symbol) has no close price")
            #expect(quote.companyName?.isEmpty == false)

            // The four numbers the widget actually shows.
            let low = try #require(quote.low, "\(quote.symbol) has no session low")
            let high = try #require(quote.high, "\(quote.symbol) has no session high")
            #expect(low <= high, "\(quote.symbol): low \(low) exceeds high \(high)")
            #expect(low > 0)

            let close = try #require(quote.close)
            #expect(close >= low && close <= high, "\(quote.symbol): close \(close) outside its range")

            // The session date is load-bearing, not decoration — the API publishes completed
            // sessions only, so the UI labels every range with the day it belongs to.
            let tradeDate = try #require(quote.tradeDate, "\(quote.symbol) has no trade_date")
            #expect(NumberFormatting.marketDate(tradeDate) != nil, "unparseable trade_date \(tradeDate)")
        }
    }

    @Test("An unknown ticker comes back as found:false, not as an HTTP error")
    func liveUnknownTicker() async throws {
        let root = TempRoot()
        // This is why a config typo renders as an `unavailable` row and is never retried.
        let quotes = try await client(root: root).fetchStockQuotes(symbols: ["NOTAREALTICKERXYZ"])
        let quote = try #require(quotes.first)
        #expect(!quote.found)
        #expect(!quote.hasUsablePrices)
    }

    @Test("A live NAV decodes with its date and a previous point")
    func liveNAV() async throws {
        let root = TempRoot()
        let nav = try await client(root: root).fetchFundNAV(schemeCode: "122639")

        #expect(nav.schemeCode == "122639")
        // Guards against the spec's mistake recurring: 122639 is Parag Parikh, 120503 is Axis ELSS.
        #expect(nav.schemeName?.localizedCaseInsensitiveContains("parag parikh") == true,
                "122639 resolved to \(nav.schemeName ?? "nil")")
        #expect(nav.nav > 0)
        #expect(NumberFormatting.marketDate(nav.navDate) != nil)

        // `limit=2` must yield the previous point, or the change column can never be populated.
        let previous = try #require(nav.previousNAV, "no previous NAV — is limit=2 still honoured?")
        #expect(previous > 0)
        #expect(nav.changePercent != nil)
        let previousDate = try #require(nav.previousNAVDate)
        #expect(previousDate < nav.navDate, "the series must arrive newest-first")
    }

    @Test("A full refresh cycle against the live API costs one request per stock batch plus one per fund")
    func liveRefreshCycle() async throws {
        let root = TempRoot()
        try root.writeConfig("""
        {
          "apiKey": "\(LiveAPI.apiKey)",
          "instruments": [
            { "type": "ST", "symbol": "RELIANCE" },
            { "type": "ST", "symbol": "TCS" },
            { "type": "ST", "symbol": "HDFCBANK" },
            { "type": "MF", "symbol": "122639", "name": "Parag Parikh Flexi" }
          ]
        }
        """)

        let budget = RequestBudget(paths: root.paths, limit: 50, schedule: RefreshSchedule(.default))
        let outcome = await RefreshCoordinator(
            paths: root.paths,
            gate: RefreshGate(paths: root.paths),
            makeSource: { key, _ in
                BharatStockRESTClient(apiKey: key, budget: budget)
            }
        ).refreshNow()

        #expect(outcome.didFetch)
        #expect(outcome.cache.status == .ok, "messages: \(outcome.cache.messages)")
        #expect(outcome.cache.rows.count == 4)
        #expect(outcome.cache.rows.allSatisfy { $0.state == .fresh })
        #expect(outcome.cache.sourceTradingDate != nil)

        // 3 stocks in one batch call + 1 fund = 2 requests, not 4.
        let spent = await budget.current().spent
        #expect(spent == 2, "spent \(spent)")

        // Names came from the API and were shortened, and the key never reached the cache.
        #expect(outcome.cache.rows[0].fullName.localizedCaseInsensitiveContains("reliance"))
        #expect(outcome.cache.rows[0].displayName == "Reliance")
        let raw = try String(decoding: Data(contentsOf: root.paths.quotesCache), as: UTF8.self)
        #expect(!raw.contains(LiveAPI.apiKey))
    }

    @Test("MCP is still refused for this key, so the REST substitution still stands")
    func liveMCPStillRefused() async throws {
        // docs/mcp-tools.md rests on this. If the plan is ever upgraded this test fails, which is
        // the signal to run real tool discovery and revisit the substitution.
        var request = URLRequest(url: URL(string: "https://bharatstockapi.com/v1/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(LiveAPI.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)

        let (data, _) = try await URLSessionTransport().send(request)
        let body = try String(decoding: data, as: UTF8.self)

        #expect(
            body.contains("Developer or Pro plan"),
            "MCP may now be available — re-run tool discovery. Response: \(body.prefix(300))"
        )
    }
}
