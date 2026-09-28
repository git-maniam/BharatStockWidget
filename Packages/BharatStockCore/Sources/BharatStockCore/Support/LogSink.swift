import Foundation
import Synchronization
import os

/// Logging with two sinks, as spec §8 requires: `os.Logger` for Console.app and a rotating
/// plaintext file a non-technical user can attach to a bug report.
///
/// The API key is scrubbed on the way into both.
public struct LogSink: Sendable {
    public enum Category: String, Sendable, CaseIterable {
        case config, api, budget, widget, cache
    }

    public enum Level: String, Sendable {
        case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR"
    }

    private let isEnabled: Bool
    private let writesToFile: Bool
    /// Held solely so it can be scrubbed out of message text. Never itself logged.
    private let apiKey: String

    /// Discards everything. The default for tests, so a test run does not litter `~/Library/Logs`.
    public static let none = LogSink(isEnabled: false, writesToFile: false, apiKey: "")

    public static func standard(apiKey: String = "", writesToFile: Bool = true) -> LogSink {
        LogSink(isEnabled: true, writesToFile: writesToFile, apiKey: apiKey)
    }

    private init(isEnabled: Bool, writesToFile: Bool, apiKey: String) {
        self.isEnabled = isEnabled
        self.writesToFile = writesToFile
        self.apiKey = apiKey
    }

    /// Returns a copy that knows the key, so it can scrub it. Call once the config is loaded.
    public func scrubbing(apiKey: String) -> LogSink {
        LogSink(isEnabled: isEnabled, writesToFile: writesToFile, apiKey: apiKey)
    }

    public func debug(_ message: String, category: Category) { emit(.debug, message, category) }
    public func info(_ message: String, category: Category) { emit(.info, message, category) }
    public func warning(_ message: String, category: Category) { emit(.warning, message, category) }
    public func error(_ message: String, category: Category) { emit(.error, message, category) }

    private func emit(_ level: Level, _ message: String, _ category: Category) {
        guard isEnabled else { return }
        let safe = Redaction.scrub(message, key: apiKey)

        let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: category.rawValue)
        // Interpolated as `public`: the message is already scrubbed, and a redacted log is
        // useless for the bug reports this exists to support.
        switch level {
        case .debug: logger.debug("\(safe, privacy: .public)")
        case .info: logger.info("\(safe, privacy: .public)")
        case .warning: logger.warning("\(safe, privacy: .public)")
        case .error: logger.error("\(safe, privacy: .public)")
        }

        if writesToFile {
            RotatingFileLog.shared.append(
                "\(JSONCoding.iso8601String(.now)) [\(level.rawValue)] [\(category.rawValue)] \(safe)\n"
            )
        }
    }
}

/// Append-only text log, capped at 1 MB with one generation of rotation (§8).
///
/// Synchronous and mutex-guarded rather than actor-based so log lines keep their order and a
/// caller never has to `await` to record one.
final class RotatingFileLog: Sendable {
    static let shared = RotatingFileLog()

    private static let maxBytes = 1024 * 1024
    private let state = Mutex<Bool>(false)  // tracks whether the directory has been ensured

    private init() {}

    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = AppPaths.logFile

        state.withLock { directoryReady in
            if !directoryReady {
                try? FileManager.default.createDirectory(
                    at: AppPaths.logDirectory, withIntermediateDirectories: true
                )
                directoryReady = true
            }

            rotateIfNeeded(url: url)

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func rotateIfNeeded(url: URL) {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= Self.maxBytes
        else { return }

        let previous = url.appendingPathExtension("1")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: url, to: previous)
    }
}
