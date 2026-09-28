import BharatStockCore
import SwiftUI
import WidgetKit

/// One instrument row.
///
/// Every number shown here was computed when the cache was written; this view only lays out
/// strings. That keeps the timeline provider's work to a decode and a layout pass.
struct QuoteRowView: View {
    let row: CacheRow
    let display: DisplaySettings
    let family: WidgetFamily

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var columnGap: CGFloat = 6

    private var showsChange: Bool {
        RowLayout.showsChangeColumn(
            family: family, typeSize: typeSize, configured: display.showChangePercent
        )
    }

    var body: some View {
        Group {
            if RowLayout.isCompact(family) {
                compactLayout
            } else {
                fullLayout
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .help(tooltip)
    }

    // MARK: - Layouts

    /// Small: name on one line, a single number beneath it.
    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(Appearance.stateColor(row.state))
                .lineLimit(1)

            HStack(spacing: 3) {
                Text(primaryCompactValue)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let change = row.changePercent, row.state.hasValues {
                    Text(NumberFormatting.directionGlyph(change))
                        .font(.system(size: 7))
                        .foregroundStyle(Appearance.changeColor(change))
                }
            }
        }
    }

    /// Medium and up: name, values, and an optional change column.
    private var fullLayout: some View {
        HStack(alignment: .firstTextBaseline, spacing: columnGap) {
            Text(row.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(Appearance.stateColor(row.state))
                .lineLimit(1)
                .layoutPriority(2)

            Spacer(minLength: 2)

            valueColumn
                .layoutPriority(1)

            if showsChange {
                changeColumn
                    .frame(minWidth: 52, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var valueColumn: some View {
        if !row.state.hasValues {
            Text(unavailableText)
                .font(.caption2)
                .foregroundStyle(Appearance.faint)
                .lineLimit(1)
        } else if row.type == .stock {
            // §7: the session low and high are the required values for a stock.
            HStack(spacing: 5) {
                labelledPrice("L", row.stock?.low)
                labelledPrice("H", row.stock?.high)
                if let dateLabel = stockDateLabel {
                    Text(dateLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        } else {
            // §7: NAV is the required value for a fund, always beside its date.
            HStack(spacing: 5) {
                Text("\(display.currencySymbol)\(navText)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let dateLabel = navDateLabel {
                    Text(dateLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func labelledPrice(_ prefix: String, _ value: Double?) -> some View {
        if let value {
            HStack(spacing: 2) {
                Text(prefix)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Appearance.faint)
                Text(NumberFormatting.price(value, decimals: display.decimalPlaces))
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var changeColumn: some View {
        if let change = row.changePercent, row.state.hasValues {
            HStack(spacing: 2) {
                Text(NumberFormatting.directionGlyph(change))
                    .font(.system(size: 8))
                Text(NumberFormatting.changePercent(change))
                    .font(.caption2)
                    .monospacedDigit()
            }
            .foregroundStyle(Appearance.changeColor(change))
        } else {
            Text("—")
                .font(.caption2)
                .foregroundStyle(Appearance.faint)
        }
    }

    // MARK: - Strings

    /// Small shows the range without decimals, or just the high if even that will not fit (§7).
    private var primaryCompactValue: String {
        if row.type == .mutualFund {
            guard let nav = row.mf?.nav else { return "—" }
            return "\(display.currencySymbol)\(NumberFormatting.nav(nav))"
        }
        if let compact = NumberFormatting.compactRange(low: row.stock?.low, high: row.stock?.high) {
            return compact
        }
        if let high = row.stock?.high {
            return "H \(NumberFormatting.price(high, decimals: 0))"
        }
        return "—"
    }

    private var navText: String {
        row.mf?.nav.map(NumberFormatting.nav) ?? "—"
    }

    /// §6: never label a NAV "today" unless its date genuinely is today in IST.
    private var navDateLabel: String? {
        guard let navDate = row.mf?.navDate else { return nil }
        let today = RefreshSchedule(.default).marketDateString(at: .now)
        if navDate == today { return "NAV today" }
        guard let short = NumberFormatting.shortMarketDate(navDate) else { return nil }
        return "NAV · \(short)"
    }

    /// Label completed trading session date for stocks, e.g. "· 25 Sep".
    private var stockDateLabel: String? {
        guard let tradeDate = row.stock?.tradeDate else { return nil }
        guard let short = NumberFormatting.shortMarketDate(tradeDate) else { return nil }
        return "· \(short)"
    }

    private var unavailableText: String {
        row.state == .unavailable ? "no data" : "unavailable"
    }

    // MARK: - Accessibility

    /// §7: regardless of what is shown, the accessibility label carries the untruncated name and
    /// every number spelled out. At Small this is the only place both range values appear.
    private var accessibilityLabel: String {
        var parts = [row.fullName]

        switch row.type {
        case .stock:
            if let stock = row.stock, row.state.hasValues {
                if let low = stock.low, let high = stock.high {
                    parts.append(
                        "session low \(NumberFormatting.price(low, decimals: display.decimalPlaces)) rupees, "
                        + "high \(NumberFormatting.price(high, decimals: display.decimalPlaces)) rupees"
                    )
                }
                if let last = stock.last {
                    parts.append("close \(NumberFormatting.price(last, decimals: display.decimalPlaces)) rupees")
                }
                if let tradeDate = stock.tradeDate,
                   let readable = NumberFormatting.shortMarketDate(tradeDate) {
                    // The API publishes completed sessions only, so the date is not decoration.
                    parts.append("for the session of \(readable)")
                }
            }
        case .mutualFund:
            if let fund = row.mf, row.state.hasValues {
                if let nav = fund.nav {
                    parts.append("net asset value \(NumberFormatting.nav(nav)) rupees")
                }
                if let navDate = fund.navDate,
                   let readable = NumberFormatting.shortMarketDate(navDate) {
                    parts.append("as of \(readable)")
                }
            }
        }

        if let change = row.changePercent, row.state.hasValues {
            let direction = change > 0 ? "up" : (change < 0 ? "down" : "unchanged")
            parts.append("\(direction) \(NumberFormatting.changePercent(change))")
        }

        switch row.state {
        case .stale: parts.append("this row is out of date")
        case .error: parts.append("this row could not be loaded")
        case .unavailable: parts.append("no data is published for this instrument")
        case .fresh: break
        }
        if let note = row.note { parts.append(note) }

        return parts.joined(separator: ", ")
    }

    private var tooltip: String {
        accessibilityLabel
    }
}
