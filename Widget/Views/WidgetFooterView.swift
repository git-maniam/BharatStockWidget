import BharatStockCore
import SwiftUI

/// The one-line footer shown at every size except Small (§7).
///
/// When data is stale it says so in words. A silently stale stock widget is worse than an empty
/// one, so freshness is never left to be inferred from the numbers.
struct WidgetFooterView: View {
    let cache: QuoteCache
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            if let glyph = statusGlyph {
                Image(systemName: glyph)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .help(accessibilityText)
    }

    // MARK: - Text

    private var text: String {
        switch cache.status {
        case .ok:
            freshText
        case .stale:
            staleText
        case .partial:
            cache.messages.first ?? "Partly updated · \(freshText)"
        case .budgetExhausted:
            "Daily request limit reached · \(budgetText)"
        case .configError:
            cache.messages.first ?? "Check config.json"
        case .authError:
            cache.messages.first ?? "API key rejected"
        }
    }

    /// `10:30 IST · updated 2m ago` — the as-of time in IST plus a readable age.
    private var freshText: String {
        guard let fetched = cache.lastSuccessfulFetchUTC else { return "No data yet" }
        return "\(NumberFormatting.istClockTime(fetched)) · updated \(NumberFormatting.relativeAge(of: fetched, now: now))"
    }

    /// `Stale · last updated Fri 25 Sep 21:30 IST` — explicit, per §7.
    private var staleText: String {
        guard let fetched = cache.lastSuccessfulFetchUTC else {
            return cache.messages.first ?? "No data yet"
        }
        return "Stale · last updated \(NumberFormatting.weekdayAndShortDate(fetched)) "
            + NumberFormatting.istClockTime(fetched)
    }

    private var budgetText: String {
        "\(cache.budget.spent)/\(cache.budget.limit) today"
    }

    private var statusGlyph: String? {
        switch cache.status {
        case .ok: nil
        case .stale: "clock.badge.exclamationmark"
        case .partial: "exclamationmark.circle"
        case .budgetExhausted: "gauge.with.dots.needle.0percent"
        case .configError: "doc.badge.gearshape"
        case .authError: "key.slash"
        }
    }

    private var accessibilityText: String {
        var parts = [text]
        if let tradingDate = cache.sourceTradingDate,
           let readable = NumberFormatting.shortMarketDate(tradingDate) {
            // Worth spelling out: this is the session the prices belong to, which is not
            // necessarily today. See docs/decisions.md F8.
            parts.append("prices are from the session of \(readable)")
        }
        parts.append("\(cache.budget.spent) of \(cache.budget.limit) API requests used today")
        parts.append(contentsOf: cache.messages.dropFirst())
        return parts.joined(separator: ", ")
    }
}
