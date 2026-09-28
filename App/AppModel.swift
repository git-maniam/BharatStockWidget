import AppKit
import BharatStockCore
import Observation
import SwiftUI
import WidgetKit

/// State for the container app: first-run setup, live status, and "Refresh now".
///
/// The app is not required for the widget to work — the widget fetches and caches on its own — so
/// nothing here is on the data path. Its jobs are to create the config, keep the hand-editable
/// symlink pointing at it, and explain what the widget is currently doing.
@MainActor
@Observable
final class AppModel {
    // MARK: Observable state

    private(set) var paths: AppPaths
    private(set) var loadResult: ConfigLoadResult?
    private(set) var loadError: ConfigError?
    private(set) var cache: QuoteCache?
    private(set) var budgetSummary: String = "Checking request budget…"
    private(set) var linkOutcome: FileStore.FriendlyLinkOutcome?
    private(set) var setupProblem: String?
    private(set) var isRefreshing = false
    private(set) var lastRefreshMessage: String?
    var apiKeyField: String = ""
    var selectedInstrument: Instrument?

    // MARK: Collaborators

    private let store = FileStore()
    private let writer = ConfigWriter()
    private let log = LogSink.standard()
    private var watcher: ConfigWatcher?

    init(paths: AppPaths = .resolved()) {
        self.paths = paths
        runSetup()
        reload()
        startWatching()
    }

    // MARK: - Derived state

    var configuration: Configuration? { loadResult?.configuration }

    var diagnostics: [ConfigDiagnostic] { loadResult?.diagnostics ?? [] }

    var hasAPIKey: Bool { !(configuration?.apiKey.isEmpty ?? true) }

    /// True when the app and the widget are not sharing a container, which means the widget will
    /// show nothing however well everything else is configured. Almost always a missing Team ID.
    var appGroupUnavailable: Bool { !paths.isUsingAppGroupContainer }

    var instrumentCountSummary: String {
        guard let loadResult else { return "No configuration loaded" }
        if let notice = loadResult.truncationNotice { return notice }
        let count = loadResult.configuration.renderableInstruments.count
        return count == 1 ? "1 instrument configured" : "\(count) instruments configured"
    }

    var refreshWindowSummary: String {
        guard let configuration else { return "—" }
        let schedule = RefreshSchedule(configuration.refresh)
        let times = configuration.refresh.times.map(\.formatted).joined(separator: " and ")
        guard let next = schedule.nextBoundary(after: .now) else { return times }
        return "\(times) IST · next \(NumberFormatting.localClockTime(next)) local"
    }

    /// Rows as the widget would show them at a given size, for the in-app preview.
    func previewRows(limit: Int) -> [CacheRow] {
        cache?.rows(limit: limit) ?? []
    }

    // MARK: - Lifecycle

    func onAppear() {
        runSetup()
        reload()
        startWatching()
    }

    /// Creates the config, the example and README, and the friendly symlink.
    private func runSetup() {
        do {
            _ = try writer.bootstrap(at: paths)
            linkOutcome = try store.linkFriendlyConfigPath(to: paths.config)
            if case .blockedByRegularFile(let url) = linkOutcome {
                setupProblem = """
                    A real file already exists at \(url.path). Move it aside and reopen this app, \
                    and its contents will not be lost — the app will link that path to the config \
                    it actually reads.
                    """
            } else {
                setupProblem = nil
            }
        } catch {
            setupProblem = "Setup failed: \(error.localizedDescription)"
            log.error("setup: \(error.localizedDescription)", category: .config)
        }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let watcher = ConfigWatcher(url: paths.config) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: - Loading

    func reload() {
        if let previousMode = store.enforceOwnerOnly(paths.config) {
            log.warning(
                String(format: "config: file was mode %o; reset to 0600", previousMode),
                category: .config
            )
        }

        do {
            let result = try ConfigLoader().load(contentsOf: paths.config)
            loadResult = result
            loadError = nil
            if apiKeyField.isEmpty { apiKeyField = result.configuration.apiKey }
        } catch {
            // `ConfigLoader.load` has a typed `throws(ConfigError)`, so this is the only case.
            loadError = error
            log.error("config: \(error.userFacingReason)", category: .config)
        }

        cache = CacheStore(paths: paths).load()
        Task { await refreshBudgetSummary() }
    }

    private func refreshBudgetSummary() async {
        let limit = configuration?.refresh.maxRequestsPerDay ?? RefreshSettings.default.maxRequestsPerDay
        let schedule = RefreshSchedule(configuration?.refresh ?? .default)
        let budget = RequestBudget(paths: paths, limit: limit, schedule: schedule)
        budgetSummary = await budget.summary()
    }

    // MARK: - Actions

    func saveAPIKey() {
        let trimmed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !store.exists(paths.config) {
                _ = try writer.bootstrap(at: paths)
            }
            try writer.updateAPIKey(trimmed, in: paths.config)
            // Never log the value, only that it changed (§2).
            log.info("config: API key updated (\(Redaction.apiKey(trimmed)))", category: .config)
            reload()
            lastRefreshMessage = trimmed.isEmpty
                ? "API key cleared."
                : "API key saved. Press Refresh now to use it."
        } catch {
            lastRefreshMessage = "Could not save the key: \(error.localizedDescription)"
        }
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let coordinator = RefreshCoordinator(
            paths: paths,
            gate: RefreshGate(paths: paths),
            log: log
        )
        let outcome = await coordinator.refreshNow()

        cache = outcome.cache
        lastRefreshMessage = outcome.didFetch
            ? "\(outcome.reason) · \(outcome.cache.status.rawValue)"
            : outcome.reason
        await refreshBudgetSummary()

        if outcome.didFetch {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func revealConfigInFinder() {
        // Selects the real file rather than the symlink, so the user lands in the folder that also
        // holds README.txt and config.example.json.
        NSWorkspace.shared.activateFileViewerSelecting([paths.config])
    }

    func openConfigInEditor() {
        NSWorkspace.shared.open(paths.config)
    }

    func revealLogsInFinder() {
        try? store.ensureDirectory(AppPaths.logDirectory)
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logFile])
    }

    func handle(url: URL) {
        guard let (type, symbol) = InstrumentLink.instrument(from: url) else { return }
        selectedInstrument = configuration?.instruments.first {
            $0.type == type && $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame
        } ?? Instrument(type: type, symbol: symbol)
    }
}
