import Foundation

/// A problem found while parsing the config, precise enough to fix without guessing (§4).
public struct ConfigDiagnostic: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable, Equatable {
        /// The value was ignored and a default used; the file is still usable.
        case warning
        /// The entry was dropped entirely.
        case error
    }

    /// Index into the raw `instruments` array, or nil for a file-level problem.
    public var index: Int?
    public var rawValue: String
    public var reason: String
    public var severity: Severity

    public var id: String { "\(index.map(String.init) ?? "file"):\(reason):\(rawValue)" }

    public init(index: Int?, rawValue: String, reason: String, severity: Severity) {
        self.index = index
        self.rawValue = rawValue
        self.reason = reason
        self.severity = severity
    }
}

/// The outcome of a permissive parse: whatever was valid, plus everything that wasn't.
public struct ConfigLoadResult: Sendable, Equatable {
    public var configuration: Configuration
    public var diagnostics: [ConfigDiagnostic]
    /// How many entries the file declared, before dropping invalid ones or truncating to 15.
    /// Surfaced in the app so truncation is never silent (§4).
    public var declaredInstrumentCount: Int

    public init(configuration: Configuration, diagnostics: [ConfigDiagnostic], declaredInstrumentCount: Int) {
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.declaredInstrumentCount = declaredInstrumentCount
    }

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    /// Human-readable truncation notice, or nil when nothing is hidden.
    public var truncationNotice: String? {
        let shown = configuration.renderableInstruments.count
        guard declaredInstrumentCount > Configuration.maxRenderableInstruments else { return nil }
        return "\(declaredInstrumentCount) instruments configured, \(shown) shown at Extra Large"
    }
}

/// Raised only when the file cannot be treated as JSON at all. Every lesser problem
/// becomes a diagnostic instead, so one bad entry never sinks the file (§4).
public enum ConfigError: Error, Sendable, Equatable {
    case unreadable(path: String, underlying: String)
    case notJSON(path: String, underlying: String)
    case notAnObject(path: String)

    public var userFacingReason: String {
        switch self {
        case .unreadable(_, let underlying): "Config file could not be read: \(underlying)"
        case .notJSON(_, let underlying): "Config file is not valid JSON: \(underlying)"
        case .notAnObject: "Config file must contain a JSON object at the top level"
        }
    }
}

/// Parses `config.json` by hand-walking the JSON tree.
///
/// Deliberately not `Decodable`: `Codable` fails the whole document on the first bad value,
/// and §4 requires that a single malformed entry be reported and skipped while everything
/// around it still loads. Hand-walking also makes "unknown keys are ignored, not fatal" the
/// natural behaviour rather than something to opt into.
public struct ConfigLoader: Sendable {
    public init() {}

    public func load(contentsOf url: URL) throws(ConfigError) -> ConfigLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable(path: url.path, underlying: error.localizedDescription)
        }
        return try parse(data, path: url.path)
    }

    public func parse(_ data: Data, path: String = "<memory>") throws(ConfigError) -> ConfigLoadResult {
        let top: Any
        do {
            top = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ConfigError.notJSON(path: path, underlying: error.localizedDescription)
        }
        guard let object = top as? [String: Any] else {
            throw ConfigError.notAnObject(path: path)
        }

        var diagnostics: [ConfigDiagnostic] = []

        let schemaVersion = object.intValue("schemaVersion") ?? Configuration.currentSchemaVersion
        if schemaVersion > Configuration.currentSchemaVersion {
            diagnostics.append(ConfigDiagnostic(
                index: nil,
                rawValue: String(schemaVersion),
                reason: "Config was written by a newer version (schemaVersion \(schemaVersion)); "
                      + "unrecognised settings are being ignored",
                severity: .warning
            ))
        }

        let apiKey = (object["apiKey"] as? String) ?? ""

        let refresh = parseRefresh(object["refresh"], into: &diagnostics)
        let display = parseDisplay(object["display"], into: &diagnostics)
        let (instruments, declaredCount) = parseInstruments(object["instruments"], into: &diagnostics)

        let configuration = Configuration(
            schemaVersion: schemaVersion,
            apiKey: apiKey,
            refresh: refresh,
            display: display,
            instruments: instruments
        )
        return ConfigLoadResult(
            configuration: configuration,
            diagnostics: diagnostics,
            declaredInstrumentCount: declaredCount
        )
    }

    // MARK: - Sections

    private func parseRefresh(_ raw: Any?, into diagnostics: inout [ConfigDiagnostic]) -> RefreshSettings {
        var settings = RefreshSettings.default
        guard let object = raw as? [String: Any] else {
            if raw != nil, !(raw is NSNull) {
                diagnostics.append(ConfigDiagnostic(
                    index: nil, rawValue: describe(raw),
                    reason: "`refresh` must be an object; using defaults", severity: .warning
                ))
            }
            return settings
        }

        // `times: ["10:30", "21:30"]` is current; a bare `time: "10:30"` is the spec's original
        // single-window form and still decodes.
        if let list = object["times"] as? [Any] {
            var parsed: [DayTime] = []
            for entry in list {
                guard let text = entry as? String, let time = DayTime(text) else {
                    diagnostics.append(ConfigDiagnostic(
                        index: nil, rawValue: describe(entry),
                        reason: "`refresh.times` entries must be \"HH:mm\"; this one was skipped",
                        severity: .warning
                    ))
                    continue
                }
                parsed.append(time)
            }
            if parsed.isEmpty {
                diagnostics.append(ConfigDiagnostic(
                    index: nil, rawValue: describe(object["times"]),
                    reason: "`refresh.times` had no usable entries; using \(RefreshSettings.default.times.map(\.formatted).joined(separator: ", "))",
                    severity: .warning
                ))
            } else {
                settings.times = parsed.sorted()
            }
        } else if let single = object["time"] as? String {
            if let time = DayTime(single) {
                settings.times = [time]
            } else {
                diagnostics.append(ConfigDiagnostic(
                    index: nil, rawValue: single,
                    reason: "`refresh.time` must be \"HH:mm\"; using defaults", severity: .warning
                ))
            }
        }

        if let zone = object["timeZone"] as? String {
            if TimeZone(identifier: zone) != nil {
                settings.timeZoneIdentifier = zone
            } else {
                diagnostics.append(ConfigDiagnostic(
                    index: nil, rawValue: zone,
                    reason: "Unknown time zone identifier; using Asia/Kolkata", severity: .warning
                ))
            }
        }

        if let limit = object.intValue("maxRequestsPerDay") {
            if limit >= 1 {
                settings.maxRequestsPerDay = limit
            } else {
                diagnostics.append(ConfigDiagnostic(
                    index: nil, rawValue: String(limit),
                    reason: "`maxRequestsPerDay` must be at least 1; using 50", severity: .warning
                ))
            }
        }
        return settings
    }

    private func parseDisplay(_ raw: Any?, into diagnostics: inout [ConfigDiagnostic]) -> DisplaySettings {
        var settings = DisplaySettings.default
        guard let object = raw as? [String: Any] else {
            if raw != nil, !(raw is NSNull) {
                diagnostics.append(ConfigDiagnostic(
                    index: nil, rawValue: describe(raw),
                    reason: "`display` must be an object; using defaults", severity: .warning
                ))
            }
            return settings
        }

        if let symbol = object["currencySymbol"] as? String, !symbol.isEmpty {
            settings.currencySymbol = symbol
        }
        if let length = object.intValue("maxNameLength") {
            if (4...64).contains(length) {
                settings.maxNameLength = length
            } else {
                diagnostics.append(ConfigDiagnostic(
                    index: nil, rawValue: String(length),
                    reason: "`maxNameLength` must be 4–64; using 18", severity: .warning
                ))
            }
        }
        if let show = object["showChangePercent"] as? Bool {
            settings.showChangePercent = show
        }
        if let places = object.intValue("decimalPlaces") {
            if (0...6).contains(places) {
                settings.decimalPlaces = places
            } else {
                diagnostics.append(ConfigDiagnostic(
                    index: nil, rawValue: String(places),
                    reason: "`decimalPlaces` must be 0–6; using 2", severity: .warning
                ))
            }
        }
        return settings
    }

    private func parseInstruments(
        _ raw: Any?,
        into diagnostics: inout [ConfigDiagnostic]
    ) -> (instruments: [Instrument], declaredCount: Int) {
        guard let list = raw as? [Any] else {
            diagnostics.append(ConfigDiagnostic(
                index: nil, rawValue: describe(raw),
                reason: raw == nil
                    ? "`instruments` is missing; the widget has nothing to show"
                    : "`instruments` must be an array; the widget has nothing to show",
                severity: .error
            ))
            return ([], 0)
        }
        if list.isEmpty {
            diagnostics.append(ConfigDiagnostic(
                index: nil, rawValue: "[]",
                reason: "`instruments` is empty; add at least one entry to see anything",
                severity: .warning
            ))
            return ([], 0)
        }

        var instruments: [Instrument] = []
        var seen: [String: Int] = [:]

        for (index, entry) in list.enumerated() {
            guard let object = entry as? [String: Any] else {
                diagnostics.append(ConfigDiagnostic(
                    index: index, rawValue: describe(entry),
                    reason: "Entry must be an object like { \"type\": \"ST\", \"symbol\": \"RELIANCE\" }",
                    severity: .error
                ))
                continue
            }

            guard let rawType = object["type"] as? String else {
                diagnostics.append(ConfigDiagnostic(
                    index: index, rawValue: describe(object["type"]),
                    reason: "Missing `type`; must be \"ST\" (stock) or \"MF\" (mutual fund)",
                    severity: .error
                ))
                continue
            }
            guard let type = InstrumentType(lenient: rawType) else {
                diagnostics.append(ConfigDiagnostic(
                    index: index, rawValue: rawType,
                    reason: "Unknown `type`; must be \"ST\" (stock) or \"MF\" (mutual fund)",
                    severity: .error
                ))
                continue
            }

            // Numeric scheme codes are an easy mistake to make in JSON, so accept 122639
            // as well as "122639" rather than rejecting a file over a pair of quotes.
            let rawSymbol: String?
            switch object["symbol"] {
            case let text as String: rawSymbol = text
            case let number as NSNumber: rawSymbol = number.stringValue
            default: rawSymbol = nil
            }
            guard let symbol = rawSymbol?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !symbol.isEmpty
            else {
                diagnostics.append(ConfigDiagnostic(
                    index: index, rawValue: describe(object["symbol"]),
                    reason: type == .stock
                        ? "Missing `symbol`; use the NSE ticker, e.g. \"RELIANCE\""
                        : "Missing `symbol`; use the AMFI scheme code, e.g. \"122639\"",
                    severity: .error
                ))
                continue
            }

            let normalisedSymbol = type == .stock ? symbol.uppercased() : symbol
            let candidate = Instrument(
                type: type,
                symbol: normalisedSymbol,
                name: (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            )

            if let first = seen[candidate.id] {
                diagnostics.append(ConfigDiagnostic(
                    index: index, rawValue: candidate.id,
                    reason: "Duplicate of entry \(first); it will be fetched and shown once",
                    severity: .warning
                ))
            } else {
                seen[candidate.id] = index
            }
            instruments.append(candidate)
        }

        if instruments.isEmpty {
            diagnostics.append(ConfigDiagnostic(
                index: nil, rawValue: "\(list.count) entries",
                reason: "No valid instruments survived parsing; fix the errors above",
                severity: .error
            ))
        }
        return (instruments, list.count)
    }

    private func describe(_ value: Any?) -> String {
        switch value {
        case .none: "(absent)"
        case is NSNull: "null"
        case let text as String: "\"\(text)\""
        case let number as NSNumber: number.stringValue
        case let array as [Any]: "(array of \(array.count))"
        case let object as [String: Any]:
            "{\(object.keys.sorted().joined(separator: ", "))}"
        case .some(let other): String(describing: other)
        }
    }
}

// MARK: - Lenient scalar access

extension [String: Any] {
    /// Reads an integer that may have been written as `50`, `50.0`, or `"50"`.
    fileprivate func intValue(_ key: String) -> Int? {
        switch self[key] {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
