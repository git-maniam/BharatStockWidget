import Foundation

/// Reads and writes `quotes.json`, the one file the widget and the app share.
///
/// Reads are tolerant by design: the widget's job is to render *something* legible, so a missing
/// or corrupt cache produces a status rather than an error the caller has to handle.
public struct CacheStore: Sendable {
    private let url: URL
    private let store: FileStore

    public init(paths: AppPaths, store: FileStore = FileStore()) {
        self.url = paths.quotesCache
        self.store = store
    }

    /// The cache, or nil if there has never been one.
    ///
    /// A cache written by a *newer* schema version still loads: unknown JSON keys are ignored by
    /// `Codable`, and the status/state enums fall back rather than throw, so a downgrade renders
    /// stale-but-sane data instead of nothing (§8).
    public func load() -> QuoteCache? {
        guard let data = try? store.read(url) else { return nil }
        return try? JSONCoding.decoder.decode(QuoteCache.self, from: data)
    }

    /// Whatever is on disk, or a legible placeholder. What the widget actually calls.
    public func loadForDisplay() -> QuoteCache {
        if let cache = load() { return cache }
        if store.exists(url) {
            return .empty(status: .partial, message: "Cache file could not be read")
        }
        return .empty(status: .stale, message: "No data yet — open BharatStock Widget to set up")
    }

    /// Atomic write, then nothing else: the caller reloads timelines, because this type has no
    /// business importing WidgetKit.
    public func save(_ cache: QuoteCache) throws {
        let data = try JSONCoding.encoder.encode(cache)
        try store.writeAtomically(data, to: url)
    }

    public var fileURL: URL { url }
}
