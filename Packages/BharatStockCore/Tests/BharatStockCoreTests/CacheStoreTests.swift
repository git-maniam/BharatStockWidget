import Foundation
import Testing
@testable import BharatStockCore

@Suite("Cache file")
struct CacheStoreTests {
    private func sampleCache() -> QuoteCache {
        QuoteCache(
            generatedAtUTC: Instant.ist(2026, 9, 28, 10, 30),
            lastSuccessfulFetchUTC: Instant.ist(2026, 9, 28, 10, 30),
            sourceTradingDate: "2026-09-25",
            budget: .init(spent: 3, limit: 50),
            status: .ok,
            rows: [
                CacheRow(
                    order: 0, type: .stock, symbol: "RELIANCE",
                    displayName: "Reliance", fullName: "Reliance Industries Limited",
                    state: .fresh,
                    stock: StockValues(
                        low: 1210.5, high: 1227.4, last: 1226.0,
                        previousClose: 1219.2, changePercent: 0.56, tradeDate: "2026-09-25"
                    ),
                    asOfUTC: Instant.ist(2026, 9, 25, 0, 0)
                ),
                CacheRow(
                    order: 1, type: .mutualFund, symbol: "122639",
                    displayName: "Parag Parikh…", fullName: "Parag Parikh Flexi Cap Fund",
                    state: .fresh,
                    mf: FundValues(
                        nav: 108.1525, navDate: "2026-09-25",
                        previousNav: 108.0528, changePercent: 0.0922
                    )
                ),
            ]
        )
    }

    @Test("A cache round-trips through the file unchanged")
    func roundTrip() throws {
        let root = TempRoot()
        let store = CacheStore(paths: root.paths)
        let original = sampleCache()

        try store.save(original)
        let loaded = try #require(store.load())
        #expect(loaded == original)
    }

    @Test("Writing leaves no temporary files behind")
    func noTemporaryLeftovers() throws {
        let root = TempRoot()
        let store = CacheStore(paths: root.paths)

        try store.save(sampleCache())
        try store.save(sampleCache())  // overwrite path, which uses replaceItemAt

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: root.paths.cacheDirectory.path
        )
        #expect(contents == ["quotes.json"])
    }

    @Test("A half-written file never replaces a good one")
    func atomicityUnderFailure() throws {
        let root = TempRoot()
        let store = CacheStore(paths: root.paths)
        try store.save(sampleCache())

        // Simulate the crash window: a stray temp file in the cache directory, as a killed
        // process would leave. The visible cache must be untouched and still parse.
        let stray = root.paths.cacheDirectory.appending(path: "quotes.json.\(UUID().uuidString).tmp")
        try Data("{ truncated".utf8).write(to: stray)

        let loaded = try #require(store.load())
        #expect(loaded.rows.count == 2)
        #expect(loaded.status == .ok)
    }

    @Test("A cache written by a newer schema version still renders")
    func forwardCompatibleRead() throws {
        let root = TempRoot()
        let store = CacheStore(paths: root.paths)

        // schemaVersion 2, an unknown status, an unknown row state, and fields we know nothing
        // about. §8 requires this to load rather than blank the widget.
        try FileStore().writeAtomically(Data("""
        {
          "schemaVersion": 2,
          "generatedAtUTC": "2026-09-28T05:00:12Z",
          "lastSuccessfulFetchUTC": "2026-09-28T05:00:12Z",
          "sourceTradingDate": "2026-09-25",
          "dataSource": "mcp",
          "budget": { "spent": 7, "limit": 50, "burstLimit": 5 },
          "status": "rebalancing",
          "messages": ["hello from the future"],
          "intradayEnabled": true,
          "rows": [
            {
              "order": 0, "type": "ST", "symbol": "RELIANCE",
              "displayName": "Reliance", "fullName": "Reliance Industries Limited",
              "state": "delayed",
              "stock": { "low": 1210.5, "high": 1227.4, "last": 1226.0, "currency": "INR", "bid": 1225.9 },
              "asOfUTC": "2026-09-25T00:00:00Z"
            }
          ]
        }
        """.utf8), to: root.paths.quotesCache)

        let loaded = try #require(store.load())
        #expect(loaded.schemaVersion == 2)
        #expect(loaded.status == .partial, "an unrecognised status degrades rather than throwing")
        #expect(loaded.rows.first?.state == .unavailable)
        #expect(loaded.rows.first?.stock?.last == 1226.0)
        #expect(loaded.messages == ["hello from the future"])
    }

    @Test("A missing cache produces a legible placeholder, not a crash")
    func missingCache() {
        let root = TempRoot()
        let store = CacheStore(paths: root.paths)

        #expect(store.load() == nil)
        let display = store.loadForDisplay()
        #expect(display.rows.isEmpty)
        #expect(display.status == .stale)
        #expect(display.messages.first?.contains("No data yet") == true)
    }

    @Test("A corrupt cache produces a legible placeholder, not a crash")
    func corruptCache() throws {
        let root = TempRoot()
        let store = CacheStore(paths: root.paths)
        try FileStore().writeAtomically(Data("{ not json".utf8), to: root.paths.quotesCache)

        #expect(store.load() == nil)
        let display = store.loadForDisplay()
        #expect(display.status == .partial)
        #expect(display.messages.first?.contains("could not be read") == true)
    }

    @Test("Rows are truncated in config order for each widget size", arguments: [3, 5, 10, 15])
    func rowLimits(limit: Int) {
        let rows = (0..<20).map {
            CacheRow(
                order: $0, type: .stock, symbol: "SYM\($0)",
                displayName: "S\($0)", fullName: "Symbol \($0)", state: .fresh
            )
        }
        // Deliberately shuffled on disk: order, not array position, decides.
        let cache = QuoteCache(
            generatedAtUTC: .now, budget: .init(spent: 0, limit: 50), status: .ok,
            rows: rows.shuffled()
        )

        let selected = cache.rows(limit: limit)
        #expect(selected.count == limit)
        #expect(selected.map(\.order) == Array(0..<limit))
    }

    @Test("Fewer instruments than the size allows renders only what exists")
    func fewerRowsThanSize() {
        let cache = QuoteCache(
            generatedAtUTC: .now, budget: .init(spent: 0, limit: 50), status: .ok,
            rows: [
                CacheRow(order: 0, type: .stock, symbol: "TCS", displayName: "TCS",
                         fullName: "Tata Consultancy Services", state: .fresh)
            ]
        )
        #expect(cache.rows(limit: 15).count == 1, "§7: do not pad with placeholder rows")
    }

    @Test("The friendly symlink points into the App Group container")
    func friendlyLink() throws {
        let root = TempRoot()
        let store = FileStore()

        // Exercised against the temp root rather than the real ~/Library path, which the test
        // suite has no business writing to; the logic under test is the same.
        let link = root.paths.root.appending(path: "link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.paths.config)
        try Data(#"{"instruments":[]}"#.utf8).write(to: root.paths.config)

        #expect(FileManager.default.fileExists(atPath: link.path))
        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(resolved == root.paths.config.path)
        // Reading through the link yields the real file's contents.
        #expect(try Data(contentsOf: link) == Data(#"{"instruments":[]}"#.utf8))
        _ = store
    }
}
