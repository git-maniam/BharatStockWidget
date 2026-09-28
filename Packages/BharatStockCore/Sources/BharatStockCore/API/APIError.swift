import Foundation

public enum APIError: Error, Sendable, Equatable {
    case missingAPIKey
    case transport(String)
    case http(status: Int, detail: String, retryAfter: TimeInterval?)
    case decoding(String)
    /// The symbol resolved, but the API has no data for it. Never retried — retrying a typo
    /// only burns the ceiling (§5).
    case noData(symbol: String)
    /// `Retry-After` asked for longer than we are willing to hold a refresh cycle open.
    case backoffTooLong(TimeInterval)

    /// Only transport failures, 5xx, and 429 are worth another request (§5).
    /// A 401/403 means a bad key and a 404 means a bad symbol; both are permanent until the user acts.
    public var isRetryable: Bool {
        switch self {
        case .transport: true
        case .http(let status, _, _): status == 429 || (500...599).contains(status)
        case .missingAPIKey, .decoding, .noData, .backoffTooLong: false
        }
    }

    /// True when the failure means the key itself is the problem, which the widget surfaces as
    /// `auth_error` rather than a generic failure.
    public var isAuthFailure: Bool {
        if case .http(let status, _, _) = self { return status == 401 || status == 403 }
        if case .missingAPIKey = self { return true }
        return false
    }

    /// Honoured server-requested delay, when there is one.
    public var serverRequestedDelay: TimeInterval? {
        if case .http(_, _, let retryAfter) = self { return retryAfter }
        return nil
    }

    public var userFacingReason: String {
        switch self {
        case .missingAPIKey:
            "No API key set — add yours in BharatStock Widget's setup screen"
        case .transport(let detail):
            "Network error: \(detail)"
        case .http(401, _, _), .http(403, _, _):
            "API key rejected — check or replace it in setup"
        case .http(429, _, _):
            "Rate limited by the API — will retry at the next window"

        case .http(let status, let detail, _):
            detail.isEmpty ? "API returned HTTP \(status)" : "API returned HTTP \(status): \(detail)"
        case .decoding(let detail):
            "Unexpected API response: \(detail)"
        case .noData(let symbol):
            "No data published for \(symbol)"
        case .backoffTooLong(let seconds):
            "API asked us to wait \(Int(seconds))s — giving up until the next window"
        }
    }
}

/// Keeps the key out of logs, cache files, crash reports and the UI (§2).
public enum Redaction {
    /// §2: redact to the first 12 characters, e.g. `bsk_live_0Rs…`.
    public static func apiKey(_ key: String) -> String {
        guard !key.isEmpty else { return "(unset)" }
        guard key.count > 12 else { return "…" }
        return "\(key.prefix(12))…"
    }

    /// Scrubs any `bsk_`-prefixed token out of free text before it reaches a log sink.
    ///
    /// A belt-and-braces pass over strings we did not compose ourselves — API error bodies, for
    /// instance, which echo request context back at us.
    public static func scrub(_ text: String, key: String) -> String {
        var result = text
        if !key.isEmpty {
            result = result.replacingOccurrences(of: key, with: apiKey(key))
        }
        return result.replacingOccurrences(
            of: "bsk_(live|test)_[A-Za-z0-9_\\-]{8,}",
            with: "bsk_$1_…",
            options: .regularExpression
        )
    }
}
