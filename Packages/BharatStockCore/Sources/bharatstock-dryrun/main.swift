import BharatStockCore
import Foundation

/// §8's smoke test.
///
/// Runs a complete refresh cycle — config parsing, the window gate, budget accounting, row
/// building, name shortening, number formatting — against canned API responses, in a throwaway
/// directory. Your real config is read but never written, your real cache is never touched, and
/// the live API is never called, so this consumes zero budget and can be run as often as you like.
///
///     swift run bharatstock-dryrun                 # uses your real config if there is one
///     swift run bharatstock-dryrun --config path   # validate a specific file
///     swift run bharatstock-dryrun --json          # print the cache JSON only
@main
struct DryRun {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }
        let jsonOnly = arguments.contains("--json")
        let live = arguments.contains("--live")
        let explicitConfig = value(of: "--config", in: arguments).map {
            URL(filePath: $0, directoryHint: .notDirectory)
        }

        // Everything happens under a temp root, which is what makes this safe to run at any time.
        let sandbox = URL.temporaryDirectory.appending(
            path: "bharatstock-dryrun/\(UUID().uuidString)", directoryHint: .isDirectory
        )
        let paths = AppPaths(root: sandbox)
        let store = FileStore()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            try store.ensureDirectory(paths.root)

            // Find a config to exercise: the one given, the user's real one, or the shipped example.
            let (configSource, origin) = try resolveConfig(explicitConfig: explicitConfig, store: store)
            try store.writeAtomically(configSource, to: paths.config, mode: FileStore.ownerOnly)

            if !jsonOnly {
                print("BharatStock Widget — \(live ? "live run" : "dry run")")
                print(String(repeating: "=", count: 72))
                print("Config source : \(origin)")
                print("Sandbox       : \(sandbox.path)")
                print("Data source   : \(live ? "BharatStock REST API (live network)" : "bundled fixtures (no network, no budget spent)")")
                print("")
            }

            // Report what the parser made of the file before anything else runs.
            let parsed = try ConfigLoader().load(contentsOf: paths.config)
            if !jsonOnly { printConfigReport(parsed) }

            let outcome: RefreshOutcome
            if live {
                outcome = await RefreshCoordinator(
                    paths: paths,
                    gate: RefreshGate(paths: paths)
                ).refreshNow()
            } else {
                outcome = await RefreshCoordinator(
                    paths: paths,
                    gate: RefreshGate(paths: paths),
                    makeSource: { _, _ in FixtureSource() }
                ).refreshNow()
            }

            if jsonOnly {
                print(try String(decoding: JSONCoding.encoder.encode(outcome.cache), as: UTF8.self))
            } else {
                printCacheReport(outcome, configuration: parsed.configuration)
                print("")
                print("Cache that would have been written to \(paths.quotesCache.lastPathComponent):")
                print(String(repeating: "-", count: 72))
                print(try String(decoding: JSONCoding.encoder.encode(outcome.cache), as: UTF8.self))
            }

            // A dry run must not be able to report success on a broken config.
            if parsed.hasErrors || outcome.cache.status == .configError {
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("dry run failed: \(error)\n".utf8))
            exit(2)
        }
    }

    // MARK: - Config resolution

    static func resolveConfig(
        explicitConfig: URL?,
        store: FileStore
    ) throws -> (data: Data, origin: String) {
        if let explicitConfig {
            return (try store.read(explicitConfig), explicitConfig.path)
        }
        let real = AppPaths.resolved().config
        if store.exists(real) {
            return (try store.read(real), "\(real.path) (your live config, read-only)")
        }
        let friendly = AppPaths.friendlyConfigLink
        if store.exists(friendly) {
            return (try store.read(friendly), "\(friendly.path) (your live config, read-only)")
        }
        return (Data(ConfigWriter.exampleJSON.utf8), "built-in example (no config found on this Mac)")
    }

    // MARK: - Reporting

    static func printConfigReport(_ result: ConfigLoadResult) {
        let configuration = result.configuration
        print("CONFIG")
        print(String(repeating: "-", count: 72))
        print("  API key        : \(Redaction.apiKey(configuration.apiKey))")
        print("  Refresh windows: \(configuration.refresh.times.map(\.formatted).joined(separator: ", ")) "
              + configuration.refresh.timeZoneIdentifier)
        print("  Daily ceiling  : \(configuration.refresh.maxRequestsPerDay) requests")
        print("  Instruments    : \(result.declaredInstrumentCount) declared, "
              + "\(configuration.renderableInstruments.count) renderable")
        if let notice = result.truncationNotice { print("  Truncation     : \(notice)") }

        let stocks = configuration.renderableInstruments.filter { $0.type == .stock }.count
        let funds = configuration.renderableInstruments.filter { $0.type == .mutualFund }.count
        let cost = RequestCost.stockRequests(symbolCount: stocks) + RequestCost.fundRequests(fundCount: funds)
        print("  Cost per cycle : \(cost) request(s) — \(stocks) stocks in "
              + "\(RequestCost.stockRequests(symbolCount: stocks)) batch call(s) + \(funds) fund(s)")
        print("  Cost per day   : \(cost * configuration.refresh.times.count) request(s) for "
              + "\(configuration.refresh.times.count) scheduled window(s)")

        if result.diagnostics.isEmpty {
            print("  Diagnostics    : none")
        } else {
            print("  Diagnostics    :")
            for diagnostic in result.diagnostics {
                let where_ = diagnostic.index.map { "instrument \($0 + 1)" } ?? "file"
                print("    [\(diagnostic.severity.rawValue.uppercased())] \(where_): \(diagnostic.reason)")
            }
        }
        print("")
    }

    static func printCacheReport(_ outcome: RefreshOutcome, configuration: Configuration) {
        let cache = outcome.cache
        print("RESULT")
        print(String(repeating: "-", count: 72))
        print("  Status         : \(cache.status.rawValue)")
        print("  Fetched        : \(outcome.didFetch ? "yes" : "no") — \(outcome.reason)")
        print("  Trading session: \(cache.sourceTradingDate ?? "—")")
        print("  Budget         : \(cache.budget.spent) of \(cache.budget.limit) spent — fixtures "
              + "bypass the network, so nothing is charged and your real ledger is untouched")
        for message in cache.messages { print("  Message        : \(message)") }
        print("")

        // Show what each widget size would actually render. This is the part worth eyeballing:
        // it catches a name that shortens badly or a number that formats wrongly.
        for (label, limit) in [("Small", 3), ("Medium", 5), ("Large", 10), ("Extra Large", 15)] {
            let rows = cache.rows(limit: limit)
            guard !rows.isEmpty else { continue }
            print("\(label.uppercased()) — \(rows.count) row(s) of \(limit) slot(s)")
            print(String(repeating: "-", count: 72))
            for row in rows {
                print("  " + render(row, display: configuration.display, compact: limit == 3))
            }
            print("")
        }
    }

    /// Approximates one widget row as text, using the same formatters the views use.
    static func render(_ row: CacheRow, display: DisplaySettings, compact: Bool) -> String {
        let name = row.displayName.padding(
            toLength: max(display.maxNameLength, row.displayName.count) + 2,
            withPad: " ", startingAt: 0
        )

        var value: String
        switch row.type {
        case .stock:
            if !row.state.hasValues {
                value = "(\(row.state.rawValue))"
            } else if compact {
                value = NumberFormatting.compactRange(low: row.stock?.low, high: row.stock?.high) ?? "—"
            } else {
                let low = row.stock?.low.map { NumberFormatting.price($0, decimals: display.decimalPlaces) } ?? "—"
                let high = row.stock?.high.map { NumberFormatting.price($0, decimals: display.decimalPlaces) } ?? "—"
                let session = row.stock?.tradeDate.flatMap(NumberFormatting.shortMarketDate) ?? "—"
                value = "L \(low)  H \(high) · \(session)"
            }
        case .mutualFund:
            if !row.state.hasValues {
                value = "(\(row.state.rawValue))"
            } else {
                let nav = row.mf?.nav.map(NumberFormatting.nav) ?? "—"
                let date = row.mf?.navDate.flatMap(NumberFormatting.shortMarketDate) ?? "—"
                value = "\(display.currencySymbol)\(nav)   NAV · \(date)"
            }
        }

        var change = ""
        if display.showChangePercent, !compact, let percent = row.changePercent, row.state.hasValues {
            change = "   \(NumberFormatting.directionGlyph(percent)) \(NumberFormatting.changePercent(percent))"
        }
        return name + value + change
    }

    // MARK: - Arguments

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static let usage = """
        bharatstock-dryrun — run a full refresh cycle offline, against fixtures.

        Reads a config, parses it, builds the cache the widget would render, and prints both the
        rendered rows and the JSON. Uses bundled API responses, so it never touches the network,
        never spends a request from your daily ceiling, and never writes to your real files.

        USAGE
          swift run bharatstock-dryrun [options]

        OPTIONS
          --config <path>   Validate this file instead of your live config.
          --json            Print only the cache JSON, for piping into jq.
          -h, --help        This message.

        EXIT STATUS
          0  the config parsed and a cache was produced
          1  the config has errors (the report says which entry)
          2  the dry run itself failed
        """
}

/// Replays the captured API responses in `Fixtures/`, which were taken from the live API.
struct FixtureSource: QuoteSource {
    func fetchStockQuotes(symbols: [String]) async throws -> [StockQuote] {
        let items: [FixtureQuote] = try decode("quotes-batch")
        let bySymbol = Dictionary(items.map { ($0.symbol.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })

        // Synthesise a plausible bar for any symbol the fixture does not cover, so a dry run
        // exercises the user's actual watchlist rather than only the three tickers we captured.
        return symbols.map { symbol in
            if let match = bySymbol[symbol.uppercased()] { return match.asQuote }
            return FixtureSource.synthesised(symbol: symbol)
        }
    }

    func fetchFundNAV(schemeCode: String) async throws -> FundNAV {
        let response: FixtureNAVResponse = try decode("mf-nav")
        guard let latest = response.data.first else { throw APIError.noData(symbol: schemeCode) }

        // Vary the value by scheme code so several funds are visibly distinct in the output —
        // but leave the one the fixture actually describes at its real captured NAV.
        let isCapturedScheme = schemeCode == response.schemeCode
        let nudge = isCapturedScheme ? 0 : Double(abs(schemeCode.hashValue % 4000)) / 100
        return FundNAV(
            schemeCode: schemeCode,
            schemeName: isCapturedScheme ? response.schemeName : "Scheme \(schemeCode) (fixture)",
            nav: (latest.nav + nudge).rounded(toPlaces: 4),
            navDate: latest.date,
            previousNAV: response.data.dropFirst().first.map { ($0.nav + nudge).rounded(toPlaces: 4) },
            previousNAVDate: response.data.dropFirst().first?.date
        )
    }

    static func synthesised(symbol: String) -> StockQuote {
        let base = 250 + Double(abs(symbol.hashValue % 300_000)) / 100
        let low = (base * 0.985).rounded(toPlaces: 2)
        let high = (base * 1.012).rounded(toPlaces: 2)
        let previous = (base * 0.997).rounded(toPlaces: 2)
        return StockQuote(
            symbol: symbol.uppercased(),
            companyName: "\(symbol.uppercased()) Industries Limited",
            tradeDate: "2026-09-25",
            open: low, high: high, low: low, close: base.rounded(toPlaces: 2),
            previousClose: previous,
            changePercent: ((base - previous) / previous * 100).rounded(toPlaces: 2),
            volume: 1_000_000,
            found: true
        )
    }

    private func decode<T: Decodable>(_ name: String) throws -> T {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw APIError.decoding("fixture \(name).json is missing from the bundle")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: try Data(contentsOf: url))
    }
}

private struct FixtureQuote: Decodable {
    var symbol: String
    var companyName: String?
    var tradeDate: String?
    var open: Double?
    var high: Double?
    var low: Double?
    var close: Double?
    var prevClose: Double?
    var changePct: Double?
    var volume: Int?
    var found: Bool?

    var asQuote: StockQuote {
        StockQuote(
            symbol: symbol, companyName: companyName, tradeDate: tradeDate,
            open: open, high: high, low: low, close: close,
            previousClose: prevClose, changePercent: changePct, volume: volume,
            found: found ?? true
        )
    }
}

private struct FixtureNAVResponse: Decodable {
    var schemeCode: String?
    var schemeName: String?
    var data: [FixtureNAVPoint]
}

private struct FixtureNAVPoint: Decodable {
    var date: String
    var nav: Double
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
