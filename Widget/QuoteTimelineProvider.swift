import BharatStockCore
import SwiftUI
import WidgetKit

/// Carries a non-`Sendable` value across an isolation boundary where the surrounding API
/// guarantees safety but its types do not express it.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

struct QuoteEntry: TimelineEntry {
    let date: Date
    let cache: QuoteCache
    let display: DisplaySettings

    static func placeholder() -> QuoteEntry {
        QuoteEntry(
            date: .now,
            cache: .empty(status: .stale, message: "Loading…"),
            display: .default
        )
    }
}

/// Supplies the widget's timeline, and — because there is no helper process — performs the fetch.
///
/// The spec's architecture had a `launchd` agent own all network I/O. That existed because a
/// sandboxed extension cannot spawn `npx` to run the MCP server; with the REST API over
/// `URLSession` the constraint disappears (see `docs/decisions.md` §2). What replaces `launchd` as
/// the thing that stops the widget hammering the API is `RefreshGate`: WidgetKit decides when to
/// wake this code, and the gate decides whether that wake-up is allowed to spend a request.
struct QuoteTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuoteEntry {
        QuoteEntry.placeholder()
    }

    /// Must be fast and must not touch the network — this drives the widget gallery preview.
    func getSnapshot(in context: Context, completion: @escaping (QuoteEntry) -> Void) {
        let paths = AppPaths.resolved()
        try? ConfigWriter().bootstrap(at: paths)
        completion(
            QuoteEntry(
                date: .now,
                cache: context.isPreview
                    ? SampleData.cache
                    : CacheStore(paths: paths).loadForDisplay(),
                display: currentDisplaySettings(paths: paths)
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuoteEntry>) -> Void) {
        // The fetch is async but `TimelineProvider` is a completion-handler API, so the callback
        // has to cross into a `Task`. WidgetKit's completion is safe to invoke from any context —
        // that is the whole point of a callback-based provider — but the closure type is not marked
        // `Sendable`, hence the explicit box.
        let sink = UncheckedSendableBox(completion)

        Task {
            let paths = AppPaths.resolved()
            try? ConfigWriter().bootstrap(at: paths)
            let coordinator = RefreshCoordinator(
                paths: paths,
                gate: RefreshGate(paths: paths),
                log: LogSink.standard()
            )
            let outcome = await coordinator.refreshIfDue()
            let now = Date.now
            let entry = QuoteEntry(
                date: now, cache: outcome.cache, display: currentDisplaySettings(paths: paths)
            )
            sink.value(
                Timeline(
                    entries: [entry],
                    policy: .after(nextReload(after: now, outcome: outcome, paths: paths))
                )
            )
        }
    }

    // MARK: - Scheduling

    /// When to ask WidgetKit to come back.
    ///
    /// Normally: just after the next IST window, since nothing about the data changes in between —
    /// the API publishes completed sessions only. After a failure: much sooner, because the gate
    /// will not have credited the window and an earlier wake-up is the retry.
    ///
    /// This is a request, not a guarantee. The gate is what keeps the request count correct when
    /// the system ignores it in either direction.
    private func nextReload(after now: Date, outcome: RefreshOutcome, paths: AppPaths) -> Date {
        let schedule = loadedSchedule(paths: paths)
        let nextWindow = schedule.nextBoundary(after: now) ?? now.addingTimeInterval(3600)

        switch outcome.cache.status {
        case .ok:
            // A minute past the boundary, so a small clock skew cannot land us just before it and
            // waste a wake-up on a gate refusal.
            return nextWindow.addingTimeInterval(60)
        case .stale, .partial:
            return min(nextWindow, now.addingTimeInterval(30 * 60))
        case .budgetExhausted:
            // Nothing will change until the budget window rolls at IST midnight.
            return min(nextWindow, now.addingTimeInterval(60 * 60))
        case .configError, .authError:
            // Waiting on the user. Check back occasionally, but do not spin.
            return now.addingTimeInterval(60 * 60)
        }
    }

    private func loadedSchedule(paths: AppPaths) -> RefreshSchedule {
        guard let result = try? ConfigLoader().load(contentsOf: paths.config) else {
            return RefreshSchedule(.default)
        }
        return RefreshSchedule(result.configuration.refresh)
    }

    private func currentDisplaySettings(paths: AppPaths) -> DisplaySettings {
        (try? ConfigLoader().load(contentsOf: paths.config))?.configuration.display ?? .default
    }
}

/// The widget itself.
struct BharatStockQuoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BharatStockQuoteWidget", provider: QuoteTimelineProvider()) { entry in
            QuoteWidgetView(entry: entry)
        }
        .configurationDisplayName("BharatStock")
        .description("Daily prices for your Indian stocks and mutual funds.")
        .supportedFamilies(WidgetSizes.supported)
    }
}
