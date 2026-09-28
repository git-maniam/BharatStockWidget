import BharatStockCore
import SwiftUI

/// The container app's single window.
///
/// macOS requires a host app to deliver a widget extension, so this exists partly out of
/// necessity. What it is actually *for* is answering the question a widget cannot: when something
/// looks wrong, what happened and what should I change?
struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if model.appGroupUnavailable {
                    appGroupWarning
                }
                if let problem = model.setupProblem {
                    Callout(style: .warning, title: "Setup needs your attention", message: problem)
                }

                SetupSection(model: model)
                StatusSection(model: model)

                if let instrument = model.selectedInstrument {
                    InstrumentDetailSection(instrument: instrument, cache: model.cache) {
                        model.selectedInstrument = nil
                    }
                }

                ConfigurationSection(model: model)
                DiagnosticsSection(model: model)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BharatStock Widget")
                .font(.largeTitle.weight(.semibold))
            Text("Daily prices for Indian stocks and mutual funds, on your desktop.")
                .foregroundStyle(.secondary)
        }
    }

    private var appGroupWarning: some View {
        Callout(
            style: .error,
            title: "The widget cannot see this app's data",
            message: """
                The App Group container is unavailable, so the widget has nowhere to read from. \
                This almost always means DEVELOPMENT_TEAM is unset in Config/Signing.xcconfig — \
                macOS requires the App Group identifier to be prefixed with your Team ID. Set it, \
                rebuild, and reopen this app.
                """
        )
    }
}

// MARK: - Setup

private struct SetupSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section2(title: "API key") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SecureField("bsk_live_…", text: $model.apiKeyField)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Button("Save") { model.saveAPIKey() }
                        .disabled(model.apiKeyField == (model.configuration?.apiKey ?? ""))
                }

                // §2 requires this sentence, in plain language, on the setup screen.
                Text("""
                    Your key is stored in plain text in config.json so that one file is all you \
                    ever need to edit. That file is created readable only by you, and the app \
                    resets its permissions on every launch — but don't share it, attach it to a \
                    bug report, or commit it to a repository.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.hasAPIKey {
                    Callout(
                        style: .warning,
                        title: "No API key set",
                        message: """
                            Get one free at bharatstockapi.com and paste it above. Until then the \
                            widget will show its last data, labelled as out of date.
                            """
                    )
                }
                if let message = model.lastRefreshMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Status

private struct StatusSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section2(title: "Status") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    row("Instruments", model.instrumentCountSummary)
                    row("Refresh windows", model.refreshWindowSummary)
                    row("Request budget", model.budgetSummary)
                    row("Widget data", cacheSummary)
                    if let tradingDate = model.cache?.sourceTradingDate,
                       let readable = NumberFormatting.shortMarketDate(tradingDate) {
                        row("Price session", "\(readable) — the API publishes completed sessions only")
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await model.refreshNow() }
                    } label: {
                        if model.isRefreshing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Refreshing…")
                            }
                        } else {
                            Text("Refresh now")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRefreshing)

                    Text("At most one manual refresh every five minutes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let messages = model.cache?.messages, !messages.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(messages, id: \.self) { message in
                            Label(message, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var cacheSummary: String {
        guard let cache = model.cache else { return "No data yet — press Refresh now" }
        let age = cache.lastSuccessfulFetchUTC.map {
            "updated \(NumberFormatting.relativeAge(of: $0)) (\(NumberFormatting.istClockTime($0)))"
        } ?? "never fetched"
        return "\(cache.status.rawValue) · \(cache.rows.count) rows · \(age)"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Configuration

private struct ConfigurationSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section2(title: "Configuration file") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Edit this file and save; the widget picks the change up at the next refresh, or immediately if you press Refresh now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppPaths.friendlyConfigLink.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )

                if let outcome = model.linkOutcome {
                    Text(describe(outcome))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("Open in editor") { model.openConfigInEditor() }
                    Button("Reveal in Finder") { model.revealConfigInFinder() }
                    Button("Reveal logs") { model.revealLogsInFinder() }
                }
            }
        }
    }

    private func describe(_ outcome: FileStore.FriendlyLinkOutcome) -> String {
        switch outcome {
        case .created, .alreadyCorrect, .repointed:
            """
            That path is a link to the real file inside the app's shared container, which is the \
            only place a sandboxed widget is allowed to read. Editing either path edits the same \
            file. README.txt beside it explains every field.
            """
        case .blockedByRegularFile(let url):
            "A real file at \(url.path) is in the way, so that shortcut is not available yet."
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section2(title: "Diagnostics") {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.loadError {
                    Callout(
                        style: .error,
                        title: "config.json could not be read",
                        message: """
                            \(error.userFacingReason)

                            Your file has not been modified, and the widget is still showing the \
                            last data it successfully fetched. Fix the file and it will be picked \
                            up within a second of saving.
                            """
                    )
                }

                if model.diagnostics.isEmpty, model.loadError == nil {
                    Label("No problems found in config.json.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.diagnostics) { diagnostic in
                        DiagnosticRow(diagnostic: diagnostic)
                    }
                }
            }
        }
    }
}

private struct DiagnosticRow: View {
    let diagnostic: ConfigDiagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: diagnostic.severity == .error
                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostic.severity == .error
                                 ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange))

            VStack(alignment: .leading, spacing: 2) {
                Text(location)
                    .font(.callout.weight(.medium))
                Text(diagnostic.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
    }

    private var location: String {
        // Instruments are one-based in the message because that is how a person counts a list.
        if let index = diagnostic.index {
            return "Instrument \(index + 1) — \(diagnostic.rawValue)"
        }
        return diagnostic.rawValue
    }
}

// MARK: - Instrument detail (§11.5)

private struct InstrumentDetailSection: View {
    let instrument: Instrument
    let cache: QuoteCache?
    let onClose: () -> Void

    private var row: CacheRow? {
        cache?.rows.first { $0.type == instrument.type && $0.symbol == instrument.symbol }
    }

    var body: some View {
        Section2(title: row?.fullName ?? instrument.symbol) {
            VStack(alignment: .leading, spacing: 8) {
                if let row {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        detail("Symbol", row.symbol)
                        detail("Type", row.type == .stock ? "Stock" : "Mutual fund")
                        detail("Shown as", row.displayName)
                        detail("State", row.state.rawValue)
                        if let stock = row.stock {
                            detail("Session low", stock.low.map { NumberFormatting.price($0) } ?? "—")
                            detail("Session high", stock.high.map { NumberFormatting.price($0) } ?? "—")
                            detail("Close", stock.last.map { NumberFormatting.price($0) } ?? "—")
                            detail("Session date", stock.tradeDate ?? "—")
                        }
                        if let fund = row.mf {
                            detail("NAV", fund.nav.map(NumberFormatting.nav) ?? "—")
                            detail("NAV date", fund.navDate ?? "—")
                        }
                        if let change = row.changePercent {
                            detail(
                                "Change",
                                "\(NumberFormatting.directionGlyph(change)) \(NumberFormatting.changePercent(change))"
                            )
                        }
                        if let note = row.note {
                            detail("Note", note)
                        }
                    }
                } else {
                    Text("\(instrument.symbol) is not in the current cache yet.")
                        .foregroundStyle(.secondary)
                }

                Button("Close", action: onClose)
            }
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Shared chrome

/// A titled block. Named `Section2` to avoid colliding with SwiftUI's `Section`.
private struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor))
        )
    }
}

private struct Callout: View {
    enum Style { case warning, error }

    let style: Style
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35)))
    }

    private var tint: Color {
        style == .error ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange)
    }
}
