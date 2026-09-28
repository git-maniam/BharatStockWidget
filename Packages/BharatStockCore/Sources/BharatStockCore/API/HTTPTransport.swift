import Foundation

/// The seam that lets the whole refresh cycle be tested offline against fixtures (§8).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real transport.
///
/// Timeouts are deliberately short. A widget extension's timeline provider is given only a few
/// seconds of wall clock before the system loses patience, so a hung socket must fail fast rather
/// than take the whole refresh down with it.
public struct URLSessionTransport: HTTPTransport {
    public static let requestTimeout: TimeInterval = 20
    public static let resourceTimeout: TimeInterval = 30

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.resourceTimeout
            // The cache file is our cache; an HTTP one would only serve stale prices behind our back.
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("Response was not HTTP")
            }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
}

/// Backoff for the retries spec §5 allows: at most two, 2s then 8s, ±20% jitter.
public struct RetryPolicy: Sendable {
    public static let maxAttempts = 3  // one initial attempt plus two retries
    /// §5: abandon the cycle if the server asks for longer than this.
    public static let maxServerBackoff: TimeInterval = 120

    public let baseDelays: [TimeInterval]
    public let jitterFraction: Double
    /// Injectable so the jitter is deterministic under test.
    private let jitter: @Sendable (ClosedRange<Double>) -> Double

    public init(
        baseDelays: [TimeInterval] = [2, 8],
        jitterFraction: Double = 0.2,
        jitter: (@Sendable (ClosedRange<Double>) -> Double)? = nil
    ) {
        self.baseDelays = baseDelays
        self.jitterFraction = jitterFraction
        self.jitter = jitter ?? { range in Double.random(in: range) }
    }

    /// Never jitters, for tests that assert on exact delays.
    public static let deterministic = RetryPolicy(jitter: { $0.lowerBound + ($0.upperBound - $0.lowerBound) / 2 })

    /// Delay before retry number `retryIndex` (0-based), or nil when retries are exhausted.
    ///
    /// A server-supplied `Retry-After` wins outright — it is the one party that knows when it will
    /// be ready — unless it exceeds `maxServerBackoff`, which is reported as a distinct failure so
    /// the cycle ends instead of sleeping for minutes inside a timeline provider.
    public func delay(retryIndex: Int, serverRequested: TimeInterval?) throws(APIError) -> TimeInterval? {
        if let serverRequested {
            guard serverRequested <= Self.maxServerBackoff else {
                throw APIError.backoffTooLong(serverRequested)
            }
            return serverRequested
        }
        guard retryIndex < baseDelays.count else { return nil }
        let base = baseDelays[retryIndex]
        let spread = base * jitterFraction
        return max(0, jitter((base - spread)...(base + spread)))
    }
}
