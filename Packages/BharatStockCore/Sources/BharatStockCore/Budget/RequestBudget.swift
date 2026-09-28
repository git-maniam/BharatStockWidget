import Foundation

/// On-disk budget ledger (spec §5).
public struct BudgetLedger: Codable, Sendable, Equatable {
    public var windowStartUTC: Date
    public var spent: Int
    public var limit: Int

    public init(windowStartUTC: Date, spent: Int, limit: Int) {
        self.windowStartUTC = windowStartUTC
        self.spent = spent
        self.limit = limit
    }

    public var remaining: Int { max(0, limit - spent) }
}

public enum BudgetError: Error, Sendable, Equatable {
    /// The ceiling was reached. The caller must not issue the request.
    case exhausted(spent: Int, limit: Int)
    /// The cycle's worst case would eat into the five-request reserve (§5).
    case insufficientHeadroom(required: Int, available: Int, reserve: Int)
}

/// The hard ceiling on outbound API requests.
///
/// Every call site must `consume` *before* issuing its request, so a crash between the two can
/// only ever over-count — never under-count — and the ceiling stays a safety property rather than
/// an estimate. The window rolls at midnight in the market zone.
///
/// The free plan's real server-side limit is 50/day, which is where the spec's number comes from;
/// this ledger is shared with anything else using the same key, so it is a best-effort mirror of
/// the server's count, deliberately biased towards under-spending.
public actor RequestBudget {
    /// §5: always keep this many requests back so a manual refresh or a retry stays possible.
    public static let reserve = 5

    private let ledgerURL: URL
    private let store: FileStore
    private let schedule: RefreshSchedule
    private let limit: Int
    private var ledger: BudgetLedger?

    public init(
        paths: AppPaths,
        limit: Int,
        schedule: RefreshSchedule,
        store: FileStore = FileStore()
    ) {
        self.ledgerURL = paths.budget
        self.limit = limit
        self.schedule = schedule
        self.store = store
    }

    /// Current ledger, after rolling the window if the market date has changed.
    public func current(now: Date = .now) -> BudgetLedger {
        let midnight = schedule.mostRecentMarketMidnight(at: now)

        var resolved: BudgetLedger
        if let ledger {
            resolved = ledger
        } else {
            resolved = (try? store.read(ledgerURL))
                .flatMap { try? JSONCoding.decoder.decode(BudgetLedger.self, from: $0) }
                ?? BudgetLedger(windowStartUTC: midnight, spent: 0, limit: limit)
        }

        if resolved.windowStartUTC < midnight {
            resolved = BudgetLedger(windowStartUTC: midnight, spent: 0, limit: limit)
        }
        // A config edit to `maxRequestsPerDay` takes effect immediately, without resetting spend.
        resolved.limit = limit
        ledger = resolved
        return resolved
    }

    /// Reserves `count` requests. Throws rather than returning a flag so a caller cannot
    /// accidentally ignore the result and issue the request anyway.
    public func consume(_ count: Int = 1, now: Date = .now) throws {
        var ledger = current(now: now)
        guard ledger.spent + count <= ledger.limit else {
            throw BudgetError.exhausted(spent: ledger.spent, limit: ledger.limit)
        }
        ledger.spent += count
        try persist(ledger)
    }

    /// Gate for starting a whole refresh cycle: refuses if the worst case would breach the reserve.
    ///
    /// Checked once up front so a cycle either has room to finish — retries included — or never
    /// starts, instead of dying halfway and leaving a half-refreshed cache.
    public func authoriseCycle(worstCaseCost: Int, now: Date = .now) throws {
        let ledger = current(now: now)
        let available = ledger.limit - ledger.spent - Self.reserve
        guard worstCaseCost <= available else {
            throw BudgetError.insufficientHeadroom(
                required: worstCaseCost,
                available: max(0, available),
                reserve: Self.reserve
            )
        }
    }

    /// Whether a single request can still be made at all, ignoring the cycle reserve.
    /// Manual refreshes and retries are allowed to draw on the reserve — that is its purpose.
    public func canSpend(_ count: Int = 1, now: Date = .now) -> Bool {
        let ledger = current(now: now)
        return ledger.spent + count <= ledger.limit
    }

    /// Human-readable status for the container app (§5).
    public func summary(now: Date = .now) -> String {
        let ledger = current(now: now)
        return "\(ledger.spent) of \(ledger.limit) requests used today, resets at midnight IST."
    }

    private func persist(_ ledger: BudgetLedger) throws {
        self.ledger = ledger
        try store.writeAtomically(try JSONCoding.encoder.encode(ledger), to: ledgerURL)
    }
}
