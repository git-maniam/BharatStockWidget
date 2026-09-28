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

    /// The real App Group container, or nil when entitlements are missing, the group is
    /// unregistered, or we are running an ad-hoc build without a Team ID.
    ///
    /// On macOS, App Sandbox only permits access to Group Containers when the identifier is
    /// prefixed with a registered Apple Developer Team ID (`<TeamID>.group.…`).
    /// For ad-hoc / local builds without a Team ID (e.g. `group.…`), macOS App Sandbox blocks
    /// access to `~/Library/Group Containers/`, causing file operations to throw permission denied.
    public static func appGroupContainer(
        identifier: String = AppIdentity.appGroupIdentifier
    ) -> URL? {
        guard identifier.contains(".group.") else {
            return nil
        }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return nil
        }
        let probe = url.appending(path: ".probe_\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .notDirectory)
        do {
            try Data().write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
            return url
        } catch {
            return nil
        }
    }

    /// Directory used for local development when no Apple Developer Team ID is available.
    ///
    /// Both the sandboxed widget extension and the unsandboxed companion app use the widget's
    /// container directory, allowing the widget to read and write without sandbox permission denials.
    public static func localSharedContainerURL() -> URL {
        let appSupport = URL.applicationSupportDirectory
        if appSupport.path().contains("/Containers/\(AppIdentity.widgetBundleID)/") {
            return appSupport.appending(path: "BharatStockWidget", directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(
                path: "Library/Containers/\(AppIdentity.widgetBundleID)/Data/Library/Application Support/BharatStockWidget",
                directoryHint: .isDirectory
            )
    }

    /// Paths for normal operation. Falls back to the widget's local container directory
    /// so an ad-hoc or sandbox-less build still functions without permission errors.
    public static func resolved() -> AppPaths {
        if let container = appGroupContainer() {
            return AppPaths(root: container)
        }
        return AppPaths(root: localSharedContainerURL())
    }

    /// True when we are using a shared container (either via an official App Group or local container sharing).
    public var isUsingAppGroupContainer: Bool {
        AppPaths.appGroupContainer() != nil || root.path().contains("/Containers/\(AppIdentity.widgetBundleID)/")
    }
}
