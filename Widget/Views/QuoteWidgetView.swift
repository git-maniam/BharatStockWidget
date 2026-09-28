import BharatStockCore
import SwiftUI
import WidgetKit

/// The widget's root view.
///
/// There is no error case here that renders nothing: §10 requires that network failures, a bad
/// key and a malformed config each produce a legible state, so every path below ends in text the
/// user can act on.
struct QuoteWidgetView: View {
    let entry: QuoteEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appearanceOverrides) private var overrides
    @ScaledMetric(relativeTo: .caption) private var rowSpacing: CGFloat = 3

    private var reduceMotion: Bool {
        overrides.reduceMotion ?? systemReduceMotion
    }

    private var rows: [CacheRow] {
        entry.cache.rows(limit: RowLayout.rowCount(for: family))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            if rows.isEmpty {
                emptyState
            } else {
                rowList
                if !RowLayout.isCompact(family) {
                    Spacer(minLength: 0)
                    Divider().overlay(Appearance.separator)
                    WidgetFooterView(cache: entry.cache, now: entry.date)
                }
            }
        }
        .padding(.horizontal, RowLayout.isCompact(family) ? 2 : 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackgroundTreatment()
        .respectingReduceMotion(reduceMotion)
        // §11.5: clicking a row opens the app focused on that instrument. At Small the whole
        // widget is one link, because individual rows are too small to target reliably.
        .widgetURL(RowLayout.isCompact(family) ? InstrumentLink.appHome : nil)
    }

    // MARK: - Pieces

    private var rowList: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(rows) { row in
                if RowLayout.isCompact(family) {
                    QuoteRowView(row: row, display: entry.display, family: family)
                } else {
                    Link(destination: InstrumentLink.url(type: row.type, symbol: row.symbol)) {
                        QuoteRowView(row: row, display: entry.display, family: family)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Shown when there is nothing to render — a fresh install, or a config with no valid entries.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BharatStock")
                .font(.caption.weight(.semibold))
            Text(entry.cache.messages.first ?? "No instruments configured")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !RowLayout.isCompact(family) {
                Text("Open BharatStock Widget to set up")
                    .font(.system(size: 9))
                    .foregroundStyle(Appearance.faint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
