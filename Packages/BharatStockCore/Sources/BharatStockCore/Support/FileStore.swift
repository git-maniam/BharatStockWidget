import Foundation

/// Filesystem primitives with the two properties the product depends on:
/// writes are atomic (§6) and secrets stay owner-only (§2).
public struct FileStore: Sendable {
    /// Owner read/write only. The mode the config file must always have.
    public static let ownerOnly: mode_t = 0o600

    /// `FileManager` is not `Sendable`, so it is reached for per call rather than stored. Tests
    /// get their isolation from `AppPaths.root` pointing at a scratch directory, not from a
    /// substituted file manager.
    private var fileManager: FileManager { .default }

    public init() {}

    public func ensureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    /// Writes via a sibling temp file, flushes it to disk, then swaps it in.
    ///
    /// The widget must never observe a half-written cache, so the visible file only ever changes
    /// by an atomic rename. The temp file is a sibling because `replaceItemAt` cannot rename
    /// across filesystems.
    public func writeAtomically(_ data: Data, to url: URL, mode: mode_t? = nil) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)

        let temporary = directory.appending(
            path: "\(url.lastPathComponent).\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )

        // Create the temp file already restricted, so a secret is never briefly world-readable.
        let attributes: [FileAttributeKey: Any]? = mode.map {
            [.posixPermissions: NSNumber(value: $0)]
        }
        guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: attributes) else {
            throw FileStoreError.temporaryFileCreationFailed(temporary.path)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        // `replaceItemAt` can carry over the mode of the file it replaced, so re-assert.
        if let mode { try setPermissions(mode, on: url) }
    }

    public func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    // MARK: - Permissions

    public func permissions(of url: URL) throws -> mode_t {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.posixPermissions] as? NSNumber else {
            throw FileStoreError.permissionsUnreadable(url.path)
        }
        return mode_t(number.uint16Value) & 0o777
    }

    public func setPermissions(_ mode: mode_t, on url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    /// Re-asserts `0600` on a file that holds a secret.
    ///
    /// Returns the mode it found if it had to intervene, so the caller can log the warning
    /// §2 requires. Returns nil when the file was already correct or absent.
    @discardableResult
    public func enforceOwnerOnly(_ url: URL) -> mode_t? {
        guard exists(url), let current = try? permissions(of: url) else { return nil }
        guard current != FileStore.ownerOnly else { return nil }
        try? setPermissions(FileStore.ownerOnly, on: url)
        return current
    }

    // MARK: - The friendly symlink

    /// Points `~/Library/Application Support/BharatStockWidget/config.json` at the real file in
    /// the App Group container.
    ///
    /// Idempotent. Refuses to touch a *regular* file at the link path: that would be a config the
    /// user wrote before this mechanism existed, and silently deleting it would lose their data.
    public func linkFriendlyConfigPath(to target: URL) throws -> FriendlyLinkOutcome {
        let link = AppPaths.friendlyConfigLink
        if target.standardizedFileURL == link.standardizedFileURL {
            return .alreadyCorrect
        }
        try ensureDirectory(AppPaths.friendlyConfigDirectory)

        let existing = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
        if let existing {
            let resolved = URL(fileURLWithPath: existing, relativeTo: AppPaths.friendlyConfigDirectory)
            if resolved.standardizedFileURL == target.standardizedFileURL { return .alreadyCorrect }
            try fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            return .repointed(from: existing)
        }

        if fileManager.fileExists(atPath: link.path) {
            return .blockedByRegularFile(link)
        }

        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        return .created
    }

    public enum FriendlyLinkOutcome: Sendable, Equatable {
        case created
        case alreadyCorrect
        case repointed(from: String)
        /// A real file sits where the symlink belongs; the caller must ask the user what to do.
        case blockedByRegularFile(URL)
    }
}

public enum FileStoreError: Error, Sendable, Equatable {
    case temporaryFileCreationFailed(String)
    case permissionsUnreadable(String)
}
