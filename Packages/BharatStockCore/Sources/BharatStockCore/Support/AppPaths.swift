import Foundation

/// Identity constants shared by the app and the widget extension.
public enum AppIdentity {
    public static let bundlePrefix = "com.ravisubramaniam"
    public static let appBundleID = "\(bundlePrefix).bharatstockwidget"
    public static let widgetBundleID = "\(appBundleID).widget"
    public static let loggingSubsystem = appBundleID

    /// The unprefixed App Group name.
    ///
    /// On macOS the *resolvable* group identifier is Team-ID-prefixed (`ABCDE12345.group.…`),
    /// and the Team ID is only known once the project is signed. Both targets therefore carry
    /// `BSWAppGroupIdentifier` in their Info.plist, generated from the build setting, and that
    /// value wins at runtime. The bare name below is the fallback used by tests and the CLI.
    public static let appGroupFallback = "group.\(bundlePrefix).bharatstockwidget"

    public static var appGroupIdentifier: String {
        let key = "BSWAppGroupIdentifier"
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty {
            let trimmed = value.hasPrefix(".") ? String(value.dropFirst()) : value
            return trimmed.isEmpty ? appGroupFallback : trimmed
        }
        return appGroupFallback
    }
}

/// Every file location the product owns, rooted at one directory.
///
/// `root` is injectable so tests and `--dry-run` can operate on a scratch directory rather
/// than the real App Group container.
public struct AppPaths: Sendable, Equatable {
    /// The App Group container, or a substitute for tests and CLI use.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Files

    /// Canonical config. Lives here, not under `~/Library/Application Support`, because a
    /// sandboxed widget extension cannot read the latter (see `docs/decisions.md` §2).
    public var config: URL { root.appending(path: "config.json", directoryHint: .notDirectory) }

    public var configExample: URL {
        root.appending(path: "config.example.json", directoryHint: .notDirectory)
    }

    public var configReadme: URL { root.appending(path: "README.txt", directoryHint: .notDirectory) }

    public var cacheDirectory: URL {
        root.appending(path: "Library/Caches", directoryHint: .isDirectory)
    }

    /// The helper→widget contract file of spec §6.
    public var quotesCache: URL {
        cacheDirectory.appending(path: "quotes.json", directoryHint: .notDirectory)
    }

    public var budget: URL { root.appending(path: "budget.json", directoryHint: .notDirectory) }

    /// Tracks which refresh windows have already been served, so the gate can cap the day's
    /// fetches at one per window no matter how often WidgetKit wakes the extension.
    public var refreshState: URL {
        root.appending(path: "refresh-state.json", directoryHint: .notDirectory)
    }

    // MARK: - The friendly path

    /// The hand-editable path the spec documents. The app maintains this as a symlink into the
    /// App Group container: the user's editor is not sandboxed, so it follows the link happily,
    /// while the widget reads `config` directly.
    public static var friendlyConfigDirectory: URL {
        URL.applicationSupportDirectory.appending(
            path: "BharatStockWidget", directoryHint: .isDirectory
        )
    }

    public static var friendlyConfigLink: URL {
        friendlyConfigDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    }

    public static var logDirectory: URL {
        URL.libraryDirectory.appending(path: "Logs/BharatStockWidget", directoryHint: .isDirectory)
    }

    public static var logFile: URL {
        logDirectory.appending(path: "helper.log", directoryHint: .notDirectory)
    }

    // MARK: - Resolution

    /// The real App Group container, or nil when entitlements are missing or the group is
    /// unregistered — which is exactly what an unsigned build looks like.
    public static func appGroupContainer(
        identifier: String = AppIdentity.appGroupIdentifier
    ) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Paths for normal operation. Falls back to `~/Library/Application Support/BharatStockWidget`
    /// so an unsigned or sandbox-less build (notably the `--dry-run` tool) still functions.
    public static func resolved() -> AppPaths {
        if let container = appGroupContainer() {
            return AppPaths(root: container)
        }
        return AppPaths(root: friendlyConfigDirectory)
    }

    /// True when we fell back, i.e. the widget and app are *not* sharing a container.
    /// The app surfaces this because it means the widget will show nothing.
    public var isUsingAppGroupContainer: Bool {
        AppPaths.appGroupContainer().map { $0.standardizedFileURL == root.standardizedFileURL } ?? false
    }
}
