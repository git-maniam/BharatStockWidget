import Foundation

/// The live data source: BharatStock's REST API over `URLSession`.
///
/// Chosen over the MCP server because the supplied key is on the Free plan, which the MCP server
/// declines outright (`docs/decisions.md` F1, and `docs/mcp-tools.md` for the full substitution
/// record). Everything the widget renders is available here, and the batch quote endpoint makes it
/// markedly cheaper: one request covers every stock in the config.
public struct BharatStockRESTClient: QuoteSource {
    public static let defaultBaseURL = URL(string: "https://bharatstockapi.com/v1")!

    private let apiKey: String
    private let baseURL: URL
    private let transport: HTTPTransport
    private let budget: RequestBudget
    private let retryPolicy: RetryPolicy
    private let log: LogSink
    /// Injected so tests exercise the retry ladder without actually waiting 10 seconds.
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(
        apiKey: String,
        budget: RequestBudget,
        baseURL: URL = BharatStockRESTClient.defaultBaseURL,
        transport: HTTPTransport = URLSessionTransport(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        log: LogSink = .none,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.budget = budget
        self.baseURL = baseURL
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.log = log
        self.sleeper = sleeper ?? { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    }

    // MARK: - QuoteSource

    public func fetchStockQuotes(symbols: [String]) async throws -> [StockQuote] {
        guard !symbols.isEmpty else { return [] }
        var quotes: [StockQuote] = []
        // The endpoint accepts 50 tickers per call; the widget renders at most 15, so this loop
        // runs once in practice and exists only so the contract is honoured if that ever changes.
        for chunk in symbols.chunked(into: RequestCost.batchLimit) {
            let data = try await perform(
                request(path: "stocks/quotes", query: [.init(name: "symbols", value: chunk.joined(separator: ","))]),
                label: "stocks/quotes(\(chunk.count))"
            )
            let items: [QuoteItemDTO]
            do {
                items = try APICoding.decoder.decode([QuoteItemDTO].self, from: data)
            } catch {
                throw APIError.decoding("stocks/quotes: \(error.localizedDescription)")
            }
            quotes.append(contentsOf: items.map(\.asQuote))
        }
        return quotes
    }

    public func fetchFundNAV(schemeCode: String) async throws -> FundNAV {
        // Two points is all we need: the latest NAV and the one before it, for the change figure.
        // The endpoint returns newest-first, and defaults to a year of history if left alone.
        let data = try await perform(
            request(
                path: "mf/schemes/\(schemeCode)/nav",
                query: [.init(name: "limit", value: "2")]
            ),
            label: "mf/nav(\(schemeCode))"
        )

        let response: NAVResponseDTO
        do {
            response = try APICoding.decoder.decode(NAVResponseDTO.self, from: data)
        } catch {
            throw APIError.decoding("mf/nav: \(error.localizedDescription)")
        }
        guard let latest = response.data.first else {
            throw APIError.noData(symbol: schemeCode)
        }
        let previous = response.data.dropFirst().first
        return FundNAV(
            schemeCode: response.schemeCode ?? schemeCode,
            schemeName: response.schemeName,
            nav: latest.nav,
            navDate: latest.date,
            previousNAV: previous?.nav,
            previousNAVDate: previous?.date
        )
    }

    // MARK: - Request plumbing

    private func request(path: String, query: [URLQueryItem]) throws(APIError) -> URLRequest {
        guard !apiKey.isEmpty else { throw APIError.missingAPIKey }

        var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query
        guard let url = components?.url else {
            throw APIError.transport("Could not build a URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "BharatStockWidget/1.0 (macOS; +\(AppIdentity.appBundleID))",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    /// Issues a request, charging the budget before *every* attempt and retrying per §5.
    ///
    /// `consume` deliberately happens before the socket is opened rather than after a response
    /// arrives: a crash in between can then only over-count, never under-count, which is the
    /// direction a ceiling has to err in.
    private func perform(_ request: URLRequest, label: String) async throws -> Data {
        var lastError: APIError = .transport("No attempt was made")

        for attempt in 0..<RetryPolicy.maxAttempts {
            try await budget.consume(1)
            log.debug("→ \(label) attempt \(attempt + 1) key=\(Redaction.apiKey(apiKey))", category: .api)

            do {
                let (data, response) = try await transport.send(request)
                guard (200...299).contains(response.statusCode) else {
                    throw APIError.http(
                        status: response.statusCode,
                        detail: Self.errorDetail(from: data, apiKey: apiKey),
                        retryAfter: Self.retryAfter(from: response)
                    )
                }
                return data
            } catch let error as APIError {
                lastError = error
                guard error.isRetryable else { throw error }

                let delay = try retryPolicy.delay(
                    retryIndex: attempt,
                    serverRequested: error.serverRequestedDelay
                )
                guard let delay else { break }

                // A retry is pointless if there is nothing left to spend it with.
                guard await budget.canSpend(1) else {
                    log.warning("\(label): out of budget, abandoning retries", category: .budget)
                    throw error
                }
                log.warning(
                    "\(label) failed (\(error.userFacingReason)); retrying in \(String(format: "%.1f", delay))s",
                    category: .api
                )
                try await sleeper(delay)
            }
        }
        throw lastError
    }

    // MARK: - Response inspection

    /// FastAPI puts a human-readable reason in `detail`, which may be a string or a list of
    /// validation objects. Anything unrecognised degrades to an empty string rather than throwing —
    /// we are already on an error path and should not mask the real status code.
    static func errorDetail(from data: Data, apiKey: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"]
        else { return "" }

        let text: String
        switch detail {
        case let string as String: text = string
        case let list as [Any]:
            text = list.compactMap { ($0 as? [String: Any])?["msg"] as? String }
                .joined(separator: "; ")
        default: text = ""
        }
        return Redaction.scrub(text, key: apiKey)
    }

    /// `Retry-After` is either a delay in seconds or an HTTP date; both are legal.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        if let date = httpDateFormatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

// MARK: - Wire types

/// Decoding conventions for the API, which is snake_case throughout.
/// Separate from `JSONCoding`, whose camelCase files are ours.
enum APICoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

struct QuoteItemDTO: Decodable {
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
            symbol: symbol,
            companyName: companyName,
            tradeDate: tradeDate,
            open: open,
            high: high,
            low: low,
            close: close,
            previousClose: prevClose,
            changePercent: changePct,
            volume: volume,
            // The schema defaults `found` to true; absent means present.
            found: found ?? true
        )
    }
}

struct NAVResponseDTO: Decodable {
    var schemeCode: String?
    var schemeName: String?
    var count: Int?
    var data: [NAVPointDTO]
}

struct NAVPointDTO: Decodable {
    var date: String
    var nav: Double
}

// MARK: -

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
