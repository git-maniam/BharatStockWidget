import Foundation
import Testing
@testable import BharatStockCore

@Suite("REST client")
struct RESTClientTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func client(
        root: borrowing TempRoot,
        transport: HTTPTransport,
        limit: Int = 50
    ) -> BharatStockRESTClient {
        BharatStockRESTClient(
            apiKey: "bsk_live_testkey_0123456789",
            budget: RequestBudget(paths: root.paths, limit: limit, schedule: RefreshSchedule(.default)),
            transport: transport,
            retryPolicy: .deterministic,
            sleeper: { _ in }  // the ladder is exercised without actually waiting
        )
    }

    // MARK: - Decoding the real wire format

    @Test("A live batch-quotes response decodes, including the not-found entry")
    func decodesBatchQuotes() async throws {
        let root = TempRoot()
        let transport = StubTransport(responses: [.success((try Self.fixture("quotes-batch"), 200))])
        let quotes = try await client(root: root, transport: transport)
            .fetchStockQuotes(symbols: ["RELIANCE", "TCS", "HDFCBANK", "NOTATICKER"])

        #expect(quotes.count == 4)

        let reliance = try #require(quotes.first { $0.symbol == "RELIANCE" })
        #expect(reliance.companyName == "Reliance Industries Limited")
        #expect(reliance.tradeDate == "2026-09-25")
        #expect(reliance.low == 1210.5)
        #expect(reliance.high == 1227.4)
        #expect(reliance.close == 1226.0)
        #expect(reliance.previousClose == 1219.2)
        #expect(reliance.changePercent == 0.56)
        #expect(reliance.hasUsablePrices)

        // `found: false` with null prices is how the API reports an unknown ticker — not an error.
        let missing = try #require(quotes.first { $0.symbol == "NOTATICKER" })
        #expect(!missing.found)
        #expect(!missing.hasUsablePrices)
        #expect(missing.close == nil)
    }

    @Test("A live NAV response yields the latest value and the one before it")
    func decodesNAV() async throws {
        let root = TempRoot()
        let transport = StubTransport(responses: [.success((try Self.fixture("mf-nav"), 200))])
        let nav = try await client(root: root, transport: transport).fetchFundNAV(schemeCode: "122639")

        #expect(nav.schemeCode == "122639")
        #expect(nav.schemeName == "Parag Parikh Flexi Cap Fund")
        #expect(nav.nav == 108.1525)
        #expect(nav.navDate == "2026-09-25")
        #expect(nav.previousNAV == 108.0528)
        // (108.1525 - 108.0528) / 108.0528 × 100
        let change = try #require(nav.changePercent)
        #expect(abs(change - 0.0923) < 0.001)
    }

    @Test("An empty NAV series is reported as no-data, not as a decode failure")
    func emptyNAVSeries() async throws {
        let root = TempRoot()
        let body = Data(#"{"scheme_code":"999999","scheme_name":"Nothing","count":0,"data":[]}"#.utf8)
        let transport = StubTransport(responses: [.success((body, 200))])

        await #expect(throws: APIError.noData(symbol: "999999")) {
            _ = try await client(root: root, transport: transport).fetchFundNAV(schemeCode: "999999")
        }
    }

    @Test("Fifteen symbols still go out as a single request")
    func batchesInOneRequest() async throws {
        let root = TempRoot()
        let transport = StubTransport(responses: [.success((Data("[]".utf8), 200))])
        _ = try await client(root: root, transport: transport)
            .fetchStockQuotes(symbols: (1...15).map { "SYM\($0)" })

        #expect(transport.calls.count == 1)
        #expect(RequestCost.stockRequests(symbolCount: 15) == 1)
        #expect(RequestCost.stockRequests(symbolCount: 51) == 2, "the 50-symbol cap is respected")
    }

    @Test("An empty symbol list costs nothing")
    func emptySymbolsCostNothing() async throws {
        let root = TempRoot()
        let transport = StubTransport(responses: [.success((Data("[]".utf8), 200))])
        let quotes = try await client(root: root, transport: transport).fetchStockQuotes(symbols: [])

        #expect(quotes.isEmpty)
        #expect(transport.calls.count == 0)
    }

    // MARK: - Retry policy (§5)

    @Test("A 5xx is retried twice, then gives up")
    func retriesServerErrors() async throws {
        let root = TempRoot()
        let transport = StubTransport(responses: [.success((Data("{}".utf8), 503))])

        await #expect(throws: APIError.self) {
            _ = try await client(root: root, transport: transport).fetchStockQuotes(symbols: ["TCS"])
        }
        #expect(transport.calls.count == RetryPolicy.maxAttempts)
        #expect(transport.calls.count == 3, "one attempt plus two retries")
    }

    @Test("A transient failure followed by success returns data")
    func recoversAfterTransientFailure() async throws {
        let root = TempRoot()
        let transport = StubTransport(responses: [
            .failure(.transport("connection reset")),
            .success((try Self.fixture("quotes-batch"), 200)),
        ])

        let quotes = try await client(root: root, transport: transport)
            .fetchStockQuotes(symbols: ["RELIANCE"])
        #expect(quotes.contains { $0.symbol == "RELIANCE" })
        #expect(transport.calls.count == 2)
    }

    @Test("A 4xx other than 429 is never retried")
    func doesNotRetryClientErrors() async throws {
        for status in [400, 401, 403, 404, 422] {
            let root = TempRoot()
            let transport = StubTransport(
                responses: [.success((Data(#"{"detail":"nope"}"#.utf8), status))]
            )
            await #expect(throws: APIError.self) {
                _ = try await client(root: root, transport: transport).fetchStockQuotes(symbols: ["TCS"])
            }
            #expect(
                transport.calls.count == 1,
                "HTTP \(status) means a bad key or symbol; retrying only burns the ceiling"
            )
        }
    }

    @Test("Retry delays are 2s then 8s, and stop after two")
    func backoffLadder() throws {
        let policy = RetryPolicy.deterministic
        #expect(try policy.delay(retryIndex: 0, serverRequested: nil) == 2)
        #expect(try policy.delay(retryIndex: 1, serverRequested: nil) == 8)
        #expect(try policy.delay(retryIndex: 2, serverRequested: nil) == nil)
    }

    @Test("Jitter stays inside ±20%")
    func jitterBounds() throws {
        let policy = RetryPolicy()
        for _ in 0..<200 {
            // `delay` itself throws, so it is called before `#require` rather than inside it.
            let firstDelay = try policy.delay(retryIndex: 0, serverRequested: nil)
            let secondDelay = try policy.delay(retryIndex: 1, serverRequested: nil)
            let first = try #require(firstDelay)
            let second = try #require(secondDelay)
            #expect((1.6...2.4).contains(first), "\(first) outside 2s ±20%")
            #expect((6.4...9.6).contains(second), "\(second) outside 8s ±20%")
        }
    }

    @Test("A Retry-After header wins over the backoff ladder")
    func honoursRetryAfter() throws {
        let policy = RetryPolicy.deterministic
        #expect(try policy.delay(retryIndex: 0, serverRequested: 30) == 30)
        // §5: abandon the cycle if it exceeds 120 seconds.
        #expect(throws: APIError.backoffTooLong(300)) {
            _ = try policy.delay(retryIndex: 0, serverRequested: 300)
        }
        #expect(try policy.delay(retryIndex: 0, serverRequested: 120) == 120)
    }

    @Test("Retry-After is parsed from both seconds and an HTTP date")
    func parsesRetryAfter() throws {
        func response(_ value: String?) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil,
                headerFields: value.map { ["Retry-After": $0] } ?? [:]
            )!
        }
        #expect(BharatStockRESTClient.retryAfter(from: response("42")) == 42)
        #expect(BharatStockRESTClient.retryAfter(from: response(nil)) == nil)
        #expect(BharatStockRESTClient.retryAfter(from: response("not a duration")) == nil)

        let future = Date.now.addingTimeInterval(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let parsed = try #require(BharatStockRESTClient.retryAfter(from: response(formatter.string(from: future))))
        #expect(abs(parsed - 60) < 2)
    }

    @Test("A 429 with a long Retry-After abandons immediately")
    func longRetryAfterAbandons() async throws {
        let root = TempRoot()
        let transport = StubTransport(
            responses: [.success((Data(#"{"detail":"slow down"}"#.utf8), 429))],
            headers: ["Retry-After": "600"]
        )
        await #expect(throws: APIError.backoffTooLong(600)) {
            _ = try await client(root: root, transport: transport).fetchStockQuotes(symbols: ["TCS"])
        }
        #expect(transport.calls.count == 1)
    }

    // MARK: - Budget interaction

    @Test("Every attempt, retries included, is charged to the budget")
    func retriesConsumeBudget() async throws {
        let root = TempRoot()
        let budget = RequestBudget(paths: root.paths, limit: 50, schedule: RefreshSchedule(.default))
        let transport = StubTransport(responses: [.success((Data("{}".utf8), 500))])
        let client = BharatStockRESTClient(
            apiKey: "bsk_live_testkey_0123456789", budget: budget,
            transport: transport, retryPolicy: .deterministic, sleeper: { _ in }
        )

        await #expect(throws: APIError.self) {
            _ = try await client.fetchStockQuotes(symbols: ["TCS"])
        }
        #expect(await budget.current().spent == 3, "§5: each retry consumes budget")
    }

    @Test("Retries stop when the budget runs dry rather than throwing past the ceiling")
    func retriesStopAtCeiling() async throws {
        let root = TempRoot()
        let budget = RequestBudget(paths: root.paths, limit: 2, schedule: RefreshSchedule(.default))
        let transport = StubTransport(responses: [.success((Data("{}".utf8), 500))])
        let client = BharatStockRESTClient(
            apiKey: "bsk_live_testkey_0123456789", budget: budget,
            transport: transport, retryPolicy: .deterministic, sleeper: { _ in }
        )

        await #expect(throws: (any Error).self) {
            _ = try await client.fetchStockQuotes(symbols: ["TCS"])
        }
        #expect(await budget.current().spent <= 2, "the ceiling is never crossed")
        #expect(transport.calls.count <= 2)
    }

    @Test("No key means no request at all")
    func missingKeyIssuesNoRequest() async throws {
        let root = TempRoot()
        let transport = StubTransport(responses: [.success((Data("[]".utf8), 200))])
        let client = BharatStockRESTClient(
            apiKey: "",
            budget: RequestBudget(paths: root.paths, limit: 50, schedule: RefreshSchedule(.default)),
            transport: transport
        )

        await #expect(throws: APIError.missingAPIKey) {
            _ = try await client.fetchStockQuotes(symbols: ["TCS"])
        }
        #expect(transport.calls.count == 0)
    }

    // MARK: - Error surfacing

    @Test("A FastAPI `detail` body is surfaced, with any key scrubbed out")
    func errorDetailExtraction() {
        let key = "bsk_live_secret_value_here"
        #expect(
            BharatStockRESTClient.errorDetail(
                from: Data(#"{"detail":"Invalid API key"}"#.utf8), apiKey: key
            ) == "Invalid API key"
        )
        // FastAPI validation errors come back as a list of objects.
        #expect(
            BharatStockRESTClient.errorDetail(
                from: Data(#"{"detail":[{"msg":"field required"},{"msg":"bad symbol"}]}"#.utf8),
                apiKey: key
            ) == "field required; bad symbol"
        )
        // A body that echoes the key back must not leak it.
        let leaky = BharatStockRESTClient.errorDetail(
            from: Data(#"{"detail":"key \#(key) is not valid"}"#.utf8), apiKey: key
        )
        #expect(!leaky.contains(key))
        // Unparseable bodies degrade quietly rather than masking the status code.
        #expect(BharatStockRESTClient.errorDetail(from: Data("<html>502</html>".utf8), apiKey: key) == "")
    }

    @Test("Which errors are retryable, and which mean the key is wrong")
    func errorClassification() {
        #expect(APIError.transport("x").isRetryable)
        #expect(APIError.http(status: 500, detail: "", retryAfter: nil).isRetryable)
        #expect(APIError.http(status: 429, detail: "", retryAfter: nil).isRetryable)
        #expect(!APIError.http(status: 404, detail: "", retryAfter: nil).isRetryable)
        #expect(!APIError.http(status: 401, detail: "", retryAfter: nil).isRetryable)
        #expect(!APIError.noData(symbol: "X").isRetryable)

        #expect(APIError.http(status: 401, detail: "", retryAfter: nil).isAuthFailure)
        #expect(APIError.http(status: 403, detail: "", retryAfter: nil).isAuthFailure)
        #expect(APIError.missingAPIKey.isAuthFailure)
        #expect(!APIError.http(status: 500, detail: "", retryAfter: nil).isAuthFailure)
    }

    @Test("Malformed JSON from the API is a decoding error, not a crash")
    func malformedResponse() async throws {
        let root = TempRoot()
        let transport = StubTransport(responses: [.success((Data("{ not json".utf8), 200))])

        await #expect(throws: APIError.self) {
            _ = try await client(root: root, transport: transport).fetchStockQuotes(symbols: ["TCS"])
        }
        // A decode failure is permanent, so it must not be retried.
        #expect(transport.calls.count == 1)
    }

    @Test("The request carries the key in the X-API-Key header")
    func requestShape() async throws {
        let root = TempRoot()
        let recorder = RequestRecorder()
        _ = try? await client(root: root, transport: recorder).fetchStockQuotes(symbols: ["RELIANCE", "TCS"])

        let request = try #require(recorder.lastRequest)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "bsk_live_testkey_0123456789")
        #expect(request.httpMethod == "GET")

        let url = try #require(request.url)
        #expect(url.path == "/v1/stocks/quotes")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try #require(components.queryItems)
        #expect(query.first { $0.name == "symbols" }?.value == "RELIANCE,TCS")
    }
}

/// Captures the last request so the wire shape can be asserted.
final class RequestRecorder: HTTPTransport, @unchecked Sendable {
    private(set) var lastRequest: URLRequest?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:]
        )!
        return (Data("[]".utf8), response)
    }
}
