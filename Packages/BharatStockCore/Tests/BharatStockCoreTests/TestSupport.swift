import Foundation
import Synchronization
import Testing
@testable import BharatStockCore

/// A throwaway directory that stands in for the App Group container.
///
/// Every test that touches the filesystem gets its own, which is what makes the suite safe to run
/// in parallel and keeps it from ever writing to the real container.
struct TempRoot: ~Copyable {
    let paths: AppPaths

    init() {
        let url = URL.temporaryDirectory.appending(
            path: "BharatStockCoreTests/\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.paths = AppPaths(root: url)
    }

    func writeConfig(_ json: String) throws {
        try FileStore().writeAtomically(
            Data(json.utf8), to: paths.config, mode: FileStore.ownerOnly
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }
}

/// A `QuoteSource` backed by canned values, so the refresh cycle can be driven offline (§8).
struct FakeQuoteSource: QuoteSource {
    var quotes: [StockQuote] = []
    var navs: [String: FundNAV] = [:]
    var stockError: APIError?
    var navErrors: [String: APIError] = [:]
    /// Counts calls so tests can assert on request *shape*: one batch call, not fifteen.
    let stockCalls = Counter()
    let navCalls = Counter()

    func fetchStockQuotes(symbols: [String]) async throws -> [StockQuote] {
        stockCalls.increment()
        if let stockError { throw stockError }
        let wanted = Set(symbols.map { $0.uppercased() })
        return quotes.filter { wanted.contains($0.symbol.uppercased()) }
    }

    func fetchFundNAV(schemeCode: String) async throws -> FundNAV {
        navCalls.increment()
        if let error = navErrors[schemeCode] { throw error }
        guard let nav = navs[schemeCode] else { throw APIError.noData(symbol: schemeCode) }
        return nav
    }
}

/// A transport that replays fixed responses, for testing the client's retry ladder.
struct StubTransport: HTTPTransport {
    /// Consumed in order; the last entry repeats once exhausted.
    let responses: [Result<(Data, Int), APIError>]
    let headers: [String: String]
    let calls = Counter()

    init(responses: [Result<(Data, Int), APIError>], headers: [String: String] = [:]) {
        self.responses = responses
        self.headers = headers
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = min(calls.increment() - 1, responses.count - 1)
        switch responses[index] {
        case .failure(let error):
            throw error
        case .success(let (data, status)):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (data, response)
        }
    }
}

/// Thread-safe call counter. `Mutex` rather than an actor so tests can read it without awaiting.
final class Counter: Sendable {
    private let value = Mutex(0)

    @discardableResult
    func increment() -> Int {
        value.withLock { count in
            count += 1
            return count
        }
    }

    var count: Int { value.withLock { $0 } }
}

// MARK: - Fixed instants

enum Instant {
    /// Builds an instant from IST wall-clock components, which is how every schedule assertion
    /// in this suite is expressed.
    static func ist(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = DayTime.indiaStandardTime

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DayTime.indiaStandardTime
        return calendar.date(from: components)!
    }
}
