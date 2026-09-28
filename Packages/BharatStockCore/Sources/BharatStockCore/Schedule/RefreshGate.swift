import Foundation

/// Persisted record of which windows have been served.
public struct RefreshState: Codable, Sendable, Equatable {
    /// The window *boundary instant* most recently satisfied by a successful fetch — not the time
    /// the fetch happened. Storing the boundary is what makes a late fetch still count as serving
    /// that window, so a single window can never be fetched twice.
    public var lastServedWindowUTC: Date?
    public var lastAttemptUTC: Date?
    public var lastManualRefreshUTC: Date?

    public init(
        lastServedWindowUTC: Date? = nil,
        lastAttemptUTC: Date? = nil,
        lastManualRefreshUTC: Date? = nil
    ) {
        self.lastServedWindowUTC = lastServedWindowUTC
        self.lastAttemptUTC = lastAttemptUTC
        self.lastManualRefreshUTC = lastManualRefreshUTC
    }
}

public enum RefreshDecision: Sendable, Equatable {
    /// Go ahead; on success, credit this window boundary.
    case fetch(window: Date?)
    /// This window's data is already in the cache.
    case alreadyServed(window: Date)
    /// The first window of the schedule hasn't come round yet on a fresh install.
    case noWindowElapsed
    /// Manual refresh clicked too soon after the last one (§5).
    case manualThrottled(retryAt: Date)

    public var shouldFetch: Bool {
        if case .fetch = self { return true }
        return false
    }
}

/// Decides whether a wake-up should spend a network request.
///
/// This is the mechanism that replaces `launchd` as the enforcer of "at most N fetches per day".
/// WidgetKit may wake the extension far more often than requested, or much later than requested;
/// neither can cause an extra fetch, because eligibility is derived from *which window boundary
/// has elapsed*, not from elapsed time since the last fetch.
public actor RefreshGate {
    /// §5: manual refresh is capped at one per five minutes regardless of remaining budget.
    public static let manualCooldown: TimeInterval = 5 * 60

    private let stateURL: URL
    private let store: FileStore
    private var cached: RefreshState?

    public init(paths: AppPaths, store: FileStore = FileStore()) {
        self.stateURL = paths.refreshState
        self.store = store
    }

    public func state() -> RefreshState {
        if let cached { return cached }
        let loaded = (try? store.read(stateURL)).flatMap {
            try? JSONCoding.decoder.decode(RefreshState.self, from: $0)
        } ?? RefreshState()
        cached = loaded
        return loaded
    }

    /// Eligibility for an automatic, system-initiated refresh.
    public func decideScheduled(schedule: RefreshSchedule, now: Date = .now) -> RefreshDecision {
        guard let boundary = schedule.mostRecentBoundary(at: now) else { return .noWindowElapsed }
        let served = state().lastServedWindowUTC
        if let served, served >= boundary { return .alreadyServed(window: boundary) }
        return .fetch(window: boundary)
    }

    /// Eligibility for a user-initiated "Refresh now".
    ///
    /// Deliberately ignores window state — the point of the button is to override the schedule —
    /// but is throttled so click-spamming cannot drain the day's budget.
    public func decideManual(now: Date = .now) -> RefreshDecision {
        if let last = state().lastManualRefreshUTC {
            let readyAt = last.addingTimeInterval(Self.manualCooldown)
            if now < readyAt { return .manualThrottled(retryAt: readyAt) }
        }
        return .fetch(window: nil)
    }

    public func recordAttempt(now: Date = .now) throws {
        var next = state()
        next.lastAttemptUTC = now
        try persist(next)
    }

    /// Credits a successful fetch. `window` is nil for manual refreshes, which record the cooldown
    /// stamp but must not consume a scheduled window — otherwise a manual refresh at 09:00 would
    /// suppress the 10:30 one.
    public func recordSuccess(window: Date?, isManual: Bool, now: Date = .now) throws {
        var next = state()
        next.lastAttemptUTC = now
        if let window { next.lastServedWindowUTC = window }
        if isManual { next.lastManualRefreshUTC = now }
        try persist(next)
    }

    private func persist(_ next: RefreshState) throws {
        cached = next
        try store.writeAtomically(try JSONCoding.encoder.encode(next), to: stateURL)
    }
}
