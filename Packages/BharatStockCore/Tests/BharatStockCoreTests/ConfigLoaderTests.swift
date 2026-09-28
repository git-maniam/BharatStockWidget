import Foundation
import Testing
@testable import BharatStockCore

@Suite("Config parsing")
struct ConfigLoaderTests {
    let loader = ConfigLoader()

    @Test("A well-formed file loads every field")
    func validConfig() throws {
        let result = try loader.parse(Data("""
        {
          "schemaVersion": 1,
          "apiKey": "bsk_live_example",
          "refresh": { "times": ["10:30", "21:30"], "timeZone": "Asia/Kolkata", "maxRequestsPerDay": 50 },
          "display": { "currencySymbol": "₹", "maxNameLength": 18, "showChangePercent": true, "decimalPlaces": 2 },
          "instruments": [
            { "type": "ST", "symbol": "RELIANCE", "name": "Reliance Industries" },
            { "type": "MF", "symbol": "122639" }
          ]
        }
        """.utf8))

        #expect(result.diagnostics.isEmpty)
        #expect(result.configuration.apiKey == "bsk_live_example")
        #expect(result.configuration.refresh.times == [DayTime(hour: 10, minute: 30), DayTime(hour: 21, minute: 30)])
        #expect(result.configuration.display.maxNameLength == 18)
        #expect(result.configuration.instruments.count == 2)
        #expect(result.configuration.instruments[0].name == "Reliance Industries")
        #expect(result.configuration.instruments[1].name == nil)
    }

    @Test("One bad entry among good ones is reported, not fatal")
    func oneBadEntry() throws {
        let result = try loader.parse(Data("""
        {
          "instruments": [
            { "type": "ST", "symbol": "RELIANCE" },
            { "type": "XX", "symbol": "NONSENSE" },
            { "type": "MF", "symbol": "122639" }
          ]
        }
        """.utf8))

        #expect(result.configuration.instruments.map(\.symbol) == ["RELIANCE", "122639"])
        #expect(result.declaredInstrumentCount == 3)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors[0].index == 1)
        #expect(errors[0].rawValue == "XX")
    }

    @Test("`type` is case-insensitive on read")
    func lenientType() throws {
        let result = try loader.parse(Data("""
        { "instruments": [ { "type": "st", "symbol": "tcs" }, { "type": " Mf ", "symbol": "122639" } ] }
        """.utf8))

        #expect(result.configuration.instruments.map(\.type) == [.stock, .mutualFund])
        // Tickers are normalised to upper case; scheme codes are left exactly as written.
        #expect(result.configuration.instruments.map(\.symbol) == ["TCS", "122639"])
    }

    @Test("A missing symbol is rejected with a type-appropriate hint")
    func missingSymbol() throws {
        let result = try loader.parse(Data("""
        { "instruments": [ { "type": "ST" }, { "type": "MF", "symbol": "  " } ] }
        """.utf8))

        #expect(result.configuration.instruments.isEmpty)
        let reasons = result.diagnostics.filter { $0.severity == .error }.map(\.reason)
        #expect(reasons.contains { $0.contains("NSE ticker") })
        #expect(reasons.contains { $0.contains("AMFI scheme code") })
    }

    @Test("A scheme code written as a JSON number still loads")
    func numericSchemeCode() throws {
        let result = try loader.parse(Data("""
        { "instruments": [ { "type": "MF", "symbol": 122639 } ] }
        """.utf8))

        #expect(result.configuration.instruments.first?.symbol == "122639")
        #expect(result.diagnostics.filter { $0.severity == .error }.isEmpty)
    }

    @Test("Duplicates are kept with a warning but fetched once")
    func duplicateSymbols() throws {
        let result = try loader.parse(Data("""
        {
          "instruments": [
            { "type": "ST", "symbol": "RELIANCE" },
            { "type": "ST", "symbol": "reliance" },
            { "type": "ST", "symbol": "TCS" }
          ]
        }
        """.utf8))

        #expect(result.configuration.instruments.count == 3)
        #expect(result.configuration.renderableInstruments.map(\.symbol) == ["RELIANCE", "TCS"])
        #expect(result.diagnostics.contains { $0.severity == .warning && $0.reason.contains("Duplicate") })
    }

    @Test("An empty instruments array warns rather than throwing")
    func emptyInstruments() throws {
        let result = try loader.parse(Data(#"{ "instruments": [] }"#.utf8))
        #expect(result.configuration.instruments.isEmpty)
        #expect(result.diagnostics.contains { $0.reason.contains("empty") })
    }

    @Test("Twenty entries are all parsed; only fifteen are renderable")
    func twentyEntries() throws {
        let entries = (1...20).map { #"{ "type": "ST", "symbol": "SYM\#($0)" }"# }
        let result = try loader.parse(Data(#"{ "instruments": [\#(entries.joined(separator: ","))] }"#.utf8))

        #expect(result.configuration.instruments.count == 20)
        #expect(result.configuration.renderableInstruments.count == 15)
        #expect(result.declaredInstrumentCount == 20)
        #expect(result.truncationNotice == "20 instruments configured, 15 shown at Extra Large")
    }

    @Test("Unknown keys are ignored, not fatal")
    func unknownKeys() throws {
        let result = try loader.parse(Data("""
        {
          "schemaVersion": 1,
          "somethingNew": { "nested": true },
          "instruments": [ { "type": "ST", "symbol": "TCS", "futureField": 42 } ]
        }
        """.utf8))

        #expect(result.configuration.instruments.map(\.symbol) == ["TCS"])
        #expect(result.diagnostics.filter { $0.severity == .error }.isEmpty)
    }

    @Test("A newer schemaVersion loads with a warning")
    func forwardCompatibleSchema() throws {
        let result = try loader.parse(Data("""
        { "schemaVersion": 2, "instruments": [ { "type": "ST", "symbol": "TCS" } ] }
        """.utf8))

        #expect(result.configuration.instruments.count == 1)
        #expect(result.diagnostics.contains { $0.reason.contains("newer version") })
    }

    @Test("Total garbage throws, so the caller can keep the last good cache")
    func totalGarbage() {
        #expect(throws: ConfigError.self) {
            _ = try loader.parse(Data("this is not JSON at all {{{".utf8), path: "/tmp/x")
        }
    }

    @Test("A JSON array at the top level is rejected as not-an-object")
    func topLevelArray() {
        #expect(throws: ConfigError.notAnObject(path: "/tmp/x")) {
            _ = try loader.parse(Data("[1,2,3]".utf8), path: "/tmp/x")
        }
    }

    @Test("Out-of-range and malformed settings fall back with warnings")
    func invalidSettings() throws {
        let result = try loader.parse(Data("""
        {
          "refresh": { "times": ["99:99", "nope"], "timeZone": "Mars/Olympus", "maxRequestsPerDay": 0 },
          "display": { "maxNameLength": 900, "decimalPlaces": 99 },
          "instruments": [ { "type": "ST", "symbol": "TCS" } ]
        }
        """.utf8))

        #expect(result.configuration.refresh.times == RefreshSettings.default.times)
        #expect(result.configuration.refresh.timeZoneIdentifier == "Asia/Kolkata")
        #expect(result.configuration.refresh.maxRequestsPerDay == 50)
        #expect(result.configuration.display.maxNameLength == 18)
        #expect(result.configuration.display.decimalPlaces == 2)
        #expect(result.configuration.instruments.count == 1)
    }

    @Test("The spec's original single `time` field still works")
    func legacySingleTime() throws {
        let result = try loader.parse(Data("""
        { "refresh": { "time": "10:30" }, "instruments": [ { "type": "ST", "symbol": "TCS" } ] }
        """.utf8))

        #expect(result.configuration.refresh.times == [DayTime(hour: 10, minute: 30)])
    }

    @Test("A file written to disk at 0600 keeps that mode")
    func configPermissions() throws {
        let root = TempRoot()
        try root.writeConfig(#"{ "instruments": [ { "type": "ST", "symbol": "TCS" } ] }"#)

        let store = FileStore()
        #expect(try store.permissions(of: root.paths.config) == FileStore.ownerOnly)

        // Loosen it the way a careless `chmod` would, then confirm the enforcement fixes it.
        try store.setPermissions(0o644, on: root.paths.config)
        let previous = store.enforceOwnerOnly(root.paths.config)
        #expect(previous == 0o644)
        #expect(try store.permissions(of: root.paths.config) == FileStore.ownerOnly)
        // Idempotent: a second pass reports nothing to fix.
        #expect(store.enforceOwnerOnly(root.paths.config) == nil)
    }
}
